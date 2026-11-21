import Foundation
import zlib

/// Packages already-authored USD layers and assets. Call from a file worker.
public enum USDZArchiveWriter
{
    public struct Member: Sendable
    {
        public let name: String
        public let fileURL: URL

        public init(name: String, fileURL: URL)
        {
            self.name = name
            self.fileURL = fileURL
        }
    }

    public enum Failure: LocalizedError, Sendable
    {
        case invalidRoot
        case invalidMember(String)
        case capacityExceeded
        case sourceChanged(String)

        public var errorDescription: String?
        {
            switch self
            {
                case .invalidRoot: "The first USDZ member must be a USD root layer."
                case let .invalidMember(name): "Invalid or repeated USDZ member: \(name)"
                case .capacityExceeded: "The USDZ exceeds the ZIP32 archive limit."
                case let .sourceChanged(name): "A USDZ member changed while being written: \(name)"
            }
        }
    }

    private struct Record
    {
        let name: Data
        let flags: UInt16
        let crc: UInt32
        let size: UInt32
        let offset: UInt32
    }

    private static let limit = UInt64(UInt32.max)
    private static let chunkSize = 1024 * 1024
    private static let date: UInt16 = 33

    /// Writes to a new file and returns its byte count.
    @discardableResult
    public static func write(_ members: [Member], to destination: URL) throws -> Int
    {
        try Task.checkCancellation()
        guard let root = members.first,
              ["usd", "usda", "usdc"].contains((root.name as NSString).pathExtension.lowercased())
        else { throw Failure.invalidRoot }
        guard members.count < Int(UInt16.max) else { throw Failure.capacityExceeded }
        guard destination.isFileURL else { throw CocoaError(.fileWriteUnsupportedScheme) }

        var names: Set<String> = []
        var directorySize: UInt64 = 22
        for member in members
        {
            try Task.checkCancellation()
            guard member.fileURL.isFileURL, !member.name.isEmpty, member.name.utf8.count <= Int(UInt16.max),
                  member.name.rangeOfCharacter(from: .controlCharacters) == nil,
                  !member.name.contains("\\"), !member.name.contains(":"),
                  member.name.split(separator: "/", omittingEmptySubsequences: false).allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
                  names.insert(member.name).inserted
            else { throw Failure.invalidMember(member.name) }
            directorySize += 46 + UInt64(member.name.utf8.count)
        }
        guard directorySize < limit else { throw Failure.capacityExceeded }

        try Data().write(to: destination, options: .withoutOverwriting)
        var completed = false
        defer
        {
            if !completed { try? FileManager.default.removeItem(at: destination) }
        }
        let output = try FileHandle(forWritingTo: destination)
        defer
        {
            if !completed { try? output.close() }
        }

        var records: [Record] = []
        records.reserveCapacity(members.count)
        for member in members
        {
            try Task.checkCancellation()
            let values = try member.fileURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true
            else { throw Failure.invalidMember(member.name) }
            let input = try FileHandle(forReadingFrom: member.fileURL)
            defer { try? input.close() }
            let offset = try output.offset()
            let size = try input.seekToEnd()
            guard size < limit else { throw Failure.capacityExceeded }
            let name = Data(member.name.utf8)
            let padding = (64 - (offset + 30 + UInt64(name.count) + 4) % 64) % 64
            guard offset + 30 + UInt64(name.count) + 4 + padding + size + directorySize < limit
            else { throw Failure.capacityExceeded }
            let checksum = try copy(input, size: size, name: member.name, output: nil)
            let flags: UInt16 = name.contains(where: { $0 > 127 }) ? 1 << 11 : 0
            let record = Record(name: name, flags: flags, crc: checksum, size: UInt32(size), offset: UInt32(offset))

            var header = Data()
            append(UInt32(0x04034B50), to: &header)
            for value in [UInt16(20), record.flags, 0, 0, date] { append(value, to: &header) }
            for value in [record.crc, record.size, record.size] { append(value, to: &header) }
            append(UInt16(name.count), to: &header)
            append(UInt16(4 + padding), to: &header)
            header.append(name)
            append(UInt16(0x1986), to: &header)
            append(UInt16(padding), to: &header)
            header.append(Data(count: Int(padding)))
            try output.write(contentsOf: header)
            guard try copy(input, size: size, name: member.name, output: output) == checksum
            else { throw Failure.sourceChanged(member.name) }
            records.append(record)
        }

        let directoryStart = try output.offset()
        for record in records
        {
            try Task.checkCancellation()
            var header = Data()
            append(UInt32(0x02014B50), to: &header)
            for value in [UInt16(20), 20, record.flags, 0, 0, date] { append(value, to: &header) }
            for value in [record.crc, record.size, record.size] { append(value, to: &header) }
            for value in [UInt16(record.name.count), 0, 0, 0, 0] { append(value, to: &header) }
            append(UInt32(0), to: &header)
            append(record.offset, to: &header)
            header.append(record.name)
            try output.write(contentsOf: header)
        }
        let directoryEnd = try output.offset()
        var footer = Data()
        append(UInt32(0x06054B50), to: &footer)
        for value in [0, 0, UInt16(records.count), UInt16(records.count)] { append(value, to: &footer) }
        append(UInt32(directoryEnd - directoryStart), to: &footer)
        append(UInt32(directoryStart), to: &footer)
        append(UInt16(0), to: &footer)
        try Task.checkCancellation()
        try output.write(contentsOf: footer)
        try output.synchronize()
        try output.close()
        completed = true
        return Int(directoryEnd) + footer.count
    }

    private static func copy(_ input: FileHandle, size: UInt64, name: String, output: FileHandle?) throws -> UInt32
    {
        try input.seek(toOffset: 0)
        var checksum: uLong = 0
        var count: UInt64 = 0
        while let data = try input.read(upToCount: chunkSize), !data.isEmpty
        {
            try Task.checkCancellation()
            count += UInt64(data.count)
            guard count <= size else { throw Failure.sourceChanged(name) }
            checksum = data.withUnsafeBytes { crc32(checksum, $0.bindMemory(to: UInt8.self).baseAddress, uInt(data.count)) }
            try output?.write(contentsOf: data)
        }
        guard count == size else { throw Failure.sourceChanged(name) }
        return UInt32(checksum)
    }

    private static func append<Value: FixedWidthInteger>(_ value: Value, to data: inout Data)
    {
        Swift.withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }
}
