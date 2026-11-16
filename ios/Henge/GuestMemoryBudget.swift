import Foundation

/// Guest RAM is limited separately by storage for its backing file and by a contiguous address range.
/// Measure the latter only after releasing unused Mac-app reservations.
struct GuestMemoryBudget {
    let requestedMB: UInt64
    let freeStorageBytes: Int64?
    let largestMappingMB: UInt64

    var storageMB: UInt64 {
        guard let freeStorageBytes else { return .max }
        guard freeStorageBytes > 2 << 30 else { return 0 }
        return UInt64(freeStorageBytes - (2 << 30)) >> 20
    }

    var addressMB: UInt64 { largestMappingMB > 512 ? largestMappingMB - 512 : 0 }
    var ramMB: UInt64 { min(requestedMB, storageMB, addressMB) / 512 * 512 }

    func refusal(minimumMB: UInt64) -> String? {
        guard ramMB < minimumMB else { return nil }
        if requestedMB < minimumMB { return "Select at least \(minimumMB) MB of VM memory." }
        if storageMB < minimumMB {
            let freeMB = max(freeStorageBytes ?? 0, 0) >> 20
            return "Not enough free device storage for VM memory: \(freeMB) MB available. Free at least \(minimumMB + 2048) MB, then try again. Increasing the virtual disk capacity does not free device storage."
        }
        return "Not enough contiguous address space for VM memory: \(largestMappingMB) MB available; at least \(minimumMB + 512) MB is needed. Quit Henge completely and reopen it, enable JIT, and try again before running Mac Apps."
    }
}
