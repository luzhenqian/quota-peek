#!/bin/zsh
# 构建 → 签名（Developer ID + hardened runtime）→ 打 DMG → 公证 → staple。
#
# 用法：
#   scripts/release.sh
#
# 环境变量：
#   SIGN_IDENTITY   签名身份，默认 "Developer ID Application"（自动匹配本机唯一的 Developer ID 证书）
#   公证凭证（二选一，缺省则跳过公证、只签名）：
#     NOTARY_PROFILE                 xcrun notarytool 的 keychain profile 名
#       （先运行一次：xcrun notarytool store-credentials <名字> --apple-id ... --team-id ... --password <app 专用密码>）
#     或 App Store Connect API key：
#       NOTARY_KEY      AuthKey_XXXX.p8 路径
#       NOTARY_KEY_ID   Key ID
#       NOTARY_ISSUER   Issuer ID
set -euo pipefail

SCRIPT_DIR=${0:A:h}
PROJECT_DIR=${SCRIPT_DIR:h}
DIST="$PROJECT_DIR/dist"
APP_DIR="$DIST/QuotaPeek.app"
DMG="$DIST/QuotaPeek.dmg"
ENTITLEMENTS="$PROJECT_DIR/Resources/QuotaPeek.entitlements"
SIGN_IDENTITY="${SIGN_IDENTITY:-Developer ID Application}"

echo "▸ 构建 release..."
swift build -c release --package-path "$PROJECT_DIR"

echo "▸ 组装 .app bundle..."
rm -rf "$APP_DIR" "$DMG"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$PROJECT_DIR/.build/release/QuotaPeek" "$APP_DIR/Contents/MacOS/QuotaPeek"
cp "$PROJECT_DIR/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"
cp -R "$PROJECT_DIR/.build/release/QuotaPeek_QuotaPeek.bundle" "$APP_DIR/Contents/Resources/"

echo "▸ 签名（hardened runtime + timestamp）..."
codesign --force --options runtime --timestamp \
  --entitlements "$ENTITLEMENTS" --sign "$SIGN_IDENTITY" \
  "$APP_DIR/Contents/MacOS/QuotaPeek"
codesign --force --options runtime --timestamp \
  --entitlements "$ENTITLEMENTS" --sign "$SIGN_IDENTITY" \
  "$APP_DIR"
codesign --verify --strict --verbose=2 "$APP_DIR"

echo "▸ 打 DMG..."
STAGING=$(mktemp -d)
cp -R "$APP_DIR" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
hdiutil create -volname "QuotaPeek" -srcfolder "$STAGING" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGING"

if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  echo "▸ 公证（keychain profile: $NOTARY_PROFILE）..."
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG"
  xcrun stapler staple "$APP_DIR"
  echo "✓ 已签名并公证：$DMG"
elif [[ -n "${NOTARY_KEY:-}" ]]; then
  echo "▸ 公证（App Store Connect API key）..."
  xcrun notarytool submit "$DMG" \
    --key "$NOTARY_KEY" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER" --wait
  xcrun stapler staple "$DMG"
  xcrun stapler staple "$APP_DIR"
  echo "✓ 已签名并公证：$DMG"
else
  echo "⚠️  未提供公证凭证（NOTARY_PROFILE 或 NOTARY_KEY），已签名但未公证。"
  echo "   未公证的 DMG 下载后首次打开仍会被 Gatekeeper 拦截，需右键→打开。"
  echo "   DMG：$DMG"
fi
