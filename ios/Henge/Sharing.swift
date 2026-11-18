import SwiftUI
import UIKit
import Combine

/// What a running Mac shares with this device: the Shared folder in Files, and the clipboard. The Mac mounts
/// the folder and follows the clipboard through a small helper (host/share.c, tools/henge-agent.m).
enum Sharing {
    static var folder: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Shared", isDirectory: true)
    }

    static let setUpCommand = "curl -s http://10.0.2.4/.henge/install | sh"
    /// Less background work and drawing in macOS (host/share.c, lighten_script), and back.
    static let lightenCommand = "curl -s http://10.0.2.4/.henge/lighten | sh"
    static let unlightenCommand = "curl -s http://10.0.2.4/.henge/unlighten | sh"

    /// Before a Mac starts.
    static func prepare() {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // A Unix socket's path can't be long, so the short temporary folder.
        let socket = (NSTemporaryDirectory() as NSString).appendingPathComponent("s.sock")
        henge_vm_share(folder.path, socket, Bundle.main.path(forResource: "henge-agent", ofType: "gz"))
    }

    /// The helper asks the server for news at most 25 s apart.
    static var helperRunning: Bool {
        let seen = henge_share_agent_seen()
        return seen >= 0 && seen < 40
    }

    /// What is copied on the Mac is copied here too. The other way needs the system's paste button: iOS
    /// asks for permission whenever an app reads the clipboard on its own.
    static func followMacClipboard() async {
        while !Task.isCancelled {
            if let text = henge_share_take_clipboard() {
                UIPasteboard.general.string = String(cString: text)
                free(text)
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
    }

    /// Text from this device, pasted at the Mac's cursor. Without the helper it is typed, as far as the keyboard can.
    static func paste(_ text: String) {
        Task { @MainActor in
            if helperRunning {
                henge_share_set_clipboard(text)
                try? await Task.sleep(nanoseconds: 800_000_000) // for the helper to put it on the Mac's clipboard
                Keys.chord(Keys.command, "v")
            } else {
                await Keys.typeSlowly(text)
            }
        }
    }

    /// Types the set up command at the Mac's cursor, and stops there: the person using the Mac presses Return.
    /// Henge can't see what has the keyboard, so it must not submit anything by itself. Opening Terminal for them
    /// through Spotlight was tried: when Spotlight was slow the text went to a web search, and it could as easily
    /// have gone to a chat.
    static func typeSetUpCommand() async {
        await Keys.typeSlowly(setUpCommand)
    }
}

/// Publish a fresh reading whenever the running Mac becomes visible, then follow UIKit notifications.
struct SharedBattery: ViewModifier {
    let active: Bool
    @State private var previousMonitoring: Bool?

    private func monitor(_ on: Bool) {
        let device = UIDevice.current
        if on {
            if previousMonitoring == nil { previousMonitoring = device.isBatteryMonitoringEnabled }
            device.isBatteryMonitoringEnabled = true
            publish()
        } else if let previousMonitoring {
            device.isBatteryMonitoringEnabled = previousMonitoring
            self.previousMonitoring = nil
            hv_share_set_battery(-1, HV_BATTERY_UNKNOWN, 0)
        }
    }

    private func publish() {
        let device = UIDevice.current
        let level = device.batteryLevel
        let percent: Int32 = (0...1).contains(level) ? Int32((level * 100).rounded()) : -1
        let state: HvBatteryState
        switch device.batteryState {
        case .charging: state = HV_BATTERY_CHARGING
        case .full: state = HV_BATTERY_FULL
        case .unplugged: state = HV_BATTERY_UNPLUGGED
        default: state = HV_BATTERY_UNKNOWN
        }
        hv_share_set_battery(percent, state, ProcessInfo.processInfo.isLowPowerModeEnabled ? 1 : 0)
    }

    func body(content: Content) -> some View {
        let notifications = NotificationCenter.default
        content
            .onChange(of: active, initial: true) { _, on in monitor(on) }
            .onReceive(notifications.publisher(for: UIDevice.batteryLevelDidChangeNotification)
                .merge(with: notifications.publisher(for: UIDevice.batteryStateDidChangeNotification),
                       notifications.publisher(for: .NSProcessInfoPowerStateDidChange))
                .receive(on: RunLoop.main)) { _ in
                    if active { publish() }
                }
            .onDisappear { monitor(false) }
    }
}
