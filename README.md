# 阿扫 · agent-disk-clean

给 AI agent 用的 Mac 磁盘清理工具。你可以自己点按钮清，也可以交给 Claude Code、Codex、Cursor、Gemini CLI 这些 agent 去清，它们只能按阿扫的规则删，删不到你的文件。

[English](#english)

## 为什么要做它

用上 AI 工具以后，磁盘满得特别快：agent 的旧版本、对话记录、自动化浏览器、本地模型、各种包管理器缓存，几天就能占掉几十 GB。

让 agent 直接帮你清理很省事，但也很危险：它可能因为「这个文件夹很大」「很久没动」就 `rm -rf`。阿扫把「什么能删、什么必须问你、什么绝对不能碰」写成规则，agent 只能通过阿扫来删。

## 三个级别

| 级别 | 意思 | 例子 |
|---|---|---|
| 🟢 safe | 会自动重建，可以直接清 | 应用缓存、旧日志、包管理器下载缓存、Xcode 编译产物、Claude Code 旧版本 |
| 🟡 review | 必须你点头才清 | 废纸篓、下载里的旧安装包、Playwright 浏览器、Codex 30 天前的对话 |
| 🔵 report | 只告诉你，绝不自动删 | 本地大模型、Docker 数据、iPhone 备份、Xcode 归档 |

另外还有一张禁区清单：文稿、桌面、iCloud 云盘、钥匙串、`~/.ssh`、`~/.claude`、任何 `.git` 和 `.env`……其中最关键的几处直接写死在程序里，改规则文件也绕不过去。

你还可以在 `~/.config/agent-disk-clean/protected.json` 里加上自己的禁区。这个文件只能增加禁区，不能放宽任何规则：

```json
[
  { "path": "~/MyProjects", "reason": "我的代码" }
]
```

## 安装

需要 macOS 15 以上，并且装好 Xcode 或 Command Line Tools（Swift 6）。

```bash
git clone https://github.com/taozi19981125/agent-disk-clean.git
cd agent-disk-clean
./build.sh            # 生成 dist/阿扫.app，并把命令 diskclean 链接到 ~/.local/bin
```

`~/.local/bin` 不在 PATH 里的话，把它加进去：`echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc`。

读取废纸篓等位置需要在「系统设置 → 隐私与安全性 → 完全磁盘访问权限」里允许阿扫。

## 用法

### 自己用

打开 `阿扫.app`：上面是可用空间和占用分布，下面勾选要清理的项目，点「清理」。「空间占用」页可以看每个文件夹有多大，只看不删。

### AI 占用

一页看清 Claude Code、Codex、Cursor、Gemini CLI、ChatGPT 桌面版、本地模型、自动化浏览器各占多少，点开能看到具体在哪些文件夹。

- **涨得最快**：阿扫每天记一次各文件夹的大小，告诉你「这周 Codex 涨了 2 GB」，磁盘满之前就知道是谁在吃空间。
- **本地模型管家**：Ollama、HuggingFace、LM Studio、Whisper 的模型逐个列出大小、下载时间、大概多久没用，点「删除」自己挑着删。HuggingFace 共用的大文件会一起算、一起删，删了真能腾出空间。模型只能你自己删，agent 删不了。

### 记录

每一次清理都会记下：谁（你在 app 里点的，还是哪个 agent 通过 MCP / 命令行做的）、什么时候、删了什么、释放了多少。让 AI 动手也能放心。

### 空间不足提醒

点右上角的铃铛，打开「可用空间不足时提醒我」，选 10 / 20 / 50 / 100 GB 或者自己填一个数。开启后每 30 分钟在后台检查一次，低于这条线就发系统通知。只提醒，不自动删。命令行：`diskclean watch --on --gb 20`。

### 让 AI 帮我看

点「让 AI 帮我看」，阿扫在后台把本地扫描结果交给你电脑上已经装好的 Claude Code 或 Codex。十几秒后，建议直接显示在窗口里：每一项标上「建议清 / 你看一眼 / 先别动」和一句理由，建议清的自动勾好，你看过点「清理」就行。

- 没有接 API：阿扫是在后台运行你已经登录好的命令行 AI（`claude -p` / `codex exec`），用的是你自己的订阅，不用填 Key。
- 按钮左边可以选用哪个 AI；也可以填一条自定义命令，比如 `ollama run qwen3:8b` 用本地模型完全离线（提示词从标准输入传进去）。
- AI 拿不到任何工具，只能看、不能删。
- 电脑上没装这两个的话，阿扫会把扫描结果复制好，你贴给豆包、DeepSeek 这类网页版 AI 就行。

扫描和清理都在本机完成，不联网。只有用这个按钮时，扫描结果（文件夹路径和大小，不含文件内容，用户名会隐去）会发给 AI。

### 接入各家 agent（MCP）

```bash
diskclean connect all       # 自动接入这台电脑上装了的 agent
diskclean connect           # 查看手动配置方法
```

目前自动接入支持 Claude Code、Codex、Cursor、Gemini CLI、Windsurf。其他支持 MCP 的工具，在配置里加：

```json
"mcpServers": {
  "agent-disk-clean": { "command": "/Users/你/.local/bin/diskclean", "args": ["mcp"] }
}
```

接入后 agent 会拿到四个工具：

| 工具 | 做什么 |
|---|---|
| `disk_scan` | 扫描，列出每个分类能释放多少 |
| `disk_auto` | 清掉所有 safe 项，返回三行总结 |
| `disk_clean` | 清理指定分类；review 级必须传 `user_approved` |
| `disk_check` | 删任何东西前先问：可清理 / 只报告 / 禁止 / 未知 |
| `disk_ai_usage` | 只读：各 AI 工具和本地模型占多少，最近 7 天谁涨得最快 |
| `disk_history` | 只读：清理记录 |

不支持 MCP 的 agent，只要能跑终端命令，就让它先读 [AGENT_RULES.md](AGENT_RULES.md)，再用下面的命令。

### 命令行

```bash
diskclean auto [--dry-run]                 # 清掉所有 safe 项，输出三行总结
diskclean scan [--json] [--details]        # 每个分类能释放多少
diskclean clean <分类id...> [--dry-run]     # 清理指定分类
diskclean clean <id> --user-approved       # review 分类，用户同意后才能加
diskclean check <路径...>                   # 这个路径能不能删
diskclean rules                            # 规则文件和守则的位置
diskclean ai [--json]                      # 各 AI 工具、本地模型占多少，涨得最快的文件夹
diskclean history                          # 清理记录
diskclean watch --on [--gb 20]             # 空间不足提醒（--off 关闭，--status 查看）
```

退出码：`0` 成功，`1` 出错，`2` 被安全规则拒绝。删除记录在 `~/Library/Logs/DiskClean/clean.log`。

## 改规则

规则都在 [`Resources/cleanup-rules.json`](Resources/cleanup-rules.json)，App、命令行、MCP 共用这一份。欢迎提 PR 补充更多 AI 工具的缓存位置，请写清楚：删了以后会不会自动重建、会丢什么。

## 协议

[MIT](LICENSE)

---

## English

**阿扫 (Asao) / agent-disk-clean** is a macOS disk cleaner built for the AI-agent era. Clean it yourself in the app, or let Claude Code, Codex, Cursor, Gemini CLI and other agents do it — they can only delete what the rules allow.

- **Three risk levels**: `safe` (rebuilt automatically, cleaned directly), `review` (needs your explicit approval), `report` (never deleted, only reported).
- **Hard-coded protected paths** (Documents, iCloud Drive, Keychains, `~/.ssh`, `~/.claude`, any `.git` / `.env`…) that editing the rules file can't bypass. Add your own in `~/.config/agent-disk-clean/protected.json`; it can only add protection, never remove it.
- **AI usage page**: how much Claude Code, Codex, Cursor, local models etc. take, which folders grew fastest this week, and a local model manager (Ollama / HuggingFace / LM Studio / Whisper) — models can only be deleted by you, never by agents.
- **Activity log**: who cleaned what and when — you in the app, or which agent via MCP / CLI.
- **Low-space alert**: notify when free space drops below your threshold.
- **MCP server**: `diskclean connect all` registers it with installed agents. Tools: `disk_scan`, `disk_auto`, `disk_clean`, `disk_check`, `disk_ai_usage`, `disk_history`.
- **CLI** for any agent that can run shell commands; see [AGENT_RULES.md](AGENT_RULES.md).

Build: macOS 15+, Swift 6. Run `./build.sh` → `dist/阿扫.app` plus `diskclean` linked into `~/.local/bin`.

The UI and messages are currently in Chinese. License: MIT.
