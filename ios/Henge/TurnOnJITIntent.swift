import AppIntents

struct TurnOnJITIntent: AppIntent {
    static let title = LocalizedStringResource("Turn On JIT", table: "HengeShortcuts")
    static let description = IntentDescription(
        LocalizedStringResource("Open Henge and request JIT using the method selected in Settings.", table: "HengeShortcuts"))

    // iOS 17–18 use openAppWhenRun. Newer systems can explicitly foreground Henge before perform().
    static let openAppWhenRun = true
    @available(iOS 26.0, macOS 26.0, *)
    static var supportedModes: IntentModes { .foreground(.immediate) }

    @MainActor
    func perform() async throws -> some IntentResult {
        JITCoordinator.shared.enable()
        return .result()
    }
}

struct HengeShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: TurnOnJITIntent(),
                    phrases: ["Turn on JIT in \(.applicationName)"],
                    shortTitle: LocalizedStringResource("Turn On JIT", table: "HengeShortcuts"),
                    systemImageName: "bolt.fill")
        AppShortcut(intent: IsJITEnabledIntent(),
                    phrases: ["Check JIT status in \(.applicationName)"],
                    shortTitle: LocalizedStringResource("Is JIT Enabled?", table: "HengeShortcuts"),
                    systemImageName: "bolt.badge.checkmark")
    }
}
