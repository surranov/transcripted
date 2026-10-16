import Foundation

/// Fork: reads one value of a page's `localStorage` from a Chromium profile on
/// disk (`<profile>/Local Storage/leveldb`), while the browser runs: where T3
/// Code keeps a new chat's settings (`T3CodeDrafts`).
///
/// Chromium keeps it in LevelDB, written as Chromium wrote it on 2026-10-16
/// (Electron 44):
/// - A key is `_<origin>\0` and the page's key, a first byte telling its
///   encoding (0 UTF-16LE, 1 Latin-1); a value starts with the same byte.
/// - Recent writes sit in the `.log` file: 32 KiB blocks of records (7-byte
///   header: checksum, length, type; full, first, middle or last piece of a
///   write batch); a batch is its first sequence number, a count, then each
///   key put (1) or deleted (0).
/// - Older ones in `.ldb` tables: blocks of prefix-shared keys (each key
///   ending with its sequence number and kind), compressed with Snappy or
///   not, found through the index block the 48-byte footer points to.
/// - The newest write of a key, by sequence number, is its value; a delete
///   means none. Compaction removes and adds files at any moment, so a file
///   that vanished mid-read reads again once.
///
/// Read only; nothing is locked or written.
enum ChromiumLocalStorage {
    /// The value of `key` stored by pages of `origin` (`t3code://app`); nil
    /// when it isn't there or can't be read.
    static func value(origin: String, key: String, in directory: URL) -> String? {
        let mapKey = Data("_\(origin)".utf8) + Data([0]) + encodedKey(key)
        for _ in 0..<2 {
            if let found = try? newest(mapKey, in: directory) {
                return found.flatMap(decodedValue)
            }
        }
        return nil
    }

    /// The page's key as Chromium stores it: Latin-1 when it fits, else UTF-16LE.
    static func encodedKey(_ key: String) -> Data {
        if let latin1 = key.data(using: .isoLatin1) { return Data([1]) + latin1 }
        return Data([0]) + (key.data(using: .utf16LittleEndian) ?? Data())
    }

    static func decodedValue(_ value: Data) -> String? {
        guard let kind = value.first else { return nil }
        let body = value.dropFirst()
        switch kind {
        case 0: return String(data: body, encoding: .utf16LittleEndian)
        case 1: return String(data: body, encoding: .isoLatin1)
        default: return nil
        }
    }

    private struct Entry {
        let sequence: UInt64
        /// Nil for a delete.
        let value: Data?
    }

    /// A file listed was gone when read: compaction moved its data.
    private struct FileVanished: Error {}

    /// The newest write of `key` across the directory's files: `.some(nil)`
    /// when the newest is a delete or none is there.
    private static func newest(_ key: Data, in directory: URL) throws -> Data?? {
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        var best: Entry?
        func consider(_ entry: Entry) {
            if best.map({ entry.sequence > $0.sequence }) ?? true { best = entry }
        }
        for name in names where name.hasSuffix(".log") || name.hasSuffix(".ldb") || name.hasSuffix(".sst") {
            guard let data = FileManager.default.contents(atPath: directory.appendingPathComponent(name).path) else {
                throw FileVanished()
            }
            if name.hasSuffix(".log") {
                LogFile.entries(of: key, in: data).forEach(consider)
            } else {
                Table.entries(of: key, in: data).forEach(consider)
            }
        }
        return .some(best?.value)
    }

    // MARK: - The write-ahead log

    private enum LogFile {
        static let blockSize = 32_768
        static let headerSize = 7

        static func entries(of key: Data, in data: Data) -> [Entry] {
            var found: [Entry] = []
            for batch in batches(in: [UInt8](data)) {
                found += entries(of: key, inBatch: batch)
            }
            return found
        }

        /// Whole write batches; a piece cut short at the end (a write under
        /// way) and anything after a broken record are left out.
        static func batches(in bytes: [UInt8]) -> [[UInt8]] {
            var batches: [[UInt8]] = []
            var pending: [UInt8]?
            var offset = 0
            while offset + headerSize <= bytes.count {
                let left = blockSize - offset % blockSize
                if left < headerSize {
                    offset += left
                    continue
                }
                let length = Int(bytes[offset + 4]) | Int(bytes[offset + 5]) << 8
                let type = bytes[offset + 6]
                let start = offset + headerSize
                guard type != 0, start + length <= bytes.count, length <= left - headerSize else { break }
                let piece = Array(bytes[start..<(start + length)])
                offset = start + length
                switch type {
                case 1: batches.append(piece); pending = nil
                case 2: pending = piece
                case 3: pending? += piece
                case 4:
                    if let first = pending { batches.append(first + piece) }
                    pending = nil
                default: return batches
                }
            }
            return batches
        }

        static func entries(of key: Data, inBatch batch: [UInt8]) -> [Entry] {
            guard batch.count >= 12 else { return [] }
            var sequence = littleEndian(batch, at: 0, count: 8)
            let count = littleEndian(batch, at: 8, count: 4)
            var reader = ByteReader(bytes: batch, offset: 12)
            var found: [Entry] = []
            let target = [UInt8](key)
            for _ in 0..<count {
                guard let kind = reader.byte(), let entryKey = reader.lengthPrefixed() else { break }
                var value: [UInt8]?
                if kind == 1 {
                    guard let read = reader.lengthPrefixed() else { break }
                    value = read
                } else if kind != 0 {
                    break
                }
                if entryKey == target { found.append(Entry(sequence: sequence, value: value.map { Data($0) })) }
                sequence += 1
            }
            return found
        }
    }

    // MARK: - Sorted tables

    private enum Table {
        static let footerSize = 48
        static let magic: UInt64 = 0xdb4775248b80fb57

        static func entries(of key: Data, in data: Data) -> [Entry] {
            let bytes = [UInt8](data)
            guard bytes.count >= footerSize,
                  littleEndian(bytes, at: bytes.count - 8, count: 8) == magic else { return [] }
            var footer = ByteReader(bytes: bytes, offset: bytes.count - footerSize)
            guard footer.varint() != nil, footer.varint() != nil,
                  let indexOffset = footer.varint(), let indexSize = footer.varint(),
                  let index = block(in: bytes, offset: indexOffset, size: indexSize) else { return [] }
            let target = [UInt8](key)
            var found: [Entry] = []
            for (_, handle) in blockEntries(index) {
                var reader = ByteReader(bytes: handle, offset: 0)
                guard let offset = reader.varint(), let size = reader.varint(),
                      let data = block(in: bytes, offset: offset, size: size) else { continue }
                for (internalKey, value) in blockEntries(data) where internalKey.count >= 8 {
                    guard Array(internalKey.dropLast(8)) == target else { continue }
                    let trailer = littleEndian(Array(internalKey.suffix(8)), at: 0, count: 8)
                    let kind = trailer & 0xff
                    guard kind <= 1 else { continue }
                    found.append(Entry(sequence: trailer >> 8, value: kind == 1 ? Data(value) : nil))
                }
            }
            return found
        }

        /// A block's contents, uncompressed; its trailer (kind, checksum) follows it.
        static func block(in bytes: [UInt8], offset: UInt64, size: UInt64) -> [UInt8]? {
            guard offset < UInt64(bytes.count), size <= UInt64(bytes.count) else { return nil }
            let start = Int(offset)
            let end = start + Int(size)
            guard end + 5 <= bytes.count else { return nil }
            let contents = Array(bytes[start..<end])
            switch bytes[end] {
            case 0: return contents
            case 1: return Snappy.decompress(contents)
            default: return nil
            }
        }

        /// The key and value of each entry, keys rebuilt from the shared prefixes.
        static func blockEntries(_ block: [UInt8]) -> [([UInt8], [UInt8])] {
            guard block.count >= 4 else { return [] }
            let restarts = Int(littleEndian(block, at: block.count - 4, count: 4))
            let end = block.count - 4 - restarts * 4
            guard restarts >= 0, end >= 0 else { return [] }
            var reader = ByteReader(bytes: block, offset: 0, end: end)
            var entries: [([UInt8], [UInt8])] = []
            var key: [UInt8] = []
            while reader.offset < end {
                guard let shared = reader.varint(), let unshared = reader.varint(), let valueLength = reader.varint(),
                      Int(shared) <= key.count,
                      let delta = reader.bytes(Int(unshared)), let value = reader.bytes(Int(valueLength)) else { break }
                key = Array(key.prefix(Int(shared))) + delta
                entries.append((key, value))
            }
            return entries
        }
    }

    // MARK: - Snappy

    enum Snappy {
        /// Snappy's raw format: the length, then literals and copies back.
        static func decompress(_ input: [UInt8]) -> [UInt8]? {
            var reader = ByteReader(bytes: input, offset: 0)
            guard let length = reader.varint(), length < 1 << 28 else { return nil }
            var output: [UInt8] = []
            output.reserveCapacity(Int(length))
            while reader.offset < input.count {
                guard let tag = reader.byte() else { return nil }
                switch tag & 3 {
                case 0:
                    var literal = Int(tag >> 2) + 1
                    if literal > 60 {
                        let extra = literal - 60
                        guard let raw = reader.bytes(extra) else { return nil }
                        literal = Int(littleEndian(raw, at: 0, count: extra)) + 1
                    }
                    guard let bytes = reader.bytes(literal) else { return nil }
                    output += bytes
                    continue
                case 1:
                    guard let low = reader.byte() else { return nil }
                    let count = Int((tag >> 2) & 7) + 4
                    let distance = Int(tag >> 5) << 8 | Int(low)
                    guard copy(&output, distance: distance, count: count) else { return nil }
                case 2:
                    guard let raw = reader.bytes(2) else { return nil }
                    guard copy(&output, distance: Int(littleEndian(raw, at: 0, count: 2)), count: Int(tag >> 2) + 1) else { return nil }
                default:
                    guard let raw = reader.bytes(4) else { return nil }
                    guard copy(&output, distance: Int(littleEndian(raw, at: 0, count: 4)), count: Int(tag >> 2) + 1) else { return nil }
                }
            }
            return output.count == Int(length) ? output : nil
        }

        /// A copy may overlap what it writes (a run).
        private static func copy(_ output: inout [UInt8], distance: Int, count: Int) -> Bool {
            guard distance > 0, distance <= output.count else { return false }
            let start = output.count - distance
            for index in 0..<count { output.append(output[start + index]) }
            return true
        }
    }

    // MARK: - Bytes

    private static func littleEndian(_ bytes: [UInt8], at offset: Int, count: Int) -> UInt64 {
        var value: UInt64 = 0
        for index in (0..<count).reversed() { value = value << 8 | UInt64(bytes[offset + index]) }
        return value
    }

    struct ByteReader {
        let bytes: [UInt8]
        var offset: Int
        var end: Int

        init(bytes: [UInt8], offset: Int, end: Int? = nil) {
            self.bytes = bytes
            self.offset = offset
            self.end = end ?? bytes.count
        }

        mutating func byte() -> UInt8? {
            guard offset < end else { return nil }
            defer { offset += 1 }
            return bytes[offset]
        }

        mutating func bytes(_ count: Int) -> [UInt8]? {
            guard count >= 0, offset + count <= end else { return nil }
            defer { offset += count }
            return Array(bytes[offset..<(offset + count)])
        }

        mutating func varint() -> UInt64? {
            var value: UInt64 = 0
            var shift: UInt64 = 0
            while shift < 64 {
                guard let next = byte() else { return nil }
                value |= UInt64(next & 0x7f) << shift
                if next & 0x80 == 0 { return value }
                shift += 7
            }
            return nil
        }

        mutating func lengthPrefixed() -> [UInt8]? {
            guard let length = varint(), length <= UInt64(end - offset) else { return nil }
            return bytes(Int(length))
        }
    }
}
