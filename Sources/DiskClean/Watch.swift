import Foundation

/// 空间不足提醒：用 LaunchAgent 每 30 分钟检查一次可用空间，低于用户设的线就发系统通知。
/// 不会自动删任何东西，只提醒。
enum Watch {
    struct Settings: Codable {
        var lowSpaceGB: Double = 20
        var enabled = false
    }

    struct State: Codable {
        var lastFree: Int64 = 0
        var lastAt: Date = .distantPast
    }

    static let label = "com.agentdiskclean.watch"
    static let settingsPath = "~/.config/agent-disk-clean/settings.json"
    static let statePath = "~/.config/agent-disk-clean/watch-state.json"
    static var plistPath: String { expand("~/Library/LaunchAgents/\(label).plist") }
    /// 已经提醒过后，再少这么多才再提醒一次；或者隔一天再提醒
    static let realertDrop: Int64 = 5_000_000_000
    static let realertAfter: TimeInterval = 86400

    static func load<T: Decodable>(_ p: String, _ fallback: T) -> T {
        guard let d = FileManager.default.contents(atPath: expand(p)), let v = try? JSONDecoder().decode(T.self, from: d) else { return fallback }
        return v
    }

    static func save<T: Encodable>(_ v: T, _ p: String) {
        let path = expand(p)
        try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? enc.encode(v).write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    static var settings: Settings { load(settingsPath, Settings()) }
    static var threshold: Int64 { Int64(settings.lowSpaceGB * 1e9) }

    // MARK: 命令行

    static func run(_ args: [String]) -> Int32 {
        var s = settings
        if let i = args.firstIndex(of: "--gb"), i + 1 < args.count {
            guard let v = Double(args[i + 1]), v > 0 else { fputs("--gb 后面要跟一个大于 0 的数字\n", stderr); return 1 }
            s.lowSpaceGB = v
            save(s, settingsPath)
        }
        if args.contains("--on") { print(enable(s.lowSpaceGB)); return 0 }
        if args.contains("--off") { print(disable()); return 0 }
        if args.contains("--status") {
            let free = DiskSpace.current()?.free ?? 0
            print("提醒：\(s.enabled ? "开" : "关")，低于 \(fmtGB(s.lowSpaceGB)) GB 时提醒，现在可用 \(gb(free)) GB")
            return 0
        }
        check(force: args.contains("--force"))
        // 后台任务顺便每天记一次各文件夹大小，给「涨得最快」用
        if args.count == 1 { Growth.recordIfNeeded() }
        return 0
    }

    /// 检查一次；低于提醒线就发通知（同一次「变少」只提醒一次，不刷屏）
    @discardableResult
    static func check(force: Bool = false) -> Bool {
        guard let d = DiskSpace.current() else { return false }
        let line = threshold
        var st: State = load(statePath, State())
        guard d.free < line else {
            if st.lastFree != 0 { save(State(), statePath) }
            return false
        }
        let due = st.lastFree == 0 || st.lastFree - d.free >= realertDrop || Date().timeIntervalSince(st.lastAt) >= realertAfter
        guard due || force else { return true }
        notify(title: "阿扫：磁盘空间不足", body: "可用空间只剩 \(gb(d.free)) GB，低于你设的 \(fmtGB(settings.lowSpaceGB)) GB。打开阿扫，或让 AI 运行 diskclean auto。")
        st.lastFree = d.free
        st.lastAt = Date()
        save(st, statePath)
        return true
    }

    static func notify(title: String, body: String) {
        func esc(_ s: String) -> String { s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", "display notification \"\(esc(body))\" with title \"\(esc(title))\" sound name \"Funk\""]
        try? p.run()
        p.waitUntilExit()
    }

    // MARK: 开关（LaunchAgent）

    static func enable(_ gbLine: Double) -> String {
        var s = settings
        s.enabled = true
        s.lowSpaceGB = gbLine
        save(s, settingsPath)
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [Connect.executablePath(), "watch"],
            "StartInterval": 1800,
            "RunAtLoad": true,
            "ProcessType": "Background",
            "LowPriorityIO": true,
        ]
        do {
            try FileManager.default.createDirectory(atPath: (plistPath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try data.write(to: URL(fileURLWithPath: plistPath), options: .atomic)
        } catch { return "开启失败：\(error.localizedDescription)" }
        let uid = String(getuid())
        _ = Connect.shell("/bin/launchctl", ["bootout", "gui/\(uid)/\(label)"])
        let (code, out) = Connect.shell("/bin/launchctl", ["bootstrap", "gui/\(uid)", plistPath])
        if code != 0 { return "已保存设置，但后台检查没启动：\(out.trimmingCharacters(in: .whitespacesAndNewlines))" }
        return "已开启：每 30 分钟检查一次，可用空间低于 \(fmtGB(gbLine)) GB 时发通知"
    }

    static func disable() -> String {
        var s = settings
        s.enabled = false
        save(s, settingsPath)
        _ = Connect.shell("/bin/launchctl", ["bootout", "gui/\(getuid())/\(label)"])
        try? FileManager.default.removeItem(atPath: plistPath)
        return "已关闭空间不足提醒"
    }

    static func fmtGB(_ v: Double) -> String { v == v.rounded() ? String(Int(v)) : String(format: "%.1f", v) }
}
