<div align="center">

# 🔥 FlameLauncher for iOS

**아이폰·아이패드에서 마인크래프트 자바 에디션을 실행합니다.**

[![iOS](https://img.shields.io/badge/iOS-17.0%2B-000000?logo=apple&logoColor=white)](#)
[![arm64](https://img.shields.io/badge/arch-arm64-orange)](#)
[![AGPL-3.0](https://img.shields.io/badge/license-AGPL--3.0-blue)](LICENSE)

**[🇰🇷 한국어](#-한국어)** · **[🇺🇸 English](#-english)**

</div>

---
---

# 🇰🇷 한국어

## 1. 무엇을 할 수 있나

베드락이 아닌 **자바 에디션**입니다. PC 서버에 그대로 접속하고, PC 모드를 그대로 씁니다.
앱 프로세스 안에 진짜 OpenJDK 를 띄우는 방식이라 에뮬레이터가 아닙니다.

### 버전과 모드

| | |
|---|---|
| **바닐라** | 1.7 ~ **26.3** |
| **모드 로더** | Fabric · Forge · NeoForge · Quilt |
| **모드·모드팩** | CurseForge · Modrinth 에서 검색해 바로 설치 |
| **의존성** | 필요한 모드를 **자동으로 같이 설치**합니다 |

### 그래픽

| | |
|---|---|
| **셰이더** | Iris — 물 반사 · 그림자 · 광원 |
| **렌더러** | MobileGlues(기본, 셰이더용) · Zink · GL4ES(구버전용) |
| **해상도** | 25~100% 조절. 낮추면 프레임이 올라갑니다 |

인스턴스마다 렌더러를 따로 정할 수 있습니다. 셰이더를 쓰려면 **MobileGlues** 여야 합니다.

### 조작

- **화면 버튼** — 위치·크기를 직접 배치합니다 (`키보드 편집`)
- **물리 키보드** — 연결하면 바로 잡힙니다
- **게임패드** — 스틱·트리거까지 매핑됩니다
- **인게임 메뉴** — 실행 중에 해상도·핫바 크기를 바꿀 수 있습니다

### 멀티플레이

일반 서버 접속은 물론, **온라인 LAN** 으로 서버 없이 친구와 함께 할 수 있습니다.
방을 열면 코드가 나오고, 친구는 그 코드로 들어옵니다.

### 계정

마이크로소프트 정품 로그인만 지원합니다. **게임 파일은 앱에 들어 있지 않고**,
본인 계정으로 Mojang 서버에서 직접 받습니다.

---

## 2. 실행 방법

### 준비물

| | |
|---|---|
| **iOS 17.0 이상** | arm64 기기 (아이폰 XS 이후 / 2018년 이후 아이패드) |
| **여유 공간 3GB** | 앱 1GB + 게임·자바 런타임 |
| **정품 계정** | 마인크래프트 자바 에디션 |

### 2-1. JIT 를 먼저 이해해야 합니다

**iOS 는 앱이 실행 중에 기계어를 만드는 것을 막습니다.** 자바가 바로 그 방식으로 도는
언어라(JIT 컴파일), 이걸 풀지 않으면 게임이 부팅 도중에 멈춥니다.

푸는 방법은 **디버거를 붙이는 것** 하나뿐이고, 앱이 스스로는 못 합니다.

> ⚠️ **그래서 설치 방법이 곧 JIT 가능 여부를 결정합니다.**
> **UDID 를 안 받는 서명 서비스는 절대 쓰지 마세요.** 그런 곳은 배포(distribution)
> 인증서로 서명하는데, 그러면 앱에 `get-task-allow` 가 없어서 **디버거를 아예 붙일 수
> 없습니다.** 어떤 도구로도 JIT 가 안 켜집니다.
> 개발(development) 인증서여야 하며 **무료 Apple ID 로도 됩니다.**

### 2-2. TrollStore — 가장 편한 길 (iOS 17.0 이하)

되는 기기라면 **이게 답입니다.**

1. [TrollStore](https://github.com/opa334/TrollStore) 를 설치합니다
2. [Releases](https://github.com/FlameLaunchers/FlameLauncher-iOS/releases) 에서 `.ipa` 를 받습니다
3. `.ipa` 를 TrollStore 로 엽니다

**끝입니다.** 7일 재서명도, JIT 도구도, 컴퓨터도 필요 없습니다. TrollStore 가 영구 서명을
해주고 JIT 도 자체 API 로 즉시 켜집니다. 런처가 알아서 호출하므로 손댈 게 없습니다.

단점은 지원 범위입니다 — TrollStore 는 **iOS 17.0 까지**만 됩니다. 그 위 버전이면 아래로.

### 2-3. StikDebug — iOS 17.4 ~ 26

TrollStore 가 안 되는 기기에서 가장 편한 길입니다. 컴퓨터는 **최초 1회만** 필요합니다.

**설치**

1. [SideStore](https://sidestore.io) 또는 [AltStore](https://altstore.io) 로 `.ipa` 를 설치합니다
2. [StikDebug](https://github.com/StephenDev0/StikDebug) 를 설치합니다

**페어링 (최초 1회)**

3. 컴퓨터에 기기를 연결해 **페어링 파일**을 만듭니다 (StikDebug 안내를 따르세요)
4. 만든 파일을 StikDebug 에 넣습니다

**이후로는**

5. FlameLauncher 를 열면 StikDebug 로 잠깐 전환됐다가 **자동으로 돌아옵니다**

런처가 JIT 스크립트까지 같이 보내므로 StikDebug 안에서 따로 고를 것이 없습니다.
컴퓨터는 3번 이후로 필요 없습니다.

### 2-4. 그 밖의 경로

| 상황 | 방법 |
|---|---|
| **iOS 17.0 ~ 17.3** | [SideJITServer](https://github.com/nythepegasus/SideJITServer) — 컴퓨터에서 띄우고 같은 Wi-Fi |
| **AltStore / SideStore 사용 중** | 앱 목록에서 **Enable JIT** — 컴퓨터의 AltServer 와 같은 Wi-Fi |
| **개발자** | Xcode 로 연결한 채 실행 |

### 2-5. 첫 실행

1. **로그인** — 오른쪽 위 아바타 → 마이크로소프트 계정
2. **버전 고르기** — 왼쪽 메뉴 `인스턴스 선택` → `정식` 탭
3. **모드 로더 선택** — 바닐라 / Fabric / Forge / NeoForge
4. **다운로드** — 게임 파일과 자바 런타임 (첫 실행만, 5~15분)
5. **실행** — `설치됨` 탭에서 고른 뒤 `▶ 실행`

### 2-6. 셰이더 켜기

1. 인스턴스에 **Fabric** 을 설치합니다
2. `모드팩 설치` 에서 **Iris Shaders** 를 설치합니다 (의존 모드는 자동으로 같이)
3. 렌더러가 **MobileGlues** 인지 확인합니다 (`설치됨` 탭 아래 띠)
4. 게임 안 `설정 → 그래픽 → Shader Packs`

무거운 셰이더는 버겁습니다. 가벼운 것(Complementary, BSL 저설정)부터 시작하세요.

### 2-7. 버전을 바꿀 때

자바 가상머신은 **앱 실행당 한 번만** 뜹니다. 다른 버전으로 넘어가려면 앱을 완전히
종료했다 열어야 하고, JIT 는 프로세스 속성이라 **새 프로세스에는 디버거를 다시 붙여야
합니다.** iOS 의 구조적 제약이라 우회할 수 없습니다.

대신 안내창에서 `지금 종료` 를 누르면, **다시 열었을 때 그 버전으로 바로 이어집니다.**
앱만 다시 열면 나머지는 알아서 진행됩니다.

### 2-8. 안 될 때

| 증상 | 확인할 것 |
|---|---|
| "JIT 가 필요합니다" 에서 멈춤 | 화면의 `진단 정보` 를 펼치세요. 배포 인증서 서명이면 **재서명 외에 방법이 없습니다** |
| 실행하자마자 꺼짐 | JIT 가 안 켜진 상태입니다. 위 2-1 부터 확인하세요 |
| 게임 중 꺼짐 | 메모리 부족입니다. 렌더 거리를 낮추고, 가벼운 셰이더로 바꿔보세요 |
| 다른 버전 실행이 안 됨 | 위 2-7 참고 — 앱을 완전히 종료했다 여세요 |
| 26.3 에서 핫바 터치가 어긋남 | 26.3 은 해상도 배율을 쓰지 않고 항상 기기 해상도로 그립니다. 설정에서 **100%** 로 두세요 |
| 온라인 LAN 참가가 안 보임 | iOS 는 가상 네트워크 장치를 못 만듭니다. 화면의 주소를 **직접 입력**하세요 (방 열기는 정상 동작) |

---

## 3. 라이선스

**[AGPL-3.0](LICENSE)** 입니다. 선택이 아니라 의무입니다.

결합 저작물의 라이선스는 **가장 강한 카피레프트**가 정하는데, 이 앱이 정적 링크하는
Terracotta 가 AGPL-3.0 입니다.

| 구성 요소 | 라이선스 | 쓰이는 방식 |
|---|---|---|
| **Terracotta** | **AGPL-3.0** | `libterracotta.a` 정적 링크 (온라인 LAN) |
| Amethyst-iOS / PojavLauncher | GPL-3.0 | JavaApp · 네이티브 브릿지 · 패치된 LWJGL/GLFW |
| EasyTier | LGPL-3.0 | Terracotta 내부 |
| MobileGlues | LGPL-2.1-only | 렌더러 `libmobileglues.dylib` |
| LWJGL | BSD-3-Clause | 3.3.3 · 3.4.1 두 스택 |
| OpenJDK (Temurin) | GPL-2.0 + Classpath Exception | 번들 JRE |

GPL-3.0 코드는 AGPL-3.0 저작물에 결합할 수 있고(GPLv3 13조가 명시적으로 허용),
결과물은 AGPL-3.0 으로 배포해야 합니다.

업스트림에 가한 수정은 이 저장소에 사본으로 두지 않고, 전부 빌드 시점에 스크립트가
적용합니다. 그 패치와 업스트림별 라이선스 전문은
**[FlameLauncher-Natives](https://github.com/FlameLaunchers/FlameLauncher-Natives)** 에 있습니다.

자세한 내용은 [NOTICE](NOTICE) 를 보세요.

> Minecraft 는 Mojang AB 의 상표입니다. 이 프로젝트는 Mojang AB · Microsoft 와
> 아무 관련이 없습니다.

<div align="right"><a href="#-flamelauncher-for-ios">⬆ 맨 위로</a></div>

---
---

# 🇺🇸 English

## 1. What it does

This is **Java Edition**, not Bedrock. Join the servers your PC friends use, run the mods
they run. A real OpenJDK boots inside the app process — this is not an emulator.

### Versions and mods

| | |
|---|---|
| **Vanilla** | 1.7 through **26.3** |
| **Mod loaders** | Fabric · Forge · NeoForge · Quilt |
| **Mods and modpacks** | Search and install straight from CurseForge and Modrinth |
| **Dependencies** | Required mods are **installed alongside automatically** |

### Graphics

| | |
|---|---|
| **Shaders** | Iris — reflections, shadows, coloured light |
| **Renderers** | MobileGlues (default, the one shaders need) · Zink · GL4ES (old versions) |
| **Resolution** | 25–100%; lowering it buys frames |

The renderer is per-instance. Shaders require **MobileGlues**.

### Controls

- **On-screen buttons** — you place and size them yourself
- **Hardware keyboard** — picked up as soon as it connects
- **Gamepad** — sticks and triggers included
- **In-game menu** — change resolution and hotbar size while playing

### Multiplayer

Ordinary servers, plus **Online LAN** for playing with a friend without renting a server:
open a room, share the code, they join with it.

### Account

Microsoft sign-in only. **No game files ship with the app** — you download them from
Mojang's own servers with your own account.

---

## 2. Running it

### What you need

| | |
|---|---|
| **iOS 17.0 or later** | arm64 device (iPhone XS onward, 2018-or-later iPad) |
| **3 GB free** | 1 GB app plus the game and a Java runtime |
| **A paid account** | Minecraft Java Edition |

### 2-1. Understand JIT first

**iOS forbids apps from generating machine code at runtime.** Java runs exactly that way
(JIT compilation), so without lifting that restriction the game stalls partway through boot.

The only way to lift it is to **attach a debugger**, and an app cannot do that to itself.

> ⚠️ **So how you install decides whether JIT can ever work.**
> **Never use a signing service that doesn't ask for your UDID.** Those sign with a
> *distribution* certificate, which strips `get-task-allow` — **no debugger can attach at
> all**, and no tool will enable JIT.
> You need a *development* certificate. **A free Apple ID is fine.**

### 2-2. TrollStore — the easiest path (iOS 17.0 and below)

If your device supports it, **this is the answer.**

1. Install [TrollStore](https://github.com/opa334/TrollStore)
2. Download the `.ipa` from [Releases](https://github.com/FlameLaunchers/FlameLauncher-iOS/releases)
3. Open the `.ipa` with TrollStore

**Done.** No weekly re-signing, no JIT tool, no computer. TrollStore signs permanently and
enables JIT through its own API, which the launcher calls for you.

The catch is coverage: TrollStore only goes up to **iOS 17.0**. Above that, read on.

### 2-3. StikDebug — iOS 17.4 to 26

The most comfortable path where TrollStore isn't available. A computer is needed **once**.

**Install**

1. Install the `.ipa` with [SideStore](https://sidestore.io) or [AltStore](https://altstore.io)
2. Install [StikDebug](https://github.com/StephenDev0/StikDebug)

**Pair (once)**

3. Connect the device to a computer and create a **pairing file** (follow StikDebug's guide)
4. Load that file into StikDebug

**From then on**

5. Opening FlameLauncher briefly switches to StikDebug and **returns automatically**

The launcher sends the JIT script along with the request, so there is nothing to pick
inside StikDebug. The computer is not needed again after step 3.

### 2-4. Other routes

| Situation | Method |
|---|---|
| **iOS 17.0 – 17.3** | [SideJITServer](https://github.com/nythepegasus/SideJITServer) — run it on a computer, same Wi-Fi |
| **Already on AltStore / SideStore** | **Enable JIT** in the app list — same Wi-Fi as your AltServer |
| **Developers** | Run with Xcode attached |

### 2-5. First run

1. **Sign in** — avatar, top right → Microsoft account
2. **Pick a version** — left menu → the release tab
3. **Pick a loader** — vanilla, Fabric, Forge or NeoForge
4. **Download** — game files and a Java runtime; first time only, 5–15 minutes
5. **Play** — select it under the installed tab and press play

### 2-6. Turning on shaders

1. Install **Fabric** on the instance
2. Install **Iris Shaders** from the modpack browser — dependencies come along
3. Check the renderer is **MobileGlues** (the strip under the installed list)
4. In game: `Options → Video Settings → Shader Packs`

Heavy packs are a lot to ask of a phone. Start light — Complementary, or BSL on low.

### 2-7. Switching versions

A Java virtual machine starts **once per app launch**. Moving to a different version means
fully quitting and reopening, and because JIT is a property of the *process*, the new
process **needs a debugger attached again**. This is structural to iOS and cannot be
worked around.

What we did instead: choosing `지금 종료` in the prompt makes the app **resume straight
into that version** when you reopen it. Reopen the app and the rest happens on its own.

### 2-8. When it doesn't work

| Symptom | What to check |
|---|---|
| Stuck on "JIT is required" | Expand the diagnostics on that screen. If it was signed with a distribution certificate, **re-signing is the only fix** |
| Quits immediately on launch | JIT is not enabled. Start from 2-1 |
| Crashes mid-game | Out of memory. Lower render distance, switch to a lighter shader pack |
| Play does nothing on another version | See 2-7 — fully quit and reopen |
| Hotbar taps miss on 26.3 | 26.3 ignores the resolution scale and always renders at native resolution. Keep it at **100%** in settings |
| Joining an Online LAN room shows nothing | iOS cannot create a virtual network device. **Type the address in by hand** (hosting works normally) |

---

## 3. Licence

**[AGPL-3.0](LICENSE)**, by obligation rather than preference.

A combined work takes the **strongest copyleft** it contains, and the Terracotta this app
statically links is AGPL-3.0.

| Component | Licence | How it is used |
|---|---|---|
| **Terracotta** | **AGPL-3.0** | `libterracotta.a`, linked statically (Online LAN) |
| Amethyst-iOS / PojavLauncher | GPL-3.0 | JavaApp, native bridges, patched LWJGL/GLFW |
| EasyTier | LGPL-3.0 | inside Terracotta |
| MobileGlues | LGPL-2.1-only | the `libmobileglues.dylib` renderer |
| LWJGL | BSD-3-Clause | both the 3.3.3 and 3.4.1 stacks |
| OpenJDK (Temurin) | GPL-2.0 + Classpath Exception | bundled JRE |

GPL-3.0 code may be combined into an AGPL-3.0 work — GPLv3 section 13 permits exactly this
— and the result must be distributed under AGPL-3.0.

Modifications to upstream projects are not vendored here; they are applied at build time by
scripts. Those patches, and the full licence text of every upstream, live in
**[FlameLauncher-Natives](https://github.com/FlameLaunchers/FlameLauncher-Natives)**.

See [NOTICE](NOTICE) for the details.

> Minecraft is a trademark of Mojang AB. This project is not affiliated with, endorsed by,
> or connected to Mojang AB or Microsoft.

<div align="right"><a href="#-flamelauncher-for-ios">⬆ Back to top</a></div>
