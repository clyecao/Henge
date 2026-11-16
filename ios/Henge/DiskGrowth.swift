import Foundation
import Darwin

// Adapted from Leviidev/Henge PR #139, commit c7f6307623379eb4b62687577e41fd33fa0165b3.

/// Growing a stopped Mac's disk: which sizes are offered, when it is refused, and the partition table move that lets
/// macOS use the new space. A disk only ever grows, and only as far as the largest size listed here.
enum DiskGrowth {
    static let sizesGB = [96, 128, 192, 256]

    /// What macOS has to do afterwards: it keeps using the old size until its APFS container is grown inside it.
    /// Henge has already moved the recovery partition to the end of the disk, so the free space sits right after the
    /// container and this one command is enough (APFS grows a mounted container in place).
    static let guestCommand = "sudo diskutil apfs resizeContainer disk0s2 0"

    static func choices(currentBytes: Int64) -> [Int] { sizesGB.filter { Int64($0) << 30 > currentBytes } }

    /// Why a disk cannot be grown now, or nil. `vmState` is henge_vm_state(): 1 running, 3 starting or stopping, 4 paused.
    static func refusal(vmState: Int32, currentBytes: Int64, newGB: Int) -> String? {
        if vmState != 0 && vmState != 2 { return "Stop the Mac first." }
        if !choices(currentBytes: currentBytes).contains(newGB) { return "The disk can only grow to a larger size." }
        return nil
    }

    struct Failure: LocalizedError, CustomStringConvertible {
        let description: String
        var errorDescription: String? { description }
    }

    static let temporaryName = "disk.img.growing"

    /// Makes the disk image at `path` `newBytes` long and moves its GPT to match. A macOS installer lays the disk out as
    /// iBoot system container, macOS's APFS container, then a 5 GB recovery container at the very end. Growing the file
    /// alone leaves the free space after the recovery container, where APFS cannot reach it, and the backup GPT in the
    /// middle of the disk. So every partition after the macOS container moves to the new end (same offset from the end,
    /// so alignment is kept), the backup GPT is written at the new last sector, and the space the moved partitions left
    /// is given back to the file system. Partition contents are position-independent (APFS addresses blocks from the
    /// partition start), and the GUIDs don't change. Returns what moved, for the log.
    @discardableResult
    static func grow(path: String, to newBytes: Int64) throws -> String {
        let source = open(path, O_RDONLY | O_NOFOLLOW)
        guard source >= 0 else { throw Failure(description: "The disk could not be opened (\(String(cString: strerror(errno)))).") }
        defer { close(source) }
        guard flock(source, LOCK_EX | LOCK_NB) == 0 else { throw Failure(description: "The disk is already in use.") }
        var st = stat()
        guard fstat(source, &st) == 0, st.st_mode & S_IFMT == S_IFREG else { throw Failure(description: "The disk is not a regular file.") }
        let oldBytes = Int64(st.st_size)
        guard newBytes > oldBytes, newBytes <= 256 << 30 else { throw Failure(description: "The disk can only grow, up to 256 GB.") }
        var gpt = try GPT.read(fd: source, diskBytes: oldBytes)
        guard newBytes % gpt.sector == 0 else { throw Failure(description: "The new size must be a whole number of disk sectors.") }
        guard gpt.entries.contains(where: { $0.index == 1 && $0.type == GPT.appleAPFS }) else {
            throw Failure(description: "This disk does not have the expected macOS container in partition 2.")
        }

        // APFS clones share the original blocks. All writes happen in the clone, so an I/O error, suspension or
        // interrupted copy leaves the original disk usable. Only a fully written, verified clone replaces it.
        let temporary = URL(fileURLWithPath: path).deletingLastPathComponent().appendingPathComponent(temporaryName).path
        guard clonefile(path, temporary, 0) == 0 else {
            throw Failure(description: "A safe working copy could not be created (\(String(cString: strerror(errno)))). Reopen Henge and try again.")
        }
        defer { unlink(temporary) }
        let fd = open(temporary, O_RDWR | O_NOFOLLOW)
        guard fd >= 0 else { throw Failure(description: "The working copy could not be opened.") }
        defer { close(fd) }
        guard ftruncate(fd, off_t(newBytes)) == 0 else {
            throw Failure(description: "The disk could not be made larger (\(String(cString: strerror(errno)))).")
        }
        // The old backup table isn't partition data: clear it first, so no stale header is left mid-disk.
        let oldArray = (Int64(gpt.entryArray.count) + gpt.sector - 1) / gpt.sector
        try GPT.zero(fd, at: oldBytes - (oldArray + 1) * gpt.sector, count: (oldArray + 1) * gpt.sector)
        let note = try gpt.moveTrailingPartitions(fd: fd, newBytes: newBytes)
        try gpt.write(fd: fd, diskBytes: newBytes)
        _ = try GPT.read(fd: fd, diskBytes: newBytes)
        guard fsync(fd) == 0 else { throw Failure(description: "The enlarged disk could not be saved.") }
        guard rename(temporary, path) == 0 else { throw Failure(description: "The enlarged disk could not replace the original.") }
        return note
    }
}

/// The parts of a GUID partition table (UEFI 2.10, section 5.3) a grow touches.
struct GPT {
    static let appleAPFS = "7C3457EF-0000-11AA-AA11-00306543ECAC"

    struct Entry { var index: Int; var type: String; var first: Int64; var last: Int64 }

    var sector: Int64
    var header: [UInt8]          // the primary header sector, as read
    var entryArray: [UInt8]      // every entry slot, as read
    var entrySize: Int
    var entries: [Entry]

    private static func u32(_ b: [UInt8], _ o: Int) -> UInt32 { (0..<4).reduce(UInt32(0)) { $0 | UInt32(b[o + $1]) << (8 * $1) } }
    private static func u64(_ b: [UInt8], _ o: Int) -> Int64 { Int64(bitPattern: (0..<8).reduce(UInt64(0)) { $0 | UInt64(b[o + $1]) << (8 * $1) }) }
    private static func put32(_ b: inout [UInt8], _ o: Int, _ v: UInt32) { for i in 0..<4 { b[o + i] = UInt8(truncatingIfNeeded: v >> (8 * i)) } }
    private static func put64(_ b: inout [UInt8], _ o: Int, _ v: Int64) { for i in 0..<8 { b[o + i] = UInt8(truncatingIfNeeded: UInt64(bitPattern: v) >> (8 * i)) } }

    static func crc32(_ bytes: ArraySlice<UInt8>) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for byte in bytes {
            c ^= UInt32(byte)
            for _ in 0..<8 { c = c & 1 != 0 ? (c >> 1) ^ 0xEDB8_8320 : c >> 1 }
        }
        return ~c
    }

    private static func guid(_ b: ArraySlice<UInt8>) -> String {
        let x = Array(b)
        let order = [3, 2, 1, 0, -1, 5, 4, -1, 7, 6, -1, 8, 9, -1, 10, 11, 12, 13, 14, 15]
        return order.map { $0 < 0 ? "-" : String(format: "%02X", x[$0]) }.joined()
    }

    static func pread(_ fd: Int32, _ count: Int, at offset: Int64) throws -> [UInt8] {
        var b = [UInt8](repeating: 0, count: count)
        try b.withUnsafeMutableBytes { buffer in
            var done = 0
            while done < count {
                let n = Darwin.pread(fd, buffer.baseAddress!.advanced(by: done), count - done, off_t(offset + Int64(done)))
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { throw DiskGrowth.Failure(description: "The disk could not be read.") }
                done += n
            }
        }
        return b
    }

    static func pwrite(_ fd: Int32, _ b: [UInt8], at offset: Int64) throws {
        try b.withUnsafeBytes { buffer in
            var done = 0
            while done < b.count {
                let n = Darwin.pwrite(fd, buffer.baseAddress!.advanced(by: done), b.count - done, off_t(offset + Int64(done)))
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else {
                    throw DiskGrowth.Failure(description: "The disk could not be written (\(String(cString: strerror(errno)))). Check free storage.")
                }
                done += n
            }
        }
    }

    static func read(fd: Int32, diskBytes: Int64) throws -> GPT {
        let invalid = DiskGrowth.Failure(description: "The disk's GUID partition table is damaged or unsupported. The disk was not changed.")
        for sector: Int64 in [512, 4096] {
            guard diskBytes >= 6 * sector, diskBytes % sector == 0 else { continue }
            let h = try pread(fd, Int(sector), at: sector)
            guard h[0..<8] == ArraySlice(Array("EFI PART".utf8)) else { continue }
            let size = Int(u32(h, 12))
            // Check lengths before slicing or allocating: imported disk images are not trusted.
            guard size >= 92, size <= Int(sector), u32(h, 8) == 0x0001_0000, u32(h, 20) == 0 else { throw invalid }
            var check = Array(h[0..<size]); put32(&check, 16, 0)
            guard crc32(check[...]) == u32(h, 16) else { throw invalid }
            let last = diskBytes / sector - 1
            guard u64(h, 24) == 1, u64(h, 32) == last else { throw invalid }
            let n = Int(u32(h, 80)), size1 = Int(u32(h, 84))
            guard n > 0, n <= 1024, size1 >= 128, size1 <= 4096, size1 & (size1 - 1) == 0 else { throw invalid }
            let arraySectors = (Int64(n * size1) + sector - 1) / sector
            let firstUsable = u64(h, 40), lastUsable = u64(h, 48), arrayAt = u64(h, 72)
            guard firstUsable >= 2 + arraySectors, firstUsable <= lastUsable,
                  lastUsable < last - arraySectors, arrayAt >= 2, arrayAt <= firstUsable - arraySectors else { throw invalid }
            let array = try pread(fd, n * size1, at: arrayAt * sector)
            guard crc32(array[...]) == u32(h, 88) else { throw invalid }

            // Both GPT copies must agree before any data moves; never silently grow a corrupt image.
            let backup = try pread(fd, Int(sector), at: last * sector)
            guard backup[0..<8] == h[0..<8], u32(backup, 8) == u32(h, 8), u32(backup, 12) == UInt32(size),
                  u32(backup, 20) == 0, u64(backup, 24) == last, u64(backup, 32) == 1,
                  backup[40..<72] == h[40..<72], backup[80..<92] == h[80..<92] else { throw invalid }
            var backupCheck = Array(backup[0..<size]); put32(&backupCheck, 16, 0)
            let backupAt = u64(backup, 72)
            guard crc32(backupCheck[...]) == u32(backup, 16), backupAt > lastUsable,
                  backupAt == last - arraySectors else { throw invalid }
            guard try pread(fd, n * size1, at: backupAt * sector) == array else { throw invalid }

            let mbr = try pread(fd, 512, at: 0)
            guard mbr[510] == 0x55, mbr[511] == 0xAA, mbr[450] == 0xEE,
                  u32(mbr, 454) == 1, u32(mbr, 458) == UInt32(min(last, 0xFFFF_FFFF)),
                  (1..<4).allSatisfy({ mbr[446 + 16 * $0 + 4] == 0 }) else { throw invalid }
            var entries: [Entry] = []
            for i in 0..<n {
                let o = i * size1
                if array[o..<o + 16].allSatisfy({ $0 == 0 }) { continue }
                let first = u64(array, o + 32), end = u64(array, o + 40)
                guard first >= firstUsable, end >= first, end <= lastUsable else { throw invalid }
                entries.append(Entry(index: i, type: guid(array[o..<o + 16]), first: first, last: end))
            }
            let sorted = entries.sorted { $0.first < $1.first }
            for (left, right) in zip(sorted, sorted.dropFirst()) {
                guard left.last < right.first else { throw invalid }
            }
            return GPT(sector: sector, header: h, entryArray: array, entrySize: size1, entries: entries)
        }
        throw DiskGrowth.Failure(description: "The disk has no supported GUID partition table. The disk was not changed.")
    }

    /// Moves the partitions after macOS's container to the new end of the disk, copying from the end backwards so a
    /// move shorter than the partition never reads what it already wrote. Zero runs (holes in the sparse file) become
    /// holes again instead of being written out.
    mutating func moveTrailingPartitions(fd: Int32, newBytes: Int64) throws -> String {
        guard let container = entries.first(where: { $0.index == 1 && $0.type == Self.appleAPFS }) else {
            throw DiskGrowth.Failure(description: "The macOS container could not be found.")
        }
        let delta = newBytes / sector - (Self.u64(header, 32) + 1)
        let trailing = entries.indices.filter { entries[$0].first > container.last }.sorted { entries[$0].first > entries[$1].first }
        var moved: [String] = []
        let chunk: Int64 = 1 << 20
        for i in trailing {
            let e = entries[i]
            let start = e.first * sector, end = (e.last + 1) * sector
            var at = end
            while at > start {
                let from = max(start, at - chunk), count = Int(at - from)
                let data = try Self.pread(fd, count, at: from)
                if Self.isZero(data) {
                    try Self.zero(fd, at: from + delta * sector, count: Int64(count))
                } else {
                    try Self.pwrite(fd, data, at: from + delta * sector)
                }
                at = from
            }
            // What the partition no longer covers goes back to the file system (and reads as zeros).
            try Self.zero(fd, at: start, count: min(end, start + delta * sector) - start)
            entries[i].first += delta
            entries[i].last += delta
            moved.append("partition \(e.index + 1) moved \(e.first)->\(e.first + delta)")
        }
        return moved.isEmpty ? "nothing after the macOS container" : moved.joined(separator: ", ")
    }

    private static let zeroChunk = [UInt8](repeating: 0, count: 1 << 20)

    static func isZero(_ b: [UInt8]) -> Bool {
        b.withUnsafeBytes { p in
            zeroChunk.withUnsafeBytes { z in
                var offset = 0
                while offset < p.count {
                    let count = min(p.count - offset, z.count)
                    if memcmp(p.baseAddress!.advanced(by: offset), z.baseAddress!, count) != 0 { return false }
                    offset += count
                }
                return true
            }
        }
    }

    /// Zeros a range, as a hole where the file system allows it (it needs block-aligned ranges).
    static func zero(_ fd: Int32, at offset: Int64, count: Int64) throws {
        guard count > 0 else { return }
        var hole = fpunchhole_t(fp_flags: 0, reserved: 0, fp_offset: off_t(offset), fp_length: off_t(count))
        if fcntl(fd, F_PUNCHHOLE, &hole) == 0 { return }
        let zeros = [UInt8](repeating: 0, count: Int(min(count, 1 << 20)))
        var at = offset
        while at < offset + count {
            let n = Int(min(Int64(zeros.count), offset + count - at))
            try pwrite(fd, Array(zeros[0..<n]), at: at)
            at += Int64(n)
        }
    }

    /// Writes the backup table at the new end first, then the primary, then the protective MBR's size.
    func write(fd: Int32, diskBytes: Int64) throws {
        let last = diskBytes / sector - 1
        let arraySectors = (Int64(entryArray.count) + sector - 1) / sector
        var array = entryArray
        for e in entries {
            Self.put64(&array, e.index * entrySize + 32, e.first)
            Self.put64(&array, e.index * entrySize + 40, e.last)
        }
        let arrayCRC = Self.crc32(array[...])
        let size = Int(Self.u32(header, 12))
        func headerSector(current: Int64, backup: Int64, entriesAt: Int64) -> [UInt8] {
            var h = header
            Self.put64(&h, 24, current)
            Self.put64(&h, 32, backup)
            Self.put64(&h, 48, last - arraySectors - 1)   // last usable sector
            Self.put64(&h, 72, entriesAt)
            Self.put32(&h, 88, arrayCRC)
            Self.put32(&h, 16, 0)
            Self.put32(&h, 16, Self.crc32(h[0..<size]))
            return h
        }
        let backupArrayAt = last - arraySectors
        try Self.pwrite(fd, array, at: backupArrayAt * sector)
        try Self.pwrite(fd, headerSector(current: last, backup: 1, entriesAt: backupArrayAt), at: last * sector)
        try Self.pwrite(fd, array, at: Self.u64(header, 72) * sector)
        try Self.pwrite(fd, headerSector(current: 1, backup: last, entriesAt: Self.u64(header, 72)), at: sector)
        var mbr = try Self.pread(fd, 512, at: 0)
        if mbr[510] == 0x55 && mbr[511] == 0xAA && mbr[446 + 4] == 0xEE {
            Self.put32(&mbr, 446 + 12, UInt32(min(last, 0xFFFF_FFFF)))
            try Self.pwrite(fd, mbr, at: 0)
        }
    }
}
