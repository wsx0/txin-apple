//
//  SelfTest.swift
//  TxinKit
//
//  协议金标校验：test-vectors.json 由 Node 参考实现生成（那套已经在真实站点跑通），
//  Swift 端必须复现同样的密钥、能解开同样的密文。
//
//  注意：不比对「加密产物字节」。gzip 压缩等级不同，deflate 输出就不同，
//  密文自然不同 —— 这不是错。真正要证的是：
//    · 密钥派生逐字节一致（HMAC，确定性）
//    · 能解开参考实现生成的密文（AES-CBC + PKCS7 + gunzip 全对）
//    · 自己加自己解能往返
//

import Foundation

public struct SelfTestResult: Sendable {
    public var passed: Int = 0
    public var failed: [String] = []
    public var ok: Bool { failed.isEmpty }
    public var total: Int { passed + failed.count }
}

public enum TxinSelfTest {

    public static func run(vectorsJSON: Data) -> SelfTestResult {
        var result = SelfTestResult()

        guard let root = try? JSONSerialization.jsonObject(with: vectorsJSON) as? [String: Any] else {
            result.failed.append("vectors JSON 解析失败")
            return result
        }
        let secret = root["secret"] as? String ?? TxinClient.apiSecret
        let cookieKey = root["cookieKey"] as? String ?? TxinClient.cookieKey

        // ---------- 请求向量 ----------
        if let cases = root["requestVectors"] as? [[String: Any]] {
            for (i, c) in cases.enumerated() {
                let tag = "request#\(i)"
                guard let requestId = c["requestId"] as? String,
                      let payload = c["payload"] as? [String: Any],
                      let expectKey = c["keyHex"] as? String,
                      let expectIv = c["ivHex"] as? String,
                      let expectBody = c["bodyBase64"] as? String else {
                    result.failed.append("\(tag): 向量字段缺失")
                    continue
                }

                // 1) 密钥派生
                do {
                    let key = try TxinCrypto.deriveKey(requestId: requestId, secret: secret)
                    let got = TxinCrypto.bytesToHex(key)
                    if got == expectKey {
                        result.passed += 1
                    } else {
                        result.failed.append("\(tag): key 不一致\n    期望 \(expectKey)\n    实际 \(got)")
                        continue
                    }
                } catch {
                    result.failed.append("\(tag): 派生失败 \(error)")
                    continue
                }

                // 2) 解金标密文
                do {
                    let key = try TxinCrypto.deriveKey(requestId: requestId, secret: secret)
                    let bytes = try TxinCrypto.base64Decode(expectBody)
                    let iv = Array(bytes[0..<16])
                    let ct = Array(bytes[16...])
                    let gz = try TxinCrypto.aesCBCDecrypt(key: key, iv: iv, cipher: ct)
                    let plain = try TxinGzip.gunzip(gz)
                    if let obj = try JSONSerialization.jsonObject(with: Data(plain)) as? [String: Any],
                       (obj["deviceId"] as? String) == (payload["deviceId"] as? String),
                       (obj["token"] as? String) == (payload["token"] as? String) {
                        result.passed += 1
                    } else {
                        result.failed.append("\(tag): 金标密文解开但内容不符")
                    }
                } catch {
                    result.failed.append("\(tag): 解金标密文失败 \(error)")
                }

                // 3) 自加密 → 自解密 回环
                do {
                    let key = try TxinCrypto.deriveKey(requestId: requestId, secret: secret)
                    let iv = try TxinCrypto.hexToBytes(expectIv)
                    let json = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
                    let gz = try TxinGzip.gzip([UInt8](json))
                    let ct = try TxinCrypto.aesCBCEncrypt(key: key, iv: iv, plain: gz)
                    let back = try TxinCrypto.aesCBCDecrypt(key: key, iv: iv, cipher: ct)
                    let unz = try TxinGzip.gunzip(back)
                    if let obj = try JSONSerialization.jsonObject(with: Data(unz)) as? [String: Any],
                       (obj["deviceId"] as? String) == (payload["deviceId"] as? String) {
                        result.passed += 1
                    } else {
                        result.failed.append("\(tag): 自加密回环内容不符")
                    }
                } catch {
                    result.failed.append("\(tag): 自加密回环失败 \(error)")
                }

                // 4) 与 Node 的 gzip 产物互通
                if let gzB64 = c["gzipBase64"] as? String {
                    do {
                        let nodeGz = try TxinCrypto.base64Decode(gzB64)
                        let inflated = try TxinGzip.gunzip(nodeGz)
                        if let obj = try JSONSerialization.jsonObject(with: Data(inflated)) as? [String: Any],
                           (obj["deviceId"] as? String) == (payload["deviceId"] as? String) {
                            result.passed += 1
                        } else {
                            result.failed.append("\(tag): Node gzip 解压后内容不符")
                        }
                    } catch {
                        result.failed.append("\(tag): 解 Node gzip 失败 \(error)")
                    }
                }
            }
        }

        // ---------- cookie 向量 ----------
        if let cv = root["cookieVector"] as? [String: Any],
           let plain = cv["plaintext"] as? String,
           let cipher = cv["cipherBase64"] as? String {
            do {
                let key = [UInt8](cookieKey.utf8)
                let raw = try TxinCrypto.base64Decode(cipher)
                let out = try TxinCrypto.aesECBDecrypt(key: key, cipher: raw)
                if String(bytes: out, encoding: .utf8) == plain {
                    result.passed += 1
                } else {
                    result.failed.append("cookie: 明文不一致")
                }
            } catch {
                result.failed.append("cookie: \(error)")
            }
        }

        // ---------- gzip 自环 ----------
        do {
            let probe = [UInt8]("糖心协议 gzip 回环 payload 0123456789".utf8)
            let gz = try TxinGzip.gzip(probe)
            let back = try TxinGzip.gunzip(gz)
            if back == probe && TxinGzip.crc32(probe) == TxinGzip.crc32(back) {
                result.passed += 1
            } else {
                result.failed.append("gzip: 回环失败")
            }
        } catch {
            result.failed.append("gzip: \(error)")
        }

        // ---------- uuid ----------
        let u = TxinCrypto.uuidv4()
        if u.count == 36, u.filter({ $0 == "-" }).count == 4 {
            result.passed += 1
        } else {
            result.failed.append("uuid: 形状异常 \(u)")
        }

        // ---------- base64 / hex 边界 ----------
        do {
            let hex = "00ff10aB"
            let bytes = try TxinCrypto.hexToBytes(hex)
            if bytes == [0x00, 0xff, 0x10, 0xab] { result.passed += 1 }
            else { result.failed.append("hex 解析错误") }
        } catch {
            result.failed.append("hex: \(error)")
        }

        return result
    }
}
