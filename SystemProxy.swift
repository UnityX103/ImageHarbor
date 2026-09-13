import Foundation
import SystemConfiguration
import Security

typealias ProxyDictionary = [String: Any]
struct ProxyService {
    let id: String
    let configuration: ProxyDictionary?
    let enabled: Bool
}
protocol ProxyStore {
    func begin() throws
    func end()
    func services() throws -> [ProxyService]
    func set(_ id: String, configuration: ProxyDictionary?, enabled: Bool) throws
    func commit() throws
}
func proxyError(_ message: String) -> NSError {
    NSError(domain: "ImageHarbor.SystemProxy", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
}

enum ProxySettings {
    static let groups = [
        ["HTTPEnable", "HTTPProxy", "HTTPPort", "HTTPUser"],
        ["HTTPSEnable", "HTTPSProxy", "HTTPSPort", "HTTPSUser"],
        ["SOCKSEnable"], ["ProxyAutoConfigEnable"], ["ProxyAutoDiscoveryEnable"],
        ["ExceptionsList"], ["ExcludeSimpleHostnames"]
    ]
    static func installed(over original: ProxyDictionary?, port: Int) -> ProxyDictionary {
        var result = original ?? [:]
        for prefix in ["HTTP", "HTTPS"] {
            result[prefix + "Enable"] = 1
            result[prefix + "Proxy"] = "127.0.0.1"
            result[prefix + "Port"] = port
            result.removeValue(forKey: prefix + "User")
        }
        result["SOCKSEnable"] = 0
        result["ProxyAutoConfigEnable"] = 0
        result["ProxyAutoDiscoveryEnable"] = 0
        result["ExceptionsList"] = [String]()
        result["ExcludeSimpleHostnames"] = 0
        return result
    }
    static func equal(_ a: ProxyDictionary?, _ b: ProxyDictionary?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case let (a?, b?): return NSDictionary(dictionary: a).isEqual(to: b)
        default: return false
        }
    }
    static func restored(current: ProxyDictionary?, original: ProxyDictionary?, installed: ProxyDictionary) -> ProxyDictionary? {
        if equal(current, installed) { return original }
        guard var current else { return nil }
        // Preserve changes made by the user or another proxy app during capture.
        for keys in groups {
            let now = current.filter { keys.contains($0.key) }
            let ours = installed.filter { keys.contains($0.key) }
            if equal(now, ours) {
                for key in keys {
                    current.removeValue(forKey: key)
                    if let old = original?[key] { current[key] = old }
                }
            }
        }
        return current.isEmpty && original == nil ? nil : current
    }
}

final class ProxyLease {
    let store: ProxyStore
    let journal: URL
    init(store: ProxyStore, journal: URL) { self.store = store; self.journal = journal }
    var pending: Bool { FileManager.default.fileExists(atPath: journal.path) }
    private func read() throws -> [String: ProxyDictionary] {
        guard pending else { return [:] }
        let data = try Data(contentsOf: journal)
        guard let result = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: ProxyDictionary] else { throw proxyError("无法读取原代理设置备份。") }
        return result
    }
    private func save(_ data: [String: ProxyDictionary]) throws {
        try PropertyListSerialization.data(fromPropertyList: data, format: .binary, options: 0).write(to: journal, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: journal.path)
    }
    @discardableResult func apply(port: Int) throws -> Int {
        guard (1024...65535).contains(port) else { throw proxyError("代理端口无效。") }
        try store.begin(); defer { store.end() }
        var saved = try read()
        let services = try store.services()
        guard !services.isEmpty else { throw proxyError("没有可配置的网络服务。") }
        let newServices = services.filter { saved[$0.id] == nil }
        for s in newServices {
            saved[s.id] = ["original": s.configuration ?? [:], "hasOriginal": s.configuration != nil,
                           "enabled": s.enabled, "installed": ProxySettings.installed(over: s.configuration, port: port)]
        }
        if !newServices.isEmpty {
            // Durable write-ahead journal: never touch preferences without the original values on disk.
            try save(saved)
            for s in newServices { try store.set(s.id, configuration: saved[s.id]!["installed"] as? ProxyDictionary, enabled: true) }
            try store.commit()
        }
        return services.count
    }
    func restore() throws {
        guard pending else { return }
        try store.begin(); defer { store.end() }
        let saved = try read()
        for s in try store.services() {
            guard let item = saved[s.id], let installed = item["installed"] as? ProxyDictionary else { continue }
            let original = (item["hasOriginal"] as? Bool == true) ? item["original"] as? ProxyDictionary : nil
            let restored = ProxySettings.restored(current: s.configuration, original: original, installed: installed)
            let originalEnabled = item["enabled"] as? Bool ?? true
            let enabled = ProxySettings.equal(s.configuration, installed) && s.enabled ? originalEnabled : s.enabled
            try store.set(s.id, configuration: restored, enabled: enabled)
        }
        try store.commit()
        // Keep the backup on *any* commit/apply failure so recovery can be retried.
        try FileManager.default.removeItem(at: journal)
    }
}

final class SystemProxyStore: ProxyStore {
    private let prefs: SCPreferences
    init(preferences: SCPreferences) { prefs = preferences }
    init(authorization: AuthorizationRef? = nil) throws {
        let value: SCPreferences?
        if let authorization { value = SCPreferencesCreateWithAuthorization(nil, "Image Harbor" as CFString, nil, authorization) }
        else { value = SCPreferencesCreate(nil, "Image Harbor" as CFString, nil) }
        guard let value else { throw proxyError("无法读取系统网络设置。") }
        prefs = value
    }
    func begin() throws {
        SCPreferencesSynchronize(prefs)
        guard SCPreferencesLock(prefs, true) else { throw failure("网络设置正在被其他程序修改") }
    }
    func end() { SCPreferencesUnlock(prefs) }
    private func all() -> [SCNetworkService] { SCNetworkServiceCopyAll(prefs) as? [SCNetworkService] ?? [] }
    func services() throws -> [ProxyService] {
        all().compactMap { service in
            guard let proto = SCNetworkServiceCopyProtocol(service, kSCNetworkProtocolTypeProxies), let id = SCNetworkServiceGetServiceID(service) else { return nil }
            return ProxyService(id: id as String,
                                configuration: SCNetworkProtocolGetConfiguration(proto) as? ProxyDictionary,
                                enabled: SCNetworkProtocolGetEnabled(proto))
        }
    }
    func set(_ id: String, configuration: ProxyDictionary?, enabled: Bool) throws {
        guard let service = all().first(where: { (SCNetworkServiceGetServiceID($0) as String?) == id }),
              let proto = SCNetworkServiceCopyProtocol(service, kSCNetworkProtocolTypeProxies) else { return }
        guard SCNetworkProtocolSetConfiguration(proto, configuration as CFDictionary?), SCNetworkProtocolSetEnabled(proto, enabled) else { throw failure("无法修改代理配置") }
    }
    func commit() throws {
        guard SCPreferencesCommitChanges(prefs) else { throw failure("未能保存代理设置，请允许 macOS 的网络设置授权") }
        guard SCPreferencesApplyChanges(prefs) else { throw failure("代理设置已保存，但尚未应用；正在尝试恢复") }
    }
    private func failure(_ action: String) -> NSError {
        proxyError(action + "（" + String(cString: SCErrorString(SCError())) + "）")
    }
}
