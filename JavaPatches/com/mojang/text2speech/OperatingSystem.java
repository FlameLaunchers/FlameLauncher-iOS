package com.mojang.text2speech;

import java.util.Locale;

/**
 * 원본과 같은 열거형. 네이티브에 기대지 않으므로 동작까지 그대로 옮긴다
 * ({@code os.name} 을 소문자로 바꿔 부분 문자열로 맞춘다).
 *
 * <p>ModernFix 의 {@code GameNarratorMixin} 이 이 클래스를 이름으로 찾는다 —
 * 없으면 {@code NoClassDefFoundError: com/mojang/text2speech/OperatingSystem} 로
 * {@code NarratorManager.<init>} 에서 죽는다.
 *
 * <p>iOS 의 {@code os.name} 은 "Mac OS X" 라서 {@link #MAC_OS} 가 나온다.
 */
public enum OperatingSystem {
    LINUX("linux"),
    WINDOWS("win"),
    MAC_OS("mac"),
    UNSUPPORTED("");

    private final String detectWith;

    OperatingSystem(String detectWith) {
        this.detectWith = detectWith;
    }

    public static OperatingSystem get() {
        String name = System.getProperty("os.name", "").toLowerCase(Locale.ROOT);
        for (OperatingSystem os : values()) {
            if (os != UNSUPPORTED && name.contains(os.detectWith)) return os;
        }
        return UNSUPPORTED;
    }
}
