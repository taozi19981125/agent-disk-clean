import Foundation

/// 「让 AI 帮我看」的主路径：阿扫在后台把本地扫描结果交给用户已经装好的命令行 AI（不用填 Key、不额外花钱），
/// 拿回建议显示在窗口里并自动勾好。AI 拿不到任何工具：不能读文件、不能运行命令、也接不到阿扫的 MCP，删不了东西。
enum AIAdvisor {
    struct Backend: Identifiable {
        let id: String
        let name: String
        let tool: String
        /// 参数：把提示词放在最后
        let args: [String]
        /// 自定义命令：交给 zsh 运行，提示词从标准输入传进去
        var shellCommand: String? = nil
    }

    struct Advice {
        enum Verdict: String { case clean, review, keep }
        struct Item { let verdict: Verdict; let reason: String }
        let backend: String
        let summary: String
        let items: [String: Item]
    }

    static let backends: [Backend] = [
        // 不给任何工具，不读 MCP 配置，不留会话记录
        Backend(id: "claude", name: "Claude Code", tool: "claude", args: ["-p", "--tools", "", "--strict-mcp-config", "--no-session-persistence", "--output-format", "text"]),
        // 只读沙盒，关掉所有 MCP 服务（包括阿扫自己的），不留会话记录
        Backend(id: "codex", name: "Codex", tool: "codex", args: ["exec", "--sandbox", "read-only", "--skip-git-repo-check", "--ephemeral", "-c", "mcp_servers={}"]),
    ]

    static var installed: [Backend] { backends.filter { Connect.findTool($0.tool) != nil } }

    /// 用户自己填的命令，比如 ollama run qwen3:8b（完全离线）、gemini -p。命令从标准输入收到提示词，把回答打印出来
    static func custom(_ cmd: String) -> Backend? {
        let c = cmd.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !c.isEmpty else { return nil }
        let first = c.split(separator: " ").first.map(String.init) ?? c
        return Backend(id: "custom", name: (first as NSString).lastPathComponent, tool: "/bin/zsh", args: [], shellCommand: c)
    }

    static func prompt(_ results: [ScanResult]) -> String {
        let rows = results.filter { $0.total > 0 }.sorted { $0.total > $1.total }.map { r -> String in
            let level = ["safe": "可直接清", "review": "需用户确认", "report": "只报告，阿扫不清理"][r.category.risk.rawValue] ?? ""
            let top = r.items.prefix(5).map { "      " + fmtSize($0.size) + " " + $0.path.replacingOccurrences(of: home, with: "~") }.joined(separator: "\n")
            return "- id=\(r.category.id)｜\(r.category.name)｜\(fmtSize(r.total))｜\(level)\n    说明：\(r.category.description)\(top.isEmpty ? "" : "\n    最大的几项：\n" + top)"
        }.joined(separator: "\n")
        let disk = DiskSpace.current().map { "可用 \(fmtSize($0.free)) / 共 \(fmtSize($0.total))" } ?? ""
        return """
        你是 Mac 磁盘清理顾问。下面是开源工具「阿扫」在用户电脑上本地扫描出的结果（磁盘：\(disk)）。
        请逐项给建议：clean = 建议清理；review = 让用户自己看一眼再决定；keep = 建议先别动。
        判断依据：会不会自动重建、删了有什么影响、占多大。「只报告」的项目只能是 review 或 keep。
        reason 用一句大白话中文，20 字以内，说清删了会怎样。summary 用两三句话告诉用户空间主要被谁占了、建议怎么做。

        只输出一个 JSON，不要任何别的文字：
        {"summary": "...", "items": [{"id": "分类id", "verdict": "clean|review|keep", "reason": "..."}]}

        扫描结果：
        \(rows)
        """
    }

    /// 在后台运行，最多等 3 分钟
    static func ask(_ b: Backend, results: [ScanResult]) -> Result<Advice, Error> {
        let p = Process()
        let input = Pipe()
        if let cmd = b.shellCommand {
            p.executableURL = URL(fileURLWithPath: "/bin/zsh")
            p.arguments = ["-lc", cmd]
            p.standardInput = input
        } else {
            guard let cli = Connect.findTool(b.tool) else { return .failure(msg("没找到 \(b.tool) 命令")) }
            p.executableURL = URL(fileURLWithPath: cli)
            p.arguments = b.args + [prompt(results)]
            p.standardInput = FileHandle.nullDevice
        }
        p.currentDirectoryURL = FileManager.default.temporaryDirectory
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = ([expand("~/.local/bin"), "/opt/homebrew/bin", "/usr/local/bin"] + [env["PATH"] ?? "/usr/bin:/bin"]).joined(separator: ":")
        p.environment = env
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        do { try p.run() } catch { return .failure(error) }
        if b.shellCommand != nil {
            input.fileHandleForWriting.write(Data(prompt(results).utf8))
            try? input.fileHandleForWriting.close()
        }
        let timer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 180, execute: timer)
        // 两个管道同时读，避免一边写满卡住
        var errData = Data()
        let g = DispatchGroup()
        g.enter()
        DispatchQueue.global().async { errData = err.fileHandleForReading.readDataToEndOfFile(); g.leave() }
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        g.wait()
        p.waitUntilExit()
        timer.cancel()
        let text = String(decoding: outData, as: UTF8.self)
        guard p.terminationStatus == 0 else {
            let why = String(decoding: errData, as: UTF8.self).split(separator: "\n").last.map(String.init) ?? "退出码 \(p.terminationStatus)"
            return .failure(msg(p.terminationReason == .uncaughtSignal ? "\(b.name) 3 分钟没回应，已停止" : "\(b.name) 出错：\(why)"))
        }
        return parse(text, backend: b.name, valid: Set(results.map(\.category.id)))
    }

    static func parse(_ text: String, backend: String, valid: Set<String>) -> Result<Advice, Error> {
        guard let a = text.firstIndex(of: "{"), let z = text.lastIndex(of: "}"),
              let obj = try? JSONSerialization.jsonObject(with: Data(text[a...z].utf8)) as? [String: Any] else {
            return .failure(msg("没看懂 \(backend) 的回答，可以再试一次"))
        }
        var items: [String: Advice.Item] = [:]
        for it in obj["items"] as? [[String: Any]] ?? [] {
            guard let id = it["id"] as? String, valid.contains(id),
                  let v = Advice.Verdict(rawValue: (it["verdict"] as? String ?? "").lowercased()) else { continue }
            items[id] = Advice.Item(verdict: v, reason: it["reason"] as? String ?? "")
        }
        return .success(Advice(backend: backend, summary: obj["summary"] as? String ?? "", items: items))
    }

    static func msg(_ s: String) -> NSError { NSError(domain: "AIAdvisor", code: 1, userInfo: [NSLocalizedDescriptionKey: s]) }
}
