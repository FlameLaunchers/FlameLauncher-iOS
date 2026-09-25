#!/bin/bash
#
# CurseForge API 키를 Resources/Secrets.plist 로 써 넣는다.
#
# 이 파일은 저장소에 없다(.gitignore). 로컬에서는 각자 손으로 두고, CI 에서는
# 이 스크립트가 시크릿을 받아 만든다 — 안드로이드의 keystore 주입과 같은 방식이다.
#
# ⚠️ 이 키는 앱 번들 안에 **평문으로** 들어간다. IPA 를 받은 사람은 누구나 꺼낼 수
#    있다. 클라이언트에 넣는 키는 비밀이 될 수 없다 — 남용되면 교체하는 수밖에 없다.
#    교체는 GitHub 시크릿 FLAME_CURSEFORGE_KEY 만 갈면 되고, 저장소는 건드리지 않는다.
#
# 사용:  FLAME_CURSEFORGE_KEY=... Scripts/write-secrets.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/Resources/Secrets.plist"
KEY="${FLAME_CURSEFORGE_KEY:-}"

if [ -z "$KEY" ]; then
  echo "▸ FLAME_CURSEFORGE_KEY 가 없습니다 — Secrets.plist 를 만들지 않습니다."
  echo "  (CurseForge 검색만 꺼지고 Modrinth 는 그대로 동작합니다)"
  exit 0
fi

# 평문 키를 그대로 넣으면 IPA 안에 문자열로 남아 `strings` 한 방에 나온다.
# AES-256-CBC 로 감싸서 암호문만 넣는다. 열쇠는 SHA-256(암호구절)이고, 암호구절은
# 저장소 밖(.secrets/curseforge.pass)에 둔다 — 없으면 이번 빌드용으로 무작위 생성한다.
#
# ⚠️ 이건 **난독화**지 보안이 아니다. 복호화에 필요한 게 전부 앱 안에 들어가므로
#    바이너리를 뜯으면 결국 나온다. 목적은 소스·저장소·문자열 덤프에서 없애는 것.
PASS="${FLAME_CURSEFORGE_PASS:-}"
if [ -z "$PASS" ] && [ -f "$ROOT/../.secrets/curseforge.pass" ]; then
  PASS="$(cat "$ROOT/../.secrets/curseforge.pass")"
fi
[ -z "$PASS" ] && PASS="$(openssl rand -base64 48 | tr -d '\n')"

KEYHEX="$(printf %s "$PASS" | openssl dgst -sha256 -binary | xxd -p -c 64)"
IVHEX="$(openssl rand -hex 16)"
CIPHER="$(printf %s "$KEY" | openssl enc -aes-256-cbc -K "$KEYHEX" -iv "$IVHEX" -base64 -A)"
PASS_B64="$(printf %s "$PASS" | base64)"
IV_B64="$(printf %s "$IVHEX" | xxd -r -p | base64)"

mkdir -p "$(dirname "$OUT")"
cat > "$OUT" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CURSEFORGE_KEY_CIPHER</key>
	<string>$CIPHER</string>
	<key>CURSEFORGE_KEY_IV</key>
	<string>$IV_B64</string>
	<key>CURSEFORGE_KEY_PASS</key>
	<string>$PASS_B64</string>
</dict>
</plist>
PLIST

plutil -lint "$OUT" >/dev/null
echo "▸ Resources/Secrets.plist 생성 (평문 ${#KEY}자 → 암호문 ${#CIPHER}자)"
