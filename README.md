<div align="center">

# 🔥 FlameLauncher for iOS

**마인크래프트 자바 에디션을 iOS 에서 실행하는 런처.**
앱 프로세스 안에 진짜 OpenJDK 를 띄웁니다.

[![Platform](https://img.shields.io/badge/platform-iOS%2014%2B-000000?logo=apple&logoColor=white)](#)
[![Arch](https://img.shields.io/badge/arch-arm64-orange)](#-arm64-전용)
[![License](https://img.shields.io/badge/license-AGPL--3.0-blue)](LICENSE)

</div>

---

안드로이드판 FlameLauncher 를 iOS 로 옮긴 것입니다. SwiftUI 로 새로 그렸지만
색·간격·화면 구성·문구는 안드로이드와 맞췄고, 설치/실행 규칙(폴더 구조, JVM 인자,
GLFW 매핑)도 같습니다.

**게임 파일은 들어 있지 않습니다.** 사용자가 자기 계정으로 Mojang 서버에서 직접 받습니다.

## 목차

- [빌드](#빌드)
- [동작하는 범위](#동작하는-범위)
- [구조](#구조)
- [렌더러](#렌더러)
- [JIT](#jit)
- [LWJGL 두 벌](#lwjgl-두-벌)
- [온라인 LAN (테라코타)](#온라인-lan-테라코타)
- [빌드 스크립트](#빌드-스크립트)
- [알려진 제약](#알려진-제약)
- [라이선스](#라이선스)

---

## 빌드

```bash
brew install xcodegen                 # 최초 1회
cd FlameLauncher-iOS

./Scripts/fetch-runtime.sh            # 렌더러 · LWJGL · JRE (기본 8/17/21, 약 350MB)
xcodegen generate                     # project.yml → FlameLauncher.xcodeproj
open FlameLauncher.xcodeproj
```

JRE 를 골라 받으려면 두 번째 인자로 넘깁니다 — `./Scripts/fetch-runtime.sh main "17 21"`.

`fetch-runtime.sh` 없이도 컴파일은 되지만, 게임을 실행하면 무엇이 없는지 알려주고 멈춥니다.

**추가 네이티브가 필요한 기능**은 각자 스크립트로 만듭니다(전부 선택).

```bash
./Scripts/build-mobileglues.sh        # MobileGlues 렌더러 (셰이더를 쓰려면 필요)
./Scripts/build-terracotta.sh --release  # 온라인 LAN
./Scripts/build-spirv-cross.sh        # 마인크래프트 26.2 의 blaze3d 가 요구
./Scripts/build-lwjgl-natives.sh      # LWJGL 3.4.1 네이티브 (26.2)
LWJGL_VERSION=3.4.1 ./Scripts/build-javaapp.sh   # 26.2 용 자바 스택
```

### arm64 전용

네이티브 브릿지가 arm64 인라인 어셈블리를 쓰고, 가져오는 런타임 dylib 도 전부 arm64 입니다.

**시뮬레이터에서는 게임이 실행되지 않습니다.** JRE·렌더러가 전부 기기용 arm64(iOS 플랫폼)
바이너리라 시뮬레이터가 `dlopen` 하는 순간 코드서명 검증에 걸려 프로세스가 SIGKILL 로 죽습니다
— 잡을 수 있는 예외가 아닙니다. 그래서 시뮬레이터에서는 실행 시도 자체를 막고 사유를 띄웁니다.
UI 작업은 시뮬레이터에서, 실제 실행은 기기에서 하면 됩니다.

---

## 동작하는 범위

| | |
|---|---|
| 바닐라 | 1.7 ~ **26.2** |
| 로더 | Fabric · Forge · NeoForge · Quilt |
| 셰이더 | Iris (MobileGlues 렌더러) |
| 모드팩 | CurseForge · Modrinth (의존성 자동 설치) |
| 계정 | Microsoft |

마인크래프트 **26.3 스냅샷부터는 동작하지 않습니다.** 게임이 윈도잉 라이브러리를
GLFW → SDL3 로 교체했는데, 이 런처(및 PojavLauncher 계열 전반)는 자체 GLFW 구현으로
가로채는 구조라 게임이 GLFW 를 부르지 않으면 그 계층이 통째로 무의미해집니다.

---

## 구조

```
Sources/
├── App/          진입점(UIKit) · 전역 상태 · 방향 고정
├── Model/        인스턴스 · JVM 설정 · 렌더러 · 경로
├── Service/      설치 · 실행 · 인증 · 콘텐츠 API · 테라코타
├── UI/           SwiftUI 화면 전부
├── Input/        터치/게임패드 → GLFW 키 변환
└── Natives/      ObjC·C 계층 (JVM 부팅 · GL 브릿지 · JIT)
```

SwiftUI 앱 라이프사이클이 아니라 **UIKit 진입점**을 씁니다. JLI 가 프로세스 진입점을
다시 호출하기 때문에 진입점을 직접 쥐고 있어야 합니다(PojavLauncher·Amethyst 도 같은 이유).

안드로이드가 화면마다 ViewModel → Repository → UseCase → Mapper 로 다섯 겹을 쌓은 자리를,
여기서는 서비스를 직접 부릅니다. 실제로 하는 일이 "디스크·네트워크를 읽어 화면에 준다" 하나라
중간 계층이 이름만 바꿔 넘기는 구조였습니다.

---

## 렌더러

| | 용도 |
|---|---|
| **MobileGlues** | 기본. 데스크톱 GL → GLES 변환. **셰이더가 되는 유일한 선택** |
| **Zink (MoltenVK)** | Vulkan 경유 |
| **GL4ES** | 구버전 부팅용 |

호스트는 ANGLE Metal 이고 **OpenGL ES 3.0** 입니다. 이 한 줄이 MobileGlues 패치 대부분의
이유입니다 — 업스트림의 iOS 분기는 안드로이드 호스트(ES 3.2)를 전제로 쓰여 있어서,
ES 3.2/3.1 진입점을 그냥 통과시키면 ANGLE 이 심볼은 내보내되 호출은 거부합니다.
**아무 오류 없이 조용히 아무 일도 일어나지 않습니다.**

### 셰이더가 안 되던 진짜 이유

Iris 를 켜면 엔티티와 손에 든 아이템이 **보이지 않았습니다.** 원인은 Metal 의 요구사항입니다.

> Metal 은 정점 포맷의 **부호(signedness)** 가 셰이더 선언과 일치해야 합니다.
> GL 과 GLES 는 요구하지 않습니다.

`ivec3` 로 선언된 속성에 `GL_UNSIGNED_SHORT` 를 물리면 GL 에서는 통과하지만 Metal 은
파이프라인 생성 자체를 거부합니다. `gl/drawing.cpp` 에서 프로그램의 정수 속성을
캐시해 두고 그리기 직전에 부호를 맞춰 다시 걸어 줍니다.

> 이걸 찾는 데 오래 걸린 이유: MobileGlues 의 `CHECK_GL_ERROR` 는 `#if GLOBAL_DEBUG` 아래라
> 기본 빌드에서 **226군데가 전부 `{}` 로 컴파일됩니다.** "GL 오류가 하나도 없다"는 관찰이
> 아무 근거가 없었습니다. 지금은 `gl/log.h` 패치로 오류 로그를 상시 켭니다.

---

## JIT

JVM 이 코드 캐시를 쓰려면 프로세스에 `CS_DEBUGGED` 가 서야 합니다. 앱이 스스로 켤 수 없고
**디버거가 붙어야** 합니다.

| 경로 | 조건 |
|---|---|
| **StikDebug** 등 | URL 스킴으로 자동 요청 (기본) |
| **AltStore / SideStore** | 같은 Wi-Fi 의 AltServer |
| **TrollStore** | 자체 API |
| **Xcode** | 연결한 채로 실행 |

런처를 열 때 미리 한 번 확보합니다(`prepareAtLaunch`). 실행 시점에 요청하면 설치 직후
자동 실행 흐름 한가운데서 화면이 JIT 도구로 튀어나갑니다.

**JIT 은 프로세스 속성입니다.** 다른 버전으로 넘어가려면 앱을 다시 시작해야 하는데
(JVM 은 프로세스당 한 번), 새 프로세스에는 디버거를 다시 붙여야 합니다. 이건 우회할 수
없습니다. 대신 **다시 열었을 때 고르던 버전으로 바로 이어지게** 해서 손으로 다시 찾는
단계를 없앴습니다.

---

## LWJGL 두 벌

마인크래프트 26.2 가 LWJGL 3.4.1 을 쓰는데 **3.3.3 과 섞을 수 없습니다.** 3.4 에서
콜백 인프라(`Upcalls`, `ffi_get_closure_size`, `Callback$Descriptor`)가 새로 생겨서
자바와 네이티브가 같은 버전이어야 합니다. 반대로 3.4.1 을 1.21.x 에 쓰면 Iris 가
부팅 중에 죽습니다.

그래서 스택을 통째로 둘로 나눠 두고 **버전 JSON 의 라이브러리 목록을 읽어** 고릅니다.

```
libs/    + Frameworks/          → 3.3.3 (1.21.x 이하)
libs341/ + Frameworks/lwjgl341/ → 3.4.1 (26.2+)
```

한 벌로 합치려다 1.21.x 를 깨뜨린 적이 있습니다. 공유 자원을 통째로 바꾸는 대신
인스턴스별로 고르는 것이 처음부터 맞는 설계였습니다.

---

## 온라인 LAN (테라코타)

방 코드로 함께 플레이하는 기능입니다. [Terracotta](https://github.com/PCL-Community/Terracotta-lib)
(EasyTier 기반)를 `aarch64-apple-ios` 로 빌드해 정적 링크합니다.

네이티브 진입점은 **하나뿐**입니다.

```c
uint16_t terracotta_ios_start(const char *dataDir);   // 제어 서버를 띄우고 포트 반환
```

테라코타는 제어 표면을 이미 HTTP 로 전부 내놓고 있어서(데스크톱 UI 가 그걸 씁니다),
나머지는 Swift 가 `http://127.0.0.1:<포트>/state/…` 로 부릅니다. 안드로이드는 JNI 로
함수 10개를 각각 불렀지만, 표면이 작을수록 업스트림이 바뀔 때 깨질 자리가 적습니다.

### ⚠️ iOS 에서의 제약

iOS 는 앱이 가상 네트워크 장치(TUN)를 만드는 것을 허용하지 않습니다. 유일한 길인
Network Extension 은 무료 개발자 계정으로 **서명이 안 됩니다**. 그래서 EasyTier 의
no-TUN 모드로 동작하고, 문서화된 제약이 그대로 적용됩니다.

- **방 열기** — 정상 동작
- **참가** — 서버 목록에 자동으로 뜨지 않음. 화면에 나온 주소를 직접 입력해야 함

---

## 빌드 스크립트

업스트림 소스를 패치한 **사본을 저장소에 두지 않습니다.** 전부 빌드 시점에 스크립트가
클론 → 패치 → 빌드합니다. 업스트림과의 차이가 한눈에 보이고, 업스트림이 움직이면
**그 자리에서 멈춥니다** — 모든 패치에 하드 `assert` 가 걸려 있습니다.

| 스크립트 | 패치 수 | 무엇을 고치나 |
|---|---|---|
| `build-mobileglues.sh` | 15 | Mach-O 에 없는 `__attribute__((alias))`, ES 3.0 폴백, 정점 속성 부호, `RTLD_SELF` |
| `build-terracotta.sh` | 5 | EasyTier 버전 고정, iOS 인터페이스 필터, HTTP 서버 + C FFI 노출 |
| `build-javaapp.sh` | 4 | LWJGL 3.4.1 용 GLFW 스텁, `glfwGetInputMode` 널 가드 |
| `build-lwjgl-natives.sh` | — | LWJGL 3.4.1 네이티브 (libffi 포함) |
| `build-spirv-cross.sh` | — | 26.2 의 blaze3d 가 요구 |

스크립트를 돌리면 적용한 패치를 전부 출력합니다.

---

## 알려진 제약

| | |
|---|---|
| **JIT 재연결** | 버전을 바꾸려면 앱 재시작 → 디버거 재연결. 프로세스 속성이라 우회 불가 |
| **테라코타 참가** | 주소 직접 입력 (위 참고) |
| **26.3+ 스냅샷** | 게임이 GLFW → SDL3 로 바꿈 |
| **시뮬레이터** | 실행 불가 (코드서명) |
| **메모리** | 서버 리소스팩이 크면 아틀라스를 자동 축소함. iOS 예산(아이폰 15 기준 약 3GB) 안에서 자바 힙과 아틀라스가 자리를 나눠 씀 |

---

## 라이선스

**AGPL-3.0.** 선택이 아니라 의무입니다 — 정적 링크하는 테라코타가 AGPL-3.0 이고,
결합 저작물의 라이선스는 가장 강한 카피레프트가 정합니다.

전체 구성 요소와 그 이유는 [NOTICE](NOTICE) 에 적어 두었습니다.

> Minecraft 는 Mojang AB 의 상표입니다. 이 프로젝트는 Mojang AB · Microsoft 와
> 아무 관련이 없습니다.
