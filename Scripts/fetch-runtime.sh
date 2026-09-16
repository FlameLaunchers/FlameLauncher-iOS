#!/bin/bash
#
# 게임 실행에 필요한 네이티브 바이너리와 패치된 자바 라이브러리를 가져온다.
#
# 전부 PojavLauncher iOS(GPLv3)가 빌드해 저장소에 커밋해 둔 산출물이다. 용량이 60MB 남짓이라
# 이 저장소에 함께 커밋하지 않고 여기서 받는다 — 받는 위치는 Runtime/ 이고, Xcode 빌드가
# 이걸 앱 번들의 Frameworks/ 와 libs/ 로 복사한다.
#
#   Runtime/Frameworks/          렌더러·LWJGL·OpenAL 네이티브 (.dylib)
#   Runtime/libs/                패치된 LWJGL (GLFW 를 우리 브릿지로 돌린 버전)
#   Runtime/libs_caciocavallo/   AWT 가상 백엔드 (JRE8용)
#   Runtime/libs_caciocavallo17/ AWT 가상 백엔드 (JRE9+용)
#   Runtime/java_runtimes/       iOS(arm64) OpenJDK — Amethyst(Angel Aura) 배포본
#
# JRE 는 기본으로 8/17/21 을 받는다. 25 까지 받으려면:  ./fetch-runtime.sh main "8 17 21 25"
# 기기의 Documents/runtimes/ 에 사용자가 직접 넣은 JRE 가 있으면 그쪽이 우선한다.

set -euo pipefail

REPO="PojavLauncherTeam/PojavLauncher_iOS"
REF="${1:-main}"
JRE_VERSIONS="${2:-8 17 21}"
BASE="https://raw.githubusercontent.com/$REPO/$REF"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

fetch_dir() {
  local remote="$1" local_dir="$2"
  mkdir -p "$ROOT/$local_dir"
  echo "▸ $local_dir"
  gh api "repos/$REPO/contents/$remote?ref=$REF" --jq '.[] | select(.type=="file") | .name' \
    | while read -r name; do
        [ -z "$name" ] && continue
        printf '    %s' "$name"
        curl -sL --fail --retry 3 "$BASE/$remote/$name" -o "$ROOT/$local_dir/$name" \
          && echo "  $(du -h "$ROOT/$local_dir/$name" | cut -f1)" \
          || echo "  실패"
      done
}

command -v gh >/dev/null || { echo "gh CLI 가 필요합니다: brew install gh"; exit 1; }

echo "PojavLauncher iOS ($REF) 에서 런타임 가져오는 중…"
fetch_dir "Natives/resources/Frameworks"       "Runtime/Frameworks"
fetch_dir "JavaApp/libs/lwjgl"                 "Runtime/libs"
fetch_dir "JavaApp/libs/caciocavallo"          "Runtime/libs_caciocavallo"
fetch_dir "JavaApp/libs/caciocavallo17"        "Runtime/libs_caciocavallo17"

# .framework 는 위 방식(파일 목록)으로는 못 받는다.
#   libEGL / libGLESv2 — MetalANGLE. libtinygl4angle.dylib 이 의존한다.
#   AltKit / CAltKit  — 같은 Wi-Fi 의 AltServer 에 붙어 JIT 를 켜는 데 쓴다(선택).
for fw in libEGL libGLESv2 AltKit CAltKit; do
  echo "▸ Runtime/Frameworks/$fw.framework"
  mkdir -p "$ROOT/Runtime/Frameworks/$fw.framework"
  for f in "$fw" Info.plist; do
    curl -sL --fail --retry 3 \
      "$BASE/Natives/resources/Frameworks/$fw.framework/$f" \
      -o "$ROOT/Runtime/Frameworks/$fw.framework/$f" && echo "    $f" || echo "    $f 실패"
  done
done

# ── MoltenVK ───────────────────────────────────────────────────────────
#
# ⚠️ 위에서 받은 libMoltenVK.dylib(1.2.9)을 **공식 릴리스로 덮어쓴다.**
#    26.3 의 renderpearl 셰이더에 `vertex` 라는 GLSL 함수가 있는데, 1.2.9 에 든
#    SPIRV-Cross(84cdc3b)는 그 이름을 MSL 로 그대로 옮긴다. Metal 예약어라 컴파일이 깨지고
#    로딩 타이틀 직후 게임이 멈춘다:
#      [mvk-error] Shader library compile failed:
#        float3 vertex(thread const int& index)    ← expected unqualified-id
#      Can't compile pipeline minecraft:pipeline/oit_transmittance_flat_clouds
#    1.4.2 의 SPIRV-Cross(6c09849)는 get_illegal_func_names 에 `vertex` 가 있어 이름을 바꾼다.
#
# ⚠️ 파일 이름은 그대로 둔다 — libOSMesa(Zink)가 @loader_path/libMoltenVK.dylib 로 링크돼 있다.
#    OSMesa 가 가져다 쓰는 심볼 104개는 1.4.2 에 전부 있다(dyld_info -imports 로 대조).
MVK_VERSION="v1.4.2"
MVK_SHA256="b5d947b1660e6e9fed40b9cd2387e160aaab9e80b775c0cef7e14059405178c1"
MVK_BIN="MoltenVK/MoltenVK/dynamic/MoltenVK.xcframework/ios-arm64/MoltenVK.framework/MoltenVK"
echo "▸ Runtime/Frameworks/libMoltenVK.dylib ($MVK_VERSION)"
tmp="$(mktemp -d)"
curl -sSL --fail --retry 3 -o "$tmp/mvk.tar" \
  "https://github.com/KhronosGroup/MoltenVK/releases/download/$MVK_VERSION/MoltenVK-ios.tar"
echo "$MVK_SHA256  $tmp/mvk.tar" | shasum -a 256 -c --status \
  || { echo "    ✗ 체크섬 불일치 — 받은 파일을 쓰지 않습니다"; exit 1; }
tar -xf "$tmp/mvk.tar" -C "$tmp" "$MVK_BIN"
cp "$tmp/$MVK_BIN" "$ROOT/Runtime/Frameworks/libMoltenVK.dylib"
rm -rf "$tmp"

# ── JRE ────────────────────────────────────────────────────────────────
#
# PojavLauncher iOS 저장소는 2025-09-23 에 아카이브됐고 JRE 도 2022년판이 마지막이다.
# 후속인 Amethyst(Angel Aura)가 8/17/21/25 를 현행으로 유지하므로 그쪽에서 받는다.
# 배포 형식: zip 안에 jre<N>-*.tar.xz  →  풀면 JRE 루트(bin/, lib/, release).
JRE_BASE="https://assets.angelauramc.dev/openjdk/ios-arm64"

for v in $JRE_VERSIONS; do
  dest="$ROOT/Runtime/java_runtimes/java-$v-openjdk"
  if [ -f "$dest/release" ]; then
    echo "▸ java-$v-openjdk (이미 있음)"
    continue
  fi
  echo "▸ java-$v-openjdk"
  tmp="$(mktemp -d)"
  if curl -sS -L --fail --retry 3 "$JRE_BASE/jre$v-ios-aarch64.zip" -o "$tmp/jre.zip"; then
    ( cd "$tmp" && unzip -q jre.zip )
    mkdir -p "$dest"
    # macOS tar 는 libarchive 라 .tar.xz 를 그대로 푼다.
    tar xf "$tmp"/jre"$v"-*.tar.xz -C "$dest"
    # 실행 파일·소스·문서는 안 쓴다 — Amethyst 와 같은 기준으로 덜어낸다(용량이 절반 넘게 준다).
    rm -rf "$dest"/{bin,include,jre,legal,man,ASSEMBLY_EXCEPTION,LICENSE,THIRD_PARTY_README} \
           "$dest"/lib/{ct.sym,jspawnhelper,src.zip,tools.jar} 2>/dev/null || true
    # AWT 스텁은 Xcode 빌드가 Frameworks/ 로 넣고, JRE 쪽에는 앱이 실행 시 심볼릭 링크를 건다.
    echo "    $(du -sh "$dest" | cut -f1)"
  else
    echo "    실패 — 건너뜀"
  fi
  rm -rf "$tmp"
done

echo
echo "완료. 받은 용량:"
du -sh "$ROOT/Runtime"/* 2>/dev/null | sed 's/^/  /'
echo
echo "⚠️  새로 받은 파일을 앱에 넣으려면 'xcodegen generate' 를 다시 돌려야 합니다."
echo "   (복사 단계가 파일 목록을 프로젝트에 박아두기 때문)"
echo
echo "남은 준비물은 JIT 하나입니다 — README 의 'JIT' 절을 보세요."
