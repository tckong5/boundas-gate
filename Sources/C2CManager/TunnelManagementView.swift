import AppKit
import SwiftUI

struct TunnelManagementView: View {
    @ObservedObject var gateway: SharedGatewayStore
    @Environment(\.dismiss) private var dismiss
    @State private var confirmLogout = false

    private var external: Bool { gateway.status?.transport == "external" }
    private var setup: EmbeddedConnectionSetup? { gateway.status?.transportSetup }
    private var busy: Bool { gateway.working || gateway.checking || gateway.reconnecting }
    private var savedURL: String? { gateway.status?.stableMCPURL ?? gateway.status?.mcpURL }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Advanced Tunnel Details").font(.title2.weight(.semibold))
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text(external ? "沿用 Mac 上嘅 Tailscale 裝置。" : "由 Boundas Gate 內置管理，毋須另外下載 Tailscale。")
                .font(.callout).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 6) {
                Text(setup?.state == "ready" ? "已登入" : "需要登入／授權").font(.headline)
                if let message = gateway.userFacingMessage, !message.isEmpty {
                    Text(message).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                } else if let setup, setup.state != "ready" {
                    Text(setup.message).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack {
                Button("登入／連線") { Task { await gateway.signInTunnel() } }
                    .disabled(busy || setup?.state == "ready")
                if let url = setup?.actionURL {
                    Link("繼續授權", destination: url).disabled(busy)
                }
                Button("登出…") { confirmLogout = true }
                    .disabled(busy || setup?.state == "missing" || gateway.status?.gatewayID == nil)
                Spacer()
                Button("重新檢查") { Task { await gateway.refresh() } }.disabled(busy)
            }
            if external {
                Button("開啟 Tailscale") {
                    if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "io.tailscale.ipn.macos") {
                        NSWorkspace.shared.openApplication(at: url, configuration: .init())
                    } else if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "io.tailscale.ipn.macsys") {
                        NSWorkspace.shared.openApplication(at: url, configuration: .init())
                    }
                }.buttonStyle(.borderless)
            }
            if let url = savedURL {
                Divider()
                Text("Server URL").font(.caption).foregroundStyle(.secondary)
                HStack(alignment: .top) {
                    Text(url).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button { gateway.copy(url) } label: { Image(systemName: "doc.on.doc") }
                        .buttonStyle(.borderless).help("Copy URL")
                }
            }
            Divider()
            HStack {
                Text(gateway.usable ? "Gate Open" : "登入完成後可以重新開啟 Gate。")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                if !gateway.usable {
                    Button("開啟 Gate") { Task { await gateway.repair() } }
                        .buttonStyle(.borderedProminent).disabled(busy || setup?.state != "ready")
                }
            }
        }
        .padding(24).frame(width: 500)
        .confirmationDialog("登出 Tunnel？", isPresented: $confirmLogout) {
            Button("登出", role: .destructive) {
                Task { _ = await gateway.perform("logout", confirmedExternal: external) }
            }
        } message: {
            Text(external
                 ? "將停止 Main Gate，並登出呢部 Mac 嘅外置 Tailscale；使用同一裝置嘅 Side Gates 同其他服務亦會暫停。Folders、MCP 授權同固定地址會保留。"
                 : "將停止 Main Gate 並登出佢嘅內置 Tunnel。Folders、MCP 授權同固定地址會保留；Side Gates 不受影響。")
        }
    }
}
