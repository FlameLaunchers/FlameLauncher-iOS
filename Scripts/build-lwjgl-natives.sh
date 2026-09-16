#!/bin/bash
#
# LWJGL 네이티브를 iOS(arm64)용으로 빌드한다.
#
# ── 왜 필요한가 ──────────────────────────────────────────────────────────────
# PojavLauncher/Amethyst 가 만들어 둔 dylib 은 LWJGL **3.3.3** 판이다.
# 마인크래프트 26.2 는 3.4.1 을 쓰는데, 3.4.1 은 콜백 인프라를 새로 만들면서
# 네이티브 진입점이 늘었다:
#
#     UnsatisfiedLinkError: 'long org.lwjgl.system.libffi.LibFFI.ffi_get_closure_size()'
#         at org.lwjgl.system.Upcalls.<clinit>
#         at org.lwjgl.system.Callback.<init>
#
# 자바만 3.4.1 로 올리면 여기서 막힌다. LWJGL 의 ant 빌드에는 iOS 타깃이 없어서
# 소스를 직접 clang 으로 컴파일한다(플래그는 config/macos/build.xml 을 따랐다).
#
# 산출물 (Runtime/Frameworks341/ — 26.2+ 전용, 기본 스택과 분리):
#   liblwjgl.dylib          코어 + libffi (정적 링크)
#   liblwjgl_opengl.dylib   GL 함수 포인터 글루
#   liblwjgl_stb.dylib      이미지 디코드·리사이즈
#   liblwjgl_tinyfd.dylib   파일 대화상자(마인크래프트가 참조만 한다)
#
# 사용:  Scripts/build-lwjgl-natives.sh [태그]
set -euo pipefail

# ⚠️ 기본값은 3.4.3 이다. 26.3 이 3.4.3 을 요구하고 26.2 도 같은 스택(Frameworks341)을 쓴다.
#    자바 jar 과 네이티브가 한 버전이라도 어긋나면 클래스 초기화에서 죽는다:
#      UnsatisfiedLinkError: 'int org.lwjgl.system.MemoryUtil.ngetPageSize()'   (3.4.3 jar + 3.4.1 네이티브)
REF="${1:-3.4.3}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# ⚠️ 기본 Frameworks 를 덮어쓰지 않는다. 3.4.1 네이티브는 26.2+ 전용이고,
#    1.21.x 는 Amethyst 의 3.3.3 판으로 돌아야 한다(섞으면 Iris 가 부팅 중에 죽는다).
OUT="$ROOT/Runtime/Frameworks${LWJGL_SUFFIX:-341}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
JH="${JAVA_HOME:-$(/usr/libexec/java_home 2>/dev/null || true)}"
[ -f "$JH/include/jni.h" ] || { echo "jni.h 를 가진 JDK 가 필요합니다 (JAVA_HOME)"; exit 1; }
echo "▸ SDK: $(basename "$SDK")   JDK: $JH"

# ── libffi ───────────────────────────────────────────────────────────────────
# LWJGL 은 빌드 서버가 만든 libffi.a 를 링크한다(소스에는 헤더만 있다). 직접 만든다.
echo "▸ libffi (iOS arm64)"
command -v aclocal >/dev/null || { echo "automake 가 필요합니다: brew install automake"; exit 1; }
find /opt/homebrew -name libtool.m4 -print -quit >/dev/null 2>&1 \
  || { echo "GNU libtool 이 필요합니다: brew install libtool"; exit 1; }
git clone --depth 1 https://github.com/libffi/libffi.git "$WORK/libffi" >/dev/null 2>&1
( cd "$WORK/libffi" && ACLOCAL_PATH=/opt/homebrew/share/aclocal ./autogen.sh ) >/dev/null 2>&1
mkdir -p "$WORK/libffi/b"
( cd "$WORK/libffi/b" && ../configure --host=aarch64-apple-darwin \
    --disable-shared --enable-static --disable-docs \
    CC="clang -target arm64-apple-ios14.0 -isysroot $SDK" \
    CCAS="clang -target arm64-apple-ios14.0 -isysroot $SDK" \
    CFLAGS="-O2 -fPIC" && make -j"$(sysctl -n hw.ncpu)" ) >/dev/null 2>&1
FFI_A="$WORK/libffi/b/.libs/libffi.a"
[ -f "$FFI_A" ] || { echo "libffi 빌드 실패"; exit 1; }

# ── LWJGL ────────────────────────────────────────────────────────────────────
echo "▸ LWJGL ($REF) 받는 중…"
git clone --depth 1 --branch "$REF" https://github.com/LWJGL/lwjgl3.git "$WORK/lwjgl3" >/dev/null 2>&1
M="$WORK/lwjgl3/modules/lwjgl"

# iOS SDK 에는 objc/objc-runtime.h 가 없다(맥 전용 호환 헤더). 내용은 아래 둘이 전부다.
mkdir -p "$WORK/shim/objc"
cat > "$WORK/shim/objc/objc-runtime.h" <<'HDR'
#pragma once
#include <objc/runtime.h>
#include <objc/message.h>
HDR

# ⚠️ 아키텍처 매크로는 **소문자**다 (`-DLWJGL_${build.arch}`, build.arch=arm64).
#    대문자로 주면 libffi 헤더의
#        #if defined(LWJGL_MACOS) && defined(LWJGL_arm64)
#        #define FFI_EXEC_TRAMPOLINE_TABLE 1
#    이 걸리지 않아 ffi_closure 가 tramp[] 레이아웃으로 컴파일된다. 그러면 LWJGL 이
#    계산한 오프셋(user_data@40)과 실제 libffi(iOS, 트램폴린 테이블 → 32)가 어긋나서
#    콜백의 user_data 가 0 으로 읽히고, 콜백을 해제할 때 NPE 로 죽는다.
CFLAGS_COMMON="-O2 -fPIC -DNDEBUG -DLWJGL_MACOS -DLWJGL_arm64
  -target arm64-apple-ios14.0 -isysroot $SDK -Wno-everything
  -I$WORK/shim -I$JH/include -I$JH/include/darwin
  -I$M/core/src/main/c -I$M/core/src/main/c/libffi -I$M/core/src/main/c/libffi/aarch64
  -I$M/core/src/main/c/macos"

build_lib() {           # build_lib <이름> <출력> <추가 include…> -- <소스…>
  local name="$1" out="$2"; shift 2
  local incs=() srcs=() seen_sep=0
  for a in "$@"; do
    if [ "$a" = "--" ]; then seen_sep=1; continue; fi
    if [ $seen_sep -eq 0 ]; then incs+=("$a"); else srcs+=("$a"); fi
  done
  local d="$WORK/o/$name"; mkdir -p "$d"
  ( cd "$d" && clang -c $CFLAGS_COMMON ${incs[@]+"${incs[@]}"} "${srcs[@]}" )
  ( cd "$d" && clang -dynamiclib -o "$out" ./*.o \
      -target arm64-apple-ios14.0 -isysroot "$SDK" \
      -framework CoreFoundation -framework Foundation \
      -install_name "@rpath/$(basename "$out")" ${EXTRA_LINK[@]+"${EXTRA_LINK[@]}"} )
  printf '    %-26s %s\n' "$(basename "$out")" "$(du -h "$out" | cut -f1)"
}

mkdir -p "$OUT"
echo "▸ 빌드"

EXTRA_LINK=("$FFI_A")
build_lib core "$OUT/liblwjgl.dylib" -- \
  "$M"/core/src/main/c/*.c "$M"/core/src/generated/c/*.c "$M"/core/src/generated/c/macos/*.c

EXTRA_LINK=()
# WGL / GLX 는 각각 윈도우·X11 전용이다(헤더부터 없다). 애플에서는 CGL 도 안 쓴다 —
# 우리는 MobileGlues/ANGLE 이 컨텍스트를 만들고 LWJGL 은 함수 포인터만 얻어 간다.
OPENGL_SRCS=$(ls "$M"/opengl/src/generated/c/*.c | grep -vE "_(WGL|GLX)[A-Za-z0-9_]*\.c$|_opengl_(WGL|GLX)\.c$")
build_lib opengl "$OUT/liblwjgl_opengl.dylib" -I"$M/opengl/src/main/c" -- $OPENGL_SRCS

# ⚠️ stb 는 헤더 전용 라이브러리다. stb_vorbis.c 조차 생성 소스가 #include 하므로
#    따로 컴파일하면 같은 심볼이 두 번 생겨 링크가 깨진다. include 경로만 준다.
build_lib stb "$OUT/liblwjgl_stb.dylib" \
  -I"$M/stb/src/main/c" -- "$M"/stb/src/generated/c/*.c

build_lib tinyfd "$OUT/liblwjgl_tinyfd.dylib" \
  -I"$M/tinyfd/src/main/c" -- "$M"/tinyfd/src/generated/c/*.c "$M"/tinyfd/src/main/c/*.c

# nanovg 는 빌드하지 않는다.
#
# fontstash 가 stb_truetype 의 **구현**을 요구해서 정의 순서를 맞춰야 하는데,
# 마인크래프트는 nanovg 를 한 번도 호출하지 않는다(26.2 의 LWJGL 호출 942건 전수 확인).
# 기존 3.3.3 판 liblwjgl_nanovg.dylib 을 그대로 둔다 — 아무도 열지 않으므로 문제없다.

echo
echo "완료 — LWJGL $REF 네이티브"
