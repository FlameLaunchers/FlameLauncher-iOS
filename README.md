<div align="center">

# 🔥 FlameLauncher for iOS

**아이폰·아이패드에서 마인크래프트 자바 에디션을 실행하는 런처.**
앱 프로세스 안에 진짜 OpenJDK 를 띄웁니다.

[![Platform](https://img.shields.io/badge/iOS-17.0%2B-000000?logo=apple&logoColor=white)](#)
[![Arch](https://img.shields.io/badge/arch-arm64-orange)](#)
[![License](https://img.shields.io/badge/license-AGPL--3.0-blue)](LICENSE)

**[🇰🇷 한국어](#-한국어)** · **[🇺🇸 English](#-english)**

</div>

---
---

# 🇰🇷 한국어

> 베드락이 아닌 **자바 에디션** 입니다. PC 서버에 그대로 접속하고, PC 모드를 그대로 씁니다.

## 목차

- [무엇을 할 수 있나](#무엇을-할-수-있나)
- [설치하기](#설치하기)
- [JIT 켜기 — 가장 중요한 부분](#jit-켜기--가장-중요한-부분)
- [처음 실행하기](#처음-실행하기)
- [화면 안내](#화면-안내)
- [렌더러 고르기](#렌더러-고르기)
- [셰이더](#셰이더)
- [온라인 LAN](#온라인-lan)
- [자주 겪는 문제](#자주-겪는-문제)
- [개발자용 빌드](#개발자용-빌드)
- [동작 원리](#동작-원리)
- [라이선스](#라이선스)

---

## 무엇을 할 수 있나

| | |
|---|---|
| **바닐라** | 1.7 ~ **26.2** 전부 |
| **모드 로더** | Fabric · Forge · NeoForge · Quilt |
| **모드팩** | CurseForge · Modrinth 에서 바로 설치 (의존 모드 자동 설치) |
| **셰이더** | Iris — 물 반사·그림자·광원까지 |
| **계정** | 마이크로소프트 정품 로그인 |
| **멀티플레이** | 일반 서버 접속 + 방 코드로 함께 하기 |
| **조작** | 화면 버튼(직접 배치) · 물리 키보드 · 게임패드 |

**게임 파일은 들어 있지 않습니다.** 본인 계정으로 Mojang 서버에서 직접 받습니다.

### 필요한 것

- **iOS 17.0 이상**, arm64 기기 (아이폰 XS 이후 / 2018년 이후 아이패드)
- **마인크래프트 자바 에디션 정품 계정**
- **여유 공간 3GB 이상** — 앱 1GB + 게임·자바 런타임
- **컴퓨터 한 대** — JIT 를 켜기 위한 최초 1회 페어링용 (아래 참고)

---

## 설치하기

앱스토어에는 없습니다. 사이드로드해야 하고, **서명 방식이 JIT 가능 여부를 결정**합니다.
이게 이 런처에서 가장 중요한 선택입니다.

| 방법 | iOS | JIT | 재서명 주기 |
|---|---|---|---|
| **SideStore** (권장) | 17.0+ | ✅ 자동 | 7일 (기기가 알아서 갱신) |
| **AltStore** | 17.0+ | ✅ 자동 | 7일 (컴퓨터 필요) |
| **TrollStore** | ~17.0 | ✅ 즉시 | **영구** |
| **Xcode 직접 설치** | 17.0+ | ✅ | 7일 |
| 배포 인증서 서명 서비스 | — | ❌ **불가** | — |

> ⚠️ **UDID 를 안 쓰는 서명 서비스는 쓰면 안 됩니다.** 그런 곳은 배포(distribution)
> 인증서로 서명하는데, 그러면 앱에 `get-task-allow` 가 없어서 **디버거를 붙일 수 없고
> JIT 가 영영 안 켜집니다.** 게임이 부팅 도중에 멈춥니다.
> 개발(development) 인증서여야 하고, **무료 Apple ID 로도 됩니다.**

### SideStore 로 설치 (권장)

1. [SideStore](https://sidestore.io) 를 설치하고 Apple ID 로 로그인합니다
2. [Releases](https://github.com/FlameLaunchers/FlameLauncher-iOS/releases) 에서 `.ipa` 를 받습니다
3. SideStore → `+` → 받은 `.ipa` 선택
4. SideStore 의 **Enable JIT** 를 FlameLauncher 에 켜 둡니다

### TrollStore 로 설치 (iOS 17.0 이하)

`.ipa` 를 TrollStore 로 열기만 하면 됩니다. **7일 재서명도, JIT 도구도 필요 없습니다** —
가장 편한 방법이지만 지원하는 iOS 버전이 제한적입니다.

---

## JIT 켜기 — 가장 중요한 부분

**iOS 는 앱이 실행 중에 기계어를 만드는 것을 막습니다.** 자바는 정확히 그 방식으로
도는 언어라(JIT 컴파일), 이걸 풀어주지 않으면 게임이 부팅 중에 멈춥니다.

풀어주는 유일한 방법은 **디버거를 붙이는 것**입니다. 앱이 스스로는 못 합니다.

### 기기만으로 (iOS 17.4 ~ 26) — StikDebug

가장 편한 방법입니다. **최초 1회만** 컴퓨터로 페어링 파일을 만들면, 이후로는 기기 안에서 끝납니다.

1. [StikDebug](https://github.com/StephenDev0/StikDebug) 설치
2. 컴퓨터에서 페어링 파일을 만들어 StikDebug 에 넣습니다 (StikDebug 안내를 따르세요)
3. **끝.** 다음부터는 FlameLauncher 를 열면 StikDebug 로 잠깐 전환됐다가 자동으로 돌아옵니다

> 런처가 JIT 스크립트까지 같이 보내므로 StikDebug 에서 따로 고를 필요가 없습니다.

### iOS 17.0 ~ 17.3 — SideJITServer

컴퓨터에서 [SideJITServer](https://github.com/nythepegasus/SideJITServer) 를 띄우고
기기와 같은 Wi-Fi 에 두면 됩니다.

### AltStore / SideStore 를 쓴다면

앱 목록에서 FlameLauncher 옆의 **Enable JIT** 를 누르면 됩니다.
컴퓨터의 AltServer 와 같은 Wi-Fi 에 있어야 합니다.

### ⚠️ 버전을 바꿀 때마다 다시 켜야 합니다

자바 가상머신은 **앱 실행당 한 번만** 뜹니다. 다른 버전으로 넘어가려면 앱을 완전히
종료했다 열어야 하고, JIT 는 프로세스 속성이라 새 프로세스에는 디버거를 다시 붙여야 합니다.
**iOS 의 구조적 제약이라 우회할 수 없습니다.**

대신 다시 열었을 때 **고르던 버전으로 바로 이어지게** 해 뒀습니다. 앱만 다시 열면
나머지는 알아서 진행됩니다.

---

## 처음 실행하기

1. **로그인** — 오른쪽 위 아바타 → 마이크로소프트 계정
2. **버전 고르기** — 왼쪽 메뉴 `인스턴스 선택` → 위쪽 `정식` 탭에서 원하는 버전
3. **모드 로더 선택** — 바닐라 / Fabric / Forge / NeoForge 중에서
4. **다운로드 대기** — 게임 파일과 자바 런타임을 받습니다 (첫 실행만, 5~15분)
5. **실행** — `설치됨` 탭에서 고른 뒤 `▶ 실행`

---

## 화면 안내

왼쪽 메뉴가 전부입니다.

| 메뉴 | 하는 일 |
|---|---|
| **인스턴스 선택** | 설치한 버전 목록, 새 버전 설치, 실행 |
| **모드팩 설치** | CurseForge · Modrinth 검색·설치 |
| **옵션 · 렌더러** | 메모리·해상도·렌더러, 전역 기본값 |
| **키보드 편집** | 화면 버튼 위치·크기 직접 배치 |
| **온라인 LAN** | 방 코드로 함께 하기 |
| **업데이트 노트** | 최신 소식 |

`설치됨` 탭 아래 띠에서 **버전 · 렌더러 · 실행**을 한 줄로 조작합니다.
렌더러는 여기서 바로 바꿀 수 있습니다 — 셰이더가 되고 안 되고가 여기 달려 있어서
가장 자주 만지는 값입니다.

---

## 렌더러 고르기

| | 언제 쓰나 |
|---|---|
| **MobileGlues** | **기본값.** 셰이더를 쓰려면 이것뿐입니다. 1.17 이상 권장 |
| **Zink (MoltenVK)** | Vulkan 경유. MobileGlues 가 안 될 때 |
| **GL4ES** | 구버전(1.12 이하) 부팅용 |

인스턴스마다 따로 정할 수 있고, 안 정하면 전역 기본값을 씁니다.

---

## 셰이더

**MobileGlues 렌더러 + Iris** 조합만 됩니다.

1. 인스턴스에 **Fabric** 을 설치합니다
2. `모드팩 설치` 에서 **Iris Shaders** 를 설치합니다 (의존 모드는 자동으로 같이 깔립니다)
3. 실행 후 게임 안 `설정 → 그래픽 → Shader Packs` 에서 셰이더팩을 넣습니다

> 무거운 셰이더는 아이폰에서 버겁습니다. 가벼운 것(Complementary, BSL 저설정)부터 시작하세요.

---

## 온라인 LAN

친구와 같은 월드에서 놀 때 씁니다. 서버를 따로 빌릴 필요가 없습니다.

**방을 여는 쪽**
1. 게임에 들어가 월드를 연 뒤 `ESC → LAN 에 공개`
2. 런처의 `온라인 LAN` → `방 열기`
3. 나온 **방 코드**를 친구에게 알려줍니다

**참가하는 쪽**
1. `온라인 LAN` → 방 코드 입력 → `참가`
2. 화면에 나온 **주소를 복사**해서 게임의 `멀티플레이 → 서버 추가` 에 붙여넣습니다

> ⚠️ 참가할 때 서버 목록에 자동으로 뜨지 않습니다. iOS 는 앱이 가상 네트워크 장치를
> 만드는 것을 허용하지 않아서(그 권한은 유료 개발자 계정 전용) 주소를 직접 넣어야 합니다.
> **방을 여는 쪽은 제약 없이 동작합니다.**

---

## 자주 겪는 문제

**"JIT 가 필요합니다" 에서 안 넘어감**
→ 위 [JIT 켜기](#jit-켜기--가장-중요한-부분) 를 확인하세요. 화면의 `진단 정보` 를 펼치면
정확한 사유가 나옵니다. 서명이 배포 인증서면 **어떤 방법으로도 안 됩니다** — 다시 서명해야 합니다.

**다른 버전을 눌러도 실행이 안 됨**
→ 앱을 완전히 종료했다 여세요. 안내창의 `지금 종료` 를 누르면 다시 열었을 때 그 버전으로 이어집니다.

**게임 중 갑자기 꺼짐**
→ 메모리 부족일 가능성이 큽니다. `옵션` 에서 **렌더 거리를 낮추고**, 셰이더를 쓴다면
가벼운 것으로 바꿔보세요. 고해상도 리소스팩은 특히 무겁습니다.

**26.3 스냅샷이 실행 안 됨**
→ 마인크래프트가 윈도잉 라이브러리를 GLFW 에서 SDL3 로 바꿨습니다. 이 런처는 GLFW 를
가로채는 구조라 아직 대응이 안 됩니다. **최신 정식(26.2)은 정상 동작합니다.**

**실행하면 세로로 돌아감**
→ 최신 버전에서 고쳐졌습니다. 업데이트해주세요.

---

## 개발자용 빌드

```bash
brew install xcodegen
git clone https://github.com/FlameLaunchers/FlameLauncher-iOS.git
cd FlameLauncher-iOS

./Scripts/fetch-runtime.sh     # 렌더러 · LWJGL · JRE (약 350MB)
xcodegen generate              # project.yml → .xcodeproj
open FlameLauncher.xcodeproj
```

네이티브를 직접 빌드하려면 **[FlameLauncher-Natives](https://github.com/FlameLaunchers/FlameLauncher-Natives)**
를 쓰세요 — MobileGlues · Terracotta · LWJGL 3.4.1 을 iOS 용으로 빌드하는 스크립트와
패치가 그쪽에 있습니다.

> **시뮬레이터에서는 게임이 실행되지 않습니다.** JRE·렌더러가 전부 기기용 arm64 바이너리라
> 시뮬레이터가 `dlopen` 하는 순간 코드서명 검증에 걸려 프로세스가 SIGKILL 로 죽습니다.
> UI 작업은 시뮬레이터에서, 실제 실행은 기기에서 하면 됩니다.

---

## 동작 원리

```
SwiftUI 런처
    ↓ JLI_Launch
OpenJDK (앱 프로세스 안)
    ↓ LWJGL 3.3.3 / 3.4.1
GLFW 구현 (자바로 다시 씀 — 터치·게임패드를 키 이벤트로)
    ↓ OpenGL
MobileGlues (데스크톱 GL → GLES 번역)
    ↓
ANGLE → Metal → GPU
```

**LWJGL 두 벌을 들고 있습니다.** 마인크래프트 26.2 가 LWJGL 3.4.1 을 쓰는데 3.3.3 과
섞을 수 없습니다(콜백 인프라가 새로 생겨 자바와 네이티브가 같은 버전이어야 합니다).
버전 JSON 의 라이브러리 목록을 읽어 자동으로 고릅니다.

---

## 라이선스

**AGPL-3.0.** 선택이 아니라 의무입니다 — 정적 링크하는 테라코타가 AGPL-3.0 이고,
결합 저작물의 라이선스는 가장 강한 카피레프트가 정합니다. 전체 구성 요소는 [NOTICE](NOTICE) 참조.

> Minecraft 는 Mojang AB 의 상표입니다. 이 프로젝트는 Mojang AB · Microsoft 와 아무 관련이 없습니다.

<div align="right"><a href="#-flamelauncher-for-ios">⬆ 맨 위로</a></div>

---
---

# 🇺🇸 English

> This is **Java Edition**, not Bedrock. Join the same servers your PC friends use,
> run the same mods.

## Contents

- [What it does](#what-it-does)
- [Installing](#installing)
- [Enabling JIT — the part that matters](#enabling-jit--the-part-that-matters)
- [First run](#first-run)
- [Getting around](#getting-around)
- [Choosing a renderer](#choosing-a-renderer)
- [Shaders](#shaders)
- [Online LAN](#online-lan)
- [Troubleshooting](#troubleshooting)
- [Building it yourself](#building-it-yourself)
- [How it works](#how-it-works)
- [Licence](#licence)

---

## What it does

| | |
|---|---|
| **Vanilla** | 1.7 through **26.2** |
| **Mod loaders** | Fabric · Forge · NeoForge · Quilt |
| **Modpacks** | Install straight from CurseForge and Modrinth (dependencies resolved automatically) |
| **Shaders** | Iris — reflections, shadows, coloured light |
| **Account** | Microsoft sign-in |
| **Multiplayer** | Normal servers, plus room-code play with friends |
| **Controls** | On-screen buttons you lay out yourself · hardware keyboard · gamepad |

**No game files ship with this app.** You download them from Mojang's own servers with
your own account.

### What you need

- **iOS 17.0 or later**, arm64 device (iPhone XS onward, 2018-or-later iPad)
- **A paid Minecraft Java Edition account**
- **3 GB free space** — 1 GB app plus the game and a Java runtime
- **A computer**, once, to pair for JIT (see below)

---

## Installing

Not on the App Store. You sideload it, and **how you sign it decides whether JIT can
work** — which is the single most important choice here.

| Method | iOS | JIT | Re-sign |
|---|---|---|---|
| **SideStore** (recommended) | 17.0+ | ✅ automatic | 7 days, on-device |
| **AltStore** | 17.0+ | ✅ automatic | 7 days, needs a computer |
| **TrollStore** | up to 17.0 | ✅ instant | **never** |
| **Xcode direct install** | 17.0+ | ✅ | 7 days |
| Distribution-cert signing services | — | ❌ **impossible** | — |

> ⚠️ **Avoid signing services that don't ask for your UDID.** Those sign with a
> *distribution* certificate, which strips `get-task-allow` — no debugger can attach, so
> **JIT can never be enabled** and the game stops partway through boot.
> You need a *development* certificate. **A free Apple ID is fine.**

### With SideStore (recommended)

1. Install [SideStore](https://sidestore.io) and sign in with your Apple ID
2. Download the `.ipa` from [Releases](https://github.com/FlameLaunchers/FlameLauncher-iOS/releases)
3. SideStore → `+` → pick the `.ipa`
4. Turn on **Enable JIT** for FlameLauncher

### With TrollStore (iOS 17.0 and below)

Just open the `.ipa` with TrollStore. **No weekly re-signing, no JIT tool** — easily the
most comfortable route, but only on the iOS versions TrollStore supports.

---

## Enabling JIT — the part that matters

**iOS forbids apps from generating machine code at runtime.** That is exactly how Java
runs (JIT compilation), so without lifting that restriction the game stalls during boot.

The only way to lift it is to **attach a debugger**. An app cannot do it to itself.

### On-device only (iOS 17.4 – 26) — StikDebug

The most convenient route. You need a computer **once**, to create a pairing file; after
that everything happens on the device.

1. Install [StikDebug](https://github.com/StephenDev0/StikDebug)
2. Create a pairing file on a computer and load it into StikDebug (follow StikDebug's guide)
3. **Done.** From then on, opening FlameLauncher briefly switches to StikDebug and returns
   automatically

> The launcher sends the JIT script along with the request, so there is nothing to pick
> inside StikDebug.

### iOS 17.0 – 17.3 — SideJITServer

Run [SideJITServer](https://github.com/nythepegasus/SideJITServer) on a computer and keep
the device on the same Wi-Fi.

### If you use AltStore / SideStore

Press **Enable JIT** next to FlameLauncher in the app list. Your computer's AltServer must
be on the same Wi-Fi.

### ⚠️ You re-enable it every time you switch versions

A Java virtual machine starts **once per app launch**. Moving to a different version means
fully quitting and reopening the app, and because JIT is a property of the *process*, the
new process needs a debugger attached again. **This is structural to iOS and cannot be
worked around.**

What we did instead: reopening the app **resumes straight into the version you picked**.
Just reopen it and the rest happens on its own.

---

## First run

1. **Sign in** — avatar, top right → Microsoft account
2. **Pick a version** — left menu `인스턴스 선택` → `정식` tab
3. **Pick a loader** — vanilla, Fabric, Forge or NeoForge
4. **Wait for the download** — game files and a Java runtime, first time only, 5–15 minutes
5. **Play** — select it under the installed tab and press `▶`

---

## Getting around

The left menu is the whole app.

| Menu | What it does |
|---|---|
| **인스턴스 선택** | Installed versions, install new ones, launch |
| **모드팩 설치** | Search and install from CurseForge · Modrinth |
| **옵션 · 렌더러** | Memory, resolution, renderer defaults |
| **키보드 편집** | Lay out the on-screen buttons yourself |
| **온라인 LAN** | Room-code multiplayer |
| **업데이트 노트** | Release notes |

The strip under the installed list holds **version · renderer · play** on one row. The
renderer is right there because it decides whether shaders work — it is the setting you
touch most.

---

## Choosing a renderer

| | When |
|---|---|
| **MobileGlues** | **Default.** The only one shaders work on. Best on 1.17+ |
| **Zink (MoltenVK)** | Via Vulkan. Try it when MobileGlues misbehaves |
| **GL4ES** | For booting old versions (1.12 and below) |

Set per instance, or leave it to follow the global default.

---

## Shaders

Only **MobileGlues + Iris** works.

1. Install **Fabric** on the instance
2. Install **Iris Shaders** from `모드팩 설치` — its dependencies come along automatically
3. In game, `Options → Video Settings → Shader Packs`

> Heavy packs are a lot to ask of a phone. Start with something light — Complementary, or
> BSL on low.

---

## Online LAN

Play in the same world as a friend without renting a server.

**Hosting**
1. Open a world in game, then `ESC → Open to LAN`
2. Launcher → `온라인 LAN` → open a room
3. Share the **room code**

**Joining**
1. `온라인 LAN` → enter the room code → join
2. **Copy the address** shown and paste it into `Multiplayer → Add Server`

> ⚠️ When joining, the world does not appear in the server list on its own. iOS does not
> let apps create a virtual network device — that entitlement is paid-account only — so
> the address goes in by hand. **Hosting has no such limitation.**

---

## Troubleshooting

**Stuck on "JIT is required"**
→ See [Enabling JIT](#enabling-jit--the-part-that-matters). Expand `진단 정보` on that
screen for the exact reason. If the app was signed with a distribution certificate,
**no method will work** — it has to be re-signed.

**Tapping play on a different version does nothing**
→ Fully quit and reopen. Choosing `지금 종료` in the prompt makes the app resume into that
version when you reopen it.

**Crashes mid-game**
→ Most likely memory. Lower the **render distance** in options, and switch to a lighter
shader pack if you use one. High-resolution resource packs are especially expensive.

**26.3 snapshots won't run**
→ Minecraft swapped its windowing library from GLFW to SDL3. This launcher intercepts
GLFW, so that path no longer applies. **The current release, 26.2, works fine.**

**The app rotates to portrait**
→ Fixed in the latest build. Please update.

---

## Building it yourself

```bash
brew install xcodegen
git clone https://github.com/FlameLaunchers/FlameLauncher-iOS.git
cd FlameLauncher-iOS

./Scripts/fetch-runtime.sh     # renderers · LWJGL · JRE (~350 MB)
xcodegen generate              # project.yml → .xcodeproj
open FlameLauncher.xcodeproj
```

To build the natives yourself, use
**[FlameLauncher-Natives](https://github.com/FlameLaunchers/FlameLauncher-Natives)** — the
scripts and patches that build MobileGlues, Terracotta and LWJGL 3.4.1 for iOS live there.

> **The game does not run in the Simulator.** The JRE and renderers are device arm64
> binaries, so the moment the Simulator `dlopen`s one it fails code-signature validation
> and the process is SIGKILLed. Do UI work in the Simulator, run the game on a device.

---

## How it works

```
SwiftUI launcher
    ↓ JLI_Launch
OpenJDK (inside the app process)
    ↓ LWJGL 3.3.3 / 3.4.1
GLFW reimplementation (touch and gamepad become key events)
    ↓ OpenGL
MobileGlues (desktop GL → GLES translation)
    ↓
ANGLE → Metal → GPU
```

**Two LWJGL stacks ship side by side.** Minecraft 26.2 needs LWJGL 3.4.1, which cannot be
mixed with 3.3.3 — 3.4 introduced new callback infrastructure, so the Java side and the
natives have to match. The right stack is chosen by reading the version JSON's library list.

---

## Licence

**AGPL-3.0**, by obligation rather than preference: the statically linked Terracotta is
AGPL-3.0, and a combined work takes the strongest copyleft it contains. See
[NOTICE](NOTICE) for the full component list.

> Minecraft is a trademark of Mojang AB. This project is not affiliated with, endorsed by,
> or connected to Mojang AB or Microsoft.

<div align="right"><a href="#-flamelauncher-for-ios">⬆ Back to top</a></div>
