---
name: agent-disk-clean
description: 帮用户检查和清理 Mac 磁盘空间（阿扫 / agent-disk-clean）。用户说磁盘满了、空间不够、清理磁盘、清缓存、看看什么占了空间、AI 工具/模型占了多少空间时使用。包含安装方法和必须遵守的删除规则：只能通过 diskclean 删除，不能自己 rm。
---

# 阿扫（agent-disk-clean）

给 agent 用的 Mac 磁盘清理工具。你**只能通过它删除东西**，它会拦住不该删的路径。

## 1. 先确认装好了

```bash
command -v diskclean || ls ~/.local/bin/diskclean
```

有输出说明阿扫已经装过，跳过安装，但还要看下面「把这个 skill 装进你自己」做了没有。没有输出就按下面安装（全程不需要 sudo）：

```bash
# 需要 macOS 15 或更新，以及 Swift 6（随 Xcode 命令行工具一起装）
sw_vers -productVersion
swift --version || xcode-select --install   # 弹出窗口后让用户点「安装」，装完再继续

SRC="$HOME/.local/share/agent-disk-clean"
if [ -d "$SRC/.git" ]; then git -C "$SRC" pull --ff-only; else git clone https://github.com/taozi19981125/agent-disk-clean.git "$SRC"; fi
mkdir -p "$HOME/Applications"
APP_DIR="$HOME/Applications" "$SRC/build.sh"   # 编译约 1 分钟，生成 ~/Applications/阿扫.app，并把 diskclean 链接到 ~/.local/bin
```

`~/.local/bin` 不在 PATH 里时，本次会话用完整路径 `~/.local/bin/diskclean`，并告诉用户可以运行
`echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc`。

装好后（包括下面「把 skill 装进你自己」这一步）告诉用户：
- 可以在「应用程序」（~/Applications）里打开「阿扫」自己点着清理。
- 想清废纸篓，需要在「系统设置 → 隐私与安全性 → 完全磁盘访问权限」里允许阿扫。

### 把这个 skill 装进你自己（装一次，以后用户说「清一下磁盘」你就会按规矩来）

把仓库里的 skill 文件夹复制到**你自己**的用户级 skills 目录（已存在就覆盖，更新阿扫后再复制一次）：

```bash
SKILL_SRC="$HOME/.local/share/agent-disk-clean/skills/agent-disk-clean"
# 按你是谁选一个目标目录：
#   Claude Code      ~/.claude/skills
#   Codex            ~/.codex/skills
#   其他支持 skills 的 agent：用它自己的 skills 目录；通用位置是 ~/.agents/skills
DEST="$HOME/.claude/skills"   # ← 换成你自己的
mkdir -p "$DEST" && rm -rf "$DEST/agent-disk-clean" && cp -R "$SKILL_SRC" "$DEST/"
```

不确定自己的 skills 目录在哪，就问用户，不要乱放。
你不支持 skills 的话，把下面第 3 节「绝对不能做」和这句话记进你的全局说明（比如 AGENTS.md）：
「用户要清理磁盘时，先读 ~/.local/share/agent-disk-clean/skills/agent-disk-clean/SKILL.md，只能通过 diskclean 删除。」

可选：`diskclean connect all` 会把阿扫的 MCP 工具接入这台电脑上的 Claude Code、Codex、Cursor 等，之后可以直接调用 `disk_scan`、`disk_clean` 等工具。改动别的 agent 的配置前先问用户。

## 2. 清理流程

1. **先量**：`diskclean scan`（想看 AI 工具和本地模型各占多少：`diskclean ai`）。
2. **报告**：把三个级别的大小告诉用户：
   - safe（可直接清，会自动重建）
   - review（必须用户点头）
   - report（只提醒，阿扫不会删）
3. **safe**：`diskclean clean --safe --dry-run` 预演，再 `diskclean clean --safe`。用户只说「帮我清一下」时可以直接用 `diskclean auto`，把输出原样转给用户。
4. **review**：逐项说清「是什么、多大、删了有什么后果」，用户明确同意哪项才运行 `diskclean clean <id> --user-approved`。
5. **report**：只告诉用户大小和处理办法。本地模型让用户打开阿扫的「AI 占用」页自己删。
6. **收尾**：报告释放了多少、可用空间前后对比。

## 3. 绝对不能做

- 不要自己用 `rm` / `find -delete` / `trash` 删任何东西，所有删除都走 `diskclean`。
- 删任何路径前不确定，就先 `diskclean check <路径>`；结果不是「可清理」就不删。
- 命令返回退出码 `2`（被安全规则拒绝）就停下来告诉用户，不要换办法绕过去。
- 不要加 `--user-approved`，除非用户在对话里明确同意了那一项。
- 不要修改阿扫的规则文件来放宽限制。
- 不要用 sudo，不要卸载应用，不要删本地模型。

完整守则：`diskclean rules` 会打印守则文件位置，遇到上面没写到的情况先读它。
