import Foundation

struct SecureAccessPresentation {
    enum Action: Equatable { case setUp, signIn, approve, repair, repairDNS, recheck }
    let description: String
    let action: Action?
    let external: Bool
    let isSideGate: Bool
    let shared: Bool
    let approvalURL: URL?
    let canSignOut: Bool
    var button: String {
        switch action {
        case .setUp: return "Set Up"
        case .signIn: return isSideGate && !shared ? "Continue with Tailscale" : "Sign In"
        case .approve: return "Continue Authorization"
        case .repair, .repairDNS: return "Repair"
        case .recheck: return "Recheck"
        case nil: return ""
        }
    }
    static func approvalLink(in message: String) -> URL? {
        guard let range = message.range(of: #"https://login\.tailscale\.com/[^\s<>"']+"#, options: .regularExpression),
              let url = URL(string: String(message[range])), url.host == "login.tailscale.com" else { return nil }
        return url
    }

    static func make(status: GatewayStatus?, complete: Bool, message: String?, diagnostics: ConnectionDiagnostics? = nil,
                     isSideGate: Bool = false) -> Self {
        let external = status?.transport == "external"
        func result(_ text: String, _ action: Action?, _ url: URL? = nil) -> Self {
            .init(description: text, action: action, external: external, isSideGate: isSideGate, shared: status?.sharedTunnel == true, approvalURL: url,
                  canSignOut: status?.transport != "cloudflare" && status?.transportSetup?.state == "ready" && action != .signIn)
        }
        if complete { return result(status?.transport == "cloudflare" ? "Secure access is available." : "Tailscale · Connected", nil) }
        if status?.running == true, status?.tunnel?.running == true,
           diagnostics?.hasPublicDNSFailure == true, diagnostics?.address.passed == true {
            return result("This Mac can't find your Gate's address. Repair can refresh its network cache, then check again.", .repairDNS)
        }
        let setup = status?.transportSetup
        if status?.transport == "cloudflare" {
            return result(status?.localOnly == true ? "Secure access needs to be set up." : "Secure access needs attention. Your existing setup is preserved.",
                          status?.localOnly == true ? .setUp : .repair)
        }
        if setup?.state == "ready", status?.localOnly == true { return result(status?.sharedTunnel == true && isSideGate ? "Use your existing Tailscale connection for this Gate." : "Secure access needs to be set up.", .setUp) }
        if let url = setup?.actionURL, setup?.approvalURL != nil {
            return result("Tailscale needs your approval.", .approve, url)
        }
        if setup?.state == "login" || setup?.loginURL != nil {
            if isSideGate && status?.sharedTunnel != true {
                return result("Continue with Tailscale to authorize secure access for this Side Gate.", .signIn)
            }
            return result(external ? "Sign in to Tailscale to continue." : "Sign in to Tailscale to securely reach this Gate.", .signIn)
        }
        if let message, let url = Self.approvalLink(in: message) {
            return result("Tailscale needs your approval.", .approve, url)
        }
        if status?.gatewayID == nil || setup?.state == "unconfigured" { return result("Secure access needs to be set up.", .setUp) }
        if setup?.state == "starting" { return result("Preparing secure access to your Gate.", .recheck) }
        return result("Tailscale connection needs attention. Your existing setup is preserved.", .repair)
    }
}
