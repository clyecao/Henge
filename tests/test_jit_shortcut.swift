import AppIntents

// The intent runs in the app process. Record its call without starting a device-specific JIT helper.
@MainActor
final class JITCoordinator {
    static let shared = JITCoordinator()
    private(set) var requests = 0
    func enable() { requests += 1 }
}

@main
struct JITShortcutTests {
    @MainActor static func main() async throws {
        precondition(TurnOnJITIntent.openAppWhenRun)
        if #available(macOS 26.0, *) {
            precondition(TurnOnJITIntent.supportedModes == .foreground(.immediate))
        }
        _ = try await TurnOnJITIntent().perform()
        precondition(JITCoordinator.shared.requests == 1)

        var cold = JITLaunchRequest.idle
        precondition(cold.takeExplicitRequest())
        precondition(!cold.takeAutomaticRequest(if: true))
        precondition(cold.takeExplicitRequest()) // manual retry after returning to Henge

        var launch = JITLaunchRequest.idle
        precondition(!launch.takeAutomaticRequest(if: false))
        precondition(launch.takeAutomaticRequest(if: true))
        launch = .waitingForVPN
        precondition(!launch.takeExplicitRequest())
        precondition(!launch.takeAutomaticRequest(if: true))
        precondition(launch.finishVPNHandoff())
        precondition(!launch.finishVPNHandoff())
        precondition(launch.takeExplicitRequest())
        precondition(!launch.takeAutomaticRequest(if: true))
        print("JIT shortcut: foreground intent, explicit requests and launch/VPN handoff passed")
    }
}
