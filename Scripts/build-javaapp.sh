#!/bin/bash
#
# Amethyst-iOS 의 JavaApp 을 우리 앱 이름으로 빌드해 Runtime/libs 에 넣는다.
#
# ── 왜 필요한가 ──────────────────────────────────────────────────────────────
# 순정 LWJGL 은 GLFW 를 `libglfw.dylib` 파일에서 찾는다. iOS 에는 그런 파일이 없다 —
# GLFW 구현이 **앱 실행 파일 안**에 있기 때문이다. 그래서 Amethyst 는 org.lwjgl.glfw.GLFW
# 를 직접 다시 써서, 앱 실행 파일을 dlopen 하고 RTLD_DEFAULT 로 심볼을 찾게 만든다:
#
#     System.load(System.getenv("BUNDLE_PATH") + "/AngelAuraAmethyst");
#     new MacOSXLibraryDL("AngelAuraAmethyst", DynamicLinkLoader.RTLD_DEFAULT);
#
# 실행 파일 이름이 **하드코딩**돼 있으므로 우리 이름으로 바꿔서 컴파일해야 한다.
#
# 또 Amethyst 는 순정 lwjgl*.jar 들을 전부 풀어 META-INF 를 지우고(네이티브 추출
# 메타데이터 제거) 패치 클래스를 덮어써서 **하나의 lwjgl.jar** 로 합친다.
# 저장소에 있는 JavaApp/libs/lwjgl/*.jar 은 그 **입력**이지 결과물이 아니다.
#
# 산출물 (Runtime/libs/):
#   lwjgl.jar           병합·패치된 LWJGL (GLFW 가 앱 바이너리를 가리킨다)
#   launcher.jar        text2speech 스텁 등 iOS 용 대체 클래스
#   patchjna_agent.jar  JNA 의 Platform 을 iOS 로 인식시키는 자바 에이전트
#
# 사용:  Scripts/build-javaapp.sh [ref]
set -euo pipefail

# 패치 결과를 읽을 수 있는 diff 로 내보낸다(build-mobileglues.sh 의 같은 함수 참고).
emit_patch() {   # emit_patch <저장소경로> <이름>
    [ -n "${EMIT_PATCH_DIR:-}" ] || return 0
    mkdir -p "$EMIT_PATCH_DIR"
    git -C "$1" add -A >/dev/null 2>&1
    git -C "$1" diff --cached > "$EMIT_PATCH_DIR/$2.patch"
    printf '  패치 저장: %s.patch (%s줄)\n' "$2" "$(wc -l < "$EMIT_PATCH_DIR/$2.patch" | tr -d ' ')"
}

REPO="https://github.com/AngelAuraMC/Amethyst-iOS.git"
REF="${1:-main}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
EXEC_NAME="FlameLauncher"          # 앱 실행 파일 이름 — GLFW.java 에 박아 넣는다
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Amethyst 는 Java 8 로 빌드한다(클래스 파일 52 — 8/17/21 어디서든 돌아간다).
# ⚠️ `java_home -v 8` 은 JDK 26 을 돌려준다(느슨한 매칭). Java 8 은 "1.8" 로 골라야 한다.
#    JDK 9+ 로 컴파일하면 com.apple.eawt / sun.font 가 모듈에 가려 "not visible" 로 깨진다.
BOOTJDK="${BOOTJDK:-}"
if [ -z "$BOOTJDK" ]; then
  home="$(/usr/libexec/java_home -v 1.8 2>/dev/null || true)"
  [ -n "$home" ] && BOOTJDK="$home/bin"
fi
[ -n "$BOOTJDK" ] || { echo "Java 8 JDK 가 필요합니다: brew install --cask temurin@8"; exit 1; }
case "$("$BOOTJDK/javac" -version 2>&1)" in
  *" 1.8."*) ;;
  *) echo "Java 8 이 아닙니다: $("$BOOTJDK/javac" -version 2>&1)"; exit 1 ;;
esac
echo "▸ JDK: $BOOTJDK ($("$BOOTJDK/javac" -version 2>&1))"

echo "▸ Amethyst-iOS ($REF) 받는 중…"
git clone --depth 1 --branch "$REF" "$REPO" "$WORK/src" >/dev/null 2>&1

echo "▸ 실행 파일 이름을 $EXEC_NAME 로 치환"
grep -rl "AngelAuraAmethyst" "$WORK/src/JavaApp/src" \
  | xargs sed -i '' "s/AngelAuraAmethyst/$EXEC_NAME/g"

# ── LWJGL 3.4.1 로 넓어진 표면 메우기 ─────────────────────────────────────────
#
# 마인크래프트 26.2 는 LWJGL 3.4.1 을 쓰는데 우리 병합본은 3.3.3 이다. blaze3d 전체를
# 리플렉션으로 대조해 보니 부팅 경로에서 빠지는 건 얼마 되지 않는다. 그중 **네이티브가
# 필요 없는 것**만 여기서 채운다.
# ── LWJGL 을 3.4.1 로 올린다 ──────────────────────────────────────────────────
#
# 마인크래프트 26.2 는 LWJGL 3.4.1 을 쓴다. 3.3.3 위에 빠진 것만 얹으려 했더니
# `Callback$Descriptor` 처럼 **코어 자체가 달라진 부분**에서 막혔다
# (3.4.1 의 콜백 인터페이스가 3.3.3 Callback 과 바이너리 호환이 아니다).
#
# Amethyst 가 패치하는 소스는 8개뿐(GLFW, Callbacks, GLFWNative*, …)이라
# 입력 jar 만 3.4.1 로 갈아끼우고 그 위에 다시 얹는 편이 깔끔하다.
#
# ⚠️ 네이티브(liblwjgl*.dylib)는 여전히 3.3.3 판이다. GLFW 는 Amethyst 가 자바로
#    다시 써서 우리 브릿지로 보내므로 영향이 없지만, 나머지 모듈은 심볼이 어긋나면
#    거기서 드러난다. 드러나면 그 모듈만 되돌린다.
# ⚠️ 기본값은 **비워 둔다.** Amethyst 가 함께 배포하는 3.3.3 판이 검증된 조합이다.
#    3.4.1 로 올리면 마인크래프트 26.2 의 API 격차는 사라지지만, **1.21.x 가 깨진다**
#    (Iris 의 glGenSamplers 가 NULL 로 잡혀 부팅 중 JVM 이 죽는 것까지 확인했다).
#    올려 쓰려면 명시적으로:  LWJGL_VERSION=3.4.1 Scripts/build-javaapp.sh
#    그때는 Scripts/build-lwjgl-natives.sh 로 네이티브도 같은 버전으로 맞춰야 한다.
LWJGL_VERSION="${LWJGL_VERSION:-}"
# ⚠️ lwjgl-sdl 은 26.3 부터 필요하다. 그 버전이 GLFW 를 **완전히 버리고** SDL3 로
#    갔기 때문이다(26.3 의 version.json 에 glfw 라이브러리가 0개다).
#    바닐라 jar 을 클래스패스에 섞으면 안 되고(아래 shouldDropVanillaLwjgl 주석 참고)
#    이렇게 병합본 안에 넣어야 한다 — 26.2 의 spvc 와 같은 처리다.
#    코어 쪽 준비는 이미 돼 있다: 3.4.1 의 Configuration 에 SDL_LIBRARY_NAME 이 있다.
LWJGL_MODULES="lwjgl lwjgl-glfw lwjgl-opengl lwjgl-openal lwjgl-stb lwjgl-tinyfd \
               lwjgl-vma lwjgl-freetype lwjgl-vulkan lwjgl-nanovg lwjgl-shaderc \
               lwjgl-spvc lwjgl-jemalloc lwjgl-sdl"
if [ -n "$LWJGL_VERSION" ]; then
echo "▸ LWJGL $LWJGL_VERSION 로 입력 jar 교체"
# lwjglx(레거시 호환)는 업스트림 LWJGL 이 아니라 그대로 둔다.
find "$WORK/src/JavaApp/libs/lwjgl" -name 'lwjgl*.jar' ! -name 'lwjgl-lwjglx.jar' -delete
for m in $LWJGL_MODULES; do
  url="https://repo1.maven.org/maven2/org/lwjgl/$m/$LWJGL_VERSION/$m-$LWJGL_VERSION.jar"
  if curl -sS -L --fail --retry 3 "$url" -o "$WORK/src/JavaApp/libs/lwjgl/$m.jar"; then
    printf '    %-18s %s\n' "$m" "$(du -h "$WORK/src/JavaApp/libs/lwjgl/$m.jar" | cut -f1)"
  else
    echo "    $m 실패 — 이 모듈 없이 진행합니다"
    rm -f "$WORK/src/JavaApp/libs/lwjgl/$m.jar"
  fi
done
fi

echo "▸ LWJGL 3.4.1 호환 보강"
python3 - "$WORK/src/JavaApp/src/lwjgl/org/lwjgl/glfw/GLFW.java" "$LWJGL_VERSION" <<'GLFWPATCH'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
s = p.read_text()

# 0) JNI.invokeI 시그니처 변화 (3.4.3).
#
#    3.4.1 까지는 boolean 을 그대로 넘겼는데 3.4.3 에서 int 만 받게 바뀌었다:
#      GLFW.java:796: error: incompatible types: boolean cannot be converted to int
#        isGLFWReady = invokeI(!isCalledFromLWJGLX, __functionAddress) != 0;
#
#    26.3 은 GLFW 를 아예 안 쓰지만(SDL3 로 갔다) 이 파일은 여전히 컴파일돼야 한다.
old = "invokeI(!isCalledFromLWJGLX, __functionAddress)"
if old in s:
    s = s.replace(old, "invokeI(!isCalledFromLWJGLX ? 1 : 0, __functionAddress)")
    print("  GLFW.java: invokeI 에 boolean→int (3.4.3)")

# 1) glfwPlatformSupported — 26.2 의 GLX._initGlfw 가 부팅 첫머리에 부른다.
#    없으면 NoSuchMethodError 로 게임 초기화 단계에서 죽는다.
old = "        return GLFW_PLATFORM_X11;\n    }"
assert old in s, "glfwGetPlatform 본문을 못 찾았습니다 (업스트림이 바뀜)"
s = s.replace(old, old + """

    /** LWJGL 3.4.1. 우리가 보고하는 플랫폼 하나만 지원한다고 답한다.
     *  26.2 는 X11/Wayland 지원 여부를 물어 glfwInitHint(GLFW_PLATFORM, ...) 을 정한다. */
    public static boolean glfwPlatformSupported(int platform) {
        return platform == glfwGetPlatform();
    }""", 1)

# 2) glfwGetMonitorName — Monitor 초기화가 부른다.
anchor = "    public static PointerBuffer glfwGetMonitors() {"
assert anchor in s, "glfwGetMonitors 를 못 찾았습니다 (업스트림이 바뀜)"
# ⚠️ 앵커 바로 위에 이미 @Nullable 이 붙어 있다. 여기서 또 붙이면
#    "Nullable is not a repeatable annotation type" 으로 컴파일이 깨진다.
s = s.replace(anchor, """    /** LWJGL 3.4.1. 화면이 하나뿐이라 고정 이름을 돌려준다. */
    public static String glfwGetMonitorName(@NativeType("GLFWmonitor *") long monitor) {
        return "iOS Display";
    }

""" + anchor, 1)
# 2.5) glfwGetInputMode 가 설정된 적 없는 모드에서 NPE 로 죽는다.
#
#      원본:  return internalGetWindow(window).inputModes.get(mode);
#      inputModes 는 빈 HashMap 이고 반환값을 그대로 int 로 언박싱한다. 그래서
#      **한 번도 glfwSetInputMode 로 설정하지 않은 모드**를 물으면 무조건 NPE 다.
#
#      마인크래프트 26.2 가 매 틱 GLFW_IME(0x33007, 3.4 에서 새로 생긴 모드)를 묻는다:
#        NullPointerException: Cannot invoke "java.lang.Integer.intValue()"
#          at org.lwjgl.glfw.GLFW.glfwGetInputMode
#          at com.mojang.blaze3d.platform.TextInputManager.getIMEStatus
#          at net.minecraft.client.Minecraft.tick
#
#      IME 만 특별히 봐 주는 대신 함수 하나에서 막는다 — 나머지 모드도 똑같이 위험하다.
#      기본값은 실제 GLFW 와 맞춘다: 커서는 NORMAL, 그 밖엔 FALSE.
#      (3.3.3 에도 있는 잠재 버그라 버전과 무관하게 넣는다.)
old = "        return internalGetWindow(window).inputModes.get(mode);"
assert old in s, "glfwGetInputMode 본문을 못 찾았습니다 (업스트림이 바뀜)"
s = s.replace(old, """        Integer value = internalGetWindow(window).inputModes.get(mode);
        if (value != null) return value;
        return mode == GLFW_CURSOR ? GLFW_CURSOR_NORMAL : GLFW_FALSE;""", 1)

# 3) IME / preedit — 26.2 의 KeyboardHandler.setup 이 창을 만들자마자 등록한다.
#    ⚠️ GLFWPreeditCallback* 타입은 LWJGL 3.4.1 에만 있다. 3.3.3 입력 jar 로 빌드할 때
#       넣으면 "cannot find symbol" 로 컴파일이 깨진다. 버전을 올릴 때만 넣는다.
if len(sys.argv) > 2 and sys.argv[2]:
#    iOS 에는 preedit 개념이 없다(문자 입력은 우리 오버레이가 직접 흘려 넣는다).
#    등록만 받아주고 아무 일도 하지 않는다. 반환값은 "이전 콜백 없음" 이라 null 이다.
    anchor = "    public static PointerBuffer glfwGetMonitors() {"
    s = s.replace(anchor, """    /** LWJGL 3.4.1 / IME. iOS 에는 preedit 이 없다 — 등록만 받는다. */
    public static GLFWPreeditCallback glfwSetPreeditCallback(long window, GLFWPreeditCallbackI cbfun) {
        return null;
    }

    /** LWJGL 3.4.1 / IME. 위와 같다. */
    public static GLFWIMEStatusCallback glfwSetIMEStatusCallback(long window, GLFWIMEStatusCallbackI cbfun) {
        return null;
    }

    /** LWJGL 3.4.1 / IME. 후보창 위치 — iOS 키보드는 스스로 자리를 잡는다. */
    public static void glfwSetPreeditCursorRectangle(long window, int x, int y, int w, int h) {
    }

""" + anchor, 1)

p.write_text(s)
print("  GLFW.java: glfwPlatformSupported / glfwGetMonitorName"
      + (" / IME 3종" if len(sys.argv) > 2 and sys.argv[2] else ""))
GLFWPATCH

emit_patch "$WORK/src" amethyst-javaapp

echo "▸ 컴파일"
# ⚠️ stdout 을 버리지 않는다. 예전에는 `>/dev/null` 이었는데, Makefile 의 검사들이
#    실패 이유를 **stdout 으로** 말한다(check_empty_classes 가 어떤 파일이 비었는지
#    echo 한다). 그걸 버리면 `make: *** [check_empty_classes] Error 1` 만 남아서
#    무엇이 잘못됐는지 알 수 없다 — 실제로 두 번 헤맸다.
if ! make -C "$WORK/src/JavaApp" -j"$(sysctl -n hw.ncpu)" BOOTJDK="$BOOTJDK" > "$WORK/make.log" 2>&1; then
  echo "▸ make 실패 — 마지막 40줄:"
  tail -40 "$WORK/make.log" | sed 's/^/    /'
  exit 1
fi

BUILD="$WORK/src/JavaApp/build"
echo "▸ FlameLauncher 자체 부트스트랩 컴파일"
# Forge/NeoForge 프로세서를 게임 JVM 안에서 돌리는 래퍼. (JavaSrc/ 참고)
mkdir -p "$WORK/flame"
# ⚠️ FlameAllocator 는 org.lwjgl.system.MemoryUtil.MemoryAllocator 를 구현한다 —
#    방금 만든 lwjgl.jar 을 컴파일 클래스패스에 넣어야 한다(런타임에도 같은 jar 을 쓴다).
"$BOOTJDK/javac" -cp "$BUILD/lwjgl.jar" -d "$WORK/flame" $(find "$ROOT/JavaSrc" -name '*.java')
# ⚠️ 매니페스트가 있어야 한다 — 이 jar 은 **자바 에이전트이기도 하다**(IosFsAgent).
#    Premain-Class 가 없으면 -javaagent 가 조용히 실패하고, toRealPath 가 다시 막힌다.
cat > "$WORK/agent-manifest.txt" <<'MANIFEST'
Premain-Class: kr.co.donghyun.flame.IosFsAgent
Can-Retransform-Classes: true
MANIFEST
"$BOOTJDK/jar" -cfm "$BUILD/flame_bootstrap.jar" "$WORK/agent-manifest.txt" -C "$WORK/flame" .

echo "▸ text2speech 스텁 보강"
# ⚠️ 원본 text2speech jar 은 클래스패스에서 뺀다(Forge 모듈 경로에서 같은 패키지를 두
#    모듈이 export 하면 부팅이 막힌다). 그런데 Amethyst 의 대체 스텁에는
#    Narrator.InitializeException 이 없어서 MinecraftClient.<init> 이 그 타입을 풀다
#    NoClassDefFoundError 로 죽는다. 중첩 클래스 하나만 만들어 넣는다.
#    (바깥 Narrator 는 컴파일용 껍데기라 버린다 — launcher.jar 것을 그대로 쓴다)
mkdir -p "$WORK/t2s"
"$BOOTJDK/javac" -d "$WORK/t2s" $(find "$ROOT/JavaPatches" -name '*.java')
# 껍데기(Narrator / NarratorDummy)는 버리고 빠진 것만 넣는다 — JavaPatches/README.md 참고.
"$BOOTJDK/jar" uf "$BUILD/launcher.jar" \
  -C "$WORK/t2s" 'com/mojang/text2speech/Narrator$InitializeException.class' \
  -C "$WORK/t2s" 'com/mojang/text2speech/OperatingSystem.class' \
  -C "$WORK/t2s" 'com/mojang/text2speech/NarratorMac.class'

# ⚠️ 26.3+ 의 macOS 전용 창 손질을 끈다. 마인크래프트는 os.name 만 보고 macOS 분기를
#    타는데(iOS 는 "Mac OS X" 로 보고된다) 그 안쪽이 Rococoa → JNA → AppKit 이라
#    iOS 에서 NoClassDefFoundError 로 부팅이 끝난다. Error 라 try/catch 에도 안 걸린다:
#      at ca.weblite.objc.Runtime.<clinit>
#      at com.mojang.blaze3d.platform.MacosUtil.disableCloseWindowMenuItem
#      at com.mojang.blaze3d.platform.Window.<init>
#    com.mojang.blaze3d 는 난독화되지 않고 launcher.jar 이 클래스패스 맨 앞이라
#    이렇게 가릴 수 있다. (JavaPatches/com/mojang/blaze3d/platform/MacosUtil.java)
"$BOOTJDK/jar" uf "$BUILD/launcher.jar" \
  -C "$WORK/t2s" 'com/mojang/blaze3d/platform/MacosUtil.class'

for j in lwjgl.jar launcher.jar patchjna_agent.jar flame_bootstrap.jar; do
  [ -f "$BUILD/$j" ] || { echo "빌드 산출물 없음: $j"; exit 1; }
done

# LWJGL 을 올려 빌드할 때는 **별도 폴더**에 넣는다. 기본 스택(libs/)은 건드리지 않는다.
LIBS_DIR="Runtime/libs"
if [ -n "$LWJGL_VERSION" ]; then
  LIBS_DIR="Runtime/libs341"
  echo "▸ $LIBS_DIR (LWJGL $LWJGL_VERSION 전용 — 기본 libs/ 는 그대로 둔다)"
fi

echo "▸ $LIBS_DIR 교체"
# 순정 입력 jar 들은 지운다 — 병합본과 같이 두면 어느 쪽 클래스가 이길지 알 수 없다.
rm -f "$ROOT/$LIBS_DIR"/*.jar
mkdir -p "$ROOT/$LIBS_DIR"
cp "$BUILD"/lwjgl.jar "$BUILD"/launcher.jar "$BUILD"/patchjna_agent.jar \
   "$BUILD"/flame_bootstrap.jar "$ROOT/$LIBS_DIR/"

# Amethyst 가 별도로 번들하는 런타임 의존성.
#
# ⚠️ 여기 넣는 것은 **게임 라이브러리를 가린다.** Runtime/libs 가 클래스패스 맨 앞이라
#    (패치된 LWJGL 이 먼저 와야 해서) 같은 라이브러리를 게임도 들고 있으면 우리 것이 이긴다.
#    실제로 gson 2.13.1 이 마인크래프트의 2.10.1 을 가려서 모드가 죽었다:
#    2.11 부터 TypeToken 이 타입 변수를 거부하는데(verifyNoTypeVariable), 그걸 쓰는
#    모드(rctmod → CobbleVerse)가 "TypeToken type argument must not contain a type
#    variable" 로 부팅 중에 터진다. 데스크톱·안드로이드는 2.10.1 이라 멀쩡하다.
#
#    그래서 **우리 코드가 실제로 쓰는 것만** 가져온다. 지금은 없다
#    (lwjgl/launcher/patchjna/flame_bootstrap 넷 다 gson·jsr305 를 참조하지 않는다).
for j in "$WORK/src/JavaApp/libs/others"/*.jar; do
  [ -e "$j" ] || continue
  case "$(basename "$j")" in
    arc_dns_injector.jar) continue ;;   # 선택 기능(DNS 우회) — 쓰지 않는다
    gson*.jar|jsr305*.jar) continue ;;  # 게임 것을 가린다 — 위 설명 참고
  esac
  cp "$j" "$ROOT/$LIBS_DIR/"
done

echo
echo "완료:"
ls -la "$ROOT/$LIBS_DIR"
echo
echo "⚠️ Xcode 프로젝트를 다시 만들어야 합니다: xcodegen generate"
