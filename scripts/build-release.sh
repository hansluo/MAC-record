#!/bin/bash
# =============================================================
# Mac-Record 一键打包发布脚本
# 用法：./scripts/build-release.sh
# =============================================================

set -euo pipefail

# ---- 配置 ----
APP_NAME="Mac-Record"
SCHEME="MacRecord"
BUNDLE_ID="com.hansluo.mac-record"
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="${PROJECT_DIR}/build"
ARCHIVE_PATH="${BUILD_DIR}/${APP_NAME}.xcarchive"
EXPORT_DIR="${BUILD_DIR}/export"
DMG_PATH="${BUILD_DIR}/${APP_NAME}.dmg"

# 颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info()  { echo -e "${BLUE}[INFO]${NC} $1"; }
ok()    { echo -e "${GREEN}[✓]${NC} $1"; }
warn()  { echo -e "${YELLOW}[!]${NC} $1"; }
fail()  { echo -e "${RED}[✗]${NC} $1"; exit 1; }

# ---- Step 0: 环境检查 ----
info "检查环境..."

cd "$PROJECT_DIR"

# 检查 xcodegen
if ! command -v xcodegen &>/dev/null; then
    fail "未安装 xcodegen。请运行: brew install xcodegen"
fi

# 检查签名证书
CERT_COUNT=$(security find-identity -v -p codesigning 2>/dev/null | grep "Developer ID Application" | wc -l | tr -d ' ')
if [ "$CERT_COUNT" -eq 0 ]; then
    warn "未找到 Developer ID Application 证书"
    echo ""
    echo "请先在 Xcode 中创建证书："
    echo "  1. Xcode → Settings → Accounts → 登录 Apple Developer 账号"
    echo "  2. 选择 Team → Manage Certificates"
    echo "  3. 点击 + → Developer ID Application"
    echo ""
    echo "创建完成后重新运行此脚本。"
    echo ""
    
    # 尝试使用 Apple Development 证书（本地测试用）
    DEV_COUNT=$(security find-identity -v -p codesigning 2>/dev/null | grep "Apple Development" | wc -l | tr -d ' ')
    if [ "$DEV_COUNT" -gt 0 ]; then
        warn "找到 Apple Development 证书，将使用它进行本地签名（无法分发给其他人）"
        SIGNING_IDENTITY="Apple Development"
    else
        fail "没有任何有效的签名证书。请按上述步骤操作。"
    fi
else
    SIGNING_IDENTITY="Developer ID Application"
    ok "找到 Developer ID Application 证书"
fi

# 获取 Team ID
TEAM_ID=$(security find-identity -v -p codesigning 2>/dev/null | grep "$SIGNING_IDENTITY" | head -1 | sed 's/.*(\([^)]*\)).*/\1/' | tr -d ' ')
info "Team ID: ${TEAM_ID}"

# ---- Step 1: 生成 Xcode 项目 ----
info "生成 Xcode 项目..."
xcodegen generate
ok "项目生成完成"

# ---- Step 2: 清理旧构建 ----
info "清理旧构建..."
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

# ---- Step 3: Archive ----
info "开始 Archive（Release 模式）..."
xcodebuild archive \
    -scheme "$SCHEME" \
    -configuration Release \
    -archivePath "$ARCHIVE_PATH" \
    ARCHS=arm64 \
    ONLY_ACTIVE_ARCH=NO \
    CODE_SIGN_IDENTITY="$SIGNING_IDENTITY" \
    DEVELOPMENT_TEAM="$TEAM_ID" \
    CODE_SIGN_STYLE=Manual \
    2>&1 | tail -5

if [ ! -d "$ARCHIVE_PATH" ]; then
    fail "Archive 失败"
fi
ok "Archive 完成: $ARCHIVE_PATH"

# ---- Step 4: 导出 .app ----
info "导出 .app..."

# 创建 ExportOptions.plist
cat > "${BUILD_DIR}/ExportOptions.plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>developer-id</string>
    <key>teamID</key>
    <string>${TEAM_ID}</string>
    <key>signingStyle</key>
    <string>manual</string>
    <key>signingCertificate</key>
    <string>${SIGNING_IDENTITY}</string>
</dict>
</plist>
EOF

xcodebuild -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportPath "$EXPORT_DIR" \
    -exportOptionsPlist "${BUILD_DIR}/ExportOptions.plist" \
    2>&1 | tail -5

APP_PATH="${EXPORT_DIR}/${APP_NAME}.app"
if [ ! -d "$APP_PATH" ]; then
    # 如果 exportArchive 失败，直接从 archive 中复制
    warn "exportArchive 失败，直接从 Archive 提取..."
    mkdir -p "$EXPORT_DIR"
    cp -R "${ARCHIVE_PATH}/Products/Applications/${APP_NAME}.app" "$APP_PATH"
fi
ok "App 导出完成: $APP_PATH"

# ---- Step 5: 验证签名 ----
info "验证代码签名..."
codesign -dvv "$APP_PATH" 2>&1 | head -10
echo ""
codesign --verify --deep --strict "$APP_PATH" 2>&1 && ok "签名验证通过" || warn "签名验证有警告"

# ---- Step 6: 创建 DMG ----
info "创建 DMG 安装包..."
rm -f "$DMG_PATH"

# 创建临时目录
DMG_TEMP="${BUILD_DIR}/dmg_temp"
DMG_RW="${BUILD_DIR}/${APP_NAME}_rw.dmg"
rm -rf "$DMG_TEMP"
rm -f "$DMG_RW"
mkdir -p "$DMG_TEMP"
cp -R "$APP_PATH" "$DMG_TEMP/"

# 创建 Applications 快捷方式
ln -s /Applications "$DMG_TEMP/Applications"

# 先创建读写 DMG（用于设置窗口外观）
hdiutil create \
    -volname "$APP_NAME" \
    -srcfolder "$DMG_TEMP" \
    -ov \
    -format UDRW \
    -nospotlight \
    "$DMG_RW" 2>&1 | tail -3

rm -rf "$DMG_TEMP"

# 挂载读写 DMG 并设置 Finder 窗口外观
info "设置 DMG 窗口外观..."
MOUNT_DIR=$(hdiutil attach "$DMG_RW" -readwrite -noverify -noautoopen 2>/dev/null | grep "/Volumes/" | awk '{print $NF}')

if [ -n "$MOUNT_DIR" ]; then
    # 用 AppleScript 设置窗口大小、图标大小、图标位置
    osascript <<APPLESCRIPT
tell application "Finder"
    tell disk "$APP_NAME"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set bounds of container window to {200, 120, 860, 520}
        set theViewOptions to the icon view options of container window
        set arrangement of theViewOptions to not arranged
        set icon size of theViewOptions to 128
        set position of item "$APP_NAME.app" of container window to {180, 200}
        set position of item "Applications" of container window to {480, 200}
        close
        open
        update without registering applications
        delay 1
        close
    end tell
end tell
APPLESCRIPT

    # 等待 Finder 完成
    sleep 2

    # 卸载
    hdiutil detach "$MOUNT_DIR" -quiet 2>/dev/null
    sleep 1
fi

# 转换为只读压缩 DMG
hdiutil convert "$DMG_RW" \
    -format UDBZ \
    -o "$DMG_PATH" 2>&1 | tail -3

rm -f "$DMG_RW"

if [ -f "$DMG_PATH" ]; then
    ok "DMG 创建完成: $DMG_PATH"
else
    warn "DMG 创建失败，但 .app 已准备好"
fi

# ---- Step 7: 公证（如果有 Developer ID 证书）----
if [ "$SIGNING_IDENTITY" = "Developer ID Application" ]; then
    echo ""
    info "========================================="
    info "接下来需要公证（Notarization）"
    info "========================================="
    echo ""
    echo "请运行以下命令提交公证："
    echo ""
    echo "  # 首次需要存储 App Store Connect 凭据："
    echo "  xcrun notarytool store-credentials \"mac-record\" \\"
    echo "    --apple-id \"你的Apple ID\" \\"
    echo "    --team-id \"${TEAM_ID}\" \\"
    echo "    --password \"App 专用密码\""
    echo ""
    echo "  # 提交公证："
    echo "  xcrun notarytool submit \"${DMG_PATH}\" \\"
    echo "    --keychain-profile \"mac-record\" \\"
    echo "    --wait"
    echo ""
    echo "  # 公证通过后，装订票据："
    echo "  xcrun stapler staple \"${DMG_PATH}\""
    echo ""
    echo "App 专用密码请到 https://appleid.apple.com → 登录 → App 专用密码 中创建"
    echo ""
fi

# ---- 完成 ----
echo ""
echo "========================================"
ok "打包完成！"
echo "========================================"
echo ""
echo "  📦 App:  ${APP_PATH}"
echo "  💿 DMG:  ${DMG_PATH}"
echo "  📁 大小: $(du -sh "$APP_PATH" 2>/dev/null | cut -f1)"
echo ""
echo "分发给他人前，请确保完成公证（Notarization）。"
echo "未公证的 App 在其他 Mac 上打开时会被 Gatekeeper 阻止。"
echo ""
