import SwiftUI
import AppKit
import ImageIO

@MainActor final class HarborModel: ObservableObject {
    @Published var images: [CapturedImage] = []
    @Published var state = "未启动"
    @Published var active = false
    @Published var starting = false
    @Published var port = "8877"
    @Published var query = ""
    @Published var mode: ExportMode = .address
    @Published var message = ""
    @Published var exporting = false
    @Published var selected: CapturedImage?
    @Published var showHelp = false
    @Published var systemCapturing = false
    @Published var connecting = false
    @Published var restoring = false
    @Published var needsRecovery = false
    @Published var proxyDetail = ""
    var proxyAgent: Process?
    var captureRequested = false
    var quitPending = false
    var pendingUpdateInstallation: (() -> Void)?
    var stoppingEngine: Process?
    @Published var updateInstalling = false
    private var lastProxyPhase = ""
    let root: URL
    var process: Process?
    var timer: Timer?
    var offset: UInt64 = 0
    var pending = Data()
    var startedAt = Date()
    var sessionPort = "8877"
    var logHandle: FileHandle?
    var visible: [CapturedImage] { query.isEmpty ? images : images.filter { $0.url.localizedCaseInsensitiveContains(query) || $0.format.localizedCaseInsensitiveContains(query) } }
    var totalSize: String { ByteCountFormatter.string(fromByteCount: Int64(images.reduce(0) { $0 + $1.size }), countStyle: .file) }
    var cert: URL { root.appendingPathComponent("certificates/mitmproxy-ca-cert.pem") }
    init() {
        root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("ImageHarbor")
        try? FileManager.default.createDirectory(at: root.appendingPathComponent("images"), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        needsRecovery = FileManager.default.fileExists(atPath: root.appendingPathComponent("proxy-restore.plist").path)
        poll()
        timer = Timer.scheduledTimer(withTimeInterval: 0.7, repeats: true) { [weak self] _ in Task { @MainActor in self?.poll() } }
    }
    func poll() {
        if let handle = try? FileHandle(forReadingFrom: root.appendingPathComponent("records.jsonl")) {
            defer { try? handle.close() }
            do {
                try handle.seek(toOffset: offset)
                let data = try handle.readToEnd() ?? Data()
                offset += UInt64(data.count)
                pending.append(data)
                var incoming: [CapturedImage] = []
                while let newline = pending.firstIndex(of: 10) {
                    let line = pending[..<newline]
                    if let item = try? JSONDecoder().decode(CapturedImage.self, from: line) { incoming.append(item) }
                    pending.removeSubrange(...newline)
                }
                if !incoming.isEmpty { images.insert(contentsOf: incoming.reversed(), at: 0) }
            } catch { message = "读取记录失败：\(error.localizedDescription)" }
        }
        if starting, process?.isRunning == true, FileManager.default.fileExists(atPath: root.appendingPathComponent("ready").path) {
            starting = false; active = true; state = "代理已就绪"
            if captureRequested { launchProxyAgent(restoreOnly: false) }
        }
        pollProxyStatus()
        continueUpdateIfSafe()
        if starting, Date().timeIntervalSince(startedAt) > 25 {
            captureRequested = false; stop(); message = "代理启动超时，请打开日志查看原因。"
        }
    }
    func start() {
        guard process == nil, !updateInstalling, pendingUpdateInstallation == nil else { return }
        guard let value = Int(port), (1024...65535).contains(value) else { captureRequested = false; message = "请输入 1024–65535 之间的端口。"; return }
        guard let resources = Bundle.main.resourceURL else { return }
        let engine = resources.appendingPathComponent("mitmproxy.app/Contents/MacOS/mitmdump")
        guard FileManager.default.isExecutableFile(atPath: engine.path) else { captureRequested = false; message = "内置代理引擎缺失，请重新安装。"; return }
        try? FileManager.default.removeItem(at: root.appendingPathComponent("ready"))
        let log = root.appendingPathComponent("proxy.log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        logHandle = try? FileHandle(forWritingTo: log)
        let p = Process()
        p.executableURL = engine
        sessionPort = String(value)
        p.arguments = ["--listen-host", "127.0.0.1", "--listen-port", sessionPort, "--set", "confdir=\(root.appendingPathComponent("certificates").path)", "--set", "flow_detail=0", "--set", "termlog_verbosity=warn", "-s", resources.appendingPathComponent("capture.py").path]
        var env = ProcessInfo.processInfo.environment
        env["IMAGE_HARBOR_DATA"] = root.path
        env["IMAGE_HARBOR_PARENT"] = String(ProcessInfo.processInfo.processIdentifier)
        p.environment = env
        p.standardOutput = logHandle; p.standardError = logHandle
        p.terminationHandler = { [weak self] finished in
            Task { @MainActor in
                guard let self, self.process === finished else { return }
                self.process = nil; self.active = false; self.starting = false; self.captureRequested = false
                self.state = "已停止"
                if self.proxyAgent != nil { self.stop() }
                try? self.logHandle?.close(); self.logHandle = nil
                if finished.terminationStatus != 0 { self.message = "代理退出（\(finished.terminationStatus)），端口可能被占用，请查看日志。" }
            }
        }
        do {
            try p.run(); process = p; starting = true; startedAt = Date(); state = "正在启动…"
        } catch { captureRequested = false; message = "启动失败：\(error.localizedDescription)"; try? logHandle?.close(); logHandle = nil }
    }
    func stopEngine() {
        guard let p = process else { return }
        p.terminationHandler = nil
        stoppingEngine = p
        if p.isRunning { p.terminate() }
        process = nil; active = false; starting = false; state = "已停止"
        try? logHandle?.close(); logHandle = nil
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) { if p.isRunning { kill(p.processIdentifier, SIGKILL) } }
    }
    func startCapture() {
        guard !updateInstalling && pendingUpdateInstallation == nil && !connecting && !restoring && !captureRequested && !starting && proxyAgent == nil else { return }
        if needsRecovery { launchProxyAgent(restoreOnly: true); return }
        let url = cert
        Task {
            let ready = (try? await Task.detached { try CertificateInspector.inspect(url).trusted }.value) ?? false
            guard !updateInstalling, pendingUpdateInstallation == nil else { return }
            guard ready else { showHelp = true; return }
            captureRequested = true
            if active { launchProxyAgent(restoreOnly: false) } else { start() }
        }
    }
    func launchProxyAgent(restoreOnly: Bool) {
        guard proxyAgent == nil else { return }
        let agent = Process()
        agent.executableURL = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("ImageHarborProxy")
        agent.arguments = [restoreOnly ? "--restore" : "--capture", String(getpid()), sessionPort, root.path]
        try? FileManager.default.removeItem(at: root.appendingPathComponent("proxy-status.json"))
        lastProxyPhase = ""
        connecting = !restoreOnly; restoring = restoreOnly
        state = restoreOnly ? "正在恢复原代理…" : "等待系统网络授权…"
        agent.terminationHandler = { [weak self] finished in
            Task { @MainActor in
                guard let self, self.proxyAgent === finished else { return }
                self.pollProxyStatus()
                self.proxyAgent = nil; self.connecting = false; self.restoring = false; self.systemCapturing = false
                self.captureRequested = false
                self.needsRecovery = FileManager.default.fileExists(atPath: self.root.appendingPathComponent("proxy-restore.plist").path)
                if self.needsRecovery {
                    self.state = "原代理设置需要恢复"
                    self.message = "代理管理进程已退出。请点击“恢复原代理设置”；恢复完成前会保留监听。"
                    if self.quitPending { self.quitPending = false; NSApp.reply(toApplicationShouldTerminate: false) }
                } else {
                    self.stopEngine()
                    if finished.terminationStatus != 0 { self.message = self.proxyDetail.isEmpty ? "未能启用系统代理，请重新开始采集并允许系统授权。" : self.proxyDetail }
                    self.completeQuit()
                }
            }
        }
        do { try agent.run(); proxyAgent = agent }
        catch { connecting = false; restoring = false; captureRequested = false; message = error.localizedDescription; if quitPending { quitPending = false; NSApp.reply(toApplicationShouldTerminate: false) } }
    }
    func pollProxyStatus() {
        guard proxyAgent != nil,
              let data = try? Data(contentsOf: root.appendingPathComponent("proxy-status.json")),
              let status = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let phase = status["phase"] as? String,
              phase != lastProxyPhase else { return }
        lastProxyPhase = phase
        proxyDetail = status["message"] as? String ?? ""
        switch phase {
        case "active":
            systemCapturing = true; connecting = false; restoring = false; state = "正在采集系统请求"
        case "restoring":
            systemCapturing = false; connecting = false; restoring = true; state = "正在恢复原代理…"
        case "restoreFailed":
            restoring = true; state = "恢复原代理需要处理"; message = proxyDetail
            if quitPending { quitPending = false; NSApp.reply(toApplicationShouldTerminate: false) }
        case "restored": state = "原代理已恢复"
        case "failed": message = proxyDetail
        default: break
        }
    }
    func stop() {
        captureRequested = false
        if let agent = proxyAgent, agent.isRunning {
            restoring = true; systemCapturing = false; state = "正在恢复原代理…"; agent.terminate()
        } else if needsRecovery {
            launchProxyAgent(restoreOnly: true)
        } else { stopEngine(); completeQuit() }
    }
    func prepareForUpdate(_ install: @escaping () -> Void) {
        pendingUpdateInstallation = install
        state = "正在停止采集以安装更新…"
        stop()
        // Resume from the next polling cycle, after Sparkle has accepted postponement.
    }
    func continueUpdateIfSafe() {
        guard let install = pendingUpdateInstallation,
              !exporting, !active, !starting, proxyAgent == nil, !needsRecovery,
              stoppingEngine?.isRunning != true else { return }
        pendingUpdateInstallation = nil
        updateInstalling = true
        install()
    }
    func completeQuit() {
        if quitPending && !needsRecovery && proxyAgent == nil { quitPending = false; NSApp.reply(toApplicationShouldTerminate: true) }
    }
    func export() {
        guard !updateInstalling, pendingUpdateInstallation == nil else { return }
        let snapshot = images
        guard !snapshot.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true
        panel.prompt = "导出到这里"; panel.message = "导出全部 \(snapshot.count) 张图片（搜索不会限制导出范围）"
        guard panel.runModal() == .OK, let destination = panel.url,
              !updateInstalling, pendingUpdateInstallation == nil else { return }
        exporting = true
        let source = root.appendingPathComponent("images"), mode = mode
        Task {
            do {
                let folder = try await Task.detached(priority: .userInitiated) { try ImageExporter.export(snapshot, source: source, destination: destination, mode: mode) }.value
                exporting = false; message = "已导出 \(snapshot.count) 张图片，并附带来源清单 manifest.json。"
                NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: folder.path)
            } catch { exporting = false; message = "导出失败：\(error.localizedDescription)" }
        }
    }
    func clear() {
        guard !active && !starting && !exporting else { return }
        let alert = NSAlert(); alert.messageText = "清空全部采集记录？"; alert.informativeText = "会删除本机采集缓存，已经导出的图片不受影响。"
        alert.addButton(withTitle: "清空"); alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            let dir = root.appendingPathComponent("images")
            try FileManager.default.removeItem(at: dir)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data().write(to: root.appendingPathComponent("records.jsonl"), options: .atomic)
            images = []; selected = nil; offset = 0; pending = Data()
        } catch { message = error.localizedDescription }
    }
}

struct Thumb: View {
    let url: URL
    @State private var thumbnail: NSImage?
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.04))
            if let thumbnail { Image(nsImage: thumbnail).resizable().scaledToFit().padding(8) }
            else { Image(systemName: "photo").font(.system(size: 30)).foregroundStyle(.tertiary) }
        }.task(id: url) {
            let path = url
            let result = await Task.detached(priority: .utility) { () -> Data? in
                guard let source = CGImageSourceCreateWithURL(path as CFURL, nil),
                      let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 440, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else { return nil }
                return NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
            }.value
            if let result { thumbnail = NSImage(data: result) }
        }
    }
}

struct ContentView: View {
    @ObservedObject var model: HarborModel
    @ObservedObject var updates: UpdateCoordinator
    var body: some View {
        NavigationSplitView {
            List {
                Section("系统采集") {
                    Label(model.state, systemImage: model.systemCapturing ? "record.circle" : "network")
                    HStack { Text("端口"); Spacer(); TextField("8877", text: $model.port).frame(width: 62).disabled(model.active || model.starting || model.connecting || model.restoring) }
                    Button(model.restoring ? "正在恢复…" : (model.needsRecovery ? "恢复原代理设置" : (model.systemCapturing || model.connecting ? "停止采集" : "开始采集"))) {
                        if model.systemCapturing || model.connecting { model.stop() } else { model.startCapture() }
                    }.disabled(model.restoring || model.starting || model.updateInstalling || model.pendingUpdateInstallation != nil)
                }
                Section("导出") {
                    Picker("整理方式", selection: $model.mode) { ForEach(ExportMode.allCases) { Text($0.rawValue).tag($0) } }
                    Button(model.exporting ? "正在导出…" : "导出全部图片") { model.export() }.disabled(model.images.isEmpty || model.exporting)
                }
                Section("设置") {
                    Button("检查更新…") { updates.checkForUpdates() }
                    Button("HTTPS 证书设置") { model.showHelp = true }
                    Button("查看日志") { NSWorkspace.shared.open(model.root.appendingPathComponent("proxy.log")) }
                    Button("清空记录") { model.clear() }.disabled(model.active || model.starting || model.exporting || model.images.isEmpty)
                }
            }.listStyle(.sidebar).navigationSplitViewColumnWidth(min: 230, ideal: 260, max: 290)
        } detail: {
            VStack(spacing: 0) {
                if model.images.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "photo.on.rectangle").font(.system(size: 42)).foregroundStyle(.secondary)
                        Text("尚未采集图片").font(.title3.bold())
                        Text("开始采集后，直接使用现有浏览器和应用。\n经过系统代理的图片会显示在这里。").multilineTextAlignment(.center).foregroundStyle(.secondary)
                        Button("设置 HTTPS 证书") { model.showHelp = true }
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 14)], spacing: 14) {
                            ForEach(model.visible) { item in
                                VStack(alignment: .leading, spacing: 5) {
                                    Thumb(url: model.root.appendingPathComponent("images/\(item.file)")).frame(height: 130)
                                    Text(item.title).font(.callout).lineLimit(1)
                                    Text("\(item.format.uppercased()) · \(item.host)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }.contentShape(Rectangle()).onTapGesture { model.selected = item }
                                .contextMenu {
                                    Button("复制来源地址") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(item.url, forType: .string) }
                                    Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([model.root.appendingPathComponent("images/\(item.file)")]) }
                                }
                            }
                        }.padding(20)
                        if model.visible.isEmpty { Text("没有匹配的图片").foregroundStyle(.secondary).padding() }
                    }
                }
                Divider()
                HStack { Text("\(model.images.count) 张图片 · \(model.totalSize)"); Spacer(); Text("系统 HTTP / HTTPS 代理") }.font(.caption).foregroundStyle(.secondary).padding(12)
            }.navigationTitle("图片")
            .searchable(text: $model.query, prompt: "搜索地址或格式")
            .toolbar {
                ToolbarItem { Button { model.export() } label: { Label("导出全部", systemImage: "square.and.arrow.up") }.disabled(model.images.isEmpty || model.exporting) }
            }
        }.frame(minWidth: 900, minHeight: 620)
        .sheet(isPresented: $model.showHelp) { HelpView(model: model) }
        .sheet(item: $model.selected) { item in
            VStack(alignment: .leading, spacing: 16) {
                HStack { Text(item.title).font(.headline); Spacer(); Button("完成") { model.selected = nil } }
                Thumb(url: model.root.appendingPathComponent("images/\(item.file)")).frame(height: 300)
                Text(item.url).font(.caption).textSelection(.enabled)
                Text("\(item.format.uppercased()) · \(item.size) 字节 · HTTP \(item.status)").foregroundStyle(.secondary)
                if item.partial { Text("此记录是 HTTP 206 分段响应，可能不是完整图片。").foregroundStyle(.orange) }
                Button("打开原图") { NSWorkspace.shared.open(model.root.appendingPathComponent("images/\(item.file)")) }
            }.padding(24).frame(width: 600)
        }
        .alert("Image Harbor", isPresented: Binding(get: { !model.message.isEmpty }, set: { if !$0 { model.message = "" } })) { Button("好") { model.message = "" } } message: { Text(model.message) }
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: HarborModel?
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        if model.proxyAgent != nil || model.needsRecovery {
            model.quitPending = true; Task { @MainActor in model.stop() }; return .terminateLater
        }
        model.stopEngine(); return .terminateNow
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main struct ImageHarborApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject var model = HarborModel()
    @StateObject var updates = UpdateCoordinator()
    var body: some Scene {
        WindowGroup { ContentView(model: model, updates: updates).onAppear { delegate.model = model; updates.connect(to: model); NSApp.activate(ignoringOtherApps: true); if CommandLine.arguments.contains("--certificate-guide") { model.showHelp = true } } }
            .defaultSize(width: 1160, height: 760)
            .commands {
                CommandGroup(replacing: .newItem) { }
                CommandGroup(after: .appInfo) { Button("检查更新…") { updates.checkForUpdates() } }
            }
    }
}
