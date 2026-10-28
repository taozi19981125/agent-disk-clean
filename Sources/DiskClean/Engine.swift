import Foundation

struct Item: Identifiable {
    var id: String { path }
    let path: String
    let size: Int64
}

struct ScanResult: Identifiable {
    var id: String { category.id }
    let category: Category
    var items: [Item] = []
    var notes: [String] = []
    var commandEstimate: Int64? = nil
    var toolPath: String? = nil
    var total: Int64 { commandEstimate ?? items.reduce(0) { $0 + $1.size } }
    var cleanable: Bool { category.risk != .report && (toolPath != nil || !items.isEmpty) }
}

struct CleanReport {
    var freed: Int64 = 0
    var removed = 0
    var failures: [String] = []
    var log: [String] = []
}

final class Engine {
    let rules: Rules
    let guardian: Guard
    let fm = FileManager.default

    init(rules: Rules) {
        self.rules = rules
        self.guardian = Guard(rules: rules)
    }

    // MARK: 扫描

    func scanAll() -> [ScanResult] {
        var out = [ScanResult?](repeating: nil, count: rules.categories.count)
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: rules.categories.count) { i in
            let r = scan(rules.categories[i])
            lock.lock(); out[i] = r; lock.unlock()
        }
        return out.compactMap { $0 }
    }

    func scan(_ cat: Category) -> ScanResult {
        var res = ScanResult(category: cat)
        if cat.action == .command { return scanCommand(cat, res) }
        let cutoff = cat.minAgeDays.map { Date().addingTimeInterval(-$0 * 86400) }
        let kept = guardian.keptTargets(cat)
        for root in (cat.paths ?? []).map(expand) {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: root, isDirectory: &isDir), isDir.boolValue else { continue }
            guard fm.isReadableFile(atPath: root), (try? fm.contentsOfDirectory(atPath: root)) != nil else {
                res.notes.append("无法读取 \(root)：可能需要在「系统设置 → 隐私与安全性 → 完全磁盘访问权限」里允许")
                continue
            }
            var found: [(path: String, date: Date)] = []
            for path in entries(root, depth: cat.depth ?? 1) {
                let name = (path as NSString).lastPathComponent
                if name == ".DS_Store" || name == ".localized" { continue }
                if (cat.exclude ?? []).contains(where: { glob($0, name) }) { continue }
                if let m = cat.match, !m.contains(where: { glob($0, name) }) { continue }
                let date = modDate(path) ?? .distantPast
                if let cutoff, date > cutoff { continue }
                if kept.contains(URL(fileURLWithPath: path).resolvingSymlinksInPath().path) { continue }
                found.append((path, date))
            }
            // 保留最新的几项
            found.sort { $0.date > $1.date }
            for f in found.dropFirst(cat.keepNewest ?? 0) {
                // 可清理的分类在扫描阶段就过一遍禁区检查，被拒的不出现在列表里
                if cat.risk != .report, guardian.refusal(f.path, in: cat) != nil { continue }
                res.items.append(Item(path: f.path, size: allocatedSize(f.path)))
            }
        }
        res.items.sort { $0.size > $1.size }
        return res
    }

    private func scanCommand(_ cat: Category, _ r: ScanResult) -> ScanResult {
        var res = r
        guard let spec = cat.command, let tool = spec.tools.first(where: { fm.isExecutableFile(atPath: $0) }) else {
            res.notes.append("没有安装对应工具，跳过")
            return res
        }
        res.toolPath = tool
        // brew 支持 -n 预演，从输出里读出能释放多少
        if (tool as NSString).lastPathComponent == "brew" {
            let out = run(tool, spec.args + ["-n"])
            res.commandEstimate = parseBrewEstimate(out) ?? 0
        }
        return res
    }

    func parseBrewEstimate(_ s: String) -> Int64? {
        let re = try! NSRegularExpression(pattern: #"approximately ([\d.]+)\s*([KMGT]?B)"#)
        guard let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
              let r1 = Range(m.range(at: 1), in: s), let r2 = Range(m.range(at: 2), in: s),
              let v = Double(s[r1]) else { return nil }
        let mult: Double = ["B": 1, "KB": 1e3, "MB": 1e6, "GB": 1e9, "TB": 1e12][String(s[r2])] ?? 1
        return Int64(v * mult)
    }

    // MARK: 清理

    func clean(_ results: [ScanResult], dryRun: Bool = false) -> CleanReport {
        var rep = CleanReport()
        for res in results {
            let cat = res.category
            guard cat.risk != .report else { rep.failures.append("\(cat.name)：只报告，不清理"); continue }
            if cat.action == .command {
                guard let tool = res.toolPath, let spec = cat.command else { continue }
                let line = "\(tool) \(spec.args.joined(separator: " "))"
                if dryRun { rep.log.append("[预演] 运行 \(line)"); rep.freed += res.total; continue }
                _ = run(tool, spec.args)
                rep.log.append("运行 \(line)")
                rep.freed += res.total
                continue
            }
            for item in res.items {
                if let why = guardian.refusal(item.path, in: cat) {
                    rep.failures.append("拒绝 \(item.path)：\(why)")
                    continue
                }
                let verb = cat.action == .trash ? "移到废纸篓" : "删除"
                if dryRun { rep.log.append("[预演] \(verb) \(item.path)"); rep.freed += item.size; rep.removed += 1; continue }
                do {
                    if cat.action == .trash {
                        try fm.trashItem(at: URL(fileURLWithPath: item.path), resultingItemURL: nil)
                    } else {
                        try fm.removeItem(atPath: item.path)
                    }
                    rep.freed += item.size
                    rep.removed += 1
                    rep.log.append("\(verb) \(item.path)（\(fmtSize(item.size))）")
                } catch {
                    // 应用正在用的文件可能删不掉，跳过即可
                    rep.failures.append("\(item.path)：\(error.localizedDescription)")
                }
            }
        }
        if !dryRun {
            writeLog(rep)
            let names = results.filter { $0.total > 0 || $0.toolPath != nil }.map(\.category.name)
            if rep.removed > 0 || rep.freed > 0 {
                Activity.record(Activity.Entry(at: Date(), actor: Actor.current, what: names, freed: rep.freed, removed: rep.removed, skipped: rep.failures.count, details: rep.log))
            }
        }
        return rep
    }

    private func writeLog(_ rep: CleanReport) {
        let dir = home + "/Library/Logs/DiskClean"
        try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let path = dir + "/clean.log"
        let f = ISO8601DateFormatter(); f.timeZone = .current
        var text = "== \(f.string(from: Date())) 释放 \(fmtSize(rep.freed))，\(rep.removed) 项 ==\n"
        text += (rep.log + rep.failures.map { "失败 " + $0 }).joined(separator: "\n") + "\n"
        if let h = FileHandle(forWritingAtPath: path) {
            h.seekToEndOfFile(); h.write(text.data(using: .utf8)!); try? h.close()
        } else {
            try? text.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }

    // MARK: 工具

    /// root 下第 depth 层的条目（不跟随软链接）
    func entries(_ root: String, depth: Int) -> [String] {
        guard let names = try? fm.contentsOfDirectory(atPath: root) else { return [] }
        let paths = names.map { root + "/" + $0 }
        if depth <= 1 { return paths }
        return paths.flatMap { p -> [String] in
            let v = try? URL(fileURLWithPath: p).resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard v?.isDirectory == true, v?.isSymbolicLink != true else { return [] }
            return entries(p, depth: depth - 1)
        }
    }

    func modDate(_ path: String) -> Date? {
        (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    func allocatedSize(_ path: String) -> Int64 { Self.sizer(path) }

    /// 文件或文件夹实际占用的磁盘空间（不跟随软链接）
    static func sizer(_ path: String) -> Int64 {
        let fm = FileManager.default
        let url = URL(fileURLWithPath: path)
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .isDirectoryKey, .isSymbolicLinkKey]
        guard let v = try? url.resourceValues(forKeys: keys) else { return 0 }
        if v.isSymbolicLink == true || v.isDirectory != true { return Int64(v.totalFileAllocatedSize ?? 0) }
        var total: Int64 = 0
        let e = fm.enumerator(at: url, includingPropertiesForKeys: Array(keys), options: [], errorHandler: { _, _ in true })
        while let u = e?.nextObject() as? URL {
            total += Int64((try? u.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?.totalFileAllocatedSize ?? 0)
        }
        return total
    }

    func run(_ tool: String, _ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["HOMEBREW_NO_AUTO_UPDATE"] = "1"
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        p.environment = env
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}

private let sizeFormatter: ByteCountFormatter = {
    let f = ByteCountFormatter()
    f.countStyle = .file
    f.allowsNonnumericFormatting = false
    return f
}()

func fmtSize(_ b: Int64) -> String { b == 0 ? "0 KB" : sizeFormatter.string(fromByteCount: b) }

struct DiskSpace {
    let total: Int64
    let free: Int64
    static func current() -> DiskSpace? {
        let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]
        guard let v = try? URL(fileURLWithPath: "/").resourceValues(forKeys: keys),
              let t = v.volumeTotalCapacity, let f = v.volumeAvailableCapacityForImportantUsage else { return nil }
        return DiskSpace(total: Int64(t), free: f)
    }
}
