import Foundation
import Security
import Darwin

private var stopRequested = false

@main struct ProxyAgent {
    static func main() {
        let args = CommandLine.arguments
        if args.contains("--probe") {
            do { print("Available proxy services: \(try SystemProxyStore().services().count)") }
            catch { print(error.localizedDescription); exit(1) }
            return
        }
        guard args.count == 5, let parent = Int32(args[2]), let port = Int(args[3]), (1024...65535).contains(port) else { exit(64) }
        let restoreOnly = args[1] == "--restore"
        let root = URL(fileURLWithPath: args[4], isDirectory: true)
        let statusURL = root.appendingPathComponent("proxy-status.json")
        func status(_ phase: String, _ message: String) {
            if let data = try? JSONSerialization.data(withJSONObject: ["phase": phase, "message": message, "pid": getpid()]) {
                try? data.write(to: statusURL, options: .atomic)
            }
        }
        let fd = open(root.appendingPathComponent("proxy.lock").path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0, flock(fd, LOCK_EX | LOCK_NB) == 0 else { exit(75) }
        defer { close(fd) }
        signal(SIGTERM) { _ in stopRequested = true }
        signal(SIGINT) { _ in stopRequested = true }
        status("authorizing", "请在 macOS 对话框中允许修改网络代理设置。")
        var authorization: AuthorizationRef?
        let code = AuthorizationCreate(nil, nil, [], &authorization)
        guard code == errAuthorizationSuccess, let authorization else { status("failed", "无法启动系统授权（\(code)）。"); exit(1) }
        defer { AuthorizationFree(authorization, []) }
        let granted = "system.preferences".withCString { name -> OSStatus in
            var item = AuthorizationItem(name: name, valueLength: 0, value: nil, flags: 0)
            return withUnsafeMutablePointer(to: &item) { pointer in
                var rights = AuthorizationRights(count: 1, items: pointer)
                return AuthorizationCopyRights(authorization, &rights, nil, [.interactionAllowed, .extendRights, .preAuthorize], nil)
            }
        }
        guard granted == errAuthorizationSuccess else {
            status("failed", granted == errAuthorizationCanceled ? "你取消了系统授权，代理设置未更改。" : "系统未允许修改代理（\(granted)），代理设置未更改。")
            exit(1)
        }
        do {
            let store = try SystemProxyStore(authorization: authorization)
            let lease = ProxyLease(store: store, journal: root.appendingPathComponent("proxy-restore.plist"))
            // An unfinished lease from a prior run is always restored before enabling a new one.
            if lease.pending { try lease.restore() }
            guard !restoreOnly && !stopRequested && kill(parent, 0) == 0 else { status("restored", "原代理设置已恢复。"); return }
            var activationError: String?
            do {
                let count = try lease.apply(port: port)
                status("active", "已接管 \(count) 个网络服务的 HTTP / HTTPS 系统代理。")
                while !stopRequested && kill(parent, 0) == 0 {
                    Thread.sleep(forTimeInterval: 2)
                    if stopRequested { break }
                    // Include newly added network services without overwriting existing services again.
                    _ = try lease.apply(port: port)
                }
            } catch { activationError = error.localizedDescription; status("restoring", error.localizedDescription + "；正在恢复原代理设置。") }
            status("restoring", "正在恢复原代理设置…")
            var attempts = 0
            while lease.pending {
                do { try lease.restore() }
                catch {
                    attempts += 1
                    status("restoreFailed", "恢复失败：\(error.localizedDescription)。原设置备份仍保留，正在重试。")
                    // Stay alive independently of the UI. A permission dialog may require the user.
                    Thread.sleep(forTimeInterval: min(Double(attempts) * 2, 10))
                }
            }
            if let activationError { status("failed", activationError + "。原代理设置已恢复。"); exit(1) }
            status("restored", "原代理设置已恢复。")
        } catch { status("failed", error.localizedDescription); exit(1) }
    }
}
