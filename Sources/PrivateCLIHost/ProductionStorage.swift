import AppKit
import CryptoKit
import Foundation

enum PrivateStore {
    private struct Envelope<Value: Codable>: Codable {
        var schema: Int
        var value: Value
    }

    static func read<Value: Codable>(_ type: Value.Type, from url: URL, default fallback: Value) throws -> Value {
        guard FileManager.default.fileExists(atPath: url.path) else { return fallback }
        let data = try Data(contentsOf: url)
        let envelope = try JSONDecoder().decode(Envelope<Value>.self, from: data)
        guard envelope.schema == 1 else {
            throw CommandError.failed("This data was written by a different app version. Restore a compatible backup before editing it.")
        }
        return envelope.value
    }

    static func write<Value: Codable>(_ value: Value, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let data = try JSONEncoder().encode(Envelope(schema: 1, value: value))
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    static func key(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

struct AccountProfile: Codable, Identifiable, Equatable {
    let id: String
    var name: String
    static let personal = AccountProfile(id: "default", name: "Personal")
    var isValid: Bool { id == "default" || UUID(uuidString: id) != nil }
}

struct RecoveryDraft: Codable, Identifiable {
    let id: UUID
    let project: String
    let provider: String
    let profileID: String
    var text: String
    var images: [String]
    var updatedAt: Date
    var deliveryUnconfirmed: Bool
    var kind: String
}

@MainActor
final class ProductionCenter: ObservableObject {
    let root: URL
    @Published private(set) var profiles: [AccountProfile] = [.personal]
    @Published private(set) var drafts: [RecoveryDraft] = []
    @Published var storageError: String?
    private let writer = DispatchQueue(label: "m4ix.cli.recovery", qos: .utility)
    private var writable = true
    private var draftsURL: URL { root.appendingPathComponent("production/recovery.json") }
    private var profilesURL: URL { root.appendingPathComponent("production/profiles.json") }

    init(root: URL) {
        self.root = root
        do {
            profiles = try PrivateStore.read([AccountProfile].self, from: profilesURL, default: [.personal])
            guard profiles.contains(where: { $0.id == "default" }), profiles.allSatisfy(\.isValid),
                  Set(profiles.map(\.id)).count == profiles.count else {
                throw CommandError.failed("The account profile list is invalid. Restore its backup before editing profiles.")
            }
            drafts = try PrivateStore.read([RecoveryDraft].self, from: draftsURL, default: [])
        } catch { writable = false; storageError = error.localizedDescription }
    }

    func base(for profileID: String) -> URL {
        guard profileID != "default", profiles.contains(where: { $0.id == profileID }) else { return root }
        return root.appendingPathComponent("named-profiles").appendingPathComponent(profileID)
    }

    func name(for profileID: String) -> String { profiles.first { $0.id == profileID }?.name ?? "Unknown profile" }

    func addProfile(name: String) throws -> AccountProfile {
        guard writable else { throw CommandError.failed(storageError ?? "Profile storage is unavailable.") }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 60, !profiles.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
            throw CommandError.failed("Use a unique profile name between 1 and 60 characters.")
        }
        let profile = AccountProfile(id: UUID().uuidString.lowercased(), name: name)
        let updated = profiles + [profile]
        try PrivateStore.write(updated, to: profilesURL)
        profiles = updated
        return profile
    }

    func saveDraft(id: UUID, project: String, provider: String, profileID: String, text: String,
                   images: [URL], deliveryUnconfirmed: Bool = false, kind: String = "Message") {
        guard writable else { return }
        if text.isEmpty && images.isEmpty {
            // Clearing the editor after Send must not erase an uncertain delivery.
            if drafts.first(where: { $0.id == id })?.deliveryUnconfirmed != true { removeDraft(id) }
            return
        }
        let imageRoot = root.appendingPathComponent("production/recovery-images")
        let destinations = images.map { source in
            source.path.hasPrefix(imageRoot.path + "/") ? source : imageRoot.appendingPathComponent(PrivateStore.key(source.path) + "." + source.pathExtension)
        }
        let uncertain = deliveryUnconfirmed || drafts.first(where: { $0.id == id })?.deliveryUnconfirmed == true
        let draft = RecoveryDraft(id: id, project: project, provider: provider, profileID: profileID,
                                  text: text, images: destinations.map(\.path), updatedAt: Date(),
                                  deliveryUnconfirmed: uncertain, kind: kind)
        drafts.removeAll { $0.id == id }
        drafts.insert(draft, at: 0)
        let snapshot = drafts
        let url = draftsURL
        let copies = Array(zip(images, destinations))
        writer.async { [weak self] in
            do {
                for (source, destination) in copies where source != destination && !FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.createDirectory(at: imageRoot, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                    if !FileManager.default.fileExists(atPath: destination.path) {
                        try FileManager.default.copyItem(at: source, to: destination)
                        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
                    }
                }
                try PrivateStore.write(snapshot, to: url)
            } catch {
                Task { @MainActor in
                    self?.storageError = "Draft recovery could not be saved: \(error.localizedDescription)"
                }
            }
        }
    }

    func removeDraft(_ id: UUID) {
        guard writable, drafts.contains(where: { $0.id == id }) else { return }
        drafts.removeAll { $0.id == id }
        let snapshot = drafts
        let url = draftsURL
        writer.async { [weak self] in
            do { try PrivateStore.write(snapshot, to: url) }
            catch { Task { @MainActor in self?.storageError = error.localizedDescription } }
        }
    }

    func flush() { writer.sync {} }
}
