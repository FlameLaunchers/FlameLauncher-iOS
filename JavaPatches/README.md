# JavaPatches — text2speech 스텁 보강

원본 `text2speech` jar 은 클래스패스에서 **뺀다**. 놔두면 Forge 모듈 경로에서 같은 패키지를
두 모듈이 export 해서 부팅이 막힌다:

    Modules text2speech and launcher export package com.mojang.text2speech

대신 Amethyst 의 `launcher.jar` 안에 있는 iOS 용 스텁을 쓰는데, 그 스텁에 원본이 가진
클래스 몇 개가 빠져 있다. 빠진 걸 모드가 이름으로 찾으면 `NoClassDefFoundError` 로 죽는다.
여기서 그 구멍만 메운다.

| 원본에 있는 것 | 스텁 | 처리 |
|---|---|---|
| `Narrator` | 있음 | 그대로 쓴다 |
| `Narrator$InitializeException` | **없음** | 추가 — `MinecraftClient.<init>` 이 이 타입을 푼다 |
| `OperatingSystem` | **없음** | 추가 — ModernFix 의 `GameNarratorMixin` 이 쓴다 |
| `NarratorMac` | 없음(`NarratorOSX` 만) | 추가 — 원본은 Rococoa(네이티브 ObjC)를 상속하므로 무해한 껍데기로 |
| `Narrator$1`, `Narrator$2` | 없음 | **안 넣는다** — 원본 `Narrator` 안의 익명 클래스라 밖에서 이름으로 찾을 일이 없다 |
| `NarratorLinux$FliteLibrary[$CmuUsKal16]` | 없음 | **안 넣는다** — 원본 `NarratorLinux` 전용 JNA 인터페이스다 |

`Narrator.java` 와 `NarratorDummy.java` 는 **컴파일용 껍데기**다. 빌드 스크립트는
아래 세 개의 class 파일만 꺼내 `launcher.jar` 에 넣고 나머지는 버린다:

    Narrator$InitializeException.class   OperatingSystem.class   NarratorMac.class
