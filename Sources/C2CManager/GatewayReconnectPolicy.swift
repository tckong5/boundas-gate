import Foundation

struct GatewayReconnectPolicy {
    private(set) var attempts = 0
    private(set) var nextAttemptAt: Date?

    mutating func reset() {
        attempts = 0
        nextAttemptAt = nil
    }

    mutating func shouldAttempt(status: GatewayStatus?, usable: Bool, confirmed: Bool,
                                busy: Bool, now: Date = .now) -> Bool {
        guard confirmed, let status else { return false }
        if usable || status.desiredRunning != true || status.reconnectEnabled == false {
            reset()
            return false
        }
        guard !busy, status.state != "unknown", status.running != nil, !status.roots.isEmpty else { return false }
        if let current = EndpointAddress.mcpURL(status.publicUrl ?? status.tunnel?.url),
           let expected = EndpointAddress.mcpURL(status.stableMCPURL ?? status.configuredMCPURL), current != expected {
            return false
        }
        guard nextAttemptAt == nil || now >= nextAttemptAt! else { return false }
        nextAttemptAt = now.addingTimeInterval(min(120, 10 * pow(2, Double(attempts))))
        attempts = min(5, attempts + 1)
        return true
    }
}
