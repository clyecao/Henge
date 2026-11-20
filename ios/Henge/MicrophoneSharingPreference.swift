import Foundation

/// The host's choice for one virtual Mac, independent of its current audio session.
struct MicrophoneSharingPreference {
    private let key: String

    init(macID: UUID) { key = "henge.microphone.\(macID.uuidString)" }

    var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: key) }
        nonmutating set {
            if newValue {
                UserDefaults.standard.set(true, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
    }
}
