<div align="center">

# 🔥 FlameLauncher for iOS

**Run Minecraft: Java Edition on iPhone and iPad.**

[![iOS](https://img.shields.io/badge/iOS-17.0%2B-000000?logo=apple&logoColor=white)](#)
[![arm64](https://img.shields.io/badge/arch-arm64-orange)](#)
[![AGPL-3.0](https://img.shields.io/badge/license-AGPL--3.0-blue)](LICENSE)

</div>

---
---

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

What we did instead: choosing `Quit Now` in the prompt makes the app **resume straight
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
