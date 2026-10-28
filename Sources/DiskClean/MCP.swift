import Foundation

/// MCP 服务（stdio）：让 Claude Code、Codex、Cursor、Gemini CLI 等任何支持 MCP 的 agent 直接调用阿扫。
/// 每个工具都转成一条命令行子命令执行，所以安全规则和命令行完全一样：所有删除都经过 Guard。
enum MCP {
    static let instructions = """
    阿扫（agent-disk-clean）：给 agent 用的 Mac 磁盘清理工具。
    规则：只删会自动重建的东西；不在规则里的路径一律不删；不要自己用 rm 删，统一用这里的工具。
    流程：先 disk_scan 看空间去哪了 → 把三个级别的大小告诉用户 → safe 级可以直接 disk_clean（先 dry_run）→
    review 级逐项说明「是什么、多大、删了有什么后果」，用户明确同意哪项才清哪项，并传 user_approved=true →
    report 级只告诉用户怎么自己处理，绝不清理。工具返回「拒绝」时就停下，不要换别的办法绕过去。
    """

    static let tools: [[String: Any]] = [
        [
            "name": "disk_scan",
            "description": "扫描这台 Mac，列出每个清理分类能释放多少空间。分 safe（可直接清）、review（必须用户同意）、report（只报告）三级。清理前先调用它。",
            "inputSchema": ["type": "object", "properties": [
                "details": ["type": "boolean", "description": "是否列出每个分类里最大的具体条目"],
            ]],
        ],
        [
            "name": "disk_auto",
            "description": "一步完成：清掉所有 safe 级分类，并返回三行总结（释放了多少、哪些需要用户点头、哪些只提醒）。用户只说「帮我清一下磁盘」时用它。",
            "inputSchema": ["type": "object", "properties": [
                "dry_run": ["type": "boolean", "description": "只预演不删除"],
            ]],
        ],
        [
            "name": "disk_clean",
            "description": "清理指定分类（分类 id 来自 disk_scan）。review 级分类必须在用户明确同意后才传 user_approved=true；report 级永远不能清理。建议先 dry_run=true。",
            "inputSchema": ["type": "object", "required": ["categories"], "properties": [
                "categories": ["type": "array", "items": ["type": "string"], "description": "分类 id 列表；传 [\"safe\"] 表示所有 safe 分类"],
                "dry_run": ["type": "boolean", "description": "只预演不删除"],
                "user_approved": ["type": "boolean", "description": "只有用户在对话里明确同意清理这些 review 分类时才设为 true"],
            ]],
        ],
        [
            "name": "disk_ai_usage",
            "description": "只读：各 AI 工具（Claude Code、Codex、Cursor……）、本地模型、自动化浏览器各占多少空间，以及最近 7 天涨得最快的文件夹。本地模型只能由用户在阿扫 app 里删，你不能删。",
            "inputSchema": ["type": "object", "properties": [:] as [String: Any]],
        ],
        [
            "name": "disk_history",
            "description": "只读：之前的清理记录（谁、什么时候、清了什么、释放了多少）。",
            "inputSchema": ["type": "object", "properties": [:] as [String: Any]],
        ],
        [
            "name": "disk_check",
            "description": "删除任何文件或文件夹之前先问它：返回 可清理 / 只报告 / 禁止 / 未知。只有「可清理」才能删，而且要用 disk_clean 删。",
            "inputSchema": ["type": "object", "required": ["paths"], "properties": [
                "paths": ["type": "array", "items": ["type": "string"]],
            ]],
        ],
    ]

    /// 连上来的 agent 的名字（initialize 里的 clientInfo），用来记「谁清理的」
    static var client = ""

    static func serve() -> Int32 {
        setvbuf(stdout, nil, _IOLBF, 0)
        while let line = readLine(strippingNewline: true) {
            guard !line.isEmpty,
                  let msg = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let method = msg["method"] as? String else { continue }
            let id = msg["id"]
            // 没有 id 的是通知（比如 notifications/initialized），不用回复
            guard let id, !(id is NSNull) else { continue }

            switch method {
            case "initialize":
                let params = msg["params"] as? [String: Any]
                let version = params?["protocolVersion"] as? String ?? "2025-06-18"
                client = (params?["clientInfo"] as? [String: Any])?["name"] as? String ?? "agent"
                reply(id, result: [
                    "protocolVersion": version,
                    "capabilities": ["tools": [:] as [String: Any]],
                    "serverInfo": ["name": "agent-disk-clean", "title": "阿扫", "version": appVersion],
                    "instructions": instructions,
                ])
            case "ping":
                reply(id, result: [:])
            case "tools/list":
                reply(id, result: ["tools": tools])
            case "tools/call":
                let params = msg["params"] as? [String: Any] ?? [:]
                let name = params["name"] as? String ?? ""
                let a = params["arguments"] as? [String: Any] ?? [:]
                guard let args = cliArgs(name, a) else {
                    reply(id, error: [-32602, "未知工具或参数不对：\(name)"]); continue
                }
                let (code, out) = runSelf(args)
                var text = out.trimmingCharacters(in: .whitespacesAndNewlines)
                if code == 2 { text += "\n\n[被安全规则拒绝。停下来把原因告诉用户，不要换别的办法绕过去。]" }
                reply(id, result: ["content": [["type": "text", "text": text]], "isError": code == 1])
            default:
                reply(id, error: [-32601, "不支持的方法：\(method)"])
            }
        }
        return 0
    }

    /// MCP 工具参数 → 命令行参数
    static func cliArgs(_ name: String, _ a: [String: Any]) -> [String]? {
        let dry = a["dry_run"] as? Bool == true
        switch name {
        case "disk_scan":
            return ["scan"] + (a["details"] as? Bool == true ? ["--details"] : [])
        case "disk_auto":
            return ["auto"] + (dry ? ["--dry-run"] : [])
        case "disk_clean":
            guard let cats = a["categories"] as? [String], !cats.isEmpty else { return nil }
            var args = ["clean"]
            for c in cats { args.append(c == "safe" ? "--safe" : c) }
            if dry { args.append("--dry-run") }
            if a["user_approved"] as? Bool == true { args.append("--user-approved") }
            return args
        case "disk_ai_usage":
            return ["ai"]
        case "disk_history":
            return ["history"]
        case "disk_check":
            guard let paths = a["paths"] as? [String], !paths.isEmpty else { return nil }
            return ["check"] + paths
        default:
            return nil
        }
    }

    /// 用同一个程序跑一条子命令，拿到输出和退出码
    static func runSelf(_ args: [String]) -> (Int32, String) {
        let p = Process()
        p.executableURL = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])).resolvingSymlinksInPath()
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        p.standardInput = FileHandle.nullDevice
        var env = ProcessInfo.processInfo.environment
        env["ASAO_ACTOR"] = client.isEmpty ? "agent" : client
        p.environment = env
        do { try p.run() } catch { return (1, "启动失败：\(error.localizedDescription)") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    static func reply(_ id: Any, result: [String: Any]) {
        send(["jsonrpc": "2.0", "id": id, "result": result])
    }

    static func reply(_ id: Any, error: [Any]) {
        send(["jsonrpc": "2.0", "id": id, "error": ["code": error[0], "message": error[1]]])
    }

    static func send(_ obj: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: obj) else { return }
        FileHandle.standardOutput.write(data + Data("\n".utf8))
    }
}

let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
