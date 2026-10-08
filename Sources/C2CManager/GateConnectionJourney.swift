import SwiftUI

struct GateConnectionJourney {
    enum Stage: Int, CaseIterable {
        case local, tunnel, aiConnection, ready
        var title: String {
            switch self {
            case .local: return "Boundas Gate"
            case .tunnel: return "Secure Access"
            case .aiConnection: return "Connect an AI App"
            case .ready: return "Ready to Use"
            }
        }
        var completedDescription: String {
            switch self {
            case .local: return "Local MCP host is running."
            case .tunnel: return "Tailscale · Connected"
            case .aiConnection: return "An AI app is authorized to use this Gate."
            case .ready: return "Your Gate is ready to use."
            }
        }
    }
    enum NodeState { case completed, waiting, current, pending, attention }

    let nodes: [NodeState]
    let activeStage: Stage
    let isReady: Bool
    let isOpen: Bool
    let aiConnections: [GatewayAIConnection]
    var attentionCount: Int { aiConnections.filter(\.needsAttention).count }
    var hasAIWarning: Bool { attentionCount > 0 }
    var showsSummaryCounts: Bool { isReady || aiConnections.contains(where: \.isAuthorized) }
    var showsLocalCloseControl: Bool { nodes[Stage.local.rawValue] == .completed }

    func presentsContent(for stage: Stage) -> Bool {
        stage == activeStage || nodes[stage.rawValue] == .completed
            || (stage == .ready && isReady)
    }

    func presentsPrimaryAction(for stage: Stage) -> Bool { stage == activeStage }

    func presentsSecondaryActions(for stage: Stage) -> Bool { presentsContent(for: stage) }

    func summaryTitle(opening: Bool, reopening: Bool, closed: Bool) -> String {
        if reopening { return "Reopening Gate…" }
        if opening { return "Opening Gate…" }
        if closed { return "Gate Closed" }
        if !showsSummaryCounts { return "Finish setting up your Gate" }
        if isOpen { return "Gate Open" }
        if nodes.contains(.attention) { return "Gate Needs Attention" }
        return "Finish setting up your Gate"
    }
    var presentationKey: String {
        "\(activeStage.rawValue):\(isReady):" + aiConnections.map { "\($0.id):\($0.statusLabel)" }.joined(separator: ",")
    }

    static func make(status: GatewayStatus?, diagnostics: ConnectionDiagnostics?, confirmed: Bool,
                     busy: Bool, usable: Bool) -> Self {
        let connections = status?.aiConnections ?? []
        func waiting(_ stage: Stage, _ state: NodeState) -> Self {
            var nodes = Array(repeating: NodeState.pending, count: 4)
            for index in 0..<stage.rawValue { nodes[index] = .completed }
            // Processing is a presentation state only while an operation/check
            // is active; incomplete evidence alone is not ongoing work.
            nodes[stage.rawValue] = busy ? .current : state == .current ? .waiting : state
            return .init(nodes: nodes, activeStage: stage, isReady: false,
                         isOpen: stage.rawValue >= Stage.aiConnection.rawValue && usable, aiConnections: connections)
        }
        guard confirmed, let status, status.state != "unknown" else {
            return waiting(.local, status == nil || busy ? .current : .attention)
        }
        guard let running = status.running else { return waiting(.local, .current) }
        guard running else { return waiting(.local, busy ? .current : .waiting) }
        guard let diagnostics else { return waiting(.local, .current) }
        let local = [diagnostics.bridge, diagnostics.localMCP]
        if local.contains(where: { $0.state == .failed }) { return waiting(.local, .attention) }
        guard local.allSatisfy(\.passed) else { return waiting(.local, .current) }
        if status.localOnly == true { return waiting(.tunnel, busy ? .current : .waiting) }
        let remote = [diagnostics.publicEndpoint, diagnostics.publicMCP, diagnostics.address]
        if remote.contains(where: { $0.state == .failed }) { return waiting(.tunnel, .attention) }
        let transportReady = status.transport != "embedded" || status.transportSetup?.state == "ready"
        guard transportReady, status.tunnel?.running == true, remote.allSatisfy(\.passed) else {
            return waiting(.tunnel, busy ? .current : .waiting)
        }
        guard status.aiConnections != nil else { return waiting(.aiConnection, .current) }
        guard connections.contains(where: \.isAuthorized) else {
            let invalid = connections.contains { ["Invalid", "Revoked"].contains($0.statusLabel) }
            return waiting(.aiConnection, invalid ? .attention : busy ? .current : .waiting)
        }
        guard usable else { return waiting(.ready, .attention) }
        let warning = connections.contains(where: \.needsAttention)
        return .init(nodes: [.completed, .completed, warning ? (busy ? .current : .attention) : .completed, .completed],
                     activeStage: warning ? .aiConnection : .ready, isReady: true, isOpen: true, aiConnections: connections)
    }
}

struct GateConnectionStepper<Action: View, LabelAccessory: View, Secondary: View, Connections: View, Tunnel: View>: View {
    let journey: GateConnectionJourney
    let explanation: String?
    let showConnections: Bool
    var aiConnectionTitle: String? = nil
    var localTitle: String? = nil
    @ViewBuilder let action: (GateConnectionJourney.Stage) -> Action
    @ViewBuilder let labelAccessory: (GateConnectionJourney.Stage) -> LabelAccessory
    @ViewBuilder let secondary: (GateConnectionJourney.Stage) -> Secondary
    @ViewBuilder let connections: () -> Connections
    @ViewBuilder let tunnel: () -> Tunnel

    var body: some View {
        VStack(spacing: 0) {
            ForEach(GateConnectionJourney.Stage.allCases, id: \.rawValue) { stage in
                HStack(alignment: .top, spacing: 12) {
                    GateJourneyDot(state: journey.nodes[stage.rawValue])
                        .accessibilityLabel(displayTitle(stage))
                        .accessibilityValue(accessibilityState(journey.nodes[stage.rawValue]))
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(displayTitle(stage)).font(.system(size: 13, weight: .medium))
                                .foregroundStyle(journey.nodes[stage.rawValue] == .pending ? Color.secondary : Color.primary)
                            if journey.presentsContent(for: stage) { labelAccessory(stage) }
                            Spacer(minLength: 12)
                            HStack(spacing: 8) {
                                if journey.presentsContent(for: stage) { action(stage) }
                                // A shared trailing menu slot keeps every action's
                                // right edge aligned, including rows without a menu.
                                Group {
                                    if journey.presentsSecondaryActions(for: stage) { secondary(stage) }
                                }.frame(width: 24, alignment: .trailing)
                            }
                        }
                        .frame(minHeight: 28)
                        if stage == journey.activeStage, let explanation {
                            Text(explanation).font(.callout).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        } else if journey.nodes[stage.rawValue] == .completed && stage != .tunnel && stage != .aiConnection && stage != .ready {
                            Text(stage.completedDescription).font(.callout).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if stage == .tunnel && journey.presentsContent(for: stage) { tunnel() }
                        if stage == .aiConnection && showConnections && journey.presentsContent(for: stage) { connections() }
                        if stage == .ready && journey.isReady {
                            Text(stage.completedDescription).font(.callout).foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.bottom, stage == .ready ? 0 : 18)
                .background(alignment: .leading) {
                    if stage != .ready {
                        GeometryReader { geometry in
                            Rectangle()
                                .fill(Color.secondary.opacity(0.18))
                                .frame(width: lineWidth(stage), height: max(0, geometry.size.height - 28))
                                .offset(x: 14 - lineWidth(stage) / 2, y: 28)
                        }
                    }
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func lineIsCompleted(_ stage: GateConnectionJourney.Stage) -> Bool {
        journey.nodes[stage.rawValue] == .completed || (stage == .aiConnection && journey.isReady)
    }

    private func displayTitle(_ stage: GateConnectionJourney.Stage) -> String {
        switch stage {
        case .local: return localTitle ?? stage.title
        case .aiConnection: return aiConnectionTitle ?? stage.title
        default: return stage.title
        }
    }

    private func lineWidth(_ stage: GateConnectionJourney.Stage) -> CGFloat {
        lineIsCompleted(stage) ? 1.5 : 1
    }

    private func accessibilityState(_ state: GateConnectionJourney.NodeState) -> String {
        switch state {
        case .completed: return "Complete"
        case .waiting: return "Waiting for your action"
        case .current: return journey.isReady && journey.activeStage == .ready ? "Gate Open" : "In progress"
        case .pending: return "Pending"
        case .attention: return "Needs attention"
        }
    }
}

struct GateJourneyDot: View {
    let state: GateConnectionJourney.NodeState
    var pulses = true
    var completedColor: Color = .green
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var breathing: Bool { pulses && (state == .waiting || state == .current || state == .attention) }
    private var color: Color {
        switch state {
        case .completed: return completedColor
        case .waiting, .pending: return .secondary
        case .current: return .blue
        case .attention: return .orange
        }
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !breathing || reduceMotion)) { context in
            let wave = reduceMotion ? 0.5 : (sin(context.date.timeIntervalSinceReferenceDate * .pi / 1.8) + 1) / 2
            ZStack {
                if breathing {
                    Circle().fill(color.opacity(0.03 + wave * 0.025))
                        .frame(width: 17, height: 17).scaleEffect(0.96 + wave * 0.04)
                }
                if state == .pending {
                    Circle().strokeBorder(Color.secondary.opacity(0.35), lineWidth: 1.5)
                        .frame(width: 9, height: 9)
                } else {
                    Circle().fill(color).frame(width: 9, height: 9)
                        .scaleEffect(breathing && !reduceMotion ? 0.98 + wave * 0.04 : 1)
                }
            }
            .frame(width: 28, height: 28)
        }
        .frame(width: 28, height: 28)
        .allowsHitTesting(false)
    }
}
