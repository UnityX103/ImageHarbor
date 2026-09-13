import Foundation
import SystemConfiguration

@main struct SystemConfigurationIntegration {
    static func main() throws {
        let fm = FileManager.default
        let temp = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: temp) }
        let liveBefore = SCDynamicStoreCopyProxies(nil) as? ProxyDictionary
        let prefs = SCPreferencesCreate(nil, "ImageHarbor isolated test" as CFString, temp.appendingPathComponent("network.plist").path as CFString)!
        let interfaces = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] ?? []
        guard let interface = interfaces.first(where: { (SCNetworkInterfaceGetBSDName($0) as String?) == "en0" }) ?? interfaces.first,
              let service = SCNetworkServiceCreate(prefs, interface),
              let id = SCNetworkServiceGetServiceID(service) else { throw proxyError("No interface available for isolated fixture") }
        _ = SCNetworkServiceAddProtocolType(service, kSCNetworkProtocolTypeProxies)
        guard let proto = SCNetworkServiceCopyProtocol(service, kSCNetworkProtocolTypeProxies) else { throw proxyError("Fixture proxy protocol unavailable") }
        let original: ProxyDictionary = ["HTTPEnable": 1, "HTTPProxy": "fixture.proxy", "HTTPPort": 3128, "ExceptionsList": ["*.internal"]]
        assert(SCNetworkProtocolSetConfiguration(proto, original as CFDictionary))
        guard SCPreferencesCommitChanges(prefs) else { throw proxyError("This optional isolated-framework integration test requires administrator rights; live system settings were not changed.") }
        let store = SystemProxyStore(preferences: prefs)
        let lease = ProxyLease(store: store, journal: temp.appendingPathComponent("recovery.plist"))
        _ = try lease.apply(port: 8877)
        let applied = try store.services().first(where: { $0.id == id as String })!
        assert(applied.configuration?["HTTPProxy"] as? String == "127.0.0.1")
        assert(applied.configuration?["HTTPSPort"] as? Int == 8877)
        try ProxyLease(store: store, journal: lease.journal).restore()
        let restored = try store.services().first(where: { $0.id == id as String })!
        assert(ProxySettings.equal(restored.configuration, original))
        let liveAfter = SCDynamicStoreCopyProxies(nil) as? ProxyDictionary
        assert(ProxySettings.equal(liveBefore, liveAfter), "Live system settings must not change in isolated test")
        print("PASS: real SystemConfiguration commit/apply/read-back/restore with isolated preferences; live system proxy unchanged")
    }
}
