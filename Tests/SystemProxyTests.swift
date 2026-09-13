import Foundation

final class MemoryStore: ProxyStore {
    var values: [String: ProxyService]
    var committed: [String: ProxyService]
    var failCommit = false
    var beforeSet: (() throws -> Void)?
    init(_ values: [String: ProxyService]) { self.values = values; self.committed = values }
    func begin() { values = committed }
    func end() { }
    func services() -> [ProxyService] { Array(values.values) }
    func set(_ id: String, configuration: ProxyDictionary?, enabled: Bool) throws {
        try beforeSet?()
        values[id] = ProxyService(id: id, configuration: configuration, enabled: enabled)
    }
    func commit() throws {
        if failCommit { throw proxyError("simulated commit failure") }
        committed = values
    }
}
@main struct SystemProxyTests {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let original: ProxyDictionary = ["HTTPEnable": 1, "HTTPProxy": "original.proxy", "HTTPPort": 3128,
                                        "SOCKSEnable": 1, "SOCKSPort": 1080, "ProxyAutoConfigEnable": 1,
                                        "ProxyAutoConfigURLString": "https://example.com/proxy.pac", "ExceptionsList": ["*.local"], "Custom": "keep"]
        let store = MemoryStore(["wifi": ProxyService(id: "wifi", configuration: original, enabled: true), "eth": ProxyService(id: "eth", configuration: nil, enabled: false)])
        let journal = root.appendingPathComponent("backup.plist")
        let lease = ProxyLease(store: store, journal: journal)
        store.beforeSet = { guard FileManager.default.fileExists(atPath: journal.path) else { fatalError("settings mutated before backup") } }
        _ = try lease.apply(port: 8877)
        assert(store.committed["wifi"]!.configuration?["HTTPProxy"] as? String == "127.0.0.1")
        assert(store.committed["wifi"]!.configuration?["ProxyAutoConfigEnable"] as? Int == 0)
        assert(store.committed["eth"]!.enabled)
        // Simulate process death: recover from disk in a fresh controller.
        try ProxyLease(store: store, journal: journal).restore()
        assert(ProxySettings.equal(store.committed["wifi"]!.configuration, original))
        assert(store.committed["eth"]!.configuration == nil && !store.committed["eth"]!.enabled)
        assert(!lease.pending)
        _ = try lease.apply(port: 8877)
        var userEdit = store.committed["wifi"]!.configuration!
        userEdit["HTTPProxy"] = "user.new.proxy"
        userEdit["Custom"] = "user changed"
        store.committed["wifi"] = ProxyService(id: "wifi", configuration: userEdit, enabled: true)
        store.committed["usb"] = ProxyService(id: "usb", configuration: [:], enabled: true)
        _ = try lease.apply(port: 8877)
        assert(store.committed["usb"]!.configuration?["HTTPPort"] as? Int == 8877)
        try lease.restore()
        assert(store.committed["wifi"]!.configuration?["HTTPProxy"] as? String == "user.new.proxy")
        assert(store.committed["wifi"]!.configuration?["Custom"] as? String == "user changed")
        assert(store.committed["wifi"]!.configuration?["HTTPSProxy"] == nil)
        store.failCommit = true
        do { _ = try lease.apply(port: 8877); fatalError("failure not propagated") } catch { }
        assert(lease.pending)
        do { try lease.restore(); fatalError("restore failure not propagated") } catch { }
        assert(lease.pending)
        store.failCommit = false
        try lease.restore()
        assert(!lease.pending)
        print("PASS: write-ahead backup, HTTP/HTTPS routing, PAC/SOCKS, disabled protocol, exact restoration, crash recovery, concurrent user changes, new interfaces, permission/commit failure and retry")
    }
}
