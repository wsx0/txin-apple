//
//  Crypto.swift
//  TxinKit
//
//  糖心协议用到的全部密码学原语。
//  - HMAC-SHA256        -> CryptoKit
//  - AES-256/128-CBC    -> CommonCrypto (CCCrypt)，PKCS7 由系统补齐
//  - gzip / gunzip      -> Gzip.swift（raw deflate + 自写 header/CRC32）
//

import Foundation
import CryptoKit
import CommonCrypto
import Security

public enum TxinCryptoError: Error, CustomStringConvertible {
    case badKeyLength(Int)
    case cryptFailed(Int32)
    case badBase64
    case badHex

    public var description: String {
        switch self {
        case .badKeyLength(let n): return "密钥长度非法: \(n) 字节"
        case .cryptFailed(let s): return "CCCrypt 失败, status=\(s)"
        case .badBase64: return "Base64 解码失败"
        case .badHex: return "Hex 解码失败"
        }
    }
}

public enum TxinCrypto {

    // MARK: - Hex / Base64

    public static func hexToBytes(_ hex: String) throws -> [UInt8] {
        let s = hex.replacingOccurrences(of: "-", with: "")
        guard s.count % 2 == 0 else { throw TxinCryptoError.badHex }
        var out = [UInt8]()
        out.reserveCapacity(s.count / 2)
        var idx = s.startIndex
        while idx < s.endIndex {
            let next = s.index(idx, offsetBy: 2)
            guard let b = UInt8(s[idx..<next], radix: 16) else { throw TxinCryptoError.badHex }
            out.append(b)
            idx = next
        }
        return out
    }

    public static func bytesToHex(_ bytes: [UInt8]) -> String {
        var s = ""
        s.reserveCapacity(bytes.count * 2)
        for b in bytes {
            s += String(format: "%02x", b)
        }
        return s
    }

    public static func base64Decode(_ s: String) throws -> [UInt8] {
        var t = s
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: " ", with: "")
        while t.count % 4 != 0 { t += "=" }
        guard let data = Data(base64Encoded: t, options: [.ignoreUnknownCharacters]) else {
            throw TxinCryptoError.badBase64
        }
        return [UInt8](data)
    }

    // MARK: - HMAC-SHA256

    /// 服务端语义：CryptoJS.HmacSHA256(message = hex(requestId), key = Utf8.parse(secret))
    /// 即 message 是 requestId 去掉横线后的十六进制字节，HMAC key 是 secret 的 UTF-8 字节。
    public static func deriveKey(requestId: String, secret: String) throws -> [UInt8] {
        let msg = try hexToBytes(requestId)
        let key = SymmetricKey(data: Data(secret.utf8))
        let mac = HMAC<SHA256>.authenticationCode(for: Data(msg), using: key)
        return [UInt8](mac)
    }

    // MARK: - AES-CBC

    /// AES-CBC + PKCS7。key 长度 16/24/32 分别对应 AES-128/192/256。
    public static func aesCBCDecrypt(key: [UInt8], iv: [UInt8], cipher: [UInt8]) throws -> [UInt8] {
        return try cbc(op: CCOperation(kCCDecrypt), key: key, iv: iv, data: cipher, padding: true)
    }

    public static func aesCBCEncrypt(key: [UInt8], iv: [UInt8], plain: [UInt8]) throws -> [UInt8] {
        return try cbc(op: CCOperation(kCCEncrypt), key: key, iv: iv, data: plain, padding: true)
    }

    /// AES-ECB（会话 cookie 用），无 IV。PKCS7。
    public static func aesECBDecrypt(key: [UInt8], cipher: [UInt8]) throws -> [UInt8] {
        return try cbc(op: CCOperation(kCCDecrypt), key: key, iv: nil, data: cipher, padding: true, ecb: true)
    }

    /// AES-CBC 无 padding —— HLS 的 TS 分片是整块，补了反而坏
    public static func aesCBCDecryptNoPadding(key: [UInt8], iv: [UInt8], cipher: [UInt8]) throws -> [UInt8] {
        return try cbc(op: CCOperation(kCCDecrypt), key: key, iv: iv, data: cipher, padding: false)
    }

    private static func cbc(op: CCOperation,
                            key: [UInt8],
                            iv: [UInt8]?,
                            data: [UInt8],
                            padding: Bool,
                            ecb: Bool = false) throws -> [UInt8] {
        guard [16, 24, 32].contains(key.count) else {
            throw TxinCryptoError.badKeyLength(key.count)
        }
        var options: CCOptions = 0
        if padding { options |= CCOptions(kCCOptionPKCS7Padding) }
        if ecb { options |= CCOptions(kCCOptionECBMode) }

        let outCapacity = data.count + kCCBlockSizeAES128
        var out = [UInt8](repeating: 0, count: outCapacity)
        var outLength: size_t = 0

        // 注意：iv 的指针必须 alive 到 CCCrypt 调用结束。
        // 以前的写法是
        //     let ivPtr = iv?.withUnsafeBytes { $0.baseAddress }
        //     CCCrypt(..., ivPtr, ...)
        // 闭包一返回指针就悬垂了，属于未定义行为 —— 表现为解密"有时成功有时失败"，
        // HLS 分片则一律失败并被 ?? data 静默吞掉，把密文写进了文件。
        let status: CCCryptorStatus = key.withUnsafeBytes { keyBuf -> CCCryptorStatus in
            data.withUnsafeBytes { dataBuf -> CCCryptorStatus in
                let keyBase = keyBuf.baseAddress
                let dataBase = dataBuf.baseAddress
                if let iv {
                    return iv.withUnsafeBytes { ivBuf in
                        CCCrypt(op,
                                CCAlgorithm(kCCAlgorithmAES),
                                options,
                                keyBase, key.count,
                                ivBuf.baseAddress,
                                dataBase, data.count,
                                &out, outCapacity,
                                &outLength)
                    }
                } else {
                    return CCCrypt(op,
                                   CCAlgorithm(kCCAlgorithmAES),
                                   options,
                                   keyBase, key.count,
                                   nil,
                                   dataBase, data.count,
                                   &out, outCapacity,
                                   &outLength)
                }
            }
        }
        guard status == kCCSuccess else { throw TxinCryptoError.cryptFailed(Int32(status)) }
        return Array(out[0..<outLength])
    }

    // MARK: - 随机

    public static func randomBytes(_ n: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: n)
        if SecRandomCopyBytes(kSecRandomDefault, n, &bytes) != errSecSuccess {
            for i in 0..<n { bytes[i] = UInt8.random(in: 0...255) }
        }
        return bytes
    }

    /// RFC 4122 v4，格式与 crypto.randomUUID() 一致
    public static func uuidv4() -> String {
        var b = randomBytes(16)
        b[6] = (b[6] & 0x0F) | 0x40
        b[8] = (b[8] & 0x3F) | 0x80
        let hex = bytesToHex(b)
        let ranges = [0..<8, 8..<12, 12..<16, 16..<20, 20..<32]
        let parts = ranges.map { r -> String in
            let start = hex.index(hex.startIndex, offsetBy: r.lowerBound)
            let end = hex.index(hex.startIndex, offsetBy: r.upperBound)
            return String(hex[start..<end])
        }
        return parts.joined(separator: "-")
    }

    /// 与 Date.now().toString().slice(0, 11) 等价：13 位毫秒时间戳的前 11 位
    public static func shortTimestamp() -> String {
        let ms = Int64(Date().timeIntervalSince1970 * 1000)
        let s = String(ms)
        return String(s.prefix(11))
    }
}
