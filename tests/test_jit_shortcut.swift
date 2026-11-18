import AppIntents

// The intent runs in the app process. Record its call without starting a device-specific JIT helper.
@MainActor
final class JITCoordinator {
    static let shared = JITCoordinator()
    private(set) var requests = 0
    func enable() { requests += 1 }
}

@MainActor
enum JITBootstrap {
    static var confirmedReady = false
}

@main
struct JITShortcutTests {
    @MainActor static func query(wait seconds: Int) async throws -> Bool? {
        let intent = IsJITEnabledIntent()
        intent.waitSeconds = seconds
        return try await intent.perform().value
    }

    @MainActor static func main() async throws {
        precondition(TurnOnJITIntent.openAppWhenRun)
        precondition(!IsJITEnabledIntent.openAppWhenRun)
        if #available(macOS 26.0, *) {
            precondition(TurnOnJITIntent.supportedModes == .foreground(.immediate))
            precondition(IsJITEnabledIntent.supportedModes == .background)
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

        let pending = try await query(wait: 0)
        precondition(pending == false)
        let turnOn = Task { @MainActor in
            try await Task.sleep(for: .milliseconds(100))
            JITBootstrap.confirmedReady = true
        }
        let enabled = try await query(wait: 5)
        try await turnOn.value
        precondition(enabled == true)
        let immediate = try await query(wait: 0)
        precondition(immediate == true)
        JITBootstrap.confirmedReady = false
        let timeout = try await query(wait: 1)
        precondition(timeout == false)
        let cancelled = Task { try await query(wait: 30) }
        cancelled.cancel()
        do {
            _ = try await cancelled.value
            preconditionFailure("A cancelled wait must stop")
        } catch is CancellationError {}
        precondition(JITCoordinator.shared.requests == 1)
        print("JIT status shortcut: Boolean off/on, pending activation, timeout and cancellation passed")
    }
}
