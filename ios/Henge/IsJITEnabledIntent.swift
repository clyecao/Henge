import AppIntents

struct IsJITEnabledIntent: AppIntent {
    static let title = LocalizedStringResource("Is JIT Enabled?", table: "HengeShortcuts")
    static let description = IntentDescription(
        LocalizedStringResource("Returns true when Henge has usable JIT. Use the result in an If action.", table: "HengeShortcuts"))
    static let openAppWhenRun = false
    @available(iOS 26.0, macOS 26.0, *)
    static var supportedModes: IntentModes { .background }

    @Parameter(title: LocalizedStringResource("Wait up to (seconds)", table: "HengeShortcuts"),
               default: 0, inclusiveRange: (0, 30))
    var waitSeconds: Int

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Bool> {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(min(max(waitSeconds, 0), 30)))
        while true {
            try Task.checkCancellation()
            if JITBootstrap.confirmedReady { return .result(value: true) }
            let now = clock.now
            if now >= deadline { return .result(value: false) }
            try await clock.sleep(until: min(deadline, now.advanced(by: .milliseconds(250))))
        }
    }
}
