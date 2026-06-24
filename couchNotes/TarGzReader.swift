//
//  TarGzReader.swift
//  couchNotes
//
//  依存ライブラリなしの .tar.gz 展開ユーティリティ（gunzip + untar）。
//  GitHub の tarball（GET /repos/{owner}/{repo}/tarball/{ref}）を1回のダウンロードで取り、
//  ローカルで全ファイルを取り出す復元経路で使う。Foundation と Compression のみ。
//

import Foundation
import Compression

enum TarGzError: LocalizedError {
    case gzipFormat
    case inflateFailed

    var errorDescription: String? {
        switch self {
        case .gzipFormat:   return "gzip データの形式が不正です。"
        case .inflateFailed: return "gzip の展開に失敗しました。"
        }
    }
}

enum TarGzReader {

    /// .tar.gz の Data を展開し、通常ファイルのエントリを (tar 内のフルパス, バイト列) で返す。
    static func entries(from targz: Data) throws -> [(path: String, data: Data)] {
        let tar = try gunzip(targz)
        return untar([UInt8](tar))
    }

    // MARK: - gunzip（RFC 1952 ヘッダを剥がして RFC 1951 DEFLATE を展開）

    static func gunzip(_ data: Data) throws -> Data {
        let bytes = [UInt8](data)
        // マジック 1f 8b、圧縮方式 08(deflate)、最低限ヘッダ10 + 末尾8 が必要
        guard bytes.count > 18, bytes[0] == 0x1f, bytes[1] == 0x8b, bytes[2] == 0x08 else {
            throw TarGzError.gzipFormat
        }
        let flags = bytes[3]
        var idx = 10
        if flags & 0x04 != 0 {                       // FEXTRA: 2バイト長 + 本体
            guard idx + 2 <= bytes.count else { throw TarGzError.gzipFormat }
            let xlen = Int(bytes[idx]) | (Int(bytes[idx + 1]) << 8)
            idx += 2 + xlen
        }
        if flags & 0x08 != 0 { idx = skipCString(bytes, idx) }   // FNAME
        if flags & 0x10 != 0 { idx = skipCString(bytes, idx) }   // FCOMMENT
        if flags & 0x02 != 0 { idx += 2 }                        // FHCRC

        guard idx < bytes.count - 8 else { throw TarGzError.gzipFormat }
        // 末尾4バイト ISIZE（展開後サイズ mod 2^32）を出力バッファのヒントに使う
        let isize = Int(bytes[bytes.count - 4])
            | (Int(bytes[bytes.count - 3]) << 8)
            | (Int(bytes[bytes.count - 2]) << 16)
            | (Int(bytes[bytes.count - 1]) << 24)
        let deflate = Array(bytes[idx ..< bytes.count - 8])      // CRC32 + ISIZE を除いた本体
        return try inflate(deflate, hint: max(isize, deflate.count * 4))
    }

    private static func skipCString(_ bytes: [UInt8], _ start: Int) -> Int {
        var i = start
        while i < bytes.count, bytes[i] != 0 { i += 1 }
        return i + 1   // NUL を飛ばす
    }

    /// 生 DEFLATE を Compression フレームワーク（COMPRESSION_ZLIB = 生 DEFLATE）で展開する。
    private static func inflate(_ src: [UInt8], hint: Int) throws -> Data {
        var stream = compression_stream(
            dst_ptr: UnsafeMutablePointer<UInt8>(bitPattern: -1)!, dst_size: 0,
            src_ptr: UnsafePointer<UInt8>(bitPattern: -1)!, src_size: 0, state: nil)
        guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB)
                == COMPRESSION_STATUS_OK else {
            throw TarGzError.inflateFailed
        }
        defer { compression_stream_destroy(&stream) }

        let bufferSize = 256 * 1024
        let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { dst.deallocate() }

        var output = Data(capacity: max(hint, bufferSize))
        let flags = Int32(COMPRESSION_STREAM_FINALIZE.rawValue)

        return try src.withUnsafeBufferPointer { srcBuf -> Data in
            stream.src_ptr = srcBuf.baseAddress!
            stream.src_size = srcBuf.count
            while true {
                stream.dst_ptr = dst
                stream.dst_size = bufferSize
                let status = compression_stream_process(&stream, flags)
                let produced = bufferSize - stream.dst_size
                if produced > 0 { output.append(dst, count: produced) }
                switch status {
                case COMPRESSION_STATUS_OK:    continue
                case COMPRESSION_STATUS_END:   return output
                default:                       throw TarGzError.inflateFailed
                }
            }
        }
    }

    // MARK: - untar（ustar / pax 'x' / GNU 'L' の各ロングパス形式に対応）

    private static func untar(_ tar: [UInt8]) -> [(path: String, data: Data)] {
        var result: [(path: String, data: Data)] = []
        let block = 512
        var offset = 0
        var pendingPath: String? = nil   // 直前の pax('x') / GNU('L') が指定する次エントリ名

        while offset + block <= tar.count {
            // ヘッダが全ゼロ＝アーカイブ終端
            if tar[offset ..< offset + block].allSatisfy({ $0 == 0 }) { break }

            let typeflag = tar[offset + 156]
            let size = octal(tar, offset + 124, 12)
            let dataStart = offset + block
            let dataEnd = dataStart + size
            guard dataEnd <= tar.count else { break }

            switch typeflag {
            case UInt8(ascii: "x"), UInt8(ascii: "g"):           // pax 拡張ヘッダ
                if let p = paxPath(tar, dataStart, size) { pendingPath = p }
            case UInt8(ascii: "L"):                              // GNU ロングネーム
                pendingPath = cString(tar, dataStart, size)
            case UInt8(ascii: "0"), 0:                           // 通常ファイル
                let name = pendingPath ?? fullName(tar, offset)
                pendingPath = nil
                if !name.isEmpty {
                    result.append((name, Data(tar[dataStart ..< dataEnd])))
                }
            default:                                             // ディレクトリ等
                pendingPath = nil
            }

            // 次ヘッダは 512 境界に切り上げ
            offset = dataEnd + ((block - (size % block)) % block)
        }
        return result
    }

    /// ustar の prefix(155) + name(100) を結合してフルパスを得る。
    private static func fullName(_ tar: [UInt8], _ off: Int) -> String {
        let name = cString(tar, off, 100)
        let prefix = cString(tar, off + 345, 155)
        return prefix.isEmpty ? name : prefix + "/" + name
    }

    /// pax 拡張ヘッダ本体から path レコードを取り出す。形式: "<len> key=value\n"。
    private static func paxPath(_ tar: [UInt8], _ off: Int, _ size: Int) -> String? {
        var i = off
        let end = off + size
        while i < end {
            var j = i
            var lenVal = 0
            while j < end, tar[j] >= 0x30, tar[j] <= 0x39 {      // 先頭の十進長
                lenVal = lenVal * 10 + Int(tar[j] - 0x30)
                j += 1
            }
            guard lenVal > 0, j < end, tar[j] == 0x20 else { break }  // 長さの後はスペース
            let recordEnd = i + lenVal
            guard recordEnd <= end, recordEnd > j + 1 else { break }
            let kv = String(decoding: tar[(j + 1) ..< recordEnd], as: UTF8.self)
            if let eq = kv.firstIndex(of: "="), String(kv[..<eq]) == "path" {
                var value = String(kv[kv.index(after: eq)...])
                if value.hasSuffix("\n") { value.removeLast() }
                return value
            }
            i = recordEnd
        }
        return nil
    }

    /// NUL 終端の固定長フィールドを文字列として読む。
    private static func cString(_ tar: [UInt8], _ off: Int, _ len: Int) -> String {
        var bytes: [UInt8] = []
        var i = off
        let end = min(off + len, tar.count)
        while i < end, tar[i] != 0 {
            bytes.append(tar[i])
            i += 1
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// 8進ASCIIの数値フィールドを読む（スペース・NUL は無視）。
    private static func octal(_ tar: [UInt8], _ off: Int, _ len: Int) -> Int {
        var value = 0
        for i in off ..< min(off + len, tar.count) {
            let b = tar[i]
            if b < 0x30 || b > 0x37 { continue }   // 0–7 以外（スペース/NUL 含む）は読み飛ばす
            value = value * 8 + Int(b - 0x30)
        }
        return value
    }
}
