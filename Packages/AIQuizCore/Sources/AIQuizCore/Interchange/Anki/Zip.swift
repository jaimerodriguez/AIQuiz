import Foundation

/// Just enough ZIP for Anki packages (docs/anki-interchange.md §1): read stored and deflated
/// entries (Zip64 included) without loading the archive, and write stored entries.
public struct ZipArchive: Sendable {
    public struct Entry: Sendable, Equatable {
        public let name: String
        let method: UInt16
        let compressedSize: UInt64
        public let size: UInt64
        let localHeaderOffset: UInt64
    }

    public enum Failure: Error, Equatable, LocalizedError {
        case notAZip
        case unsupportedMethod(UInt16)
        case corrupt(String)
        case tooLarge(String)

        public var errorDescription: String? {
            switch self {
            case .notAZip: return "This file isn't a ZIP archive."
            case .unsupportedMethod(let m): return "The archive uses a compression method AIQuiz can't read (\(m))."
            case .corrupt(let what): return "The archive is damaged (\(what))."
            case .tooLarge(let name): return "\(name) is too large to open."
            }
        }
    }

    /// Entries larger than this are refused (a damaged or hostile archive).
    public static let maxEntrySize: UInt64 = 1 << 30

    public let url: URL
    public let entries: [Entry]

    public init(url: URL) throws {
        self.url = url
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let fileSize = try handle.seekToEnd()
        let tailLength = min(fileSize, 65_557)
        try handle.seek(toOffset: fileSize - tailLength)
        let tail = try handle.read(upToCount: Int(tailLength)) ?? Data()
        guard let eocd = Self.lastIndex(of: 0x06054b50, in: tail) else { throw Failure.notAZip }

        var count = UInt64(tail.le16(eocd + 10))
        var directorySize = UInt64(tail.le32(eocd + 12))
        var directoryOffset = UInt64(tail.le32(eocd + 16))
        if directoryOffset == 0xFFFF_FFFF || count == 0xFFFF, eocd >= 20, tail.le32(eocd - 20) == 0x07064b50 {
            let recordOffset = tail.le64(eocd - 20 + 8)
            try handle.seek(toOffset: recordOffset)
            let record = try handle.read(upToCount: 56) ?? Data()
            guard record.count == 56, record.le32(0) == 0x06064b50 else { throw Failure.corrupt("Zip64 record") }
            count = record.le64(32)
            directorySize = record.le64(40)
            directoryOffset = record.le64(48)
        }
        guard directorySize < 64 << 20 else { throw Failure.tooLarge("The archive directory") }
        try handle.seek(toOffset: directoryOffset)
        let directory = try handle.read(upToCount: Int(directorySize)) ?? Data()

        var entries: [Entry] = []
        var at = 0
        for _ in 0..<count {
            guard at + 46 <= directory.count, directory.le32(at) == 0x02014b50 else { throw Failure.corrupt("directory entry") }
            let method = directory.le16(at + 10)
            var compressed = UInt64(directory.le32(at + 20))
            var size = UInt64(directory.le32(at + 24))
            let nameLength = Int(directory.le16(at + 28))
            let extraLength = Int(directory.le16(at + 30))
            let commentLength = Int(directory.le16(at + 32))
            var offset = UInt64(directory.le32(at + 42))
            guard at + 46 + nameLength + extraLength <= directory.count else { throw Failure.corrupt("directory entry") }
            let name = String(decoding: directory[directory.startIndex + at + 46 ..< directory.startIndex + at + 46 + nameLength], as: UTF8.self)
            // Zip64: the extra field holds the 64-bit values that are 0xFFFFFFFF above, in order.
            var extra = at + 46 + nameLength
            let extraEnd = extra + extraLength
            while extra + 4 <= extraEnd {
                let id = directory.le16(extra), length = Int(directory.le16(extra + 2))
                if id == 0x0001 {
                    var field = extra + 4
                    if size == 0xFFFF_FFFF { size = directory.le64(field); field += 8 }
                    if compressed == 0xFFFF_FFFF { compressed = directory.le64(field); field += 8 }
                    if offset == 0xFFFF_FFFF { offset = directory.le64(field) }
                }
                extra += 4 + length
            }
            entries.append(Entry(name: name, method: method, compressedSize: compressed, size: size, localHeaderOffset: offset))
            at += 46 + nameLength + extraLength + commentLength
        }
        self.entries = entries
    }

    public func entry(_ name: String) -> Entry? {
        entries.first { $0.name == name }
    }

    /// The entry's content, inflated.
    public func data(for entry: Entry) throws -> Data {
        guard entry.size <= Self.maxEntrySize, entry.compressedSize <= Self.maxEntrySize else { throw Failure.tooLarge(entry.name) }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: entry.localHeaderOffset)
        let header = try handle.read(upToCount: 30) ?? Data()
        guard header.count == 30, header.le32(0) == 0x04034b50 else { throw Failure.corrupt("local header for \(entry.name)") }
        let skip = UInt64(header.le16(26)) + UInt64(header.le16(28))
        try handle.seek(toOffset: entry.localHeaderOffset + 30 + skip)
        let stored = try handle.read(upToCount: Int(entry.compressedSize)) ?? Data()
        guard stored.count == Int(entry.compressedSize) else { throw Failure.corrupt("\(entry.name) is cut short") }
        switch entry.method {
        case 0:
            return stored
        case 8:
            // Apple's zlib is raw DEFLATE (RFC 1951), as ZIP stores it.
            guard entry.size > 0 else { return Data() }
            do {
                return try (stored as NSData).decompressed(using: .zlib) as Data
            } catch {
                throw Failure.corrupt("\(entry.name) won't inflate")
            }
        default:
            throw Failure.unsupportedMethod(entry.method)
        }
    }

    private static func lastIndex(of signature: UInt32, in data: Data) -> Int? {
        guard data.count >= 22 else { return nil }
        for index in stride(from: data.count - 22, through: 0, by: -1) where data.le32(index) == signature {
            return index
        }
        return nil
    }

    /// A ZIP of stored (uncompressed) entries, in order.
    public static func write(_ files: [(name: String, data: Data)]) -> Data {
        var out = Data()
        var directory = Data()
        for file in files {
            let name = Data(file.name.utf8)
            let crc = CRC32.checksum(file.data)
            let offset = UInt32(out.count)
            var local = Data()
            local.appendLE32(0x04034b50); local.appendLE16(20); local.appendLE16(0x0800); local.appendLE16(0)
            local.appendLE16(0); local.appendLE16(0x21)   // 1980-01-01 00:00
            local.appendLE32(crc); local.appendLE32(UInt32(file.data.count)); local.appendLE32(UInt32(file.data.count))
            local.appendLE16(UInt16(name.count)); local.appendLE16(0)
            out.append(local); out.append(name); out.append(file.data)

            directory.appendLE32(0x02014b50); directory.appendLE16(20); directory.appendLE16(20); directory.appendLE16(0x0800)
            directory.appendLE16(0); directory.appendLE16(0); directory.appendLE16(0x21)
            directory.appendLE32(crc); directory.appendLE32(UInt32(file.data.count)); directory.appendLE32(UInt32(file.data.count))
            directory.appendLE16(UInt16(name.count)); directory.appendLE16(0); directory.appendLE16(0)
            directory.appendLE16(0); directory.appendLE16(0); directory.appendLE32(0); directory.appendLE32(offset)
            directory.append(name)
        }
        let directoryOffset = UInt32(out.count)
        out.append(directory)
        out.appendLE32(0x06054b50); out.appendLE16(0); out.appendLE16(0)
        out.appendLE16(UInt16(files.count)); out.appendLE16(UInt16(files.count))
        out.appendLE32(UInt32(directory.count)); out.appendLE32(directoryOffset); out.appendLE16(0)
        return out
    }
}

/// CRC-32 (IEEE 802.3), as ZIP uses.
enum CRC32 {
    static let table: [UInt32] = (0..<256).map { n in
        var c = UInt32(n)
        for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data { crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
        return crc ^ 0xFFFF_FFFF
    }
}

extension Data {
    func le16(_ at: Int) -> UInt16 {
        let i = startIndex + at
        return UInt16(self[i]) | UInt16(self[i + 1]) << 8
    }

    func le32(_ at: Int) -> UInt32 {
        let i = startIndex + at
        return UInt32(self[i]) | UInt32(self[i + 1]) << 8 | UInt32(self[i + 2]) << 16 | UInt32(self[i + 3]) << 24
    }

    func le64(_ at: Int) -> UInt64 {
        UInt64(le32(at)) | UInt64(le32(at + 4)) << 32
    }

    mutating func appendLE16(_ value: UInt16) {
        append(UInt8(value & 0xFF)); append(UInt8(value >> 8))
    }

    mutating func appendLE32(_ value: UInt32) {
        appendLE16(UInt16(value & 0xFFFF)); appendLE16(UInt16(value >> 16))
    }
}
