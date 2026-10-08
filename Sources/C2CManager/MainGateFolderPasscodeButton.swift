import SwiftUI

struct MainGateFolderPasscodeButton: View {
    @ObservedObject var gateway: SharedGatewayStore
    let workspace: WorkspaceRecord
    let configurationChanged: Bool
    @State private var showingPopover = false
    @State private var hovering = false
    @State private var actionError: String?

    private var root: GatewayRoot? {
        gateway.status?.roots.first { $0.sourceID.lowercased() == workspace.id.uuidString.lowercased() }
    }

    private var required: Bool { root?.codeRequired == true }
    private var legacyConnection: Bool {
        gateway.status?.running == true && gateway.status?.accessCodeVersion != 1
    }
    private var policyDisabled: Bool {
        root == nil || gateway.working || configurationChanged || !gateway.statusConfirmed
            || gateway.status?.state == "unknown" || legacyConnection
    }
    private var codeActionsDisabled: Bool {
        policyDisabled || !gateway.usable || gateway.status?.accessCodeVersion != 1
    }

    var body: some View {
        Button {
            actionError = nil
            showingPopover.toggle()
        } label: {
            PasscodeProtectionIcon()
                .foregroundStyle(required || hovering ? Color.primary : Color.secondary)
                .frame(width: 20, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(required ? "Passcode Protection On" : "Passcode Protection Off")
        .accessibilityLabel("\(workspace.name): Passcode Protection \(required ? "On" : "Off")")
        .onHover { hovering = $0 }
        .popover(isPresented: $showingPopover, arrowEdge: .trailing) {
            settings
                .task { await gateway.refresh() }
        }
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Passcode Protection").font(.headline)
                Spacer(minLength: 12)
                Toggle("Passcode Protection", isOn: Binding(
                    get: { required },
                    set: { value in
                        Task {
                            if await perform("code-policy", required: value), value, !codeActionsDisabled {
                                await perform("folder-code")
                            }
                        }
                    }
                ))
                .toggleStyle(.switch).controlSize(.small).labelsHidden().fixedSize()
                .disabled(policyDisabled)
            }

            if !required {
                Text("Add an extra passcode before an AI can access this folder.")
                    .font(.callout).fixedSize(horizontal: false, vertical: true)
                Text("Optional extra protection for this folder.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if root == nil || configurationChanged {
                Text(root == nil
                     ? "先開啟此 Folder 嘅 Main Gate toggle 並儲存變更，再設定通行碼。"
                     : "請先儲存左邊嘅 Folder 分享變更。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if legacyConnection {
                Text("重新開啟共用連線，即可套用通行碼功能。")
                    .font(.caption).foregroundStyle(.secondary)
                Button("更新共用連線") { Task { await gateway.restart() } }
                    .disabled(gateway.working || configurationChanged)
            }

            if required, let root {
                protectionDetails(root)
                if gateway.status?.running == false {
                    Text("先開啟共用連線，再產生通行碼。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            if let actionError {
                Text(actionError).font(.caption).foregroundStyle(.orange)
            }
        }
        .controlSize(.small)
        .padding(16)
        .frame(width: 300, alignment: .leading)
    }

    private func protectionDetails(_ root: GatewayRoot) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let access = gateway.status?.folderAccess?.first { $0.workspaceID == root.id }
            let count = access?.unlockedCount ?? 0
            let code = gateway.folderCodes[root.id]
            let remaining = code.map { max(0, Int(ceil($0.expiration.timeIntervalSince(context.date)))) } ?? 0
            let codeActive = access?.codeActive == true && (code == nil || remaining > 0)

            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(count > 0 ? "Temporarily Unlocked" : access == nil ? "Access Status Unavailable" : "Protected")
                        .font(.system(size: 12, weight: .semibold))
                    Text(count > 0
                         ? "\(count) temporary access \(count == 1 ? "grant is" : "grants are") active."
                         : access == nil
                         ? "Temporary access status will appear when the Gate is available."
                         : "A passcode is required before temporary access can be granted.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if codeActive {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("Passcode").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                        if let code {
                            HStack(spacing: 6) {
                                Text(code.code)
                                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                                    .lineLimit(1).minimumScaleFactor(0.75).textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                passcodeActions
                            }
                            Text("Expires in \(remaining / 60):\(String(format: "%02d", remaining % 60)) · Single use")
                                .font(.caption).foregroundStyle(.secondary)
                        } else {
                            HStack(alignment: .top, spacing: 6) {
                                Text("An active passcode exists. Generate a new code to view or copy it.")
                                    .font(.caption).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 0)
                                passcodeActions
                            }
                        }
                        if let code {
                            Button("Copy Unlock Prompt") { gateway.copy(code.unlockPrompt) }
                        }
                    }
                } else {
                    Button("Generate Passcode") { Task { await perform("folder-code") } }
                        .disabled(codeActionsDisabled)
                }

                if count > 0 {
                    Button("Revoke Temporary Access") { Task { await perform("lock-folder") } }
                        .disabled(codeActionsDisabled)
                    Text("Generating or invalidating a passcode also revokes temporary access. Revoking access also invalidates any active passcode.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var passcodeActions: some View {
        HStack(spacing: 2) {
            Button {
                Task { await perform("folder-code") }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11)).frame(width: 20, height: 22)
                    .contentShape(Rectangle())
            }
            .help("Generate New Code").accessibilityLabel("Generate New Code")
            Button {
                Task { await perform("lock-folder") }
            } label: {
                Image(systemName: "xmark.circle")
                    .font(.system(size: 11)).frame(width: 20, height: 22)
                    .contentShape(Rectangle())
            }
            .help("Invalidate Passcode").accessibilityLabel("Invalidate Passcode")
        }
        .buttonStyle(.borderless).foregroundStyle(.secondary)
        .fixedSize().disabled(codeActionsDisabled)
    }

    @discardableResult
    private func perform(_ action: String, required: Bool? = nil) async -> Bool {
        guard let root else { return false }
        actionError = nil
        if !(await gateway.perform(action, workspaceID: root.id, codeRequired: required)) {
            actionError = gateway.message ?? "未能更新通行碼設定，請再試。"
            return false
        }
        return true
    }
}

private struct PasscodeProtectionIcon: View {
    var body: some View {
        ZStack {
            Path { path in
                path.move(to: CGPoint(x: 4.6, y: 6.4))
                path.addLine(to: CGPoint(x: 4.6, y: 3.8))
                path.addCurve(to: CGPoint(x: 11.4, y: 3.8),
                              control1: CGPoint(x: 4.6, y: -0.2), control2: CGPoint(x: 11.4, y: -0.2))
                path.addLine(to: CGPoint(x: 11.4, y: 6.4))
                path.addRoundedRect(in: CGRect(x: 2.5, y: 6.4, width: 11, height: 8), cornerSize: CGSize(width: 1.8, height: 1.8))
            }
            .stroke(style: StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round))
            HStack(spacing: 1.4) {
                ForEach(0..<3) { _ in Circle().frame(width: 1.1, height: 1.1) }
            }
            .position(x: 8, y: 10.4)
        }
        .frame(width: 16, height: 15)
        .accessibilityHidden(true)
    }
}
