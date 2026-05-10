import Foundation
import Observation
import OSLog

/// One motifd target the user has configured. The `token` field is the
/// motifd Bearer token (the iOS app talks to motifd directly via tsnet,
/// not through the motif-web bridge — so there's no separate browser
/// token).
struct MotifServer: Codable, Identifiable, Equatable, Hashable, Sendable {
    let id: UUID
    var name: String
    var host: String
    var port: UInt16
    var token: String

    init(id: UUID = UUID(), name: String, host: String, port: UInt16, token: String) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.token = token
    }

    var endpoint: String { "\(host):\(port)" }
}

/// Persistent store for the configured server list. The list lives in
/// Keychain (so tokens don't leak into iCloud backups) and the active
/// selection lives in UserDefaults.
@Observable
@MainActor
final class MotifServerStore {
    private let log = Logger(subsystem: "io.allsunday.motif", category: "Servers")
    private let keychain = Keychain(service: "io.allsunday.motif.servers")
    private static let listKey = "list.v1"
    private static let activeIDKey = "activeServerID"

    private(set) var servers: [MotifServer] = []
    private(set) var activeID: UUID?

    init() {
        load()
    }

    var activeServer: MotifServer? {
        guard let activeID else { return nil }
        return servers.first(where: { $0.id == activeID })
    }

    func add(_ server: MotifServer) {
        servers.append(server)
        if activeID == nil { activeID = server.id }
        persist()
    }

    func update(_ server: MotifServer) {
        guard let idx = servers.firstIndex(where: { $0.id == server.id }) else { return }
        servers[idx] = server
        persist()
    }

    func delete(id: UUID) {
        servers.removeAll(where: { $0.id == id })
        if activeID == id { activeID = servers.first?.id }
        persist()
    }

    func setActive(id: UUID) {
        guard servers.contains(where: { $0.id == id }) else { return }
        activeID = id
        persistActiveID()
    }

    // MARK: - Persistence

    private func load() {
        if let stored = keychain.getJSON([MotifServer].self, forKey: Self.listKey) {
            servers = stored
        }
        if let s = UserDefaults.standard.string(forKey: Self.activeIDKey),
           let uuid = UUID(uuidString: s) {
            activeID = uuid
        }
        // Heal the active id if it points at a deleted server.
        if let aid = activeID, !servers.contains(where: { $0.id == aid }) {
            activeID = servers.first?.id
            persistActiveID()
        }
    }

    private func persist() {
        keychain.setJSON(servers, forKey: Self.listKey)
        persistActiveID()
    }

    private func persistActiveID() {
        if let activeID {
            UserDefaults.standard.set(activeID.uuidString, forKey: Self.activeIDKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.activeIDKey)
        }
    }
}
