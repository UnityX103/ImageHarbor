import SwiftUI
import AppKit
import Security
import CryptoKit

struct CertificateStatus: Sendable {
    let fingerprint: String
    let trusted: Bool
    let explanation: String
}

enum CertificateInspector {
    static func der(at url: URL) throws -> Data {
        let text = try String(contentsOf: url, encoding: .utf8)
        let content = text.components(separatedBy: "-----BEGIN CERTIFICATE-----").dropFirst().first?
            .components(separatedBy: "-----END CERTIFICATE-----").first ?? ""
        guard let data = Data(base64Encoded: content, options: .ignoreUnknownCharacters), !data.isEmpty,
              SecCertificateCreateWithData(nil, data as CFData) != nil else {
            throw NSError(domain: "ImageHarbor", code: 1, userInfo: [NSLocalizedDescriptionKey: "证书文件无法解析，请查看代理日志。"])
        }
        return data
    }
    static func inspect(_ url: URL) throws -> CertificateStatus {
        let data = try der(at: url)
        let fingerprint = SHA256.hash(data: data).map { String(format: "%02X", $0) }.joined(separator: ":")
        let certificate = SecCertificateCreateWithData(nil, data as CFData)!
        var trust: SecTrust?
        let status = SecTrustCreateWithCertificates(certificate, SecPolicyCreateSSL(true, nil), &trust)
        guard status == errSecSuccess, let trust else {
            return CertificateStatus(fingerprint: fingerprint, trusted: false, explanation: "暂时无法读取系统信任状态。")
        }
        SecTrustSetNetworkFetchAllowed(trust, false)
        var error: CFError?
        let trusted = SecTrustEvaluateWithError(trust, &error)
        return CertificateStatus(fingerprint: fingerprint, trusted: trusted,
                                 explanation: trusted ? "证书已受信任，可以开始系统采集。" : "尚未检测到已保存的信任设置。请先关闭证书详情窗口，在系统提示中输入 Mac 登录密码并确认，再检查。")
    }
}


enum LoginCertificateInstaller {
    static func loginPath(home: URL = FileManager.default.homeDirectoryForCurrentUser) throws -> String {
        for name in ["login.keychain-db", "login.keychain"] {
            let path = home.appendingPathComponent("Library/Keychains/" + name).path
            if FileManager.default.fileExists(atPath: path) { return path }
        }
        throw proxyError("未找到当前用户的登录钥匙串，请先在钥匙串访问中创建或解锁“登录”钥匙串。")
    }
    static func add(der: Data, keychainPath: String) throws {
        guard let certificate = SecCertificateCreateWithData(nil, der as CFData) else { throw proxyError("公开证书无法解析。") }
        var keychain: SecKeychain?
        var result = SecKeychainOpen(keychainPath, &keychain)
        guard result == errSecSuccess, let keychain else { throw proxyError("无法打开登录钥匙串（\(result)）。") }
        result = SecCertificateAddToKeychain(certificate, keychain)
        guard result == errSecSuccess || result == errSecDuplicateItem else {
            throw proxyError("导入登录钥匙串失败：\((SecCopyErrorMessageString(result, nil) as String?) ?? String(result))")
        }
    }
}

@MainActor extension HarborModel {
    func openKeychain() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.keychainaccess") else { message = "请用 Spotlight 搜索“钥匙串访问”。"; return }
        NSWorkspace.shared.openApplication(at: url, configuration: .init()) { _, _ in }
    }
    func importLoginCertificate() async throws {
        let certURL = cert
        try await Task.detached(priority: .userInitiated) {
            let der = try CertificateInspector.der(at: certURL)
            // Explicit target; never use the selected/default keychain or System Roots.
            try LoginCertificateInstaller.add(der: der, keychainPath: LoginCertificateInstaller.loginPath())
        }.value
    }
}

struct HelpView: View {
    @ObservedObject var model: HarborModel
    @Environment(\.dismiss) private var dismiss
    @State private var step = 0
    @State private var busy = false
    @State private var feedback = ""
    @State private var fingerprint = ""
    private let titles = ["准备证书", "添加到登录钥匙串", "打开这张证书", "设为信任", "关闭窗口并确认", "开始系统采集"]
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Image(systemName: step == 5 ? "network" : "lock.shield").font(.system(size: 32)).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 4) {
                    Text(titles[step]).font(.title2.bold())
                    Text("第 \(step + 1) 步，共 6 步").font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
            }
            Divider()
            Group {
                switch step {
                case 0:
                    Text("先生成这台 Mac 专用的代理证书。")
                    Text("这一步只准备本地监听，暂不更改系统代理。").foregroundStyle(.secondary)
                case 1:
                    Text("点击下方按钮，证书会直接加入当前用户的“登录”钥匙串。")
                    Label("不会写入“系统根证书”，无需选择导入位置。", systemImage: "info.circle").foregroundStyle(.secondary)
                case 2:
                    Text("在“钥匙串访问”中：")
                    VStack(alignment: .leading, spacing: 10) {
                        Text("1. 左侧选择“登录”。")
                        Text("2. 搜索 mitmproxy。")
                        Text("3. 双击这张证书。")
                    }
                    Button("打开钥匙串访问") { model.openKeychain() }
                case 3:
                    Text("在证书详情里展开“信任”。")
                    Text("把“安全套接字层（SSL）”改为“始终信任”。")
                    Text("选好后点击“下一步”，继续完成保存。").foregroundStyle(.secondary)
                case 4:
                    Text("1. 关闭证书详情窗口。").bold()
                    Text("2. 在 macOS 提示中输入 Mac 登录密码，并确认保存。")
                    Text("窗口还开着，或密码确认尚未完成时，新设置还未保存，应用无法检测到信任状态。").foregroundStyle(.secondary)
                default:
                    Text("证书已受信任。现在可以接管这台 Mac 的系统 HTTP / HTTPS 代理。")
                    Text("点击“开始采集”后，按 macOS 提示允许修改网络设置。直接使用你现有的浏览器和应用即可。").foregroundStyle(.secondary)
                    Text("采集期间暂时替换现有系统代理，停止后恢复。").foregroundStyle(.secondary)
                }
            }.font(.body).fixedSize(horizontal: false, vertical: true)
            if (2...3).contains(step) {
                DisclosureGroup("有多个同名证书？核对指纹") {
                    Text("在证书的详细信息中查找 SHA-256，与下面的本机指纹核对：").font(.caption)
                    Text(fingerprint.isEmpty ? "正在读取…" : fingerprint).font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
                }.font(.caption).foregroundStyle(.secondary)
            }
            if !feedback.isEmpty { Text(feedback).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            Spacer(minLength: 0)
            Divider()
            HStack {
                Button("稍后设置") { dismiss() }
                Spacer()
                if step > 0 { Button("上一步") { step -= 1; feedback = "" }.disabled(busy) }
                Button(busy ? "请稍候…" : primaryTitle) { performStep() }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(busy || (step == 0 && model.starting))
            }
        }.padding(26).frame(width: 540, height: 440)
        .onAppear { readFingerprint() }
        .onChange(of: model.active) { ready in
            if ready && step == 0 && busy { busy = false; step = 1; feedback = ""; readFingerprint() }
        }
        .onChange(of: model.starting) { starting in
            if !starting && !model.active && busy && step == 0 { busy = false; feedback = model.message }
        }
    }
    private var primaryTitle: String {
        switch step {
        case 0: return FileManager.default.fileExists(atPath: model.cert.path) ? "下一步" : "准备证书"
        case 1: return "添加到登录钥匙串"
        case 2: return "已打开，下一步"
        case 3: return "下一步"
        case 4: return "已关闭并确认，检查信任"
        default: return "开始采集"
        }
    }
    private func readFingerprint() {
        let url = model.cert
        Task {
            if let result = try? await Task.detached(operation: { try CertificateInspector.inspect(url) }).value { fingerprint = result.fingerprint }
        }
    }
    private func performStep() {
        feedback = ""
        switch step {
        case 0:
            if FileManager.default.fileExists(atPath: model.cert.path) { step = 1 }
            else { busy = true; model.start(); if !model.starting && !model.active { busy = false; feedback = model.message } }
        case 1:
            busy = true
            Task {
                do { try await model.importLoginCertificate(); step = 2; feedback = "已加入“登录”钥匙串。"; readFingerprint() }
                catch { feedback = error.localizedDescription }
                busy = false
            }
        case 2: step = 3
        case 3: step = 4
        case 4:
            busy = true
            let url = model.cert
            Task {
                do {
                    let status = try await Task.detached { try CertificateInspector.inspect(url) }.value
                    if status.trusted { step = 5 } else { feedback = status.explanation }
                } catch { feedback = error.localizedDescription }
                busy = false
            }
        default: dismiss(); model.startCapture()
        }
    }
}
