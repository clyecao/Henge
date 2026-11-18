/// The launch preference gets one attempt. An explicit request can retry after setup or a failure.
enum JITLaunchRequest {
    case idle, waitingForVPN, requested

    mutating func takeAutomaticRequest(if enabled: @autoclosure () -> Bool) -> Bool {
        guard self == .idle, enabled() else { return false }
        self = .requested
        return true
    }

    mutating func takeExplicitRequest() -> Bool {
        guard self != .waitingForVPN else { return false }
        self = .requested
        return true
    }

    mutating func finishVPNHandoff() -> Bool {
        guard self == .waitingForVPN else { return false }
        self = .requested
        return true
    }
}
