import Foundation
import Darwin

@main
struct DiskGrowthTests {
    static let mib: Int64 = 1 << 20
    static func le(_ value: Int64, _ count: Int) -> [UInt8] {
        (0..<count).map { UInt8(truncatingIfNeeded: UInt64(bitPattern: value) >> (8 * $0)) }
    }
    static func number(_ bytes: [UInt8], _ offset: Int, _ count: Int = 8) -> Int64 {
        (0..<count).reduce(0) { $0 | Int64(bytes[offset + $1]) << (8 * $1) }
    }
    static func guid(_ text: String) -> [UInt8] {
        let hex = Array(text.replacingOccurrences(of: "-", with: ""))
        let b = stride(from: 0, to: 32, by: 2).map { UInt8(String(hex[$0..<$0 + 2]), radix: 16)! }
        return [b[3], b[2], b[1], b[0], b[5], b[4], b[7], b[6]] + b[8...]
    }

    struct Fixture {
        let path: String
        let sector: Int64
        let bytes: Int64
        let parts: [(type: String, first: Int64, last: Int64)]
    }

    static func fixture(in directory: URL, sector: Int64, multiple: Bool = false) throws -> Fixture {
        let path = directory.appendingPathComponent(UUID().uuidString + ".img").path
        let bytes = 64 * mib, last = bytes / sector - 1, arraySectors = 16384 / sector
        let recoveryEnd = last - arraySectors - 9, recoveryStart = recoveryEnd + 1 - 5 * mib / sector
        var parts = [("69646961-6700-11AA-AA11-00306543ECAC", Int64(40), Int64(2087)),
                     (GPT.appleAPFS, Int64(2088), recoveryStart - 1),
                     ("52637672-7900-11AA-AA11-00306543ECAC", recoveryStart, recoveryEnd)]
        if multiple {
            parts[2].2 = recoveryStart + 2 * mib / sector - 1
            parts.append((GPT.appleAPFS, parts[2].2 + 1, recoveryEnd))
        }
        var array = [UInt8](repeating: 0, count: 16384)
        for (i, part) in parts.enumerated() {
            let offset = i * 128
            array.replaceSubrange(offset..<offset + 16, with: guid(part.0))
            array.replaceSubrange(offset + 16..<offset + 32, with: [UInt8](repeating: UInt8(i + 1), count: 16))
            array.replaceSubrange(offset + 32..<offset + 48, with: le(part.1, 8) + le(part.2, 8))
            array[offset + 48] = UInt8(i) // attributes and partition names must survive too
            array[offset + 56] = UInt8(65 + i)
        }
        func header(current: Int64, backup: Int64, entries: Int64) -> [UInt8] {
            var h = [UInt8](repeating: 0, count: Int(sector))
            h.replaceSubrange(0..<8, with: Array("EFI PART".utf8))
            h.replaceSubrange(8..<16, with: le(0x10000, 4) + le(92, 4))
            h.replaceSubrange(24..<56, with: le(current, 8) + le(backup, 8) + le(2 + arraySectors, 8) + le(last - arraySectors - 1, 8))
            h.replaceSubrange(56..<72, with: [UInt8](repeating: 0xAB, count: 16))
            h.replaceSubrange(72..<92, with: le(entries, 8) + le(128, 4) + le(128, 4) + le(Int64(GPT.crc32(array[...])), 4))
            h.replaceSubrange(16..<20, with: le(Int64(GPT.crc32(h[0..<92])), 4))
            return h
        }
        let fd = open(path, O_RDWR | O_CREAT | O_EXCL, 0o600)
        precondition(fd >= 0)
        defer { close(fd) }
        precondition(ftruncate(fd, off_t(bytes)) == 0)
        var mbr = [UInt8](repeating: 0, count: 512)
        mbr[450] = 0xEE; mbr[510] = 0x55; mbr[511] = 0xAA
        mbr.replaceSubrange(454..<462, with: le(1, 4) + le(last, 4))
        try GPT.pwrite(fd, mbr, at: 0)
        try GPT.pwrite(fd, header(current: 1, backup: last, entries: 2), at: sector)
        try GPT.pwrite(fd, array, at: 2 * sector)
        try GPT.pwrite(fd, array, at: (last - arraySectors) * sector)
        try GPT.pwrite(fd, header(current: last, backup: 1, entries: last - arraySectors), at: last * sector)
        for (i, part) in parts.enumerated() {
            let pattern = (0..<8192).map { UInt8(truncatingIfNeeded: $0 * 17 + i) }
            try GPT.pwrite(fd, pattern, at: part.1 * sector)
            try GPT.pwrite(fd, pattern, at: (part.2 + 1) * sector - Int64(pattern.count))
        }
        return Fixture(path: path, sector: sector, bytes: bytes, parts: parts)
    }

    static func growth(in directory: URL, sector: Int64, increase: Int64, multiple: Bool) throws {
        let disk = try fixture(in: directory, sector: sector, multiple: multiple)
        defer { unlink(disk.path) }
        let original = try Data(contentsOf: URL(fileURLWithPath: disk.path))
        let newBytes = disk.bytes + increase
        print(try DiskGrowth.grow(path: disk.path, to: newBytes))
        let fd = open(disk.path, O_RDONLY)
        precondition(fd >= 0)
        defer { close(fd) }
        let table = try GPT.read(fd: fd, diskBytes: newBytes)
        for (i, part) in disk.parts.enumerated() {
            let shift = i > 1 ? increase : 0
            precondition(table.entries[i].first == part.first + shift / sector)
            precondition(table.entries[i].last == part.last + shift / sector)
            let offset = i * 128
            precondition(table.entryArray[offset..<offset + 32] == ArraySlice(original[Int(2 * sector) + offset..<Int(2 * sector) + offset + 32]))
            precondition(table.entryArray[offset + 48..<offset + 128] == ArraySlice(original[Int(2 * sector) + offset + 48..<Int(2 * sector) + offset + 128]))
            // Compare every partition byte, including holes and overlapping source/destination ranges.
            let start = part.first * sector, count = (part.last - part.first + 1) * sector
            precondition(try! GPT.pread(fd, Int(count), at: start + shift) == Array(original[Int(start)..<Int(start + count)]))
        }
        let gapStart = (disk.parts[1].last + 1) * sector
        precondition(GPT.isZero(try! GPT.pread(fd, Int(increase), at: gapStart)))
        // Validate backup CRC independently of GPT.read and compare both arrays.
        var backup = try GPT.pread(fd, Int(sector), at: newBytes - sector)
        let checksum = number(backup, 16, 4)
        backup.replaceSubrange(16..<20, with: le(0, 4))
        precondition(Int64(GPT.crc32(backup[0..<Int(number(backup, 12, 4))])) == checksum)
        precondition(number(backup, 24) == newBytes / sector - 1 && number(backup, 32) == 1)
        precondition(try! GPT.pread(fd, table.entryArray.count, at: number(backup, 72) * sector) == table.entryArray)
        let mbr = try GPT.pread(fd, 512, at: 0)
        precondition(number(mbr, 458, 4) == newBytes / sector - 1)
        // A second growth must recognize the rewritten geometry.
        _ = try DiskGrowth.grow(path: disk.path, to: newBytes + mib)
        precondition(!FileManager.default.fileExists(atPath: directory.appendingPathComponent(DiskGrowth.temporaryName).path))
    }

    static func rejects(in directory: URL, edit: (Int32, Fixture) throws -> Void, increase: Int64 = mib) throws {
        let disk = try fixture(in: directory, sector: 512)
        defer { unlink(disk.path) }
        let fd = open(disk.path, O_RDWR)
        precondition(fd >= 0)
        try edit(fd, disk)
        close(fd)
        let original = try Data(contentsOf: URL(fileURLWithPath: disk.path))
        do {
            _ = try DiskGrowth.grow(path: disk.path, to: disk.bytes + increase)
            preconditionFailure("invalid growth was accepted")
        } catch {
            precondition(try! Data(contentsOf: URL(fileURLWithPath: disk.path)) == original, "failed growth changed the original")
        }
    }

    static func main() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("henge-disk-growth-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let gb: Int64 = 1 << 30
        precondition(DiskGrowth.choices(currentBytes: 64 * gb) == [96, 128, 192, 256])
        precondition(DiskGrowth.choices(currentBytes: 100 * gb) == [128, 192, 256])
        precondition(DiskGrowth.choices(currentBytes: 128 * gb) == [192, 256])
        precondition(DiskGrowth.choices(currentBytes: 256 * gb).isEmpty)
        for state: Int32 in [0, 2] { precondition(DiskGrowth.refusal(vmState: state, currentBytes: 64 * gb, newGB: 128) == nil) }
        for state: Int32 in [-1, 1, 3, 4, 5] { precondition(DiskGrowth.refusal(vmState: state, currentBytes: 64 * gb, newGB: 128) != nil) }
        for size in [64, 32, 1024] { precondition(DiskGrowth.refusal(vmState: 0, currentBytes: 64 * gb, newGB: size) != nil) }
        for sector: Int64 in [512, 4096] {
            for multiple in [false, true] {
                for increase in [mib, 32 * mib] { try growth(in: directory, sector: sector, increase: increase, multiple: multiple) }
            }
        }
        try rejects(in: directory, edit: { _, _ in }, increase: 0)
        try rejects(in: directory, edit: { _, _ in }, increase: -mib)
        try rejects(in: directory, edit: { _, _ in }, increase: 1)
        try rejects(in: directory, edit: { _, _ in }, increase: 256 << 30)
        // Missing signature, invalid header lengths, and damaged primary/backup data must not mutate the disk.
        try rejects(in: directory) { fd, _ in try GPT.pwrite(fd, [0], at: 512) }
        for size: Int64 in [0, 91, 513, 0xFFFF_FFFF] {
            try rejects(in: directory) { fd, _ in try GPT.pwrite(fd, le(size, 4), at: 512 + 12) }
        }
        try rejects(in: directory) { fd, _ in try GPT.pwrite(fd, [0xFF], at: 1024) }
        try rejects(in: directory) { fd, disk in try GPT.pwrite(fd, [0], at: disk.bytes - 512) }
        try rejects(in: directory) { fd, disk in try GPT.pwrite(fd, [0xFF], at: disk.bytes - 512 - 16384) }
        try rejects(in: directory) { fd, _ in try GPT.pwrite(fd, [0], at: 450) }
        try rejects(in: directory) { fd, disk in
            var gpt = try GPT.read(fd: fd, diskBytes: disk.bytes)
            gpt.entries[2].first = gpt.entries[1].last // valid CRCs, overlapping partitions
            try gpt.write(fd: fd, diskBytes: disk.bytes)
        }
        try rejects(in: directory) { fd, disk in
            var gpt = try GPT.read(fd: fd, diskBytes: disk.bytes)
            gpt.entryArray.replaceSubrange(128..<144, with: guid("69646961-6700-11AA-AA11-00306543ECAC"))
            try gpt.write(fd: fd, diskBytes: disk.bytes) // no macOS APFS container in slot 2
        }
        // Checksummed but impossible geometry must fail before attempting an oversized read/allocation.
        for (offset, value): (Int, Int64) in [(72, Int64.max), (80, 0xFFFF_FFFF), (84, 0xFFFF_FFFF)] {
            try rejects(in: directory) { fd, _ in
                var h = try GPT.pread(fd, 512, at: 512)
                let length = offset == 72 ? 8 : 4
                h.replaceSubrange(offset..<offset + length, with: le(value, length))
                h.replaceSubrange(16..<20, with: le(0, 4))
                h.replaceSubrange(16..<20, with: le(Int64(GPT.crc32(h[0..<92])), 4))
                try GPT.pwrite(fd, h, at: 512)
            }
        }
        // A failed working-copy creation preserves both the original disk and any existing temporary file.
        let temporary = directory.appendingPathComponent(DiskGrowth.temporaryName)
        try Data("occupied".utf8).write(to: temporary)
        try rejects(in: directory) { _, _ in }
        precondition(try! Data(contentsOf: temporary) == Data("occupied".utf8))
        try FileManager.default.removeItem(at: temporary)
        // Force ftruncate to fail after the working copy has been created. The original must still be byte-identical.
        var limit = rlimit()
        precondition(getrlimit(RLIMIT_FSIZE, &limit) == 0)
        var restricted = limit
        restricted.rlim_cur = rlim_t(64 * mib)
        let previousSignal = signal(SIGXFSZ, SIG_IGN)
        precondition(setrlimit(RLIMIT_FSIZE, &restricted) == 0)
        do {
            defer {
                precondition(setrlimit(RLIMIT_FSIZE, &limit) == 0)
                signal(SIGXFSZ, previousSignal)
            }
            try rejects(in: directory) { _, _ in }
        }
        precondition(!FileManager.default.fileExists(atPath: temporary.path))
        precondition(GPT.isZero([]))
        var large = [UInt8](repeating: 0, count: 2 << 20)
        large[large.count - 1] = 1
        precondition(!GPT.isZero(large))
        print("disk growth: geometry, both GPT copies, full partition contents, overlap, repeated growth and failure preservation passed")
    }
}
