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

VERSION=$(sed -n 's/.*MARKETING_VERSION = \([^;]*\);.*/\1/p' MotionLandmarker.xcodeproj/project.pbxproj | head -1)
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

# 署名し直す（バンドル全体，ハードンドランタイム）
codesign --force --deep --options runtime --sign "$SIGN_IDENTITY" "$APP"
codesign --verify --deep --strict "$APP"

mkdir -p dist
rm -f "$OUT"
ditto -c -k --keepParent "$APP" "$OUT"
echo "built: $OUT"
