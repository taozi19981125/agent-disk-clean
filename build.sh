#!/bin/zsh
# 编译并打包成 阿扫.app（规则文件和 agent 守则一起打进包里），并把命令 diskclean 链接到 ~/.local/bin
# 可选环境变量：
#   APP_DIR        app 放在哪个文件夹（默认 ./dist）
#   SIGN_IDENTITY  代码签名证书名（默认临时签名）
#   BUNDLE_ID      应用标识（默认 com.agentdiskclean.asao）
#   RULES_BESIDE_APP=1  在 app 旁边也放一份 AGENT_RULES.md
set -e
cd "$(dirname "$0")"
swift build -c release
[ -f Resources/AppIcon.icns ] || swift scripts/make_icon.swift Resources
APP="${APP_DIR:-$PWD/dist}/阿扫.app"
BUNDLE_ID="${BUNDLE_ID:-com.agentdiskclean.asao}"
pkill -x DiskClean 2>/dev/null || true
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/DiskClean "$APP/Contents/MacOS/DiskClean"
cp Info.plist "$APP/Contents/"
plutil -replace CFBundleIdentifier -string "$BUNDLE_ID" "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns Resources/cleanup-rules.json AGENT_RULES.md "$APP/Contents/Resources/"
# 想在 app 旁边也放一份守则（方便发给其他 agent）时设 RULES_BESIDE_APP=1
[ -n "$RULES_BESIDE_APP" ] && cp AGENT_RULES.md "$(dirname "$APP")/AGENT_RULES.md"
ID=""
[ -n "$SIGN_IDENTITY" ] && ID=$(security find-identity -p codesigning | awk -v n="$SIGN_IDENTITY" 'index($0, n){print $2; exit}')
codesign --force -s "${ID:--}" --identifier "$BUNDLE_ID" "$APP"
# 命令行入口：任何终端 / agent 直接敲 diskclean
mkdir -p "$HOME/.local/bin"
ln -sf "$APP/Contents/MacOS/DiskClean" "$HOME/.local/bin/diskclean"
echo "已生成：$APP"
echo "接入 agent：diskclean connect all"
