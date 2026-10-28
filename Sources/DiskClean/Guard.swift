import Foundation

/// 删除前的最后一道检查。规则文件被改坏了也绕不过这里的硬编码清单。
struct Guard {
    let rules: Rules

    /// 写死在代码里、不受规则文件影响的禁区（相对家目录）
    static let hardProtected = [
        "Documents", "Desktop", "Pictures", "Movies", "Music",
        "Library/Mobile Documents", "Library/CloudStorage", "Library/Keychains",
        "Library/Mail", "Library/Messages", "Library/Application Support",
        "Library/Containers", "Library/Group Containers", "Library/Preferences",
        ".ssh", ".gnupg", ".claude",
    ].map { home + "/" + $0 }

    /// 禁区里唯一允许清理的几处，写死在代码里，规则文件加不了新的
    static let exemptions = [
        ".local/share/claude/versions",
        ".codex/sessions",
    ].map { home + "/" + $0 }

    var protectedPaths: [(path: String, reason: String)] {
        Self.hardProtected.map { ($0, "系统内置禁区") } + rules.protected.map { (expand($0.path), $0.reason) }
    }

    /// 返回 nil 表示允许；否则返回拒绝原因
    func protectionReason(_ path: String, exempt: String? = nil) -> String? {
        let literal = URL(fileURLWithPath: expand(path)).standardizedFileURL.path
        // 父目录解析软链接，条目本身不解析（删软链接只删链接本身）
        let parent = URL(fileURLWithPath: literal).deletingLastPathComponent().resolvingSymlinksInPath().path
        let resolved = parent + "/" + (literal as NSString).lastPathComponent
        for p in [literal, resolved] {
            if p == "/" || p == home || isInside(home, p) { return "家目录或它的上级" }
            for (pp, reason) in protectedPaths where isInside(p, pp) {
                if let ex = exempt, isInside(ex, pp), isInside(p, ex), p != ex { continue }
                return "受保护：\(reason)（\(pp)）"
            }
            for comp in p.split(separator: "/") {
                for n in rules.protectedNames where glob(n, String(comp)) { return "受保护的名称：\(n)" }
            }
        }
        return nil
    }

    /// 判断某个条目能否被这个分类删除
    func refusal(_ path: String, in cat: Category) -> String? {
        guard cat.risk != .report, cat.action == .delete || cat.action == .trash else { return "该分类只报告，不清理" }
        let p = URL(fileURLWithPath: path).standardizedFileURL.path
        guard isInside(p, home), p != home else { return "不在家目录内" }
        let roots = (cat.paths ?? []).map { URL(fileURLWithPath: expand($0)).standardizedFileURL.path }
        // 只允许删分类目录下指定层级的条目，不允许删分类目录本身
        let depth = cat.depth ?? 1
        guard let root = roots.first(where: { isInside(p, $0) && p != $0 }),
              p.dropFirst(root.count + 1).split(separator: "/").count == depth else {
            return "不是 \(cat.id) 允许的位置"
        }
        if keptTargets(cat).contains(URL(fileURLWithPath: p).resolvingSymlinksInPath().path) { return "正在使用，必须保留" }
        return protectionReason(p, exempt: Self.exemptions.first { isInside(root, $0) })
    }

    var keptTargetsAll: Set<String> { rules.categories.reduce(into: Set<String>()) { $0.formUnion(keptTargets($1)) } }

    func keptTargets(_ cat: Category) -> Set<String> {
        Set((cat.keepTargetsOf ?? []).map { URL(fileURLWithPath: expand($0)).resolvingSymlinksInPath().path })
    }

    enum Verdict { case cleanable(Category), reportOnly(Category), protected(String), unknown }

    /// 给 agent 用：某个路径能不能删
    func verdict(_ path: String) -> Verdict {
        let p = URL(fileURLWithPath: expand(path)).standardizedFileURL.path
        for c in rules.categories where c.risk == .report {
            if (c.paths ?? []).map(expand).contains(where: { isInside(p, $0) }) { return .reportOnly(c) }
        }
        let exempt = Self.exemptions.first { isInside(p, $0) && p != $0 }
        if let r = protectionReason(p, exempt: exempt) { return .protected(r) }
        if keptTargetsAll.contains(URL(fileURLWithPath: p).resolvingSymlinksInPath().path) { return .protected("正在使用的程序版本") }
        for c in rules.categories where c.risk != .report && c.action != .command {
            let roots = (c.paths ?? []).map(expand)
            for r in roots where isInside(p, r) && p != r {
                let first = r + "/" + p.dropFirst(r.count + 1).split(separator: "/")[0]
                let name = (first as NSString).lastPathComponent
                if (c.exclude ?? []).contains(where: { glob($0, name) }) { continue }
                if let m = c.match, !m.contains(where: { glob($0, name) }) { continue }
                return .cleanable(c)
            }
        }
        return .unknown
    }
}
