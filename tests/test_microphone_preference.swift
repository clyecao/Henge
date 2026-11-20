import Foundation

@main
struct MicrophonePreferenceTest {
    static func main() {
        let args = CommandLine.arguments
        let mac = MicrophoneSharingPreference(macID: UUID(uuidString: args[2])!)
        let other = MicrophoneSharingPreference(macID: UUID(uuidString: args[3])!)
        precondition(!other.enabled, "Sharing should be independent for each Mac")
        switch args[1] {
        case "enable":
            precondition(!mac.enabled, "A new Mac should start with sharing off")
            mac.enabled = true
        case "disable":
            precondition(mac.enabled, "Sharing should survive a relaunch")
            mac.enabled = false
        case "verify":
            precondition(!mac.enabled, "Turning sharing off should survive a relaunch")
        default:
            preconditionFailure("Unknown test step")
        }
        // The next test process starts immediately after this one exits.
        precondition(UserDefaults.standard.synchronize())
    }
}
