import Foundation
import MessUSDZArchiveKit
import Testing
import zlib

struct USDZArchiveWriterTests
{
    @Test
    func streamsStoredPayloadsWithAlignmentAndMatchingCRC() throws
    {
        let workspace = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: workspace) }
        let stage = workspace.appendingPathComponent("Scene.usda")
        let stageData = Data("#usda 1.0\n".utf8)
        try stageData.write(to: stage)
        let source = workspace.appendingPathComponent("source.png")
        let payload = Data((0 ..< 2_150_000).map { UInt8(truncatingIfNeeded: $0) })
        try payload.write(to: source)
        var members: [USDZArchiveWriter.Member] = [.init(name: "Scene.usda", fileURL: stage)]
        for count in 1 ... 64
        {
            members.append(.init(name: "textures/" + String(repeating: "x", count: count) + ".png", fileURL: count == 64 ? source : stage))
        }
        let destination = workspace.appendingPathComponent("Scene.usdz")
        let bytes = try USDZArchiveWriter.write(members, to: destination)
        let archive = try Data(contentsOf: destination)
        #expect(bytes == archive.count)
        var offset = 0
        for (index, member) in members.enumerated()
        {
            let word = { (byte: Int) in archive.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: byte, as: UInt32.self)) } }
            try #require(word(offset) == 0x04034B50)
            #expect(word(offset + 6) == 0)
            let size = Int(word(offset + 18))
            let lengths = word(offset + 26)
            let nameLength = Int(lengths & 0xFFFF)
            let start = offset + 30 + nameLength + Int(lengths >> 16)
            #expect(start.isMultiple(of: 64))
            #expect(String(decoding: archive[offset + 30 ..< offset + 30 + nameLength], as: UTF8.self) == member.name)
            let expected = index == members.count - 1 ? payload : stageData
            #expect(archive[start ..< start + size].elementsEqual(expected))
            #expect(word(offset + 14) == expected.withUnsafeBytes { UInt32(crc32(0, $0.bindMemory(to: UInt8.self).baseAddress, uInt(expected.count))) })
            offset = start + size
        }
        #expect(archive.suffix(22).prefix(4).elementsEqual([0x50, 0x4B, 0x05, 0x06]))
    }

    @Test
    func rejectsInvalidNamesAndLeavesExistingDestinationIntact() throws
    {
        let workspace = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: workspace) }
        let source = workspace.appendingPathComponent("Scene.usda")
        let original = Data("#usda 1.0\n".utf8)
        try original.write(to: source)
        let root = USDZArchiveWriter.Member(name: "Scene.usda", fileURL: source)
        let destination = workspace.appendingPathComponent("Scene.usdz")
        for name in ["../image.png", "/image.png", "a/./image.png", "a//image.png", "a\\image.png", "Scene.usda"]
        {
            #expect(throws: USDZArchiveWriter.Failure.self) {
                try USDZArchiveWriter.write([root, .init(name: name, fileURL: source)], to: destination)
            }
            #expect(!FileManager.default.fileExists(atPath: destination.path))
        }
        #expect(throws: (any Error).self) { try USDZArchiveWriter.write([root], to: source) }
        #expect(try Data(contentsOf: source) == original)
    }

    @Test
    func cancellationDoesNotPublishAFile() async throws
    {
        let workspace = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: workspace) }
        let source = workspace.appendingPathComponent("Scene.usda")
        try Data("#usda 1.0\n".utf8).write(to: source)
        let destination = workspace.appendingPathComponent("Scene.usdz")
        let write = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try USDZArchiveWriter.write([.init(name: "Scene.usda", fileURL: source)], to: destination)
        }
        await #expect(throws: CancellationError.self) { try await write.value }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }
}
