import AppKit
import SwiftUI

struct LiveGateActivityMap: View {
    @ObservedObject var store: WorkspaceStore
    @ObservedObject var gateway: SharedGatewayStore
    @StateObject private var activity = GateActivityModel()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var visible = false
    let connectApp: () -> Void
    private var gateID: String { gateway.status?.gatewayID ?? "" }
    private var topology: GateMapTopology {
        .make(roots: gateway.status?.roots ?? [], records: store.mainGateWorkspaces,
              connections: gateway.status?.aiConnections ?? [], availability: activity.availability)
    }

    var body: some View {
        GeometryReader { geometry in
            let graph = topology
            let width = max(geometry.size.width, CGFloat(max(graph.apps.count, graph.folders.count)) * 124 + 32)
            ScrollView(.horizontal, showsIndicators: true) {
                ZStack {
                    connectors(graph, width: width)
                    ForEach(travellingRoutes) { route in
                        if let path = routePath(route, graph: graph, width: width) {
                            MapTrafficPulse(path: path, response: route.phase == .response,
                                            failed: route.success == false)
                                .id(route.id + (route.phase == .response ? ":response" : ":request"))
                                .frame(width: width, height: 385, alignment: .topLeading)
                        }
                    }
                    ForEach(Array(graph.apps.enumerated()), id: \.element.id) { index, app in
                        MapNode(name: app.name, symbol: "app", protected: false,
                                attention: !app.authorized, active: appActive(app.id), failed: appFailed(app.id),
                                arrivals: appArrivals(app.id), reduceMotion: reduceMotion)
                            .position(x: x(index, count: graph.apps.count, width: width), y: 65)
                            .help(app.authorized ? "Authorized to use Main Gate. This does not indicate a live session." : "Authorization needs attention.")
                    }
                    Text("Boundas Gate").font(.system(size: 15, weight: .medium))
                        .padding(.horizontal, 20).padding(.vertical, 12)
                        .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))
                        .position(x: width / 2, y: 185)
                    ForEach(Array(graph.folders.enumerated()), id: \.element.id) { index, folder in
                        MapNode(name: folder.name, symbol: "folder", protected: folder.protected,
                                attention: !folder.available, active: folderActive(folder.id), failed: folderFailed(folder.id),
                                arrivals: folderArrivals(folder.id), reduceMotion: reduceMotion)
                            .position(x: x(index, count: graph.folders.count, width: width), y: 320)
                            .help(folder.available ? (folder.protected ? "Shared through Main Gate · Passcode Protection On" : "Shared through Main Gate") : "Folder unavailable")
                    }
                    if graph.apps.isEmpty {
                        VStack(spacing: 10) {
                            Text("No AI apps connected").font(.callout).foregroundStyle(.secondary)
                            Button("Connect an AI App", action: connectApp).controlSize(.small)
                        }.position(x: width / 2, y: 72)
                    }
                    if graph.folders.isEmpty {
                        Text("No folders shared").font(.callout).foregroundStyle(.secondary)
                            .position(x: width / 2, y: 305)
                    }
                }
                .frame(width: width, height: 385)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.3), value: graph)
            }
        }
        .frame(height: 385)
        .background(MapWindowVisibility(visible: $visible).frame(width: 0, height: 0))
        .onChange(of: visible) { _, value in activity.setVisible(value, gateID: gateID) }
        .onChange(of: gateID) { _, value in activity.setVisible(visible, gateID: value) }
        .onAppear { activity.setVisible(visible, gateID: gateID) }
        .onDisappear { activity.stop() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Main Gate activity map. Authorized AI apps and shared folders.")
        .overlay(alignment: .bottomTrailing) {
            if visible && !activity.feedAvailable {
                Image(systemName: "info.circle").font(.caption).foregroundStyle(.tertiary)
                    .help("Live activity is unavailable. If this Gate was started with an older version, close and reopen it to enable activity. The topology still shows existing sharing and authorization.")
            }
        }
    }
    private func x(_ index: Int, count: Int, width: CGFloat) -> CGFloat {
        width / 2 + (CGFloat(index) - CGFloat(count - 1) / 2) * 124
    }
    @ViewBuilder private func connectors(_ graph: GateMapTopology, width: CGFloat) -> some View {
        ForEach(Array(graph.apps.enumerated()), id: \.element.id) { index, _ in
            Path { path in
                GateMapGeometry.appendAI(to: &path,
                                         sourceX: x(index, count: graph.apps.count, width: width),
                                         gate: GateMapGeometry.gatePoint(width: width))
            }
            .stroke(.primary.opacity(0.12), style: StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round))
        }
        ForEach(Array(graph.folders.enumerated()), id: \.element.id) { index, _ in
            Path { path in
                GateMapGeometry.appendFolder(to: &path,
                                             gate: GateMapGeometry.gatePoint(width: width),
                                             destinationX: x(index, count: graph.folders.count, width: width))
            }
            .stroke(.primary.opacity(0.12), style: StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round))
        }
    }
    private func routePath(_ route: GateActivityModel.Route, graph: GateMapTopology, width: CGFloat) -> Path? {
        guard let index = graph.apps.firstIndex(where: { $0.id == route.request.clientID && $0.authorized }) else { return nil }
        let source = x(index, count: graph.apps.count, width: width)
        let gate = GateMapGeometry.gatePoint(width: width)
        if let id = route.request.workspaceID {
            guard let folder = graph.folders.firstIndex(where: { $0.id == id && $0.available }) else { return nil }
            let destination = x(folder, count: graph.folders.count, width: width)
            return GateMapGeometry.route(sourceX: source, gate: gate, destinationX: destination)
        }
        return GateMapGeometry.route(sourceX: source, gate: gate, destinationX: nil)
    }
    private func folderActive(_ id: String) -> Bool {
        activity.routes.values.contains { $0.request.workspaceID == id
            && ($0.phase == .waiting || $0.phase == .response || reduceMotion && $0.phase == .request) }
    }
    // Coalesce only the drawing for an identical client→Folder path. Request IDs and lifecycles remain independent.
    private var travellingRoutes: [GateActivityModel.Route] {
        struct RouteKey: Hashable { let clientID: String; let workspaceID: String? }
        var paths: [RouteKey: GateActivityModel.Route] = [:]
        for route in activity.routes.values.sorted(by: {
            $0.request.startedAt == $1.request.startedAt ? $0.id < $1.id : $0.request.startedAt < $1.request.startedAt
        }) where GateActivityModel.travels(route, reduceMotion: reduceMotion) {
            let key = RouteKey(clientID: route.request.clientID, workspaceID: route.request.workspaceID)
            if paths[key] == nil { paths[key] = route }
        }
        return paths.values.sorted { $0.id < $1.id }
    }
    private func folderArrivals(_ id: String) -> Set<String> {
        Set(activity.routes.values.filter { $0.request.workspaceID == id
            && ($0.phase == .waiting || $0.phase == .response || reduceMotion && $0.phase == .request) }.map(\.id))
    }
    private func appArrivals(_ id: String) -> Set<String> {
        Set(activity.routes.values.filter { $0.request.clientID == id
            && ($0.phase == .settled || reduceMotion && $0.phase == .request) }
            .map { $0.id + ($0.phase == .settled ? ":response" : ":request") })
    }
    private func folderFailed(_ id: String) -> Bool {
        activity.routes.values.contains { $0.request.workspaceID == id && $0.success == false && $0.phase == .response }
    }
    private func appActive(_ id: String) -> Bool {
        activity.routes.values.contains { $0.request.clientID == id && ($0.phase == .settled || reduceMotion && $0.phase == .request) }
    }
    private func appFailed(_ id: String) -> Bool {
        activity.routes.values.contains { $0.request.clientID == id && $0.phase == .settled && $0.success == false }
    }
}

enum GateMapGeometry {
    static let appY: CGFloat = 104
    static let gateY: CGFloat = 185
    static let folderY: CGFloat = 282

    static func gatePoint(width: CGFloat) -> CGPoint { CGPoint(x: width / 2, y: gateY) }

    static func appendAI(to path: inout Path, sourceX: CGFloat, gate: CGPoint) {
        path.move(to: CGPoint(x: sourceX, y: appY))
        let delta = gate.x - sourceX
        path.addCurve(to: gate,
                      control1: CGPoint(x: sourceX + delta * 0.38, y: 126),
                      control2: CGPoint(x: gate.x - delta * 0.38, y: 160))
    }

    static func appendFolder(to path: inout Path, gate: CGPoint, destinationX: CGFloat) {
        if path.isEmpty { path.move(to: gate) }
        let delta = destinationX - gate.x
        path.addCurve(to: CGPoint(x: destinationX, y: folderY),
                      control1: CGPoint(x: gate.x + delta * 0.38, y: 210),
                      control2: CGPoint(x: destinationX - delta * 0.38, y: 258))
    }

    static func route(sourceX: CGFloat, gate: CGPoint, destinationX: CGFloat?) -> Path {
        var path = Path()
        appendAI(to: &path, sourceX: sourceX, gate: gate)
        if let destinationX { appendFolder(to: &path, gate: gate, destinationX: destinationX) }
        return path
    }
}

private struct MapNode: View {
    let name: String; let symbol: String; let protected: Bool; let attention: Bool
    let active: Bool; let failed: Bool; let arrivals: Set<String>; let reduceMotion: Bool
    @State private var appeared = false
    @State private var pulseToken: UUID?
    @State private var pulseAmount: CGFloat = 0
    var body: some View {
        VStack(spacing: 8) {
            ZStack(alignment: .bottomTrailing) {
                Image(systemName: symbol).font(.system(size: 23, weight: .regular))
                    .foregroundStyle(attention || failed ? Color.orange : active ? Color.accentColor : Color.secondary)
                    .shadow(color: active ? (failed ? Color.orange : Color.accentColor).opacity(0.18) : .clear, radius: 3)
                    .overlay {
                        Image(systemName: symbol).font(.system(size: 23, weight: .regular))
                            .foregroundStyle(failed ? Color.orange : Color.primary)
                            .opacity(Double(pulseAmount) * 0.8)
                    }
                    .frame(width: 40, height: 38)
                if protected { Image(systemName: "lock.fill").font(.system(size: 9)).foregroundStyle(.secondary)
                    .padding(2).background(.background, in: Circle()).offset(x: 2, y: 1) }
            }
            .scaleEffect(reduceMotion ? 1 : 1 + pulseAmount * 0.06)
            Text(name).font(.callout).foregroundStyle(.primary).lineLimit(2)
                .multilineTextAlignment(.center).frame(width: 112, height: 34, alignment: .top)
        }
        .frame(width: 116, height: 86)
        .opacity(appeared ? 1 : 0).scaleEffect(appeared || reduceMotion ? 1 : 0.98)
        .transition(.opacity)
        .task(id: reduceMotion) {
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.3)) { appeared = true }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: active)
        .onChange(of: arrivals) { previous, current in
            if !current.subtracting(previous).isEmpty { pulseToken = UUID() }
        }
        .task(id: pulseToken) {
            guard pulseToken != nil else { return }
            withTransaction(Transaction(animation: nil)) { pulseAmount = 0 }
            await Task.yield()
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.11)) { pulseAmount = 1 }
            do { try await Task.sleep(for: .milliseconds(110)) } catch { return }
            withAnimation(.easeInOut(duration: 0.15)) { pulseAmount = 0 }
        }
        .accessibilityLabel(name + (protected ? ", Passcode Protection On" : "") + (attention ? ", Needs attention" : ""))
    }
}

private struct MapTrafficPulse: View {
    let path: Path; let response: Bool; let failed: Bool
    private let pathLength: CGFloat
    @Environment(\.colorScheme) private var colorScheme
    @State private var progress: CGFloat = 0
    init(path: Path, response: Bool, failed: Bool) {
        self.path = path; self.response = response; self.failed = failed
        pathLength = max(1, Self.approximateLength(path.cgPath))
    }
    private static func approximateLength(_ path: CGPath) -> CGFloat {
        var length: CGFloat = 0
        var current = CGPoint.zero
        path.applyWithBlock { pointer in
            let element = pointer.pointee
            switch element.type {
            case .moveToPoint:
                current = element.points[0]
            case .addLineToPoint:
                let end = element.points[0]
                length += hypot(end.x - current.x, end.y - current.y)
                current = end
            case .addQuadCurveToPoint:
                let control = element.points[0]
                let end = element.points[1]
                length += quadLength(from: current, control: control, to: end)
                current = end
            case .addCurveToPoint:
                let control1 = element.points[0]
                let control2 = element.points[1]
                let end = element.points[2]
                length += cubicLength(from: current, control1: control1, control2: control2, to: end)
                current = end
            case .closeSubpath:
                break
            @unknown default:
                break
            }
        }
        return length
    }
    private static func quadLength(from start: CGPoint, control: CGPoint, to end: CGPoint) -> CGFloat {
        var total: CGFloat = 0
        var previous = start
        for index in 1...24 {
            let t = CGFloat(index) / 24
            let inverse = 1 - t
            let point = CGPoint(x: inverse * inverse * start.x + 2 * inverse * t * control.x + t * t * end.x,
                                y: inverse * inverse * start.y + 2 * inverse * t * control.y + t * t * end.y)
            total += hypot(point.x - previous.x, point.y - previous.y)
            previous = point
        }
        return total
    }
    private static func cubicLength(from start: CGPoint, control1: CGPoint, control2: CGPoint, to end: CGPoint) -> CGFloat {
        var total: CGFloat = 0
        var previous = start
        for index in 1...32 {
            let t = CGFloat(index) / 32
            let inverse = 1 - t
            let point = CGPoint(
                x: inverse * inverse * inverse * start.x + 3 * inverse * inverse * t * control1.x
                    + 3 * inverse * t * t * control2.x + t * t * t * end.x,
                y: inverse * inverse * inverse * start.y + 3 * inverse * inverse * t * control1.y
                    + 3 * inverse * t * t * control2.y + t * t * t * end.y)
            total += hypot(point.x - previous.x, point.y - previous.y)
            previous = point
        }
        return total
    }
    var body: some View {
        MapSignalPhoton(path: path, pathLength: pathLength, progress: progress, response: response,
                        failed: failed, dark: colorScheme == .dark)
            .onAppear { withAnimation(.linear(duration: 0.7)) { progress = 1 } }
            .allowsHitTesting(false).accessibilityHidden(true)
    }
}
private struct MapSignalPhoton: View, Animatable {
    let path: Path
    let pathLength: CGFloat
    var progress: CGFloat
    let response: Bool; let failed: Bool; let dark: Bool
    var animatableData: CGFloat { get { progress } set { progress = newValue } }
    var body: some View {
        Canvas { context, _ in
            let head = max(0.000001, min(1, response ? 1 - progress : progress))
            let point = path.trimmedPath(from: 0, to: head).cgPath.currentPoint
            let tint = failed ? Color.orange : dark ? Color(red: 0.72, green: 0.77, blue: 0.88)
                : Color(red: 0.38, green: 0.45, blue: 0.58)
            let trail = min(0.08, 14 / pathLength)
            // A short tail and local line highlight use the very same path as the photon centre.
            for index in 0..<3 {
                let near = head + (response ? 1 : -1) * trail * CGFloat(index) / 3
                let far = head + (response ? 1 : -1) * trail * CGFloat(index + 1) / 3
                let segment = path.trimmedPath(from: max(0, min(near, far)), to: min(1, max(near, far)))
                context.stroke(segment, with: .color(tint.opacity(0.40 - Double(index) * 0.12)),
                               style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
            }
            let nearby = path.trimmedPath(from: max(0, head - 3 / pathLength), to: min(1, head + 3 / pathLength))
            var glow = context
            glow.addFilter(.blur(radius: 1.8))
            glow.stroke(nearby, with: .color(tint.opacity(0.25)), lineWidth: 2)
            glow.fill(Path(ellipseIn: CGRect(x: point.x - 8, y: point.y - 8, width: 16, height: 16)),
                      with: .radialGradient(Gradient(colors: [tint.opacity(0.70), tint.opacity(0.28), .clear]),
                                            center: point, startRadius: 0, endRadius: 8))
            let core = Path(ellipseIn: CGRect(x: point.x - 3.25, y: point.y - 3.25, width: 6.5, height: 6.5))
            context.fill(core, with: .radialGradient(Gradient(colors: [tint.opacity(1), tint.opacity(0.88), tint.opacity(0.62)]),
                                                     center: point, startRadius: 0, endRadius: 3.25))
            context.stroke(core, with: .color(tint.opacity(0.92)), lineWidth: 0.7)
        }
    }
}

/// Visibility, rather than focus, controls polling: an unfocused but visible window remains live.
private struct MapWindowVisibility: NSViewRepresentable {
    @Binding var visible: Bool
    func makeNSView(context: Context) -> ObserverView {
        let view = ObserverView(); view.report = { value in
            DispatchQueue.main.async { visible = value }
        }; return view
    }
    func updateNSView(_ nsView: ObserverView, context: Context) {}
    final class ObserverView: NSView {
        var report: ((Bool) -> Void)?
        private var observers: [NSObjectProtocol] = []
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver); observers = []
            for name in [NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification,
                         NSWindow.didChangeOcclusionStateNotification, NSWindow.willCloseNotification,
                         NSApplication.didHideNotification, NSApplication.didUnhideNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    self?.updateVisibility()
                })
            }
            updateVisibility()
        }
        private func updateVisibility() {
            report?(window.map { $0.isVisible && !$0.isMiniaturized && $0.occlusionState.contains(.visible) && !NSApp.isHidden } ?? false)
        }
        deinit { observers.forEach(NotificationCenter.default.removeObserver) }
    }
}
