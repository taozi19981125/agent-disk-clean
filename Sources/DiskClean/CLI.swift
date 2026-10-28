import Foundation

/// 命令行模式，给 agent 用。所有删除都经过 Guard。
enum CLI {
    static let usage = """
    阿扫 命令行（给 agent 用）

      diskclean auto [--dry-run]               一条命令搞定：清掉所有 safe 项，输出三行总结

      DiskClean scan [--json] [--details]      扫描，列出每个分类能释放多少空间
      DiskClean clean <分类id...> [--dry-run]  清理指定分类（先用 --dry-run 预演）
      DiskClean clean --safe [--dry-run]       清理所有 safe 分类
          review 分类必须加 --user-approved，且只能在用户明确同意后加
          report 分类永远不能清理
      DiskClean check <路径...>                检查某个路径能不能删
      DiskClean rules                          打印规则文件和 agent 守则的位置
      diskclean ai [--json]                    各 AI 工具、本地模型占多少，最近 7 天涨得最快的文件夹
      diskclean history                        清理记录：谁、什么时候、清了什么

      diskclean connect [claude|codex|cursor|gemini|claude_desktop|windsurf|all]
                                               把阿扫接入这些 agent（MCP）；不带参数看手动配置方法
      diskclean watch --on [--gb 20]           空间不足提醒：可用空间低于 20 GB 时发系统通知（--off 关闭，--status 查看）
      diskclean mcp                            以 MCP 服务运行（由 agent 启动，不用手动运行）

    退出码：0 成功，1 出错，2 被安全规则拒绝
    """

    static func run(_ args: [String]) -> Int32 {
        let rules: Rules
        do { rules = try Rules.load() } catch { fputs("读取规则失败：\(error.localizedDescription)\n", stderr); return 1 }
        let engine = Engine(rules: rules)
        let flags = Set(args.filter { $0.hasPrefix("--") })
        let rest = Array(args.dropFirst().filter { !$0.hasPrefix("--") })

        switch args.first {
        case "auto":
            return auto(engine, dryRun: flags.contains("--dry-run"))

        case "scan":
            let results = engine.scanAll()
            if flags.contains("--json") { printJSON(results, details: flags.contains("--details")) }
            else { printTable(results, details: flags.contains("--details")) }
            return 0

        case "clean":
            var ids = rest
            if flags.contains("--safe") { ids += rules.categories.filter { $0.risk == .safe }.map(\.id) }
            guard !ids.isEmpty else { print(usage); return 1 }
            var cats: [Category] = []
            for id in ids {
                guard let c = rules.categories.first(where: { $0.id == id }) else { fputs("没有这个分类：\(id)\n", stderr); return 1 }
                if c.risk == .report { fputs("拒绝：\(id) 是只报告的分类，不能清理。请让用户自己处理。\n", stderr); return 2 }
                if c.risk == .review && !flags.contains("--user-approved") {
                    fputs("拒绝：\(id) 需要用户确认。先把大小和内容告诉用户，用户同意后再加 --user-approved。\n", stderr); return 2
                }
                cats.append(c)
            }
            let dry = flags.contains("--dry-run")
            let before = DiskSpace.current()?.free
            let rep = engine.clean(cats.map(engine.scan), dryRun: dry)
            rep.log.forEach { print($0) }
            rep.failures.forEach { print("跳过 " + $0) }
            print(dry ? "预演：可释放约 \(fmtSize(rep.freed))，\(rep.removed) 项" : "完成：释放约 \(fmtSize(rep.freed))，\(rep.removed) 项，跳过 \(rep.failures.count) 项")
            if !dry, let before, let after = DiskSpace.current()?.free {
                print("可用空间：\(fmtSize(before)) → \(fmtSize(after))")
            }
            return 0

        case "check":
            guard !rest.isEmpty else { print(usage); return 1 }
            var code: Int32 = 0
            for p in rest {
                switch engine.guardian.verdict(p) {
                case .cleanable(let c):
                    print("可清理  \(p)\n        属于「\(c.name)」(\(c.id), \(c.risk.rawValue))\(c.risk == .review ? "，需要用户确认" : "")")
                case .reportOnly(let c):
                    print("只报告  \(p)\n        属于「\(c.name)」：\(c.description)"); code = 2
                case .protected(let why):
                    print("禁止    \(p)\n        \(why)"); code = 2
                case .unknown:
                    print("未知    \(p)\n        不在任何清理规则里，不要删。确实要删请先问用户。"); code = 2
                }
            }
            return code

        case "ai":
            printAI(json: flags.contains("--json"))
            return 0

        case "history":
            Activity.printAll()
            return 0

        case "rules":
            print("规则文件：\(Rules.resourceURL(Rules.fileName)?.path ?? "未找到")")
            print("agent 守则：\(Rules.resourceURL("AGENT_RULES.md")?.path ?? "未找到")")
            print("你自己的禁区：\(expand(Rules.extraProtectedPath))（只能增加禁区，不能放宽规则）")
            return 0

        default:
            print(usage)
            return args.first == "help" || args.first == "--help" ? 0 : 1
        }
    }

    /// 扫描 + 清理 safe 项 + 三行总结。review / report 只列出来，交给用户决定。
    static func auto(_ engine: Engine, dryRun: Bool) -> Int32 {
        let before = DiskSpace.current()?.free
        let results = engine.scanAll()
        let safe = results.filter { $0.category.risk == .safe && $0.cleanable && $0.total > 0 }
        let rep = engine.clean(safe, dryRun: dryRun)
        func list(_ rs: [ScanResult]) -> String {
            rs.filter { $0.total > 0 }.sorted { $0.total > $1.total }
                .map { "\($0.category.name) \(fmtSize($0.total))" }.joined(separator: "、")
        }
        func sum(_ rs: [ScanResult]) -> Int64 { rs.reduce(0) { $0 + $1.total } }

        var line = (dryRun ? "预演：可清理 " : "已清理 ") + fmtSize(rep.freed)
        if !safe.isEmpty { line += "（\(list(safe))）" }
        if !dryRun, let before, let after = DiskSpace.current()?.free { line += "，可用空间 \(fmtSize(before)) → \(fmtSize(after))" }
        print(line)

        let review = results.filter { $0.category.risk == .review && $0.total > 0 }
        if !review.isEmpty {
            print("需要你点头的 \(fmtSize(sum(review)))：\(list(review))")
            print("  同意哪项就运行：diskclean clean \(review.map(\.category.id).joined(separator: " ")) --user-approved（只保留同意的 id）")
        }
        let report = results.filter { $0.category.risk == .report && $0.total > 0 }
        if !report.isEmpty { print("只提醒、不会删的 \(fmtSize(sum(report)))：\(list(report))") }
        if !rep.failures.isEmpty { print("有 \(rep.failures.count) 项正在使用或没权限，已跳过（详见 ~/Library/Logs/DiskClean/clean.log）") }
        return 0
    }

    static func printAI(json: Bool) {
        let usage = AIUsage.scan()
        let models = ModelStore.scan()
        let growth = Growth.top()
        if json {
            let root: [String: Any] = [
                "tools": usage.map { ["id": $0.group.id, "name": $0.group.name, "bytes": $0.total, "size": fmtSize($0.total), "paths": $0.parts.map { ["path": $0.path, "bytes": $0.size] }] },
                "models": models.map { ["name": $0.name, "source": $0.source.rawValue, "bytes": $0.size, "size": fmtSize($0.size), "path": $0.path] },
                "growth": growth.map { ["path": $0.path, "name": $0.name, "deltaBytes": $0.delta, "delta": fmtSize($0.delta), "days": $0.days] },
                "note": "本地模型只能由用户在阿扫 app 里删除，agent 不能删。",
            ]
            let data = try! JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
            print(String(decoding: data, as: UTF8.self)); return
        }
        print("AI 工具共占 \(fmtSize(usage.reduce(0) { $0 + $1.total }))")
        for u in usage { print("  \(fmtSize(u.total).padding(toLength: 10, withPad: " ", startingAt: 0)) \(u.group.name)") }
        if !models.isEmpty {
            print("\n本地模型（只能由用户在阿扫 app 里删除）")
            for m in models { print("  \(fmtSize(m.size).padding(toLength: 10, withPad: " ", startingAt: 0)) \(m.name)  [\(m.source.rawValue)]") }
        }
        print("")
        if growth.isEmpty { print("涨得最快：阿扫每天记一次大小，记满两天后才能比较") }
        else {
            print("最近 \(growth[0].days) 天涨得最快")
            for g in growth { print("  +\(fmtSize(g.delta).padding(toLength: 10, withPad: " ", startingAt: 0)) \(g.name)") }
        }
    }

    static func printTable(_ results: [ScanResult], details: Bool) {
        if let d = DiskSpace.current() { print("磁盘：可用 \(fmtSize(d.free)) / 共 \(fmtSize(d.total))\n") }
        let label: [Risk: String] = [.safe: "可直接清理", .review: "需用户确认", .report: "只报告"]
        for risk in [Risk.safe, .review, .report] {
            let group = results.filter { $0.category.risk == risk }
            print("【\(label[risk]!)】合计 \(fmtSize(group.reduce(0) { $0 + $1.total }))")
            for r in group {
                let size = r.category.action == .command && r.toolPath == nil ? "未安装" : fmtSize(r.total)
                print("  \(r.category.id.padding(toLength: 22, withPad: " ", startingAt: 0)) \(size.padding(toLength: 10, withPad: " ", startingAt: 0)) \(r.category.name)")
                r.notes.forEach { print("      ⚠️ \($0)") }
                if details { r.items.prefix(10).forEach { print("      \(fmtSize($0.size).padding(toLength: 10, withPad: " ", startingAt: 0)) \($0.path)") } }
            }
            print("")
        }
    }

    static func printJSON(_ results: [ScanResult], details: Bool) {
        var cats: [[String: Any]] = []
        for r in results {
            var c: [String: Any] = [
                "id": r.category.id, "name": r.category.name, "risk": r.category.risk.rawValue,
                "action": r.category.action?.rawValue ?? "none", "bytes": r.total, "size": fmtSize(r.total),
                "itemCount": r.items.count, "description": r.category.description, "notes": r.notes,
            ]
            if details { c["items"] = r.items.prefix(20).map { ["path": $0.path, "bytes": $0.size] } }
            cats.append(c)
        }
        var root: [String: Any] = ["categories": cats]
        if let d = DiskSpace.current() { root["disk"] = ["totalBytes": d.total, "freeBytes": d.free] }
        let data = try! JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    }
}
