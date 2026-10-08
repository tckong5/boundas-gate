import Foundation

struct GatewayReconnectPolicy {
    private(set) var attempts = 0
    private(set) var nextAttemptAt: Date?

    mutating func reset() {
        attempts = 0
        nextAttemptAt = nil
    }

    mutating func shouldAttempt(status: GatewayStatus?, usable: Bool, confirmed: Bool,
                                busy: Bool, diagnostics: ConnectionDiagnostics? = nil, now: Date = .now) -> Bool {
        guard confirmed, let status else { return false }
        if usable || status.desiredRunning != true || status.reconnectEnabled == false {
            reset()
            return false
        }
        // Local-only startup is resumable, but never escalates into Tunnel setup.
        if status.localOnly == true && status.running == true {
            reset()
            return false
        }
        // Awaiting account consent is not a route failure. Background status
        // still observes browser completion; only ready can resume the route.
        if status.running == true, let setup = status.transportSetup,
           ["login", "blocked", "starting", "unconfigured", "missing"].contains(setup.state) {
            reset()
            return false
        }
        // Restarting a healthy route cannot repair this Mac's DNS resolver.
        // Keep observing DNS recovery without repeatedly tearing down ingress.
        if status.running == true, status.tunnel?.running == true,
           diagnostics?.hasPublicDNSFailure == true, diagnostics?.address.passed == true {
            reset()
            return false
        }
        guard !busy, status.state != "unknown", status.running != nil else { return false }
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
