import Foundation

struct CapturedImage: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let url: String
    let host: String
    let format: String
    let mime: String
    let size: Int
    let timestamp: Double
    let file: String
    let sha256: String
    let status: Int
    let partial: Bool
    var title: String { URL(string: url)?.lastPathComponent.removingPercentEncoding.flatMap { $0.isEmpty ? nil : $0 } ?? "image" }
}

enum ExportMode: String, CaseIterable, Identifiable, Sendable {
    case address = "按地址", format = "按文件格式", flat = "同一个文件夹"
    var id: String { rawValue }
    var hint: String {
        switch self {
        case .address: return "域名 / 原始路径 / 图片；保留来源结构"
        case .format: return "PNG / JPG / WEBP 等格式分别存放"
        case .flat: return "全部图片放在一个文件夹，自动避免重名"
        }
    }
}

enum ImageExporter {
    static func safe(_ value: String) -> String {
        let filtered = value.unicodeScalars.map { scalar -> String in
            if CharacterSet.alphanumerics.contains(scalar) || "-_.".unicodeScalars.contains(scalar) { return String(scalar) }
            return "_"
        }.joined()
        let s = String(filtered.prefix(70)).trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return s.isEmpty ? "_" : s
    }
    static func relativePath(_ item: CapturedImage, mode: ExportMode) -> String {
        let u = URL(string: item.url)
        let stem = safe((item.title as NSString).deletingPathExtension)
        let name = "\(stem)-\(item.id).\(safe(item.format))"
        switch mode {
        case .flat: return name
        case .format: return "\(safe(item.format).uppercased())/\(name)"
        case .address:
            let parts = (u?.pathComponents ?? []).dropLast().filter { $0 != "/" }.prefix(12).map(safe)
            let authority = item.host + (u?.port.map { "_\($0)" } ?? "")
            return ([safe(authority)] + parts + [name]).joined(separator: "/")
        }
    }
    static func export(_ items: [CapturedImage], source: URL, destination: URL, mode: ExportMode) throws -> URL {
        let fm = FileManager.default
        let folder = destination.appendingPathComponent("ImageHarbor-" + ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-") + "-" + UUID().uuidString.prefix(6))
        try fm.createDirectory(at: folder, withIntermediateDirectories: false)
        do {
            var manifest: [[String: Any]] = []
            for item in items {
                let relative = relativePath(item, mode: mode)
                let dest = folder.appendingPathComponent(relative)
                try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.copyItem(at: source.appendingPathComponent(item.file), to: dest)
                manifest.append(["url": item.url, "file": relative, "sha256": item.sha256, "size": item.size,
                                 "mime": item.mime, "timestamp": item.timestamp, "partial": item.partial, "status": item.status])
            }
            try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]).write(to: folder.appendingPathComponent("manifest.json"), options: .atomic)
            return folder
        } catch {
            try? fm.removeItem(at: folder)
            throw error
        }
    }
}
