//
//  TxinImage.swift
//  TxinKit
//
//  站点的图片全部是 `.bnc` 后缀 —— 不是普通图片，是 AES-128-ECB 加密过的。
//
//  前端逻辑（js/vBZPwP3J.js 的 decode-image 组件）：
//      xhr.responseType = 'arraybuffer'
//      decryptBase64(base64(resp), img_key)
//        = CryptoJS.AES.decrypt(cipher, Utf8.parse(img_key), { mode: ECB })
//              .toString(Base64)
//
//  等价于：AES-128-ECB + PKCS7 解密，key 是 img_key 的 UTF-8 字节（16 字符 = 16 字节）。
//  实测三个样本解出的都是标准 JPEG（ff d8 ff ...）。
//

import Foundation

public enum TxinImage {

    // MARK: - 当前 img_key

    final class State: @unchecked Sendable {
        static let shared = State()
        private let lock = NSLock()
        private var value = ""

        var key: String {
            get {
                lock.lock()
                defer { lock.unlock() }
                return value
            }
            set {
                lock.lock()
                defer { lock.unlock() }
                value = newValue
            }
        }
    }

    /// 来自 /system/info 的 img_key，systemInfo() 拿到后会写进这里
    public static var imgKey: String {
        get { State.shared.key }
        set { State.shared.key = newValue }
    }

    // MARK: - 解密

    /// `.bnc` 数据 → 真实图片字节。不是 .bnc、缺 key、解密失败时原样返回。
    public static func decodeIfNeeded(_ data: [UInt8], url: String) -> [UInt8] {
        guard url.contains(".bnc") else { return data }
        let k = imgKey
        guard !k.isEmpty else { return data }
        let key = Array(k.utf8)
        guard [16, 24, 32].contains(key.count) else { return data }
        guard let plain = try? TxinCrypto.aesECBDecrypt(key: key, cipher: data) else {
            return data
        }
        // 解出来不像图片就退回原数据（可能是没加密的资源）
        return looksLikeImage(plain) ? plain : data
    }

    /// 判断字节像不像常见图片
    public static func looksLikeImage(_ b: [UInt8]) -> Bool {
        guard b.count >= 12 else { return false }
        if b[0] == 0xFF, b[1] == 0xD8, b[2] == 0xFF { return true }                 // JPEG
        if b[0] == 0x89, b[1] == 0x50, b[2] == 0x4E, b[3] == 0x47 { return true }   // PNG
        if b[0] == 0x47, b[1] == 0x49, b[2] == 0x46 { return true }                 // GIF
        if b[0] == 0x52, b[1] == 0x49, b[2] == 0x46, b[3] == 0x46,
           b[8] == 0x57, b[9] == 0x45, b[10] == 0x42, b[11] == 0x50 { return true } // WEBP
        return false
    }

    /// 猜扩展名，仅用于调试日志
    public static func sniff(_ b: [UInt8]) -> String {
        guard b.count >= 12 else { return "unknown" }
        if b[0] == 0xFF, b[1] == 0xD8 { return "jpeg" }
        if b[0] == 0x89, b[1] == 0x50 { return "png" }
        if b[0] == 0x52, b[1] == 0x49, b[8] == 0x57, b[9] == 0x45 { return "webp" }
        if b[0] == 0x47, b[1] == 0x49 { return "gif" }
        return "unknown"
    }

    /// 解密后的像素缓存 key：URL 的 path 部分做 MD5（和前端一致的做法）
    public static func cacheKey(for url: String) -> String {
        guard let u = URL(string: url) else { return url }
        return u.path.replacingOccurrences(of: "/", with: "_")
    }
}
