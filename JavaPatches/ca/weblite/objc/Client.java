package ca.weblite.objc;

/**
 * Rococoa 의 Objective-C 클라이언트 — iOS 에서는 **아무것도 하지 않는 스텁**.
 *
 * <p>⚠️ 왜 필요한가
 * 마인크래프트는 {@code os.name} 만 보고 macOS 분기를 탄다. iOS 는 거기서
 * "Mac OS X" 로 보고되므로 {@code MacosUtil.disableCloseWindowMenuItem()} 같은
 * AppKit 손질이 실제로 불린다. 그 안쪽은 Rococoa → JNA → AppKit 인데,
 * iOS 에는 AppKit 도 iOS 용 {@code libjnidispatch} 도 없다:
 *
 * <pre>
 *   Description: Initializing game
 *   java.lang.NoClassDefFoundError: Could not initialize class com.sun.jna.Native
 *     at ca.weblite.objc.Runtime.&lt;clinit&gt;
 *     at com.mojang.blaze3d.platform.MacosUtil.disableCloseWindowMenuItem
 *     at com.mojang.blaze3d.platform.Window.&lt;init&gt;
 * </pre>
 *
 * {@code NoClassDefFoundError} 는 {@code Error} 라 마인크래프트의 try/catch
 * (Exception 만 잡는다)에 걸리지 않고 부팅을 그대로 끝낸다.
 *
 * <p>⚠️ 왜 여기를 가리는가
 * 처음에는 {@code com.mojang.blaze3d.platform.MacosUtil} 을 직접 가렸는데,
 * <b>마인크래프트 클라이언트 jar 은 서명돼 있어서</b>(META-INF/MOJANGCS.SF)
 * 같은 패키지에 서명 없는 클래스를 끼우면 JVM 이 거부한다:
 *
 * <pre>
 *   SecurityException: class "com.mojang.blaze3d.platform.MacosUtil"'s signer
 *     information does not match signer information of other classes in the same package
 * </pre>
 *
 * 반면 {@code java-objc-bridge} 는 서명이 없다. 그래서 한 단계 아래인 이쪽을 가린다 —
 * {@code Runtime/libs} 가 클래스패스 맨 앞이라 게임 라이브러리를 덮는다
 * (text2speech 스텁과 같은 방법).
 *
 * <p>여기 있는 메서드는 {@code MacosUtil} 이 실제로 부르는 것만 담았다. 클래스 초기화가
 * JNA 를 건드리지 않으므로 호출은 조용히 아무 일도 하지 않고 끝난다.
 *
 * <p>잃는 것: macOS 의 닫기 메뉴 비활성화·전체화면 메뉴·Ctrl+클릭 우클릭 흉내.
 * iOS 에는 메뉴 막대도 Ctrl 키도 없다.
 */
public class Client {
    private static final Client INSTANCE = new Client();

    public static Client getInstance() { return INSTANCE; }

    public Proxy sendProxy(String target, String selector, Object... args) {
        return new Proxy();
    }
}
