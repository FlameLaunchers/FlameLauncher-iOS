package com.mojang.blaze3d.platform;

/**
 * 마인크래프트 26.3+ 의 macOS 전용 창 손질을 **통째로 끄는 스텁**.
 *
 * <p>⚠️ 왜 필요한가
 * 마인크래프트는 {@code os.name} 만 보고 macOS 분기를 탄다. iOS 는 거기서
 * "Mac OS X" 로 보고되므로 이 클래스의 메서드들이 실제로 불린다. 그런데 안쪽은
 * Rococoa({@code ca.weblite.objc}) → JNA → AppKit 으로 내려가고, iOS 에는 AppKit 도
 * iOS 용 {@code libjnidispatch} 도 없다:
 *
 * <pre>
 *   Description: Initializing game
 *   java.lang.NoClassDefFoundError: Could not initialize class com.sun.jna.Native
 *     at ca.weblite.objc.Runtime.&lt;clinit&gt;
 *     at com.mojang.blaze3d.platform.MacosUtil.disableCloseWindowMenuItem
 *     at com.mojang.blaze3d.platform.Window.&lt;init&gt;
 *     at net.minecraft.client.Minecraft.&lt;init&gt;
 * </pre>
 *
 * <p>{@code NoClassDefFoundError} 는 {@code Error} 라 마인크래프트의 try/catch
 * (Exception 만 잡는다)에 걸리지 않고 부팅을 그대로 끝낸다.
 *
 * <p>⚠️ 왜 이렇게 고치는가
 * 이 클래스는 {@code com.mojang.blaze3d} 라 <b>난독화되지 않는다</b>. 그리고
 * {@code Runtime/libs} 가 클래스패스 맨 앞이라 게임 라이브러리를 가린다 —
 * text2speech 스텁과 같은 방법이다. 바이트코드를 고치는 것보다 안전하다
 * (메서드 본문을 잘라내면 StackMapTable 이 어긋나 VerifyError 가 난다).
 *
 * <p>⚠️ {@code IS_MACOS} 를 {@code false} 로 둔다. 이 값을 보고 다른 macOS 경로로
 * 가지 않게 하는 것이 본체다 — 메서드를 비우는 것만으로는 호출부가 계속
 * macOS 라고 믿는다({@code Options}, {@code VideoSettingsScreen} 이 이 값을 읽는다).
 *
 * <p>잃는 것: macOS 의 닫기 메뉴 비활성화·전체화면 메뉴·Ctrl+클릭 우클릭 흉내.
 * iOS 에는 메뉴 막대도 Ctrl 키도 없으므로 잃을 것이 없다.
 */
public final class MacosUtil {

    /** iOS 는 macOS 가 아니다. 호출부가 이 값으로 분기한다. */
    public static final boolean IS_MACOS = false;

    private MacosUtil() {}

    public static void disableCloseWindowMenuItem() {}

    public static void setFullscreenMenuVisibility(boolean visible) {}

    public static void setCtrlClickEmulatesRightClick(boolean emulate) {}
}
