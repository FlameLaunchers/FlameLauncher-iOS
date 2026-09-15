#!/bin/bash
#
# SPIRV-Cross 의 C 공유 라이브러리를 iOS(arm64)용으로 빌드한다.
#
# ── 왜 필요한가 ──────────────────────────────────────────────────────────────
# 마인크래프트 26.2 부터 `NativeLibrariesBootstrap` 이 부팅할 때 **무조건** lwjgl-spvc 를
# 로드한다. LWJGL 의 spvc 바인딩은 자체 JNI 셰임이 없고 업스트림 SPIRV-Cross 의
# C 공유 라이브러리를 그대로 연다(shaderc 와 같은 방식):
#
#     Library.loadNative(Spvc.class, "org.lwjgl.spvc",
#         Configuration.SPVC_LIBRARY_NAME.get(Platform.mapLibraryNameBundled("spirv-cross")), true)
#
# macOS/iOS 에서 그 이름은 그대로 "spirv-cross" 라 `libspirv-cross.dylib` 을 찾는다.
# 그래서 만들 것은 **하나뿐**이다 — 이 파일. (PojavLauncher/Amethyst 에는 없다)
#
# 산출물: Runtime/Frameworks/libspirv-cross.dylib
set -euo pipefail

REPO="https://github.com/KhronosGroup/SPIRV-Cross.git"
REF="${1:-main}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/Runtime/Frameworks/libspirv-cross.dylib"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

command -v cmake >/dev/null || { echo "cmake 가 필요합니다: brew install cmake"; exit 1; }
command -v ninja >/dev/null || { echo "ninja 가 필요합니다: brew install ninja"; exit 1; }

echo "▸ SPIRV-Cross ($REF) 받는 중…"
git clone --depth 1 --branch "$REF" "$REPO" "$WORK/src" >/dev/null 2>&1

echo "▸ 빌드 (arm64, iOS 14+)"
# SPIRV_CROSS_SHARED 가 C API 공유 라이브러리(spirv-cross-c-shared)를 만든다.
# CLI/테스트는 iOS 에서 의미가 없고 링크만 깨뜨린다.
cmake -S "$WORK/src" -B "$WORK/build" -G Ninja \
  -DCMAKE_SYSTEM_NAME=iOS \
  -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 \
  -DCMAKE_BUILD_TYPE=Release \
  -DSPIRV_CROSS_SHARED=ON \
  -DSPIRV_CROSS_STATIC=OFF \
  -DSPIRV_CROSS_CLI=OFF \
  -DSPIRV_CROSS_ENABLE_TESTS=OFF \
  -DBUILD_SHARED_LIBS=OFF >/dev/null
cmake --build "$WORK/build" --target spirv-cross-c-shared -j"$(sysctl -n hw.ncpu)" >/dev/null

BUILT="$(find "$WORK/build" -name 'libspirv-cross-c-shared*.dylib' -print -quit)"
[ -n "$BUILT" ] || { echo "빌드 산출물이 없습니다"; exit 1; }

mkdir -p "$(dirname "$OUT")"
cp "$BUILT" "$OUT"
# LWJGL 은 org.lwjgl.librarypath 에서 파일을 직접 dlopen 한다. install name 이 절대경로로
# 남아 있으면 기기에서 그 경로를 찾다 실패하므로 @rpath 로 바꾼다(다른 dylib 들과 동일).
install_name_tool -id "@rpath/$(basename "$OUT")" "$OUT"

echo
echo "완료: Runtime/Frameworks/$(basename "$OUT") ($(du -h "$OUT" | cut -f1))"
echo "  spvc_* 심볼 $(nm -gU "$OUT" | grep -c ' _spvc_')개"
