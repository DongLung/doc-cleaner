#!/usr/bin/env bash
# macOS 簽章／公證驗收。掛載 DMG 後驗「DMG 裡面那顆 App」：斷言對象就是
# 使用者實際下載解開的東西，不驗 build/ 目錄裡的散裝 .app。
#
# 兩個模式共用同一支腳本：
#   signed   → 正式驗收，任一斷言失敗即擋發布
#   unsigned → 負向對照，對 adhoc／未簽章產物跑，證明斷言不是恆真
#              （發布當天才第一次執行的腳本等於沒有防線）
#
# 用法（版號自行代入，範例刻意不寫死以免隨發版過時）：
#   scripts/verify_macos_signing.sh "dist/Doc Cleaner-<版號>.dmg" signed
#   scripts/verify_macos_signing.sh "dist/Doc Cleaner-<舊的 adhoc 產物>.dmg" unsigned
#
# 刻意要求明確的 DMG 路徑而不自動搜尋 dist/：dist/ 裡有歷史版本 dmg 與
# hdiutil 留下的 .temp* 中繼映像，任何「找第一顆」的邏輯都可能撿錯檔案。
#
# NEVER 在判定命令上接 pipe：set -o pipefail 下 `codesign ... | grep -q`
# 會因 grep 命中後提前退出，codesign 後續寫入觸發 SIGPIPE(141)，把正確
# 簽章判成失敗。輸出一律先收進變數再比對。
#
# NEVER 只用 spctl 判定：它的結果取決於執行機器的 Gatekeeper 狀態，
# `spctl --master-disable` 過的機器上未簽章 App 也會回 accepted。真正的
# 判準是憑證類型與公證票據，兩者都只讀產物本身。
set -euo pipefail

DMG="${1:?用法：verify_macos_signing.sh <dmg 路徑> signed|unsigned}"
MODE="${2:?第二個參數必須是 signed 或 unsigned}"
case "$MODE" in
  signed|unsigned) ;;
  *) echo "未知模式：${MODE}（只接受 signed 或 unsigned）" >&2; exit 2 ;;
esac
[ -f "$DMG" ] || { echo "找不到 DMG：${DMG}" >&2; exit 1; }

MNT="$(mktemp -d)"
trap 'hdiutil detach "$MNT" >/dev/null 2>&1 || true; rmdir "$MNT" 2>/dev/null || true' EXIT
hdiutil attach "$DMG" -nobrowse -noautoopen -readonly -mountpoint "$MNT" >/dev/null
APP="$MNT/Doc Cleaner.app"
[ -d "$APP" ] || { echo "DMG 內找不到 Doc Cleaner.app" >&2; exit 1; }

fail=0
SIGN_INFO="$(codesign -dv --verbose=4 "$APP" 2>&1 || true)"

echo "── 0. DMG 內容必須齊全（App ＋ 使用說明 ＋ Applications 捷徑）"
# 產物內容斷言：dmgbuild 的 files/icon_locations 設定錯了不會報錯，只會
# 少一個檔案或圖示落到視窗外，使用者看不到說明檔。
missing=""
[ -f "$MNT/ReadMe.txt" ] || missing="${missing} ReadMe.txt"
[ -L "$MNT/Applications" ] || missing="${missing} Applications(symlink)"
if [ -n "$missing" ]; then
  echo "::error::DMG 內缺少：${missing}"
  ls -la "$MNT" || true
  fail=1
else
  echo "  OK"
fi

if [ "$MODE" = "signed" ]; then
  echo "── 1. 憑證類型必須是 Developer ID Application"
  # Apple Distribution 憑證也簽得過，但那是 App Store 用的，直接分發會被
  # Gatekeeper 擋；明確斷言憑證種類而不只是「有簽章」。
  case "$SIGN_INFO" in
    *"Authority=Developer ID Application"*) echo "  OK" ;;
    *)
      echo "::error::未以 Developer ID Application 簽章（adhoc 或憑證類型錯誤）"
      sed -n '1,20p' <<<"$SIGN_INFO"
      fail=1 ;;
  esac

  echo "── 1b. 必須啟用 hardened runtime（公證的前提條件）"
  # Python App 沒有 hardened runtime 會被公證直接退件；flags 是 codesign 當下
  # 決定的，事後補不了，所以在驗收就擋。
  # 判定只看 CodeDirectory 那一行：flags 欄位在該行，比對整份 codesign 輸出會
  # 讓「路徑或其他欄位剛好含 runtime 字樣」也判成通過（斷言恆真）。也不要死認
  # flags=0x10000：複合旗標（如 0x10800）同樣帶 runtime，寫死數值會誤擋。
  CD_LINE="$(grep -m1 '^CodeDirectory' <<<"$SIGN_INFO" || true)"
  case "$CD_LINE" in
    *runtime*) echo "  OK" ;;
    *)
      echo "::error::未啟用 hardened runtime"
      printf '%s\n' "$CD_LINE"
      fail=1 ;;
  esac

  echo "── 2. 簽章本身必須通過嚴格驗證"
  codesign --verify --deep --strict --verbose=2 "$APP" || { echo "::error::codesign 驗證失敗"; fail=1; }

  echo "── 3. App 與 DMG 都必須有公證票據"
  # 票據分兩層：App 的票據在簽完 App 後 submit＋staple；DMG 的票據要等
  # dmgbuild 建完映像後另外 submit＋staple。兩層都驗，離線環境的
  # Gatekeeper 檢查才不會被擋。
  xcrun stapler validate "$APP" || { echo "::error::App 沒有公證票據"; fail=1; }
  xcrun stapler validate "$DMG" || { echo "::error::DMG 沒有公證票據"; fail=1; }

  echo "── 4. DMG 本身必須有 Developer ID 簽章"
  # 票據與簽章是兩件事：公證票據可以只由映像內容建出（未簽章的 DMG 也能
  # 通過 stapler validate），所以第 3 項過不代表 DMG 有簽章。DMG 的
  # codesign MUST 在公證之前做（codesign 改寫映像內容，先公證會使票據失效）。
  DMG_SIGN="$(codesign -dv --verbose=4 "$DMG" 2>&1 || true)"
  case "$DMG_SIGN" in
    *"Authority=Developer ID Application"*) echo "  OK" ;;
    *)
      echo "::error::DMG 沒有 Developer ID Application 簽章"
      printf '%s\n' "$DMG_SIGN"
      fail=1 ;;
  esac

  echo "── 5. Gatekeeper 評估（僅供參考，NEVER 作為硬判準）"
  # DMG 的正確評估型別是 -t open --context context:primary-signature：
  # -t install 是 .pkg 專用，預設 -t exec 是可執行檔專用，對 DMG 都會回
  # no usable signature。這條刻意不進 fail。
  SPCTL_STATUS="$(spctl --status 2>&1 || true)"
  case "$SPCTL_STATUS" in
    *"assessments enabled"*)
      SPCTL_OUT="$(spctl -a -t open --context context:primary-signature -vvv "$DMG" 2>&1 || true)"
      case "$SPCTL_OUT" in
        *accepted*) echo "  OK（${SPCTL_OUT##*source=}）" ;;
        *)
          echo "::warning::Gatekeeper 評估未通過（不擋發布，但值得查）"
          printf '%s\n' "$SPCTL_OUT" ;;
      esac ;;
    *)
      echo "::warning::此機器的 Gatekeeper 評估已停用，spctl 無判定力，略過" ;;
  esac
else
  echo "── 未簽章負向對照：斷言此產物「不是」Developer ID 簽章且無票據"
  # 負向對照防止驗收邏輯退化成「什麼都過」：若 adhoc 建置也能通過 signed
  # 模式的斷言，代表斷言本身壞了。
  case "$SIGN_INFO" in
    *"Authority=Developer ID Application"*)
      echo "::error::未簽章建置卻驗出 Developer ID 簽章，建置環境異常"; fail=1 ;;
    *) echo "  OK（非 Developer ID 簽章）" ;;
  esac
  if xcrun stapler validate "$APP" >/dev/null 2>&1; then
    echo "::error::未簽章建置卻有公證票據，建置環境異常"; fail=1
  else
    echo "  OK（無公證票據，stapler 如預期拒絕）"
  fi
  # 與 signed 模式第 4 項對稱：少了這條，DMG 簽章那條斷言就沒有負向對照，
  # 無法排除「它恆真」。
  DMG_SIGN="$(codesign -dv --verbose=4 "$DMG" 2>&1 || true)"
  case "$DMG_SIGN" in
    *"Authority=Developer ID Application"*)
      echo "::error::未簽章建置的 DMG 卻驗出 Developer ID 簽章，建置環境異常"
      fail=1 ;;
    *) echo "  OK（DMG 非 Developer ID 簽章）" ;;
  esac
fi

[ "$fail" = "0" ] || { echo "::error::簽章／公證驗收未通過，請勿發布此產物"; exit 1; }
# 變數後緊接中文字元必須用大括號界定：bash 會把多位元組字元併進變數名，
# 變成 unbound variable
echo "驗收通過（模式：${MODE}，對象：${DMG}）"
