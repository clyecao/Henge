import Foundation

@main
enum TestPhysicalPointerRoute {
    static func main() {
        let screen = CGRect(x: 20, y: 40, width: 1001, height: 601)
        let before = CGPoint(x: screen.minX, y: screen.maxY - 1)
        let after = CGPoint(x: screen.maxX - 1, y: screen.minY)

        // Switch out while locked, move on the iPad, then return before UIKit grants the lock again.
        precondition(PhysicalPointerRoute(active: true, locked: true, localDisplay: true) == .relative)
        for staleLock in [true, false] {
            precondition(PhysicalPointerRoute(active: false, locked: staleLock, localDisplay: true) == .inactive)
        }
        precondition(PhysicalPointerRoute(active: true, locked: false, localDisplay: true) == .absolute)
        precondition(PhysicalPointerRoute.position(before, in: screen) == CGPoint(x: 0, y: 1))
        precondition(PhysicalPointerRoute.position(after, in: screen) == CGPoint(x: 1, y: 0))
        precondition(PhysicalPointerRoute.position(.zero, in: screen) == .zero)
        precondition(PhysicalPointerRoute.position(CGPoint(x: 1100, y: 700), in: screen) == CGPoint(x: 1, y: 1))
        let zoom = screen.offsetBy(dx: -400, dy: -300)
        precondition(PhysicalPointerRoute.position(CGPoint(x: 120, y: 40), in: zoom) == CGPoint(x: 0.5, y: 0.5))
        precondition(PhysicalPointerRoute.position(.zero, in: .zero) == nil)
        precondition(PhysicalPointerRoute(active: true, locked: false, localDisplay: false) == .relative)
        print("Physical pointer focus, lock, edges and viewport checks passed")
    }
}
