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
            case .local: return "Running on this Mac."
            case .tunnel: return "Your Gate can be reached securely from outside this Mac."
            case .aiConnection: return "An AI app is authorized to use this Gate."
            case .ready: return "Your Gate is ready to use."
            }
        }
    }
    enum NodeState { case completed, current, pending, attention }

    let nodes: [NodeState]
    let activeStage: Stage
    let isReady: Bool
    let isOpen: Bool
    let aiConnections: [GatewayAIConnection]
    var attentionCount: Int { aiConnections.filter(\.needsAttention).count }
    var hasAIWarning: Bool { attentionCount > 0 }
    var presentationKey: String {
        "\(activeStage.rawValue):\(isReady):" + aiConnections.map { "\($0.id):\($0.statusLabel)" }.joined(separator: ",")
    }

    static func make(status: GatewayStatus?, diagnostics: ConnectionDiagnostics?, confirmed: Bool,
                     busy: Bool, usable: Bool) -> Self {
        let connections = status?.aiConnections ?? []
        func waiting(_ stage: Stage, _ state: NodeState) -> Self {
            var nodes = Array(repeating: NodeState.pending, count: 4)
            for index in 0..<stage.rawValue { nodes[index] = .completed }
            nodes[stage.rawValue] = state
            return .init(nodes: nodes, activeStage: stage, isReady: false,
                         isOpen: stage.rawValue >= Stage.aiConnection.rawValue && usable, aiConnections: connections)
        }
        guard confirmed, let status, status.state != "unknown" else {
            return waiting(.local, status == nil || busy ? .current : .attention)
        }
        guard let running = status.running else { return waiting(.local, .current) }
        guard running else { return waiting(.local, busy ? .current : .pending) }
        guard let diagnostics else { return waiting(.local, .current) }
        let local = [diagnostics.bridge, diagnostics.localMCP]
        if local.contains(where: { $0.state == .failed }) { return waiting(.local, .attention) }
        guard local.allSatisfy(\.passed) else { return waiting(.local, .current) }
        let remote = [diagnostics.publicEndpoint, diagnostics.publicMCP, diagnostics.address]
        if remote.contains(where: { $0.state == .failed }) { return waiting(.tunnel, .attention) }
        let transportReady = status.transport != "embedded" || status.transportSetup?.state == "ready"
        guard transportReady, status.tunnel?.running == true, remote.allSatisfy(\.passed) else {
            return waiting(.tunnel, .current)
        }
        guard status.aiConnections != nil else { return waiting(.aiConnection, .current) }
        guard connections.contains(where: \.isAuthorized) else {
            let invalid = connections.contains { ["Invalid", "Revoked"].contains($0.statusLabel) }
            return waiting(.aiConnection, invalid ? .attention : .current)
        }
        guard usable else { return waiting(.ready, .attention) }
        let warning = connections.contains(where: \.needsAttention)
        return .init(nodes: [.completed, .completed, warning ? .attention : .completed, .current],
                     activeStage: warning ? .aiConnection : .ready, isReady: true, isOpen: true, aiConnections: connections)
    }
}

struct GateConnectionStepper<Action: View, Connections: View, Tunnel: View>: View {
    let journey: GateConnectionJourney
    let explanation: String?
    let showConnections: Bool
    @ViewBuilder let action: () -> Action
    @ViewBuilder let connections: () -> Connections
    @ViewBuilder let tunnel: () -> Tunnel

    var body: some View {
        VStack(spacing: 0) {
            ForEach(GateConnectionJourney.Stage.allCases, id: \.rawValue) { stage in
                HStack(alignment: .top, spacing: 12) {
                    GateJourneyDot(state: journey.nodes[stage.rawValue])
                        .accessibilityLabel(stage.title)
                        .accessibilityValue(accessibilityState(journey.nodes[stage.rawValue]))
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(stage.title).font(.system(size: 13, weight: .medium))
                                .foregroundStyle(journey.nodes[stage.rawValue] == .pending ? Color.secondary : Color.primary)
                            Spacer(minLength: 12)
                            if stage == journey.activeStage { action() }
                        }
                        .frame(minHeight: 28)
                        if stage == journey.activeStage, let explanation {
                            Text(explanation).font(.callout).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        } else if journey.nodes[stage.rawValue] == .completed {
                            Text(stage.completedDescription).font(.callout).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if stage == .tunnel { tunnel() }
                        if stage == .aiConnection && showConnections { connections() }
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
                                .fill(lineColor(stage))
                                .frame(width: 1.5, height: max(0, geometry.size.height - 28))
                                .offset(x: 13.25, y: 28)
                        }
                    }
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func lineColor(_ stage: GateConnectionJourney.Stage) -> Color {
        journey.nodes[stage.rawValue] == .completed || (stage == .aiConnection && journey.isReady)
            ? Color.accentColor.opacity(0.55) : Color.secondary.opacity(0.18)
    }

    private func accessibilityState(_ state: GateConnectionJourney.NodeState) -> String {
        switch state {
        case .completed: return "Complete"
        case .current: return journey.isReady && journey.activeStage == .ready ? "Gate Open" : "In progress"
        case .pending: return "Pending"
        case .attention: return "Needs attention"
        }
    }
}

struct GateJourneyDot: View {
    let state: GateConnectionJourney.NodeState
    var pulses = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var breathing: Bool { pulses && (state == .current || state == .attention) }
    private var color: Color { state == .attention ? .orange : .accentColor }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !breathing || reduceMotion)) { context in
            let wave = reduceMotion ? 0.5 : (sin(context.date.timeIntervalSinceReferenceDate * .pi / 1.8) + 1) / 2
            ZStack {
                if breathing {
                    Circle().fill(color.opacity((state == .attention ? 0.04 : 0.06) + wave * 0.06))
                        .frame(width: 22, height: 22).scaleEffect(0.90 + wave * 0.10)
                }
                if state == .pending {
                    Circle().strokeBorder(Color.secondary.opacity(0.35), lineWidth: 1.5)
                        .frame(width: 9, height: 9)
                } else {
                    Circle().fill(color).frame(width: 9, height: 9)
                        .scaleEffect(breathing && !reduceMotion ? 0.94 + wave * 0.12 : 1)
                }
            }
            .frame(width: 28, height: 28)
        }
        .frame(width: 28, height: 28)
        .allowsHitTesting(false)
    }
}
