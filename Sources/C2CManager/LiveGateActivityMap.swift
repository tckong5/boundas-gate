import AppKit
import SwiftUI

struct LiveGateActivityMap: View {
    @ObservedObject var store: WorkspaceStore
    @ObservedObject var gateway: SharedGatewayStore
    @StateObject private var activity = GateActivityModel()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var visible = false
    @State private var viewportWidth: CGFloat = 600
    let connectApp: () -> Void
    private var gateID: String { gateway.status?.gatewayID ?? "" }
    private var topology: GateMapTopology {
        .make(roots: gateway.status?.roots ?? [], records: store.mainGateWorkspaces,
              connections: gateway.status?.aiConnections ?? [], availability: activity.availability)
    }

    var body: some View {
        GeometryReader { geometry in
            let graph = topology
            let layout = GateMapLayout(width: geometry.size.width, appCount: graph.apps.count, folderCount: graph.folders.count)
            Group {
                ZStack {
                    connectors(graph, layout: layout)
                    ForEach(travellingRoutes) { route in
                        if let path = routePath(route, graph: graph, layout: layout) {
                            MapTrafficPulse(path: path, response: route.phase == .response,
                                            failed: route.success == false)
                                .id(route.id + (route.phase == .response ? ":response" : ":request"))
                                .frame(width: layout.width, height: layout.height, alignment: .topLeading)
                        }
                    }
                    ForEach(Array(graph.apps.enumerated()), id: \.element.id) { index, app in
                        MapNode(name: app.name, symbol: "app", protected: false,
                                attention: !app.authorized, active: appActive(app.id), failed: appFailed(app.id),
                                arrivals: appArrivals(app.id), reduceMotion: reduceMotion, labelWidth: layout.apps.labelWidth)
                            .position(layout.apps.positions[index])
                            .help(app.authorized ? "Authorized to use Main Gate. This does not indicate a live session." : "Authorization needs attention.")
                    }
                    Text("Boundas Gate").font(.system(size: 15, weight: .medium))
                        .padding(.horizontal, 20).padding(.vertical, 12)
                        .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))
                        .position(layout.gate)
                    ForEach(Array(graph.folders.enumerated()), id: \.element.id) { index, folder in
                        MapNode(name: folder.name, symbol: "folder", protected: folder.protected,
                                attention: !folder.available, active: folderActive(folder.id), failed: folderFailed(folder.id),
                                arrivals: folderArrivals(folder.id), reduceMotion: reduceMotion, labelWidth: layout.folders.labelWidth)
                            .position(layout.folders.positions[index])
                            .zIndex(1)
                            .help(folder.available ? (folder.protected ? "Shared through Main Gate · Passcode Protection On" : "Shared through Main Gate") : "Folder unavailable")
                    }
                    if graph.apps.isEmpty {
                        VStack(spacing: 10) {
                            Text("No AI apps connected").font(.callout).foregroundStyle(.secondary)
                            Button("Connect an AI App", action: connectApp).controlSize(.small)
                        }.position(x: layout.gate.x, y: 72)
                    }
                    if graph.folders.isEmpty {
                        Text("No folders shared").font(.callout).foregroundStyle(.secondary)
                            .position(x: layout.gate.x, y: layout.gate.y + 120)
                    }
                }
                .frame(width: layout.width, height: layout.height)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.3), value: graph)
            }
            .onChange(of: geometry.size.width, initial: true) { _, width in viewportWidth = width }
        }
        .frame(height: GateMapLayout(width: viewportWidth, appCount: topology.apps.count, folderCount: topology.folders.count).height)
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
    @ViewBuilder private func connectors(_ graph: GateMapTopology, layout: GateMapLayout) -> some View {
        ForEach(Array(graph.apps.enumerated()), id: \.element.id) { index, _ in
            Path { path in
                GateMapGeometry.appendAI(to: &path, source: layout.apps.anchors[index], gate: layout.gate,
                                         corridor: layout.apps.corridors[index])
            }
            .stroke(.primary.opacity(0.12), style: StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round))
        }
        ForEach(Array(graph.folders.enumerated()), id: \.element.id) { index, _ in
            Path { path in
                GateMapGeometry.appendFolder(to: &path, gate: layout.gate, destination: layout.folders.anchors[index],
                                             corridor: layout.folders.corridors[index])
            }
            .stroke(.primary.opacity(0.12), style: StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round))
        }
    }
    private func routePath(_ route: GateActivityModel.Route, graph: GateMapTopology, layout: GateMapLayout) -> Path? {
        guard let index = graph.apps.firstIndex(where: { $0.id == route.request.clientID && $0.authorized }) else { return nil }
        if let id = route.request.workspaceID {
            guard let folder = graph.folders.firstIndex(where: { $0.id == id && $0.available }) else { return nil }
            return GateMapGeometry.route(source: layout.apps.anchors[index], gate: layout.gate,
                                         destination: layout.folders.anchors[folder],
                                         incomingCorridor: layout.apps.corridors[index], outgoingCorridor: layout.folders.corridors[folder])
        }
        return GateMapGeometry.route(source: layout.apps.anchors[index], gate: layout.gate, destination: nil,
                                     incomingCorridor: layout.apps.corridors[index])
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

/// Both layers use the viewport independently. Only positions/label widths change;
/// icon size, request lifecycles and drawing identity remain unchanged.
struct GateMapLayout {
    struct Layer {
        let positions: [CGPoint]
        let anchors: [CGPoint]
        let corridors: [CGPoint?]
        let labelWidth: CGFloat
        let rows: Int

        static func rowCount(_ count: Int, width: CGFloat) -> Int {
            guard count > 1 else { return 1 }
            // Compress spacing before adding a row; 9+ always uses two rows.
            return count > 8 || CGFloat(count) * 92 + CGFloat(count - 1) * 8 + 24 > width ? 2 : 1
        }
        init(count: Int, width: CGFloat, nearY: CGFloat, outerY: CGFloat, apps: Bool) {
            rows = Self.rowCount(count, width: width)
            let nearCount = rows == 1 ? count : (count + 1) / 2
            let outerCount = count - nearCount
            let available = max(44, width - 24)
            let preferredWidth: CGFloat = count <= 4 && rows == 1 ? 116 : 104
            let nodeWidth = max(44, min(preferredWidth, (available - CGFloat(max(0, nearCount - 1)) * 8) / CGFloat(max(1, nearCount))))
            labelWidth = nodeWidth - 4
            let spacing = nearCount > 1 ? min(124, max(0, (available - nodeWidth) / CGFloat(nearCount - 1))) : 124
            func x(_ index: Int, count: Int) -> CGFloat {
                width / 2 + (CGFloat(index) - CGFloat(count - 1) / 2) * spacing
            }
            let near = (0..<nearCount).map { CGPoint(x: x($0, count: nearCount), y: nearY) }
            let outer = (0..<outerCount).map { CGPoint(x: x($0, count: outerCount), y: outerY) }
            positions = near + outer
            anchors = positions.map { CGPoint(x: $0.x, y: $0.y + (apps ? 39 : -38)) }
            let gaps = (0...nearCount).map { width / 2 + (CGFloat($0) - CGFloat(nearCount) / 2) * spacing }
            corridors = Array(repeating: nil, count: nearCount) + outer.map { node in
                // Prefer an inward gap on a tie. AI routes use this passage;
                // Folder routes sweep directly behind foreground nodes.
                let gap = gaps.min {
                    let a = abs($0 - node.x), b = abs($1 - node.x)
                    return abs(a - b) < 0.01 ? abs($0 - width / 2) < abs($1 - width / 2) : a < b
                } ?? node.x
                return CGPoint(x: gap, y: nearY + (apps ? 51 : 54))
            }
        }
    }
    let width: CGFloat
    let height: CGFloat
    let gate: CGPoint
    let apps: Layer
    let folders: Layer
    init(width: CGFloat, appCount: Int, folderCount: Int) {
        self.width = max(44, width)
        let appRows = Layer.rowCount(appCount, width: self.width)
        let folderRows = Layer.rowCount(folderCount, width: self.width)
        let rowSpacing: CGFloat = 140
        gate = CGPoint(x: self.width / 2, y: 185 + CGFloat(appRows - 1) * rowSpacing)
        apps = Layer(count: appCount, width: self.width, nearY: 65 + CGFloat(appRows - 1) * rowSpacing, outerY: 65, apps: true)
        folders = Layer(count: folderCount, width: self.width, nearY: gate.y + 135, outerY: gate.y + 135 + rowSpacing, apps: false)
        height = gate.y + 200 + CGFloat(folderRows - 1) * rowSpacing
    }
}

enum GateMapGeometry {
    static func appendAI(to path: inout Path, source: CGPoint, gate: CGPoint, corridor: CGPoint? = nil) {
        path.move(to: source)
        var start = source
        if let corridor {
            path.addCurve(to: corridor, control1: CGPoint(x: corridor.x, y: source.y + 20),
                          control2: CGPoint(x: corridor.x, y: corridor.y - 16))
            start = corridor
        }
        let delta = gate.x - start.x, height = gate.y - start.y
        path.addCurve(to: gate,
                      control1: CGPoint(x: corridor == nil ? start.x + delta * 0.38 : start.x,
                                        y: corridor == nil ? start.y + height * 22 / 81 : start.y + 16),
                      control2: CGPoint(x: gate.x - delta * 0.38, y: gate.y - height * 25 / 81))
    }

    static func appendFolder(to path: inout Path, gate: CGPoint, destination: CGPoint, corridor: CGPoint? = nil) {
        if path.isEmpty { path.move(to: gate) }
        if corridor != nil {
            let delta = destination.x - gate.x, height = destination.y - gate.y
            let direction: CGFloat = delta < 0 ? -1 : 1
            // Each outer Folder gets one direct cubic, never a shared stem.
            // Folder icons and canvas-colored labels sit above intersecting routes.
            path.addCurve(to: destination,
                          control1: CGPoint(x: gate.x + direction * max(22, abs(delta) * 0.44), y: gate.y + height * 0.26),
                          control2: CGPoint(x: abs(delta) < 1 ? destination.x + 22 : destination.x - delta * 0.22,
                                            y: destination.y - height * 0.22))
        } else {
            let delta = destination.x - gate.x, height = destination.y - gate.y
            path.addCurve(to: destination,
                          control1: CGPoint(x: gate.x + delta * 0.38, y: gate.y + height * 25 / 97),
                          control2: CGPoint(x: destination.x - delta * 0.38, y: destination.y - height * 24 / 97))
        }
    }

    static func route(source: CGPoint, gate: CGPoint, destination: CGPoint?, incomingCorridor: CGPoint? = nil,
                      outgoingCorridor: CGPoint? = nil) -> Path {
        var path = Path()
        appendAI(to: &path, source: source, gate: gate, corridor: incomingCorridor)
        if let destination {
            appendFolder(to: &path, gate: gate, destination: destination, corridor: outgoingCorridor)
        }
        return path
    }
}

private struct MapNode: View {
    let name: String; let symbol: String; let protected: Bool; let attention: Bool
    let active: Bool; let failed: Bool; let arrivals: Set<String>; let reduceMotion: Bool
    var labelWidth: CGFloat = 112
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
                    .background {
                        if symbol == "folder" {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(Color(nsColor: .textBackgroundColor)).padding(-2)
                        }
                    }
                    .frame(width: 40, height: 38)
                if protected { Image(systemName: "lock.fill").font(.system(size: 9)).foregroundStyle(.secondary)
                    .padding(2).background(.background, in: Circle()).offset(x: 2, y: 1) }
            }
            .scaleEffect(reduceMotion ? 1 : 1 + pulseAmount * 0.06)
            Text(name).font(.callout).foregroundStyle(.primary).lineLimit(2)
                .multilineTextAlignment(.center)
                .background {
                    if symbol == "folder" {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color(nsColor: .textBackgroundColor)).padding(-2)
                    }
                }
                .frame(width: labelWidth, height: 34, alignment: .top)
        }
        .frame(width: labelWidth + 4, height: 86)
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
