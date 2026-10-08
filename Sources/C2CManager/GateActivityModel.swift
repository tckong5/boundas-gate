import Combine
import Foundation

struct GateMapTopology: Equatable {
    struct App: Equatable, Identifiable {
        let id: String; let name: String; let authorized: Bool
    }
    struct Folder: Equatable, Identifiable {
        let id: String; let name: String; let protected: Bool; let available: Bool
    }
    let apps: [App]
    let folders: [Folder]
    func allowsRoute(_ request: GateActivityRequest) -> Bool {
        apps.contains { $0.id == request.clientID && $0.authorized }
            && (request.workspaceID == nil || folders.contains { $0.id == request.workspaceID && $0.available })
    }
    static func make(roots: [GatewayRoot], records: [WorkspaceRecord], connections: [GatewayAIConnection],
                     availability: [String: Bool]) -> Self {
        let apps = connections.filter { $0.isAuthorized || $0.authorizationState == "invalid"
            || $0.authorizationState == "authorized" }.map { App(id: $0.clientID, name: $0.name, authorized: $0.isAuthorized) }
        let folders = roots.filter(\.enabled).compactMap { root -> Folder? in
            // The effective backend allowlist owns sharing; record owns the display name and membership.
            guard let record = records.first(where: { $0.id.uuidString.lowercased() == root.sourceID.lowercased() }),
                  record.belongsToMainGate else { return nil }
            return Folder(id: root.id, name: record.name, protected: root.codeRequired == true,
                          available: availability[root.id] ?? FileManager.default.fileExists(atPath: record.path))
        }
        return .init(apps: apps, folders: folders)
    }
}

@MainActor
final class GateActivityModel: ObservableObject {
    struct Route: Identifiable, Equatable {
        enum Phase { case request, waiting, response, settled }
        let request: GateActivityRequest
        var phase: Phase
        var success: Bool?
        var id: String { request.requestID }
    }
    @Published private(set) var routes: [String: Route] = [:]
    @Published private(set) var availability: [String: Bool] = [:]
    @Published private(set) var feedAvailable = false
    private(set) var cursor: Int?
    private var streamID: String?
    private var transitions: [String: Task<Void, Never>] = [:]
    private var requestEnds: [String: Date] = [:]
    private var polling: Task<Void, Never>?
    private var runningGateID: String?
    private let client: any GateActivityFetching
    private let pulseDuration: TimeInterval
    private let cadence: TimeInterval
    init(client: any GateActivityFetching = GateActivityClient(), pulseDuration: TimeInterval = 0.7, cadence: TimeInterval = 1) {
        self.client = client; self.pulseDuration = pulseDuration; self.cadence = cadence
    }
    static func travels(_ route: Route, reduceMotion: Bool) -> Bool {
        !reduceMotion && (route.phase == .request || route.phase == .response)
    }
    deinit { polling?.cancel(); transitions.values.forEach { $0.cancel() } }

    func setVisible(_ visible: Bool, gateID: String) {
        if visible && runningGateID == gateID { return }
        stop()
        guard visible else { return }
        runningGateID = gateID
        let client = client, cadence = cadence
        polling = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    let page = try await client.fetch(gateID: gateID, since: self?.cursor)
                    guard !Task.isCancelled else { return }
                    self?.receive(page, gateID: gateID)
                } catch {
                    guard !Task.isCancelled else { return }
                    if self?.feedAvailable == true { self?.feedAvailable = false }
                    self?.clearRoutes(); self?.cursor = nil; self?.streamID = nil
                }
                do { try await Task.sleep(for: .seconds(cadence)) } catch { return }
            }
        }
    }
    func stop() {
        polling?.cancel(); polling = nil; runningGateID = nil
        cursor = nil; streamID = nil; clearRoutes()
    }
    private func clearRoutes() {
        transitions.values.forEach { $0.cancel() }; transitions.removeAll(); requestEnds.removeAll()
        if !routes.isEmpty { routes = [:] }
    }
    func receive(_ page: GateActivityPage, gateID: String) {
        guard page.gateID == gateID, page.version == 1 else { return }
        if !feedAvailable { feedAvailable = true }
        let updated = Dictionary(page.folders.map { ($0.workspaceID, $0.available) }, uniquingKeysWith: { _, new in new })
        if availability != updated { availability = updated }
        if page.reset || streamID != page.streamID || cursor == nil {
            clearRoutes()
            for request in page.activeRequests.prefix(128) where request.gateID == gateID {
                routes[request.id] = .init(request: request, phase: .waiting)
            }
        } else {
            for event in page.events where event.gateID == gateID && event.sequence > (cursor ?? 0) {
                if event.type == "requestStarted" { start(event.request) }
                else if event.type == "requestFinished" { finish(event.request, success: event.success == true) }
            }
            // A journal gap, disconnected client or server cancellation must not leave a stale active ring.
            let active = Set(page.activeRequests.map(\.id))
            let finished = Set(page.events.filter { $0.type == "requestFinished" }.map(\.requestID))
            for (id, route) in routes where route.phase == .waiting && !active.contains(id) && !finished.contains(id) {
                routes.removeValue(forKey: id)
                requestEnds.removeValue(forKey: id)
                transitions.removeValue(forKey: id)?.cancel()
            }
        }
        streamID = page.streamID; cursor = page.cursor
    }
    private func start(_ request: GateActivityRequest) {
        guard routes[request.id] == nil, routes.count < 128 else { return }
        routes[request.id] = .init(request: request, phase: .request)
        requestEnds[request.id] = Date().addingTimeInterval(pulseDuration)
        transitions[request.id] = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(self?.pulseDuration ?? 0)) } catch { return }
            guard let self, !Task.isCancelled, self.routes[request.id]?.phase == .request else { return }
            self.routes[request.id]?.phase = .waiting
            self.transitions.removeValue(forKey: request.id)
        }
    }
    private func finish(_ request: GateActivityRequest, success: Bool) {
        // Missing starts are not replayed: show only the genuine response, never invented requests.
        guard routes[request.id] != nil || routes.count < 128 else { return }
        transitions[request.id]?.cancel()
        if routes[request.id] == nil { routes[request.id] = .init(request: request, phase: .waiting) }
        routes[request.id]?.success = success
        let delay = max(0, requestEnds[request.id]?.timeIntervalSinceNow ?? 0)
        transitions[request.id] = Task { [weak self] in
            do { if delay > 0 { try await Task.sleep(for: .seconds(delay)) } } catch { return }
            guard let self, !Task.isCancelled else { return }
            self.routes[request.id]?.phase = .response
            do { try await Task.sleep(for: .seconds(self.pulseDuration)) } catch { return }
            guard !Task.isCancelled else { return }
            self.routes[request.id]?.phase = .settled
            do { try await Task.sleep(for: .seconds(0.18)) } catch { return }
            guard !Task.isCancelled else { return }
            self.routes.removeValue(forKey: request.id); self.requestEnds.removeValue(forKey: request.id)
            self.transitions.removeValue(forKey: request.id)
        }
    }
}
