#!/bin/bash
# 编译 + 自检 + 签名。用法: ./build.sh [--install]
# 签名身份可用环境变量 GK_SIGN_IDENTITY 指定（默认 "GestureKit Self-Signed"）
set -euo pipefail
cd "$(dirname "$0")"

APP="GestureKit.app"
BIN="$APP/Contents/MacOS/GestureKit"

echo "==> 组装 App 包"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp Resources/Info.plist "$APP/Contents/Info.plist"
mkdir -p "$APP/Contents/Resources"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"   # 由 scripts/make-icon.swift 生成

echo "==> 文案检查（所有 L(\"…\") 都有英文）"
scripts/check-l10n.sh

echo "==> 编译"
swiftc -O -o "$BIN" Sources/*.swift

echo "==> 自检"
"$BIN" --selftest

# 有固定证书就用它（权限跨版本保留），否则 ad-hoc。证书用 scripts/make-signing-cert.sh 一次性创建。
IDENTITY="${GK_SIGN_IDENTITY:-GestureKit Self-Signed}"
IDS=$(security find-identity -v -p codesigning 2>/dev/null || true)
if [[ $IDS == *"\"$IDENTITY\""* ]]; then
  echo "==> 签名（证书：$IDENTITY）"
  codesign --force --deep --sign "$IDENTITY" "$APP"
  STABLE=1
else
  echo "==> 签名（ad-hoc）"
  codesign --force --deep --sign - "$APP"
  STABLE=0
fi
codesign --verify --deep --strict "$APP" && echo "签名校验通过"
echo "    身份：$(codesign -d -r- "$APP" 2>&1 | sed -n 's/^# designated => //p; s/^designated => //p')"
if [[ $STABLE == 0 ]]; then
  echo "    提示：ad-hoc 签名每次编译都会让「辅助功能」授权失效；运行一次 scripts/make-signing-cert.sh 可解决。"
fi

if [[ "${1:-}" == "--install" ]]; then
  echo "==> 安装到 /Applications"
  pkill -f "GestureKit.app/Contents/MacOS/GestureKit" 2>/dev/null || true
  sleep 1
  rm -rf /Applications/GestureKit.app
  cp -R "$APP" /Applications/
  open -a /Applications/GestureKit.app
  if [[ $STABLE == 1 ]]; then
    echo "已安装并启动。证书签名：已授权过的话权限会保留（从 ad-hoc 切到证书后需最后授权一次）。"
  else
    echo "已安装并启动。注意：ad-hoc 重新签名后需要在 系统设置→隐私与安全性→辅助功能 重新授权。"
  fi
fi

echo "完成: $APP"
