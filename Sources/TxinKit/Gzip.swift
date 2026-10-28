//
//  Gzip.swift
//  TxinKit
//
//  Apple 的 Compression framework 只给 raw deflate（RFC 1951），
//  而协议要求 gzip 容器（RFC 1952）。这里自己做 header / trailer / CRC32，
//  中间那段直接交给 compression_stream。
//
//  注意两个编译器会挑刺的点（已踩过）：
//    · compression_stream 不能无参构造，memberwise init 六个参数全要
//    · stream.src_ptr 是 UnsafePointer<UInt8>，可变指针不能直接赋给它
//

import Foundation
import Compression

public enum TxinGzipError: Error, CustomStringConvertible {
    case streamInitFailed(Int32)
    case streamProcessFailed(Int32)
    case notGzip
    case truncated

    public var description: String {
        switch self {
        case .streamInitFailed(let s): return "compression_stream_init 失败: \(s)"
        case .streamProcessFailed(let s): return "compression_stream_process 失败: \(s)"
        case .notGzip: return "不是 gzip 数据"
        case .truncated: return "gzip 数据被截断"
        }
    }
}

public enum TxinGzip {

    private static let chunkSize = 65_536

    // MARK: - CRC32

    private static let crcTable: [UInt32] = {
        var table = [UInt32](repeating: 0, count: 256)
        for i in 0..<256 {
            var c = UInt32(i)
            for _ in 0..<8 {
                c = (c & 1) != 0 ? (0xEDB88320 ^ (c >> 1)) : (c >> 1)
            }
            table[i] = c
        }
        return table
    }()

    public static func crc32(_ data: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for byte in data {
            let idx = Int((crc ^ UInt32(byte)) & 0xFF)
            crc = crcTable[idx] ^ (crc >> 8)
        }
        return crc ^ 0xFFFFFFFF
    }

    // MARK: - raw deflate

    private static func perform(_ op: compression_stream_operation,
                                on input: [UInt8]) throws -> [UInt8] {

        let dstCapacity = max(chunkSize, 1024)
        let dstBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: dstCapacity)
        defer { dstBuffer.deallocate() }

        // compression_stream 的 src_ptr 不能是 nil，空输入塞一个占位字节
        var srcWork = input
        if srcWork.isEmpty { srcWork = [0] }

        return try srcWork.withUnsafeBufferPointer { src -> [UInt8] in
            guard let srcBase = src.baseAddress else { return [] }

            // 必须显式给全部参数：Swift 不再为这个 C struct 生成无参 init
            var stream = compression_stream(
                dst_ptr: dstBuffer,
                dst_size: 0,
                src_ptr: srcBase,
                src_size: 0,
                state: nil
            )

            var status = compression_stream_init(&stream, op, COMPRESSION_ZLIB)
            guard status == COMPRESSION_STATUS_OK else {
                throw TxinGzipError.streamInitFailed(Int32(status.rawValue))
            }
            defer { compression_stream_destroy(&stream) }

            stream.src_ptr = srcBase          // 已是 UnsafePointer<UInt8>
            stream.src_size = input.count

            var output = [UInt8]()
            output.reserveCapacity(max(input.count * 2, 1024))

            repeat {
                stream.dst_ptr = dstBuffer
                stream.dst_size = dstCapacity
                status = compression_stream_process(
                    &stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))

                switch status {
                case COMPRESSION_STATUS_OK, COMPRESSION_STATUS_END:
                    let produced = dstCapacity - stream.dst_size
                    if produced > 0 {
                        output.append(contentsOf:
                            UnsafeBufferPointer(start: dstBuffer, count: produced))
                    }
                default:
                    throw TxinGzipError.streamProcessFailed(Int32(status.rawValue))
                }
            } while status == COMPRESSION_STATUS_OK

            return output
        }
    }

    // MARK: - 对外

    public static func gzip(_ data: [UInt8]) throws -> [UInt8] {
        let deflated = try perform(COMPRESSION_STREAM_ENCODE, on: data)
        var out: [UInt8] = [0x1f, 0x8b, 0x08, 0x00, 0, 0, 0, 0, 0x00, 0x03]
        out.append(contentsOf: deflated)
        let crc = crc32(data)
        out.append(UInt8(truncatingIfNeeded: crc))
        out.append(UInt8(truncatingIfNeeded: crc >> 8))
        out.append(UInt8(truncatingIfNeeded: crc >> 16))
        out.append(UInt8(truncatingIfNeeded: crc >> 24))
        let isize = UInt32(truncatingIfNeeded: data.count)
        out.append(UInt8(truncatingIfNeeded: isize))
        out.append(UInt8(truncatingIfNeeded: isize >> 8))
        out.append(UInt8(truncatingIfNeeded: isize >> 16))
        out.append(UInt8(truncatingIfNeeded: isize >> 24))
        return out
    }

    public static func gunzip(_ data: [UInt8]) throws -> [UInt8] {
        guard data.count > 18 else { throw TxinGzipError.truncated }
        guard data[0] == 0x1f, data[1] == 0x8b else { throw TxinGzipError.notGzip }
        guard data[2] == 0x08 else { throw TxinGzipError.notGzip }

        let flg = data[3]
        var i = 10
        if flg & 0x04 != 0 {                       // FEXTRA
            guard i + 2 <= data.count else { throw TxinGzipError.truncated }
            let xlen = Int(data[i]) | (Int(data[i + 1]) << 8)
            i += 2 + xlen
        }
        if flg & 0x08 != 0 {                       // FNAME
            while i < data.count && data[i] != 0 { i += 1 }
            i += 1
        }
        if flg & 0x10 != 0 {                       // FCOMMENT
            while i < data.count && data[i] != 0 { i += 1 }
            i += 1
        }
        if flg & 0x02 != 0 { i += 2 }              // FHCRC

        let end = data.count - 8
        guard i >= 0 && i < end else { throw TxinGzipError.truncated }
        return try perform(COMPRESSION_STREAM_DECODE, on: Array(data[i..<end]))
    }
}
