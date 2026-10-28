# 阿扫（agent-disk-clean）· Agent 守则

> 适用于任何在这台 Mac 上帮用户清理磁盘的 agent（Claude Code、Codex、Cursor、Gemini CLI……）。
> 机器可读的规则在同目录 `Resources/cleanup-rules.json`，App 和本守则以它为准。

## ⚡ 最短用法（大多数情况只需要这一段）

```bash
diskclean auto
```
把输出原样转给用户即可。它只清 safe 项；「需要你点头」那一行，用户同意哪项才运行
`diskclean clean <id> --user-approved`。不要自己去删任何别的东西，下面是细则。

如果你的工具列表里有 `disk_scan` / `disk_auto` / `disk_clean` / `disk_check`（阿扫的 MCP 服务），
直接用它们，规则和命令行完全一样。接入方法：`diskclean connect all`。
另有两个只读工具：`disk_ai_usage`（各 AI 工具和本地模型占多少、最近 7 天谁涨得最快）、`disk_history`（清理记录）。
你通过阿扫做的每一次清理都会记下「哪个 agent、什么时候、删了什么」，用户在 app 的「记录」页能看到。

## 0. 三条总原则

1. **只删会自动重建的东西。** 缓存、编译产物、旧日志可以删；用户自己产生的文件一律不碰。
2. **不确定就不删。** 不在规则里的路径 = 不能删。大不代表是垃圾，旧也不代表是垃圾。
3. **用工具删，别自己拼 `rm -rf`。** 优先用 DiskClean 命令行，它每一项删除前都会再做一次禁区检查。

## 1. 工具

```bash
DC=diskclean   # 已链接到 ~/.local/bin；不在 PATH 时用 "<阿扫.app 所在位置>/阿扫.app/Contents/MacOS/DiskClean"

"$DC" scan                  # 各分类能释放多少（加 --json 给程序读，加 --details 看具体条目）
"$DC" check <路径>          # 删任何东西前先问它：可清理 / 只报告 / 禁止 / 未知
"$DC" clean --safe --dry-run
"$DC" clean --safe
"$DC" clean trash old_installers --user-approved   # review 分类，必须用户同意后才能加这个参数
"$DC" rules                 # 规则文件、守则、用户自定义禁区的位置
"$DC" ai                    # 只读：各 AI 工具、本地模型占多少，最近 7 天谁涨得最快
"$DC" history               # 只读：清理记录
```

退出码：`0` 成功，`1` 出错，`2` 被安全规则拒绝。**收到 2 就停下，不要换个办法绕过去。**
删除记录写在 `~/Library/Logs/DiskClean/clean.log`。

## 2. 标准流程（必须按顺序）

1. **先量**：`df -h /` 和 `"$DC" scan`，搞清楚空间去哪了。
2. **报告**：把三个级别的大小告诉用户（模板见第 6 节）。
3. **safe 级**：先 `clean --safe --dry-run`，再 `clean --safe`。用户说过“直接清”就不必再问。
4. **review 级**：逐项告诉用户「是什么、多大、删了有什么后果」，**用户明确同意哪项才清哪项**，加 `--user-approved`。
5. **report 级**：只告诉用户大小和处理办法，自己不动手。
6. **收尾**：报告释放了多少、可用空间前后对比、跳过了什么。

## 3. 三个级别

### 🟢 safe：可以直接清理（会自动重建）

| id | 内容 | 位置 |
|---|---|---|
| `user_caches` | 第三方应用缓存 | `~/Library/Caches/*`，**不含** `com.apple.*`、`CloudKit`、`ms-playwright` |
| `user_logs` | 7 天前的日志 | `~/Library/Logs/*` |
| `xcode_derived` | Xcode 编译产物 | `~/Library/Developer/Xcode/DerivedData/*` |
| `simulator_caches` | 模拟器缓存 | `~/Library/Developer/CoreSimulator/Caches/*` |
| `dev_package_caches` | 包管理器下载缓存 | `~/.npm/_cacache` `~/.bun/install/cache` `~/.cargo/registry/cache` `~/.gradle/caches` `~/.cache/pip` `~/.cache/uv` |
| `homebrew_cleanup` | Homebrew 旧版本 | 运行 `brew cleanup --prune=all` |
| `ai_old_versions` | Claude Code 旧版本 | `~/.local/share/claude/versions/*`，**永远保留**正在用的版本（`~/.local/bin/claude` 指向的）和上一个版本 |

清之前最好提醒用户退出浏览器和 IDE；正在使用的文件删不掉会被跳过，属于正常现象。

### 🟡 review：必须先问用户

| id | 内容 | 为什么要问 |
|---|---|---|
| `trash` | 废纸篓 | 删了找不回。读取它需要「完全磁盘访问权限」 |
| `old_installers` | 下载里 30 天前的 dmg/pkg/iso/xip | 用户可能还要用；只移到废纸篓 |
| `xcode_device_support` | iOS 设备调试符号 | 再连手机要重新拷贝几分钟 |
| `agent_runtimes` | Playwright 浏览器、Codex 运行时 | agent 自动化要用，删了得重新下载 |
| `ai_old_sessions` | Codex 30 天前的对话记录（按月份删 `~/.codex/sessions/年/月`） | 删了旧对话就打不开了 |
| `dev_model_caches` | `~/.cache` 下其他工具的缓存 | 内容杂，可能重新下载很久 |

### 🔵 report：只报告，绝不自动删

| id | 内容 | 让用户怎么处理 |
|---|---|---|
| `ios_backups` | iPhone/iPad 本地备份 | Finder → 连接设备 → 管理备份 |
| `xcode_archives` | Xcode 归档 | Xcode → Organizer 自己挑 |
| `simulator_devices` | 模拟器设备 | `xcrun simctl delete unavailable` |
| `local_models` | Ollama / HuggingFace / LM Studio / Whisper 模型 | 让用户打开阿扫 →「AI 占用」页，自己挑着删。**agent 不能删模型** |
| `docker_data` | Docker 镜像和数据卷 | `docker system df` 查看；`docker image prune` 只删镜像，**数据卷不要动** |

## 4. 🚫 绝对不能碰

### 4.1 禁区路径（以及里面的任何东西）

**用户数据**
- `~/Documents` `~/Desktop` `~/Pictures` `~/Movies` `~/Music` `~/Downloads` 里除了旧安装包以外的所有文件
- 任何代码项目（`~/Projects` `~/Developer` `~/Code` 等）、任何 `.git` 目录、任何 `.env` 文件
- 用户自己加的禁区：`~/.config/agent-disk-clean/protected.json`（只能加禁区，不能放宽规则）
- 照片图库 `*.photoslibrary`、iPhone 备份 `MobileSync`、Time Machine 备份 `Backups.backupdb` / `*.sparsebundle`
- 虚拟机镜像 `*.vmwarevm` `*.pvm` `*.utm`

**同步盘：删本地 = 所有设备上一起删**
- `~/Library/Mobile Documents`（iCloud 云盘）
- `~/Library/CloudStorage`（Dropbox / Google Drive / OneDrive）

**应用数据和账号**
- `~/Library/Application Support`：微信、浏览器配置、App 数据库都在这里
- `~/Library/Containers` `~/Library/Group Containers`：沙盒应用的全部数据
- `~/Library/Keychains` `~/Library/Cookies` `~/Library/Accounts` `~/Library/Preferences`
- `~/Library/Mail` `~/Library/Messages` `~/Library/Safari` `~/Library/Calendars` `~/Library/Photos`
- `~/Library/Fonts` `~/Library/LaunchAgents`

**凭据和工具配置**
- `~/.ssh` `~/.gnupg` `~/.aws` `~/.kube` `~/.docker` `~/.config` `~/.local`
- `~/.claude` `~/.codex` `~/.cursor` `~/.vscode`：agent 的会话、记忆、设置、登录凭据、生成的图片。
  唯一例外是上面表格里的 Claude Code 旧版本和 Codex 旧对话，这两处例外写死在程序里，别的地方一律不许动。Claude Code 的对话会自动删 30 天前的，不要手动清
- `~/.ollama`、`~/.zshrc` 这类 dotfile

**系统**
- `/System` `/Library` `/Applications` `/usr` `/bin` `/sbin` `/opt` `/private`（含 `/private/var/folders`、`/private/var/vm` 交换文件）`/Volumes`

### 4.2 禁止的操作

- ❌ `sudo` 任何删除命令；关闭 SIP；改系统文件
- ❌ 删除缓存目录**本身**（如 `rm -rf ~/Library/Caches`），只能删里面的条目
- ❌ 用变量拼路径的 `rm -rf "$X"/*`，变量为空时会变成删根目录
- ❌ 跟随软链接删除（`rm -rf link/`），只能删链接本身
- ❌ 卸载应用、删 `.app`。卸载由用户自己做
- ❌ 未经同意清空废纸篓、删 Time Machine 本地快照（`tmutil deletelocalsnapshots`）
- ❌ 杀掉进程来解锁文件
- ❌ 修改 `cleanup-rules.json` 或本守则来放宽限制。改规则必须用户本人提出
- ❌ 因为“很大”或“很久没动”就删。大文件只能列给用户看

## 5. 手动操作（必须用户确认才做）

以下操作 DiskClean 不会自动做，但可以列给用户看，用户逐项同意后再做：

- 代码项目里 90 天没改过的 `node_modules` / `.venv` / `target` / `build`。先列出路径和大小：
  `find ~ -maxdepth 5 -type d -name node_modules -prune -mtime +90 2>/dev/null | xargs -I{} du -sh {}`
- 主目录里的大文件（只列，不删）：`find ~ -xdev -type f -size +1G 2>/dev/null | head -50`

没有 DiskClean 的机器上，可以用这些自带的清理命令代替 safe 级：
`npm cache clean --force`、`brew cleanup --prune=all`、`pip cache purge`、`uv cache clean`。

## 6. 给用户的汇报模板

```
磁盘：可用 X GB / 共 Y GB

🟢 可以直接清：约 A GB（应用缓存 a、开发包缓存 b、旧日志 c……）
🟡 需要你点头：约 B GB
   - 下载里的旧安装包 2.8 GB（30 天前的 dmg，移到废纸篓）→ 清吗？
   - ……
🔵 只提醒：本地大模型 12.9 GB，不用的可以 ollama rm 删掉

要我先清 🟢 吗？
```
