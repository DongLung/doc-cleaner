#!/usr/bin/env bash
# doc-cleaner macOS 簽章＋公證發布鏈。
# 2026-08-17 對 1.7.0 端到端實跑通過（兩輪公證都一次過）；步驟 0 的前置檢查在
# 2026-08-18 收緊過（unlock 改走 stdin、runtime 判定收窄到 CodeDirectory 行），
# 那兩處是單獨驗證的，收緊後未再重跑整條鏈。
#
# 前置：.app 已由 briefcase 用 Developer ID 深度簽好
#   briefcase create macOS --no-input     # create 會正確寫入 Info.plist 版號，
#   briefcase build macOS --no-input      # 不需要 update 路徑那道 PlistBuddy 補丁
#   briefcase package macOS -p zip --no-input -i "<identity>" --no-notarize
# 用 package 只為借它「由內而外逐一簽所有 nested .so/.dylib」的能力，dmg 仍由
# scripts/package_dmg.py 建（briefcase 的 dmg 不含 ReadMe.txt）。
#
# 順序是硬約束（NEVER 重排）：
#   公證＋staple .app → dmgbuild 建 dmg → codesign dmg → 公證＋staple dmg → 驗收
# dmg 的 codesign MUST 在公證之前（codesign 改寫映像內容，先公證會使票據失效）。
# .app 的 staple MUST 在建 dmg 之前（dmg 封好後就改不動裡面那顆 App）。
# 「驗收 → 再加工 → 上傳」是假綠本尊：驗過的必須就是出貨的那一顆。
#
# 環境變數（都有合理預設）：
#   SIGN_IDENTITY      預設讀 ~/.apple-signing/signing_identity.txt
#   SIGN_KEYCHAIN      預設 ~/Library/Keychains/doc-cleaner-signing.keychain-db
#   NOTARY_PROFILE     預設 doc-cleaner-notary（用 notarytool store-credentials 建）
#   KC_PASSWORD_FILE   選填；有給才會先 unlock keychain
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

IDENTITY="${SIGN_IDENTITY:-$(cat "$HOME/.apple-signing/signing_identity.txt")}"
KC="${SIGN_KEYCHAIN:-$HOME/Library/Keychains/doc-cleaner-signing.keychain-db}"
PROFILE="${NOTARY_PROFILE:-doc-cleaner-notary}"
WORK="${WORK_DIR:-${TMPDIR:-/tmp}}"
APP="$ROOT/build/macapp/macos/app/Doc Cleaner.app"
VERSION="$(python3 -c "import tomllib;print(tomllib.load(open('pyproject.toml','rb'))['tool']['briefcase']['version'])")"
DMG="$ROOT/dist/Doc Cleaner-${VERSION}.dmg"

step() { printf '\n========== %s ==========\n' "$1"; }

# 送件並等待。「送件成功」不等於「公證通過」：submit 的 exit code 只反映上傳，
# 判定必須讀 status 欄位；非 Accepted 就把 Apple 的具名錯誤 log 印出來再失敗。
notarize() {
  local target="$1" label="$2" out id status
  out="$(xcrun notarytool submit "$target" \
          --keychain-profile "$PROFILE" --keychain "$KC" \
          --wait --output-format json 2>&1 || true)"
  printf '%s\n' "$out" | tail -3
  id="$(python3 -c "
import json,sys
try: print(json.loads(sys.argv[1]).get('id',''))
except Exception: print('')
" "$out" 2>/dev/null || true)"
  status="$(python3 -c "
import json,sys
try: print(json.loads(sys.argv[1]).get('status',''))
except Exception: print('')
" "$out" 2>/dev/null || true)"
  echo "  submission id=${id} status=${status}"
  if [ "$status" != "Accepted" ]; then
    echo "::error::${label} 公證未通過（status=${status}）"
    [ -n "$id" ] && xcrun notarytool log "$id" \
      --keychain-profile "$PROFILE" --keychain "$KC" 2>&1 | head -60 || true
    return 1
  fi
  return 0
}

step "0. 前置檢查"
# 密碼走 stdin 而非 -p：-p 會讓密碼出現在 process list（同機器其他程序 ps 看得到）。
# 實測 security unlock-keychain 不帶 -p 時會從 stdin 讀，非互動環境同樣有效。
[ -n "${KC_PASSWORD_FILE:-}" ] && security unlock-keychain "$KC" < "$KC_PASSWORD_FILE"
[ -d "$APP" ] || { echo "找不到 .app：${APP}" >&2; exit 1; }
APP_SIGN="$(codesign -dv --verbose=4 "$APP" 2>&1 || true)"
case "$APP_SIGN" in
  *"Authority=Developer ID Application"*) echo "  .app 已有 Developer ID 簽章 OK" ;;
  *) echo "::error::.app 尚未用 Developer ID 簽章（先跑 briefcase package -i ...）"
     grep -E "flags=|Signature=" <<<"$APP_SIGN" || true; exit 1 ;;
esac
# 只看 CodeDirectory 那一行（flags 欄位所在）：比對整份輸出會讓路徑等欄位
# 剛好含 runtime 字樣也判成通過。複合旗標（0x10800 等）同樣帶 runtime，
# 所以認字串而不認寫死的 0x10000。
APP_CD="$(grep -m1 '^CodeDirectory' <<<"$APP_SIGN" || true)"
case "$APP_CD" in
  *runtime*) echo "  hardened runtime OK" ;;
  *) echo "::error::.app 未啟用 hardened runtime，公證會退件"
     printf '%s\n' "$APP_CD"; exit 1 ;;
esac
# 版號三處一致（Info.plist／App 內建 pyproject／根 ReadMe.txt）在 dmg 封好後就
# 改不動了，這裡先擋：改 plist 會毀掉簽章與票據，整條鏈得從頭重跑。
PLIST_VER="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist" 2>&1 || true)"
[ "$PLIST_VER" = "$VERSION" ] || { echo "::error::Info.plist 版號 ${PLIST_VER} != pyproject ${VERSION}"; exit 1; }
echo "  版本：${VERSION}（Info.plist 一致）"
echo "  目標 dmg：${DMG}"

step "1. 公證並 staple .app"
ZIP="$WORK/DocCleaner-${VERSION}-app.zip"
rm -f "$ZIP"
# notarytool 不吃裸 .app，要先打包；ditto -c -k --keepParent 是 Apple 指定格式
ditto -c -k --keepParent "$APP" "$ZIP"
echo "  zip: $(du -h "$ZIP" | cut -f1)"
notarize "$ZIP" ".app" || exit 1
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"

step "2. dmgbuild 建 dmg（此時裡面的 .app 已帶票據）"
[ -f "$DMG" ] && { echo "  已存在同名 dmg，改名保留：${DMG}.prev"; mv "$DMG" "${DMG}.prev"; }
python3 scripts/package_dmg.py

step "3. 簽 dmg（MUST 在公證之前）"
codesign --force --timestamp --sign "$IDENTITY" --keychain "$KC" "$DMG"
DMG_SIGN="$(codesign -dv --verbose=4 "$DMG" 2>&1 || true)"
case "$DMG_SIGN" in
  *"Authority=Developer ID Application"*) echo "  dmg 簽章 OK" ;;
  *) echo "::error::dmg 簽章失敗"; printf '%s\n' "$DMG_SIGN"; exit 1 ;;
esac

step "4. 公證並 staple dmg"
notarize "$DMG" "dmg" || exit 1
xcrun stapler staple "$DMG"

step "5. 四條硬驗收（對象是 dmg 裡那顆 App）"
bash scripts/verify_macos_signing.sh "$DMG" signed
