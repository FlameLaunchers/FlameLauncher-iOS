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

mkdir -p "$(dirname "$OUT")"
cat > "$OUT" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CURSEFORGE_API_KEY</key>
	<string>$KEY</string>
</dict>
</plist>
PLIST

plutil -lint "$OUT" >/dev/null
echo "▸ Resources/Secrets.plist 생성 (키 ${#KEY}자)"
