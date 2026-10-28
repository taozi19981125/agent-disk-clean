import Foundation

/// 谁在清理：阿扫 app、某个 agent（经 MCP 或命令行），还是用户自己敲的命令
enum Actor {
    /// 打开窗口时设成 true
    static var isApp = false

    static var current: String {
        if isApp { return "你（阿扫 app）" }
        let env = ProcessInfo.processInfo.environment
        // MCP 服务启动子命令时，把 agent 报上来的名字放在这里
        if let c = env["ASAO_ACTOR"], !c.isEmpty { return pretty(c) + "（MCP）" }
        if env["CLAUDECODE"] == "1" { return "Claude Code（命令行）" }
        if let a = ancestorAgent() { return a + "（命令行）" }
        return "命令行"
    }

    static func pretty(_ raw: String) -> String {
        let s = raw.lowercased()
        let known: [(String, String)] = [("claude", "Claude Code"), ("codex", "Codex"), ("cursor", "Cursor"), ("gemini", "Gemini CLI"), ("windsurf", "Windsurf"), ("cline", "Cline")]
        return known.first { s.contains($0.0) }?.1 ?? raw
    }

    /// 往上找几层父进程，看是不是从某个 agent 里运行的
    static func ancestorAgent() -> String? {
        var pid = getppid()
        for _ in 0..<6 where pid > 1 {
            let (_, out) = Connect.shell("/bin/ps", ["-o", "ppid=,comm=", "-p", String(pid)])
            let parts = out.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ", maxSplits: 1).map(String.init)
            guard parts.count == 2, let parent = Int32(parts[0]) else { return nil }
            let name = pretty((parts[1] as NSString).lastPathComponent)
            if name != (parts[1] as NSString).lastPathComponent { return name }
            pid = parent
        }
        return nil
    }
}

/// 操作记录：谁、什么时候、清了什么、释放了多少。放在 ~/.config 里（受保护，不会被「旧日志」清掉）
enum Activity {
    struct Entry: Codable, Identifiable {
        var id: String { "\(at.timeIntervalSince1970)-\(actor)" }
        let at: Date
        let actor: String
        let what: [String]
        let freed: Int64
        let removed: Int
        let skipped: Int
        let details: [String]
    }

    static let path = "~/.config/agent-disk-clean/activity.jsonl"
    static let maxDetails = 200

    static func record(_ e: Entry) {
        let p = expand(path)
        try? FileManager.default.createDirectory(atPath: (p as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        var trimmed = e
        if e.details.count > maxDetails { trimmed = Entry(at: e.at, actor: e.actor, what: e.what, freed: e.freed, removed: e.removed, skipped: e.skipped, details: Array(e.details.prefix(maxDetails)) + ["……还有 \(e.details.count - maxDetails) 项"]) }
        guard var line = try? enc.encode(trimmed) else { return }
        line.append(0x0A)
        if let h = FileHandle(forWritingAtPath: p) {
            h.seekToEndOfFile(); h.write(line); try? h.close()
        } else {
            try? line.write(to: URL(fileURLWithPath: p))
        }
    }

    /// 最新的在前
    static func load(limit: Int = 200) -> [Entry] {
        guard let text = try? String(contentsOfFile: expand(path), encoding: .utf8) else { return [] }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return text.split(separator: "\n").suffix(limit).compactMap { try? dec.decode(Entry.self, from: Data($0.utf8)) }.reversed()
    }

    static func printAll() {
        let f = DateFormatter(); f.dateFormat = "MM-dd HH:mm"
        let all = load()
        if all.isEmpty { print("还没有清理记录"); return }
        for e in all {
            print("\(f.string(from: e.at))  \(e.actor)  释放 \(fmtSize(e.freed))  \(e.what.joined(separator: "、"))\(e.skipped > 0 ? "（跳过 \(e.skipped) 项）" : "")")
        }
    }
}
