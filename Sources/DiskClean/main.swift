import SwiftUI

// 带子命令启动 = 命令行模式（给 agent 用）；否则打开窗口
let cliCommands: Set<String> = ["auto", "scan", "clean", "check", "rules", "ai", "history", "help", "--help"]
let args = Array(CommandLine.arguments.dropFirst())
if args.first == "mcp" { exit(MCP.serve()) }
if args.first == "connect" { exit(Connect.run(args)) }
if args.first == "watch" { exit(Watch.run(args)) }
if let first = args.first, cliCommands.contains(first) {
    exit(CLI.run(args))
}
Actor.isApp = true
NSApplication.shared.setActivationPolicy(.regular)
DiskCleanApp.main()
