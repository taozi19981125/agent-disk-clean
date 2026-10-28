import Foundation

/// `diskclean connect`：把阿扫的 MCP 服务登记到各家 agent 的配置里。
/// 只增加一条 agent-disk-clean 配置，不改动配置文件里的其他内容。
enum Connect {
    static let serverName = "agent-disk-clean"

    struct Target {
        let id: String
        let name: String
        /// 装了这个 agent 的标志
        let marker: String
        let install: (String) -> String
    }

    static let targets: [Target] = [
        Target(id: "claude", name: "Claude Code", marker: "~/.claude", install: claude),
        Target(id: "codex", name: "Codex", marker: "~/.codex", install: codex),
        Target(id: "cursor", name: "Cursor", marker: "~/.cursor", install: { jsonConfig("~/.cursor/mcp.json", $0) }),
        Target(id: "gemini", name: "Gemini CLI", marker: "~/.gemini", install: { jsonConfig("~/.gemini/settings.json", $0) }),
        Target(id: "claude_desktop", name: "Claude 桌面版", marker: "~/Library/Application Support/Claude", install: { jsonConfig("~/Library/Application Support/Claude/claude_desktop_config.json", $0) }),
        Target(id: "windsurf", name: "Windsurf", marker: "~/.codeium/windsurf", install: { jsonConfig("~/.codeium/windsurf/mcp_config.json", $0) }),
    ]

    static func run(_ args: [String]) -> Int32 {
        let exe = executablePath()
        let wanted = Array(args.dropFirst().filter { !$0.hasPrefix("--") })
        if args.contains("--print") || wanted.isEmpty {
            printManual(exe)
            if wanted.isEmpty {
                let found = targets.filter { exists($0.marker) }.map(\.id)
                print("\n这台电脑上找到：\(found.isEmpty ? "无" : found.joined(separator: " "))")
                print("一键接入：diskclean connect all")
            }
            return 0
        }
        var picked: [Target] = []
        for w in wanted {
            if w == "all" { picked = targets.filter { exists($0.marker) }; break }
            guard let t = targets.first(where: { $0.id == w }) else {
                fputs("不认识 \(w)。可选：\(targets.map(\.id).joined(separator: " ")) all\n", stderr); return 1
            }
            picked.append(t)
        }
        if picked.isEmpty { print("没找到已安装的 agent。用 diskclean connect --print 看手动配置方法。"); return 0 }
        for t in picked { print("\(t.name)：\(t.install(exe))") }
        print("\n重启对应的 agent 后，对它说「帮我看看磁盘空间」就会用阿扫。")
        return 0
    }

    /// 优先用 ~/.local/bin/diskclean（重新打包、挪位置都不影响），否则用程序本身的路径
    static func executablePath() -> String {
        let me = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])).resolvingSymlinksInPath().path
        let link = expand("~/.local/bin/diskclean")
        if URL(fileURLWithPath: link).resolvingSymlinksInPath().path == me { return link }
        return me
    }

    static func exists(_ p: String) -> Bool { FileManager.default.fileExists(atPath: expand(p)) }

    // MARK: 各家的配置方式

    static func claude(_ exe: String) -> String {
        guard let cli = findTool("claude") else { return "没找到 claude 命令。手动运行：claude mcp add --scope user \(serverName) -- \(exe) mcp" }
        if shell(cli, ["mcp", "get", serverName]).0 == 0 { return "已经接入过，跳过" }
        let (code, out) = shell(cli, ["mcp", "add", "--scope", "user", serverName, "--", exe, "mcp"])
        return code == 0 ? "已接入（claude mcp add --scope user）" : "接入失败：\(out.trimmingCharacters(in: .whitespacesAndNewlines))"
    }

    static func codex(_ exe: String) -> String {
        let path = expand("~/.codex/config.toml")
        var text = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        if text.contains("[mcp_servers.\(serverName)]") { return "已经接入过，跳过" }
        if !text.isEmpty && !text.hasSuffix("\n") { text += "\n" }
        text += "\n[mcp_servers.\(serverName)]\ncommand = \"\(exe)\"\nargs = [\"mcp\"]\n"
        do {
            try FileManager.default.createDirectory(atPath: expand("~/.codex"), withIntermediateDirectories: true)
            try text.write(toFile: path, atomically: true, encoding: .utf8)
            return "已接入（写入 ~/.codex/config.toml）"
        } catch { return "写入失败：\(error.localizedDescription)" }
    }

    /// Cursor / Gemini CLI / Windsurf 都是 JSON 里的 mcpServers
    static func jsonConfig(_ file: String, _ exe: String) -> String {
        let path = expand(file)
        var root: [String: Any] = [:]
        if let data = FileManager.default.contents(atPath: path), !data.isEmpty {
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return "\(file) 不是标准 JSON（可能有注释），为了不弄坏它没有改动。请手动加上：\n" + snippet(exe)
            }
            root = obj
        }
        var servers = root["mcpServers"] as? [String: Any] ?? [:]
        if servers[serverName] != nil { return "已经接入过，跳过" }
        servers[serverName] = ["command": exe, "args": ["mcp"]]
        root["mcpServers"] = servers
        do {
            try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
            return "已接入（写入 \(file)）"
        } catch { return "写入失败：\(error.localizedDescription)" }
    }

    static func snippet(_ exe: String) -> String {
        """
          "mcpServers": {
            "\(serverName)": { "command": "\(exe)", "args": ["mcp"] }
          }
        """
    }

    static func printManual(_ exe: String) {
        print("""
        让 agent 调用阿扫有两种方式：

        1. MCP（推荐）：agent 直接拿到 disk_scan / disk_auto / disk_clean / disk_check 四个工具
           Claude Code   claude mcp add --scope user \(serverName) -- \(exe) mcp
           Codex         在 ~/.codex/config.toml 里加：
                           [mcp_servers.\(serverName)]
                           command = "\(exe)"
                           args = ["mcp"]
           Cursor / Gemini CLI / Claude 桌面版 / Windsurf / 其他支持 MCP 的工具，在它们的 MCP 配置里加：
        \(snippet(exe))

        2. 命令行：任何能跑终端命令的 agent，让它先读守则，再用 diskclean 命令
           守则位置：\(Rules.resourceURL("AGENT_RULES.md")?.path ?? "AGENT_RULES.md")
        """)
    }

    static func findTool(_ name: String) -> String? {
        let dirs = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
            + ["~/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "~/.npm-global/bin"].map(expand)
        // Codex 桌面版里自带一份命令行
        let bundled = name == "codex" ? ["/Applications/ChatGPT.app", "/Applications/Codex.app"].map { $0 + "/Contents/Resources/codex-cli/bin/codex" } : []
        return (dirs.map { $0 + "/" + name } + bundled).first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func shell(_ exe: String, _ args: [String]) -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return (1, error.localizedDescription) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
