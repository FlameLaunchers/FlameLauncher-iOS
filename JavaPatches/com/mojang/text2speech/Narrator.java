package com.mojang.text2speech;

/**
 * <b>컴파일용 껍데기다.</b> 여기서 실제로 쓰는 산출물은 중첩 클래스
 * {@code Narrator$InitializeException.class} 하나뿐이고, 이 인터페이스 자체는 버린다
 * (launcher.jar 에 이미 Amethyst 가 만든 Narrator 가 들어 있다).
 *
 * <p>왜 필요한가: 원본 {@code text2speech} jar 은 클래스패스에서 제외한다 — 놔두면
 * Forge 의 모듈 경로에서 같은 패키지를 두 모듈이 export 해서 부팅이 막힌다
 * ("Modules text2speech and launcher export package com.mojang.text2speech").
 * 그런데 대체 스텁에 {@code Narrator.InitializeException} 이 빠져 있어서,
 * {@code MinecraftClient.<init>} 이 그 타입을 풀 때 터졌다:
 *
 * <pre>
 * java.lang.NoClassDefFoundError: com/mojang/text2speech/Narrator$InitializeException
 *     at net.minecraft.client.MinecraftClient.&lt;init&gt;(MinecraftClient.java:675)
 * </pre>
 *
 * <p>원본과 모양을 맞춘다 — {@code Exception} 을 상속하는 checked 예외에 생성자 두 개다.
 */
public interface Narrator {

    // launcher.jar 의 진짜 스텁과 같은 모양 — NarratorDummy 껍데기가 컴파일되려면 필요하다.
    void say(String message, boolean interrupt);
    void clear();
    boolean active();
    void destroy();

    /** 원본 {@code com.mojang.text2speech.Narrator.InitializeException} 과 같은 모양. */
    class InitializeException extends Exception {
        private static final long serialVersionUID = 1L;

        public InitializeException(String message) {
            super(message);
        }

        public InitializeException(String message, Throwable cause) {
            super(message, cause);
        }
    }
}
