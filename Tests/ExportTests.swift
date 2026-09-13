import Foundation

@main struct ExportTests {
    static func main() throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }
        let source = tmp.appendingPathComponent("source")
        try fm.createDirectory(at: source, withIntermediateDirectories: true)
        let urls = ["https://a.example/assets/logo.png?v=1", "https://a.example/assets/logo.png?v=2", "https://b.example/%2E%2E/%2F/logo.png", "https://a.example:443/logo.png"]
        var items: [CapturedImage] = []
        for (index, url) in urls.enumerated() {
            let id = UUID().uuidString
            let file = id + ".png"
            try Data("image-\(index)".utf8).write(to: source.appendingPathComponent(file))
            items.append(CapturedImage(id: id, url: url, host: URL(string: url)!.host!, format: "png", mime: "image/png", size: 7, timestamp: 0, file: file, sha256: "test", status: 200, partial: false))
        }
        for mode in ExportMode.allCases {
            let folder = try ImageExporter.export(items, source: source, destination: tmp, mode: mode)
            let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("manifest.json"))) as! [[String: Any]]
            assert(manifest.count == items.count)
            for (i, item) in items.enumerated() {
                let relative = ImageExporter.relativePath(item, mode: mode)
                let path = folder.appendingPathComponent(relative).standardizedFileURL
                assert(path.path.hasPrefix(folder.path + "/"))
                let data = try Data(contentsOf: path)
                assert(data == Data("image-\(i)".utf8))
                switch mode {
                case .flat: assert(!relative.contains("/"))
                case .format: assert(relative.hasPrefix("PNG/"))
                case .address: assert(relative.hasPrefix(item.host))
                }
            }
        }
        let before = try fm.contentsOfDirectory(atPath: tmp.path).count
        do {
            _ = try ImageExporter.export(items, source: tmp.appendingPathComponent("missing"), destination: tmp, mode: .flat)
            fatalError("Missing source must fail")
        } catch { }
        let after = try fm.contentsOfDirectory(atPath: tmp.path).count
        assert(after == before)
        print("PASS: three export layouts, query collisions, domain grouping, traversal sanitization, byte preservation, manifest, failed-export cleanup")
    }
}
