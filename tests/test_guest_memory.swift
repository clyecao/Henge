import Foundation

@main
struct GuestMemoryTests {
    static func main() {
        let gib: Int64 = 1 << 30
        // Before the unused Mac-app holds are released, even ample storage cannot fit an install's 2 GiB RAM.
        let held = GuestMemoryBudget(requestedMB: 4096, freeStorageBytes: 100 * gib, largestMappingMB: 2048)
        precondition(held.ramMB == 1536)
        precondition(held.refusal(minimumMB: 2048)?.contains("address space") == true)
        let released = GuestMemoryBudget(requestedMB: 4096, freeStorageBytes: 100 * gib, largestMappingMB: 16896)
        precondition(released.ramMB == 4096 && released.refusal(minimumMB: 2048) == nil)
        for bytes in [Int64.min, -1, 0, gib, 2 * gib, 4 * gib - 1] {
            let budget = GuestMemoryBudget(requestedMB: 4096, freeStorageBytes: bytes, largestMappingMB: 16896)
            precondition(budget.refusal(minimumMB: 2048)?.contains("device storage") == true)
        }
        let exact = GuestMemoryBudget(requestedMB: 4096, freeStorageBytes: 4 * gib, largestMappingMB: 2560)
        precondition(exact.ramMB == 2048 && exact.refusal(minimumMB: 2048) == nil)
        let unknown = GuestMemoryBudget(requestedMB: 4096, freeStorageBytes: nil, largestMappingMB: 16896)
        precondition(unknown.ramMB == 4096 && unknown.refusal(minimumMB: 2048) == nil)
        let rounded = GuestMemoryBudget(requestedMB: 4096, freeStorageBytes: 5 * gib - 1, largestMappingMB: 16896)
        precondition(rounded.ramMB == 2560)
        let maximum = GuestMemoryBudget(requestedMB: 16384, freeStorageBytes: .max, largestMappingMB: 16896)
        precondition(maximum.ramMB == 16384)
        for reach: UInt64 in [0, 512, 1024, 2048] {
            let budget = GuestMemoryBudget(requestedMB: 4096, freeStorageBytes: nil, largestMappingMB: reach)
            precondition(budget.refusal(minimumMB: 2048)?.contains("address space") == true)
        }
        let small = GuestMemoryBudget(requestedMB: 512, freeStorageBytes: 100 * gib, largestMappingMB: 16896)
        precondition(small.refusal(minimumMB: 1024)?.contains("Select at least") == true)
        print("Guest memory: storage, address space, unknown/zero capacity and RAM limits passed")
    }
}
