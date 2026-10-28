import Foundation

enum Risk: String, Codable { case safe, review, report }
enum Action: String, Codable { case delete, trash, command }

struct ProtectedEntry: Codable { let path: String; let reason: String }

struct CommandSpec: Codable { let tools: [String]; let args: [String] }

struct Category: Codable, Identifiable {
    let id: String
    let name: String
    let risk: Risk
    var action: Action?
    var mode: String?
    var paths: [String]?
    var exclude: [String]?
    var match: [String]?
    var minAgeDays: Double?
    /// 条目在 paths 下第几层（默认 1 = 直接子项）
    var depth: Int?
    /// 按修改时间保留最新的几项
    var keepNewest: Int?
    /// 这些软链接指向的条目永远保留（比如正在用的程序版本）
    var keepTargetsOf: [String]?
    var command: CommandSpec?
    let description: String
    var tip: String?
}

struct Rules: Codable {
    let version: Int
    var protected: [ProtectedEntry]
    let protectedNames: [String]
    let categories: [Category]

    static let fileName = "cleanup-rules.json"

    /// 优先读 App 包里的文件；通过 ~/.local/bin/diskclean 软链接启动时 Bundle.main 指错地方，
    /// 所以先顺着软链接找回真正的 .app；用 swift run 调试时读源码目录里的。
    static func resourceURL(_ name: String) -> URL? {
        let fm = FileManager.default
        let exe = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])).resolvingSymlinksInPath()
        let inApp = exe.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/\(name)")
        if fm.fileExists(atPath: inApp.path) { return inApp }
        let parts = name.split(separator: ".", maxSplits: 1).map(String.init)
        if let u = Bundle.main.url(forResource: parts[0], withExtension: parts.count > 1 ? parts[1] : nil) { return u }
        let src = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../..").standardizedFileURL
        return [src.appendingPathComponent("Resources/\(name)"), src.appendingPathComponent(name)].first { fm.fileExists(atPath: $0.path) }
    }

    static func load() throws -> Rules {
        guard let url = resourceURL(fileName) else {
            throw NSError(domain: "DiskClean", code: 1, userInfo: [NSLocalizedDescriptionKey: "找不到 \(fileName)"])
        }
        var rules = try JSONDecoder().decode(Rules.self, from: Data(contentsOf: url))
        rules.protected += extraProtected()
        return rules
    }

    /// 用户自己的禁区（比如自己的项目文件夹），放在 ~/.config/agent-disk-clean/protected.json。
    /// 这个文件只能增加禁区，不能放宽任何规则。格式：[{"path": "~/Projects", "reason": "我的代码"}]
    static let extraProtectedPath = "~/.config/agent-disk-clean/protected.json"

    static func extraProtected() -> [ProtectedEntry] {
        guard let data = FileManager.default.contents(atPath: expand(extraProtectedPath)) else { return [] }
        guard let list = try? JSONDecoder().decode([ProtectedEntry].self, from: data) else {
            fputs("警告：\(extraProtectedPath) 格式不对，已忽略\n", stderr)
            return []
        }
        return list
    }
}

let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path

func expand(_ p: String) -> String {
    if p == "~" { return home }
    if p.hasPrefix("~/") { return home + String(p.dropFirst(1)) }
    return p
}

func glob(_ pattern: String, _ name: String) -> Bool {
    fnmatch(pattern, name, 0) == 0
}

/// a 等于 b 或在 b 里面
func isInside(_ a: String, _ b: String) -> Bool {
    a == b || a.hasPrefix(b.hasSuffix("/") ? b : b + "/")
}
