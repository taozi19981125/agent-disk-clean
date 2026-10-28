import Foundation

// MARK: AI 工具各占多少

/// 一个 AI 工具占的空间：可能分散在好几个文件夹里
struct AIGroup: Identifiable {
    let id: String
    let name: String
    let note: String
    let paths: [String]
}

struct AIUsageEntry: Identifiable {
    var id: String { group.id }
    let group: AIGroup
    let parts: [(path: String, size: Int64)]
    var total: Int64 { parts.reduce(0) { $0 + $1.size } }
}

enum AIUsage {
    static let groups: [AIGroup] = [
        AIGroup(id: "claude_code", name: "Claude Code", note: "对话记录、设置、技能、程序版本", paths: ["~/.claude", "~/.local/share/claude", "~/Library/Caches/claude-cli-nodejs"]),
        AIGroup(id: "claude_app", name: "Claude 桌面版", note: "应用数据和缓存", paths: ["~/Library/Application Support/Claude", "~/Library/Caches/com.anthropic.claudefordesktop"]),
        AIGroup(id: "codex", name: "Codex", note: "对话记录、运行时、生成的图片", paths: ["~/.codex", "~/Library/Application Support/Codex"]),
        AIGroup(id: "chatgpt", name: "ChatGPT 桌面版", note: "应用数据和缓存", paths: ["~/Library/Application Support/com.openai.chat", "~/Library/Caches/com.openai.chat"]),
        AIGroup(id: "cursor", name: "Cursor", note: "扩展、设置、工作区缓存", paths: ["~/.cursor", "~/Library/Application Support/Cursor"]),
        AIGroup(id: "gemini", name: "Gemini CLI", note: "对话和设置", paths: ["~/.gemini"]),
        AIGroup(id: "windsurf", name: "Windsurf", note: "扩展和设置", paths: ["~/.codeium", "~/Library/Application Support/Windsurf"]),
        AIGroup(id: "models", name: "本地模型", note: "Ollama、HuggingFace、LM Studio、Whisper 下载的模型", paths: ModelStore.roots.map(\.path) + ["~/.cache/huggingface/xet"]),
        AIGroup(id: "browsers", name: "agent 用的浏览器", note: "Playwright、Puppeteer 下载的自动化浏览器", paths: ["~/Library/Caches/ms-playwright", "~/.cache/ms-playwright", "~/.cache/puppeteer"]),
    ]

    /// 只统计存在的文件夹；没装的工具不出现
    static func scan() -> [AIUsageEntry] {
        let sizer: (String) -> Int64 = Engine.sizer
        var out = [AIUsageEntry?](repeating: nil, count: groups.count)
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: groups.count) { i in
            let g = groups[i]
            let parts = g.paths.map(expand).filter { FileManager.default.fileExists(atPath: $0) }.map { ($0, sizer($0)) }.filter { $0.1 > 0 }
            lock.lock(); out[i] = parts.isEmpty ? nil : AIUsageEntry(group: g, parts: parts); lock.unlock()
        }
        return out.compactMap { $0 }.sorted { $0.total > $1.total }
    }

    /// 某个路径属于哪个 AI 工具（给「涨得最快」起名字用）
    static func name(for path: String) -> String? {
        groups.first { g in g.paths.map(expand).contains { isInside(path, $0) } }?.name
    }
}

// MARK: 本地模型管家

struct LocalModel: Identifiable {
    var id: String { path + "|" + name }
    enum Source: String { case ollama = "Ollama", huggingface = "HuggingFace", lmstudio = "LM Studio", whisper = "Whisper" }
    let name: String
    let source: Source
    let path: String
    let size: Int64
    let downloaded: Date?
    /// 文件最后被读取的时间（系统记录的访问时间，只能当参考）
    let lastUsed: Date?
}

enum ModelStore {
    static let roots: [(path: String, source: LocalModel.Source)] = [
        ("~/.ollama/models", .ollama),
        ("~/.cache/huggingface/hub", .huggingface),
        ("~/.lmstudio/models", .lmstudio),
        ("~/.cache/lm-studio/models", .lmstudio),
        ("~/.cache/whisper", .whisper),
    ]

    static func scan() -> [LocalModel] {
        var out: [LocalModel] = []
        for (root, src) in roots {
            let r = expand(root)
            guard FileManager.default.fileExists(atPath: r) else { continue }
            switch src {
            case .ollama: out += ollama(r)
            case .huggingface: out += huggingface(r)
            case .lmstudio: out += lmstudio(r)
            case .whisper: out += whisper(r)
            }
        }
        return out.sorted { $0.size > $1.size }
    }

    static func ollama(_ root: String) -> [LocalModel] {
        // manifests/<主机>/<命名空间>/<模型>/<标签>，每个文件里列着它用到的层和大小
        let man = root + "/manifests"
        var out: [LocalModel] = []
        let e = FileManager.default.enumerator(atPath: man)
        while let rel = e?.nextObject() as? String {
            let p = man + "/" + rel
            let parts = rel.split(separator: "/").map(String.init)
            guard parts.count == 4, let data = FileManager.default.contents(atPath: p),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            let layers = (obj["layers"] as? [[String: Any]] ?? []) + [obj["config"] as? [String: Any] ?? [:]]
            let size = layers.reduce(Int64(0)) { $0 + (($1["size"] as? NSNumber)?.int64Value ?? 0) }
            let name = (parts[1] == "library" ? parts[2] : parts[1] + "/" + parts[2]) + ":" + parts[3]
            let date = (try? FileManager.default.attributesOfItem(atPath: p))?[.modificationDate] as? Date
            out.append(LocalModel(name: name, source: .ollama, path: p, size: size, downloaded: date, lastUsed: nil))
        }
        return out
    }

    static func huggingface(_ root: String) -> [LocalModel] {
        entries(root).compactMap { p in
            let n = (p as NSString).lastPathComponent
            guard n.hasPrefix("models--") || n.hasPrefix("datasets--") else { return nil }
            let kind = n.hasPrefix("datasets--") ? "（数据集）" : ""
            let name = n.replacingOccurrences(of: "models--", with: "").replacingOccurrences(of: "datasets--", with: "")
                .replacingOccurrences(of: "--", with: "/") + kind
            let files = realFiles(p)
            let (created, accessed) = dates(p)
            return LocalModel(name: name, source: .huggingface, path: p, size: files.values.reduce(0, +), downloaded: created, lastUsed: accessed)
        }
    }

    /// 模型文件夹里所有文件（顺着软链接找到真正的文件，同一个文件只算一次）。
    /// 新版 HuggingFace 会把大文件放到 hub/blobs 里共用，模型文件夹里只剩软链接
    static func realFiles(_ dir: String) -> [String: Int64] {
        var out: [String: Int64] = [:]
        let e = FileManager.default.enumerator(atPath: dir)
        while let rel = e?.nextObject() as? String {
            let real = URL(fileURLWithPath: dir + "/" + rel).resolvingSymlinksInPath()
            guard let v = try? real.resourceValues(forKeys: [.isRegularFileKey, .totalFileAllocatedSizeKey]), v.isRegularFile == true else { continue }
            out[real.path] = Int64(v.totalFileAllocatedSize ?? 0)
        }
        return out
    }

    static func lmstudio(_ root: String) -> [LocalModel] {
        entries(root).flatMap { pub in entries(pub).map { model((pub as NSString).lastPathComponent + "/" + ($0 as NSString).lastPathComponent, .lmstudio, $0) } }
    }

    static func whisper(_ root: String) -> [LocalModel] {
        entries(root).filter { $0.hasSuffix(".pt") }.map { model("Whisper " + (($0 as NSString).lastPathComponent as NSString).deletingPathExtension, .whisper, $0) }
    }

    static func entries(_ dir: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).filter { !$0.hasPrefix(".") }.map { dir + "/" + $0 }
    }

    static func model(_ name: String, _ src: LocalModel.Source, _ path: String) -> LocalModel {
        let (created, accessed) = dates(path)
        return LocalModel(name: name, source: src, path: path, size: Engine.sizer(path), downloaded: created, lastUsed: accessed)
    }

    /// 最早的修改时间 ≈ 下载时间；最晚的访问时间 ≈ 最后一次用
    static func dates(_ path: String) -> (Date?, Date?) {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .contentAccessDateKey, .isRegularFileKey]
        var first: Date?, last: Date?
        func take(_ u: URL) {
            guard let v = try? u.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { return }
            if let m = v.contentModificationDate, first == nil || m < first! { first = m }
            if let a = v.contentAccessDate, last == nil || a > last! { last = a }
        }
        let url = URL(fileURLWithPath: path)
        take(url)
        let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys)
        while let u = e?.nextObject() as? URL { take(u) }
        return (first, last)
    }

    enum DeleteMode { case trash, permanent }

    /// 只能删扫描出来的模型本身，不接受任意路径。只给 app 里的按钮用，命令行和 MCP 都不提供
    static func delete(_ m: LocalModel, mode: DeleteMode) -> (ok: Bool, message: String) {
        guard scan().contains(where: { $0.id == m.id }) else { return (false, "这个模型已经不在了，刷新一下") }
        if m.source == .ollama {
            guard let tool = Connect.findTool("ollama") else { return (false, "没找到 ollama 命令，请先打开 Ollama") }
            let (code, out) = Connect.shell(tool, ["rm", m.name])
            if code != 0 { return (false, "删除失败：\(out.trimmingCharacters(in: .whitespacesAndNewlines))") }
        } else {
            // HuggingFace：模型文件夹外面、只被这个模型用到的共用文件，一起删掉，否则删了也腾不出空间
            var extra: [String] = []
            if m.source == .huggingface {
                let mine = Set(realFiles(m.path).keys)
                let others = scan().filter { $0.source == .huggingface && $0.id != m.id }.reduce(into: Set<String>()) { $0.formUnion(realFiles($1.path).keys) }
                let hub = (m.path as NSString).deletingLastPathComponent
                extra = mine.filter { !isInside($0, m.path) && isInside($0, hub) && !others.contains($0) }.sorted()
            }
            do {
                for f in extra {
                    for sidecar in [f, f + ".refs", f + ".lock"] where FileManager.default.fileExists(atPath: sidecar) {
                        if mode == .trash { try FileManager.default.trashItem(at: URL(fileURLWithPath: sidecar), resultingItemURL: nil) }
                        else { try FileManager.default.removeItem(atPath: sidecar) }
                    }
                }
                if mode == .trash { try FileManager.default.trashItem(at: URL(fileURLWithPath: m.path), resultingItemURL: nil) }
                else { try FileManager.default.removeItem(atPath: m.path) }
            } catch { return (false, "删除失败：\(error.localizedDescription)") }
        }
        let how = m.source == .ollama ? "用 ollama rm 删除" : mode == .trash ? "移到废纸篓" : "直接删除"
        Activity.record(Activity.Entry(at: Date(), actor: Actor.current, what: ["本地模型 \(m.name)"], freed: m.size, removed: 1, skipped: 0, details: ["\(how) \(m.path)（\(fmtSize(m.size))）"]))
        let tail = m.source != .ollama && mode == .trash ? "。清空废纸篓后才会真正腾出空间" : ""
        return (true, "已\(how)：\(m.name)，\(fmtSize(m.size))\(tail)")
    }
}

// MARK: 涨得最快：每天记一次各文件夹大小

enum Growth {
    struct Snapshot: Codable {
        let day: String
        let sizes: [String: Int64]
    }

    struct Grower: Identifiable {
        var id: String { path }
        let path: String
        let name: String
        let delta: Int64
        let now: Int64
        let days: Int
    }

    static let path = "~/.config/agent-disk-clean/growth.json"
    static let keepDays = 60
    /// 记到第几层文件夹、多大以上才记
    static let maxDepth = 4
    static let minSize: Int64 = 50_000_000

    static func dayString(_ d: Date = Date()) -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.timeZone = .current
        return f.string(from: d)
    }

    static func load() -> [Snapshot] { Watch.load(path, [Snapshot]()) }

    static var recordedToday: Bool { load().last?.day == dayString() }

    /// 用空间占用图的扫描结果记一次（同一天只留最新一次）
    static func record(_ root: SizeNode) {
        var sizes: [String: Int64] = [:]
        func walk(_ n: SizeNode, _ depth: Int) {
            if let p = n.path, n.size >= minSize, isInside(p, home), p != home { sizes[p] = n.size }
            guard depth < maxDepth else { return }
            n.children.forEach { walk($0, depth + 1) }
        }
        if let h = root.children.first(where: { $0.path == home }) ?? (root.path == home ? root : nil) { walk(h, 0) }
        guard !sizes.isEmpty else { return }
        var all = load().filter { $0.day != dayString() }
        all.append(Snapshot(day: dayString(), sizes: sizes))
        Watch.save(Array(all.suffix(keepDays)), path)
    }

    /// 后台（提醒任务里）每天补记一次
    static func recordIfNeeded() {
        guard !recordedToday else { return }
        let node = SizeScanner.scan(URL(fileURLWithPath: home), progress: { _ in })
        record(SizeNode(name: "整个磁盘", path: nil, size: node.size, children: [node]))
    }

    /// 和大约 7 天前比，涨得最多的几个文件夹。只有一天数据时返回空
    static func top(_ n: Int = 6, days: Int = 7) -> [Grower] {
        let all = load()
        guard let now = all.last, all.count >= 2 else { return [] }
        let target = dayString(Date().addingTimeInterval(-Double(days) * 86400))
        let base = all.dropLast().last { $0.day <= target } ?? all.first!
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        let span = max(1, Int(((f.date(from: now.day) ?? Date()).timeIntervalSince(f.date(from: base.day) ?? Date()) / 86400).rounded()))
        var rows = now.sizes.compactMap { p, s -> Grower? in
            let d = s - (base.sizes[p] ?? 0)
            guard d >= 100_000_000 else { return nil }
            return Grower(path: p, name: label(p), delta: d, now: s, days: span)
        }
        // 父文件夹的增长主要来自某个子文件夹时，只显示子文件夹，避免重复
        rows = rows.filter { parent in
            !rows.contains { $0.path != parent.path && isInside($0.path, parent.path) && Double($0.delta) >= Double(parent.delta) * 0.8 }
        }
        return Array(rows.sorted { $0.delta > $1.delta }.prefix(n))
    }

    static func label(_ p: String) -> String {
        let short = p.replacingOccurrences(of: home, with: "~")
        if let tool = AIUsage.name(for: p) { return "\(tool)（\(short)）" }
        return short
    }
}
