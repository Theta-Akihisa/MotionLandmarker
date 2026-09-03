#!/bin/sh
# 配布用の .app を Release 構成でビルドし，zip にまとめる。
#   scripts/release.sh            → dist/MotionLandmarker-<version>.zip
#   SIGN_IDENTITY="Developer ID Application: ..." scripts/release.sh
#       → Developer ID で署名（省略時は ad-hoc 署名。Gatekeeper の警告が出る）
set -eu
cd "$(dirname "$0")/.."

DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export DEVELOPER_DIR
SIGN_IDENTITY="${SIGN_IDENTITY:--}"

# 版数：CI ではタグ名（v0.1.0 → 0.1.0），ローカルでは Xcode の MARKETING_VERSION
if [ -n "${GITHUB_REF_NAME:-}" ]; then
  VERSION=${GITHUB_REF_NAME#v}
else
  VERSION=$(sed -n 's/.*MARKETING_VERSION = \([^;]*\);.*/\1/p' MotionLandmarker.xcodeproj/project.pbxproj | head -1)
fi
APP=build/Build/Products/Release/MotionLandmarker.app
OUT=dist/MotionLandmarker-${VERSION}.zip

xcodebuild -project MotionLandmarker.xcodeproj -scheme MotionLandmarker \
  -configuration Release -derivedDataPath build \
  CODE_SIGN_IDENTITY="$SIGN_IDENTITY" CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= \
  build | grep -E "error:|warning: .*deprecated|BUILD" || true
test -d "$APP"

# サイドカーの .venv や __pycache__ が紛れ込んでいないことを確認（コピー時に除外している）
if [ -e "$APP/Contents/Resources/landmarker/.venv" ]; then
  echo "error: .venv is bundled" >&2; exit 1
fi

# 署名し直す。エンタイトルメント（カメラ利用の権利）を必ず付ける。
# Hardened Runtime 有効のアプリはこれが無いとカメラ要求が無言で拒否され，
# システム設定のカメラ一覧にも現れない。
codesign --force --options runtime \
  --entitlements MotionLandmarker/MotionLandmarker.entitlements \
  --sign "$SIGN_IDENTITY" "$APP"
codesign --verify --strict "$APP"
codesign -d --entitlements - "$APP" 2>/dev/null | grep -q "com.apple.security.device.camera" \
  || { echo "error: camera entitlement missing" >&2; exit 1; }

mkdir -p dist
rm -f "$OUT"
ditto -c -k --keepParent "$APP" "$OUT"
echo "built: $OUT"
