#!/bin/bash
#
# 테라코타(陶瓦联机)를 iOS(arm64) 정적 라이브러리로 빌드해 Runtime/Terracotta 에 넣는다.
#
# ── 왜 PCL 포크인가 ──────────────────────────────────────────────────────────
# 원본 burningtnt/Terracotta 는 iOS 에서 **빌드 자체가 불가능**하다. EasyTier 실행
# 파일을 7z 로 품고 있다가 자식 프로세스로 띄우는 구조인데, iOS 샌드박스는 프로세스
# 생성을 막는다. build.rs 가 그걸 미리 잘라낸다:
#     thread 'main' panicked at build.rs:185:
#     Cannot compile Terracotta on ios-aarch64: Cannot find valid EasyTier binary.
# PCL-Community/Terracotta-lib 는 EasyTier 를 **크레이트로 링크**하도록 갈라져 나온
# 포크라 프로세스를 띄우지 않는다. iOS 에서 쓸 수 있는 건 이쪽뿐이다.
#
# ── 네 군데를 맞춰야 컴파일된다 ───────────────────────────────────────────────
# 놀랍게도 **iOS 고유의 컴파일 실패는 한 군데뿐**이다. 나머지 셋은 전부 의존성
# 버전이 어긋난 것이고, 테라코타 코드 자체는 플랫폼 분기를 그냥 통과한다.
#
#   1) Cargo.toml       easytier 가 `branch = "main"` 으로 묶여 있어 2.7.0 을 끌어온다.
#                       거기서는 워크스페이스가 쪼개져 `easytier::launcher` 와
#                       `easytier::tunnel::insecure_tls` 가 사라졌다. 정작 이 저장소는
#                       [package.metadata.easytier] 에 기대 버전을 적어 두고 있다.
#   2) Cargo.toml       그 태그(v2.5.0-terracotta.2)는 EasyTier 본가에 없다.
#                       burningtnt/EasyTier 포크에만 있다.
#   3) EasyTier         common/network.rs 의 InterfaceFilter 에 iOS 구현이 없다.
#      network.rs       → **유일한 진짜 iOS 패치.** macOS 판은 `networksetup` CLI 를
#                       부르는데 iOS 엔 그 명령이 없다. 모바일에서는 인터페이스를
#                       걸러낼 수단이 없으므로 안드로이드 분기(전부 통과)에 얹는다.
#   4) src/rooms/mod.rs PeerConfig.peer_public_key 를 쓰는데 위 태그에는 없는 필드다
#                       (포크 코드가 자기가 선언한 EasyTier 보다 앞서 있다).
#                       None 을 넣던 선택 필드라 지운다.
#
# ── 산출물 ──────────────────────────────────────────────────────────────────
# libterracotta.a (arm64, platform=iOS). FFI 는 아직 JNI 전용이라 이 라이브러리만으로는
# 스위프트에서 부를 수 없다 — iOS 용 C FFI 는 다음 단계에서 얹는다.
#
# 사용:  Scripts/build-terracotta.sh [--release]
set -euo pipefail

# ── 패치 결과를 읽을 수 있는 diff 로 내보낸다 ────────────────────────────────
# 저장소에 "고쳐진 모듈"을 남기려면 업스트림 트리를 통째로 벤더링해야 하는데,
# 서브모듈까지 합치면 수백 MB 다. 스크립트가 git 클론 위에서 고치므로
# `git diff` 가 곧 우리가 만든 변경 전부다 — 그걸 파일로 남긴다.
emit_patch() {   # emit_patch <저장소경로> <이름>
    [ -n "${EMIT_PATCH_DIR:-}" ] || return 0
    mkdir -p "$EMIT_PATCH_DIR"
    git -C "$1" add -A >/dev/null 2>&1
    git -C "$1" diff --cached > "$EMIT_PATCH_DIR/$2.patch"
    printf '  패치 저장: %s.patch (%s줄)\n' "$2" "$(wc -l < "$EMIT_PATCH_DIR/$2.patch" | tr -d ' ')"
}

TC_REPO="https://github.com/PCL-Community/Terracotta-lib.git"
ET_REPO="https://github.com/burningtnt/EasyTier.git"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PROFILE="debug"
CARGO_FLAGS=()
if [ "${1:-}" = "--release" ]; then
  PROFILE="release"
  CARGO_FLAGS=(--release)
fi

export PATH="$HOME/.cargo/bin:$PATH"
export IPHONEOS_DEPLOYMENT_TARGET=14.0

command -v cargo >/dev/null || {
  echo "cargo 가 필요합니다: curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh"; exit 1; }
command -v rustup >/dev/null || {
  echo "rustup 이 필요합니다(홈브류 rust 는 타깃을 추가할 수 없습니다)."; exit 1; }
rustup target list --installed | grep -qx aarch64-apple-ios || {
  echo "▸ aarch64-apple-ios 타깃 추가"; rustup target add aarch64-apple-ios >/dev/null; }

# ── 기대 EasyTier 버전은 저장소가 직접 적어 둔다. 추측하지 않는다. ──
echo "▸ Terracotta-lib 받는 중…"
git clone --depth 1 "$TC_REPO" "$WORK/terracotta" >/dev/null 2>&1
TC="$WORK/terracotta"

ET_TAG="$(sed -n '/\[package.metadata.easytier\]/,/^\[/p' "$TC/Cargo.toml" \
          | sed -n 's/^version *= *"\(.*\)"/\1/p' | head -1)"
[ -n "$ET_TAG" ] || { echo "Cargo.toml 에서 기대 EasyTier 버전을 못 읽었습니다"; exit 1; }
echo "  기대 EasyTier: $ET_TAG"

echo "▸ EasyTier ($ET_TAG) 받는 중…"
git clone --depth 1 --branch "$ET_TAG" "$ET_REPO" "$WORK/easytier" >/dev/null 2>&1

echo "▸ 패치 적용"
python3 - "$TC" "$WORK/easytier" "$ET_TAG" <<'PATCHES'
import pathlib, sys

tc, et, tag = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]), sys.argv[3]

# 1)+2) easytier 를 포크의 해당 태그로 고정한다.
p = tc / "Cargo.toml"
s = p.read_text()
old = 'easytier = { git = "https://github.com/EasyTier/EasyTier.git", branch = "main"}'
assert old in s, "Cargo.toml: easytier 의존성 줄을 못 찾았습니다 (업스트림이 바뀜)"
s = s.replace(old, f'easytier = {{ git = "https://github.com/burningtnt/EasyTier.git", tag = "{tag}" }}', 1)

# 우리가 손본 로컬 체크아웃을 쓰게 한다.
assert "[patch." not in s, "Cargo.toml 에 이미 [patch] 가 있습니다 (업스트림이 바뀜)"
s += (
    '\n[patch."https://github.com/burningtnt/EasyTier.git"]\n'
    f'easytier = {{ path = "{et / "easytier"}" }}\n'
)

# iOS 는 정적 라이브러리로 링크한다. cdylib 은 앱 번들에 dylib 을 하나 더 넣고
# 서명까지 붙여야 해서, 단일 .a 로 받는 편이 배선이 단순하다.
old = 'crate-type = ["lib", "cdylib"]'
assert old in s, "Cargo.toml: crate-type 을 못 찾았습니다 (업스트림이 바뀜)"
s = s.replace(old, 'crate-type = ["lib", "staticlib"]', 1)
p.write_text(s)
print("  Cargo.toml: easytier 고정 + staticlib")

# 3) EasyTier 의 InterfaceFilter 에 iOS 가 없다. **유일한 진짜 iOS 패치.**
p = et / "easytier/src/common/network.rs"
s = p.read_text()
old = '#[cfg(any(target_os = "android", target_env = "ohos"))]\nimpl InterfaceFilter {'
assert old in s, "network.rs: InterfaceFilter 의 안드로이드 분기를 못 찾았습니다 (업스트림이 바뀜)"
s = s.replace(old, (
    '// iOS 는 안드로이드와 같은 길로 간다. macOS 구현은 `networksetup` CLI 를 부르는데\n'
    '// iOS 엔 그 명령이 없고, 모바일에서는 인터페이스를 걸러낼 수단도 없다 — 전부 받는다.\n'
    '#[cfg(any(target_os = "android", target_env = "ohos", target_os = "ios"))]\n'
    'impl InterfaceFilter {'
), 1)
p.write_text(s)
print("  easytier/common/network.rs: InterfaceFilter 에 iOS 추가")

# 3.5) iOS 용 C FFI 를 얹는다.
#
#      업스트림 FFI 는 JNI 뿐이다(ffi/TerracottaAndroidAPI.java). 그런데 **제어 표면이
#      이미 HTTP 로 다 나와 있다** — 데스크톱 UI 가 그걸 쓴다:
#          GET /state/            현재 상태(JSON)
#          GET /state/ide         대기 상태로
#          GET /state/scanning    방 열기(호스트)
#          GET /state/guesting    방 참가(게스트)
#          GET /log, /meta, /panic
#      그래서 스위프트에서 필요한 네이티브 함수는 **서버를 띄우는 하나뿐**이다.
#      나머지는 전부 HTTP 로 부른다. 호출마다 FFI 를 손으로 짜는 것보다 표면이 작고,
#      업스트림이 API 를 바꿔도 깨질 자리가 적다.
p = tc / "src/lib.rs"
s = p.read_text()

# HTTP 서버 모듈은 main.rs 에만 선언돼 있어서 라이브러리 빌드에는 들어오지 않는다.
# iOS 는 실행 파일이 아니라 이 라이브러리를 링크하므로 여기서 끌어온다.
# 같이 딸려 와야 하는 것이 둘 있다:
#   - rocket 의 #[get] / routes! 매크로 (main.rs 의 #[macro_use] 로 들어오던 것)
#   - LOGGING_FILE (main.rs 의 lazy_static — /log 엔드포인트가 읽는다)
# 전부 iOS 로 묶어 안드로이드·데스크톱 빌드는 건드리지 않는다.
anchor = "pub mod rooms;"
assert anchor in s, "lib.rs: 모듈 선언부를 못 찾았습니다 (업스트림이 바뀜)"
s = s.replace(anchor, anchor + """
#[cfg(target_os = "ios")]
pub mod server;

#[cfg(target_os = "ios")]
#[macro_use]
extern crate rocket;

#[cfg(target_os = "ios")]
lazy_static::lazy_static! {
    /// 로그 파일. 데스크톱은 작업 디렉터리에 두지만 iOS 에서는 앱이 정해 준
    /// 데이터 디렉터리(terracotta_ios_start 의 인자) 아래에 둔다.
    pub static ref LOGGING_FILE: std::path::PathBuf =
        IOS_DATA_DIR.lock().unwrap().clone().unwrap_or_else(std::env::temp_dir).join("application.log");
}

#[cfg(target_os = "ios")]
static IOS_DATA_DIR: std::sync::Mutex<Option<std::path::PathBuf>> = std::sync::Mutex::new(None);""", 1)

anchor = "pub fn init_lib(machine_id: PathBuf) {"
assert anchor in s, "lib.rs: init_lib 를 못 찾았습니다 (업스트림이 바뀜)"
s = s.replace(anchor, """/// iOS 진입점. 로컬 제어 서버를 띄우고 **실제로 열린 포트**를 돌려준다.
///
/// 로켓을 포트 0 으로 띄워 OS 가 고르게 하고(고정 포트는 다른 앱과 부딪힌다),
/// liftoff 콜백으로 받은 값을 그대로 넘긴다. 실패하면 0.
///
/// 이 함수는 **블로킹이다.** 서버가 뜰 때까지만 기다리고 바로 돌아온다 —
/// 서버 자체는 전용 스레드의 토키오 런타임에서 계속 돈다.
#[cfg(target_os = "ios")]
#[unsafe(no_mangle)]
pub extern "C" fn terracotta_ios_start(data_dir: *const std::ffi::c_char) -> u16 {
    if data_dir.is_null() {
        return 0;
    }
    let dir = match unsafe { std::ffi::CStr::from_ptr(data_dir) }.to_str() {
        Ok(v) => PathBuf::from(v),
        Err(_) => return 0,
    };

    static STARTED: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);
    // 두 번 띄우면 로켓이 패닉한다. 한 번만 허용하고, 이후 호출은 0 을 돌려준다.
    if STARTED.swap(true, std::sync::atomic::Ordering::SeqCst) {
        return 0;
    }

    let _ = std::fs::create_dir_all(&dir);
    // LOGGING_FILE 이 처음 읽힐 때 이 값을 쓴다 — init_lib 보다 먼저 넣어야 한다.
    *IOS_DATA_DIR.lock().unwrap() = Some(dir.clone());
    init_lib(dir.join("machine-id"));

    let (tx, rx) = std::sync::mpsc::channel::<u16>();
    // `use std::thread` 는 안드로이드 분기 안에만 있다 — 완전 경로로 쓴다.
    std::thread::spawn(|| {
        lazy_static::initialize(&controller::SCAFFOLDING_PORT);
    });
    std::thread::spawn(move || {
        let rt = match ::rocket::tokio::runtime::Builder::new_multi_thread()
            .enable_all()
            .build()
        {
            Ok(rt) => rt,
            Err(_) => return,
        };
        rt.block_on(crate::server::server_main(tx));
    });

    // 로켓이 실제로 떠서 포트를 알려줄 때까지만 기다린다.
    rx.recv_timeout(std::time::Duration::from_secs(30)).unwrap_or(0)
}

""" + anchor, 1)
p.write_text(s)
print("  src/lib.rs: iOS C FFI(terracotta_ios_start) 추가")

# 4) 고정한 태그에 없는 필드를 쓴다.
p = tc / "src/rooms/mod.rs"
s = p.read_text()
old = "                    peer_public_key: None,\n"
assert old in s, "rooms/mod.rs: peer_public_key 줄을 못 찾았습니다 (업스트림이 바뀜)"
s = s.replace(old, "", 1)
p.write_text(s)
print("  src/rooms/mod.rs: 고정 태그에 없는 peer_public_key 제거")
PATCHES

emit_patch "$TC" terracotta
emit_patch "$WORK/easytier" easytier

echo "▸ 빌드 (aarch64-apple-ios, $PROFILE)"
( cd "$TC" && cargo build --target aarch64-apple-ios --lib ${CARGO_FLAGS[@]+"${CARGO_FLAGS[@]}"} >/dev/null )

LIB="$TC/target/aarch64-apple-ios/$PROFILE/libterracotta.a"
[ -f "$LIB" ] || { echo "빌드 산출물이 없습니다"; exit 1; }

# 맥용으로 빠져나오지 않았는지 확인한다. cargo 는 타깃을 틀려도 조용히 성공한다.
#
# ⚠️ `otool … | grep -q …` 로 쓰면 안 된다. grep -q 가 첫 일치에서 끝나면서 otool 이
#    SIGPIPE 로 죽고, `set -o pipefail` 이 그 실패를 파이프라인 결과로 삼는다 —
#    검사가 통과해도 스크립트가 여기서 멈춘다(실제로 겪음).
ARCH="$(lipo -info "$LIB")"
case "$ARCH" in *arm64*) ;; *) echo "arm64 가 아닙니다: $ARCH"; exit 1 ;; esac

PLATFORMS="$(otool -l "$LIB" | sed -n 's/^ *platform //p' | sort -u)"
# platform 2 = iOS. 맥용이면 1(macOS), 시뮬레이터면 7 이 섞여 나온다.
[ "$PLATFORMS" = "2" ] || { echo "iOS 전용이 아닙니다 (platform=$PLATFORMS)"; exit 1; }

mkdir -p "$ROOT/Runtime/Terracotta"
cp "$LIB" "$ROOT/Runtime/Terracotta/libterracotta.a"
echo
echo "완료: Runtime/Terracotta/libterracotta.a ($(du -h "$LIB" | cut -f1))"
echo "  arm64 · iOS · minos $(otool -l "$LIB" | sed -n 's/^ *minos //p' | sort -u | head -1)"
