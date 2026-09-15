package kr.co.donghyun.flame;

import java.lang.instrument.ClassFileTransformer;
import java.lang.instrument.Instrumentation;
import java.security.ProtectionDomain;

/**
 * iOS 샌드박스에서 {@code Path.toRealPath()} 가 **항상** 실패하는 것을 고친다.
 *
 * <p>JDK 21 의 {@code UnixPath.toRealPath(NOFOLLOW_LINKS)} 는 대소문자를 구분하지 않는
 * 파일시스템에서 경로를 <b>루트부터 한 구간씩 훑으며</b> 실제 이름을 찾아낸다
 * (열어서 목록을 읽고 파일 키를 맞춰본다):
 *
 * <pre>
 *   if (!fs.isCaseInsensitiveAndPreserving()) return result;   // ← 여기서 끝났어야 한다
 *   for (each element from "/") {
 *       UnixFileAttributes.get(elementPath, false);   // lstat("/private"), lstat("/private/var") …
 *       opendir(path);                                // opendir("/"), opendir("/private") …
 *   }
 * </pre>
 *
 * <p>iOS 샌드박스는 {@code /private} 와 {@code /var} 를 lstat 도 opendir 도 못 하게 막는다.
 * 그래서 우리 앱 폴더 안의 멀쩡한 경로에도 첫 구간에서 IOException 이 난다.
 *
 * <p>APFS 라서 {@code MacOSXFileSystem.isCaseInsensitiveAndPreserving()} 이 무조건
 * {@code true} 를 돌려주는 게 원인이다. 안드로이드·리눅스는 대소문자를 구분하는
 * 파일시스템이라 저 훑기 자체를 안 한다 — 같은 모드가 거기서만 되는 이유다.
 *
 * <p>그 메서드가 {@code false} 를 돌려주게 바꾼다. 잃는 것은 "경로의 대소문자를 실제
 * 파일 이름에 맞춰 고쳐주는" 기능뿐인데, 경로는 전부 우리가 만들어 넘기므로 고칠 게 없다.
 * 반대로 그대로 두면 toRealPath 가 아무 경로에서도 성공하지 못한다.
 *
 * <p>실제로 이것 때문에 Cobblemon 의 Showdown 샌드박스가
 * {@code Invalid CommonJS root folder: showdown} 으로 죽었다
 * ({@code GraalShowdownService$createContext$1.checkAccess} 가 toRealPath 로 경로를 비교한다).
 */
public final class IosFsAgent {

    private static final String TARGET = "sun/nio/fs/MacOSXFileSystem";
    private static final String METHOD = "isCaseInsensitiveAndPreserving";
    private static final String DESCRIPTOR = "()Z";

    /** `-Dflame.guiFloor=<w>x<h>` — 런처가 원하는 GUI 스케일에 맞춰 계산해 넘긴다. */
    private static int guiFloorW, guiFloorH;
    /** 한 번 찾으면 더는 훑지 않는다(클래스 수천 개를 매번 볼 이유가 없다). */
    private static boolean guiFloorDone;

    public static void premain(String args, Instrumentation inst) {
        readGuiFloor();
        inst.addTransformer(new Transformer(), true);

        // 이 클래스는 JVM 이 뜨면서 이미 로드됐을 가능성이 크다 — 다시 변환해야 한다.
        for (Class<?> loaded : inst.getAllLoadedClasses()) {
            if (!TARGET.replace('/', '.').equals(loaded.getName())) continue;
            try {
                inst.retransformClasses(loaded);
            } catch (Throwable t) {
                System.out.println("[FlameFS] 재변환 실패: " + t);
            }
            return;
        }
    }

    private static final class Transformer implements ClassFileTransformer {
        @Override
        public byte[] transform(ClassLoader loader, String className, Class<?> beingRedefined,
                                ProtectionDomain domain, byte[] classfile) {
            if (!TARGET.equals(className)) return patchGui(classfile);
            try {
                byte[] patched = patch(classfile);
                System.out.println(patched == null
                        ? "[FlameFS] " + METHOD + " 를 찾지 못했습니다 — toRealPath 가 막힐 수 있습니다"
                        : "[FlameFS] " + METHOD + " → false (toRealPath 샌드박스 우회)");
                return patched;
            } catch (Throwable t) {
                System.out.println("[FlameFS] 패치 실패: " + t);
                return null;
            }
        }
    }

    /**
     * {@code isCaseInsensitiveAndPreserving()} 의 본문 {@code iconst_1; ireturn} 을
     * {@code iconst_0; ireturn} 으로 바꾼다 — 딱 한 바이트다.
     *
     * <p>ASM 을 쓰지 않는다. 에이전트는 게임 클래스로더보다 먼저 도는데, 그 시점에
     * 의존성을 끌어오면 부팅 순서가 꼬인다. 필요한 만큼만 직접 읽는다.
     *
     * @return 고친 클래스 바이트, 못 찾았으면 null
     */
    static byte[] patch(byte[] cf) {
        Reader r = new Reader(cf);
        String[] utf8 = readHeader(r);

        for (int pass = 0; pass < 2; pass++) {       // 0 = fields, 1 = methods
            int count = r.u2();
            for (int i = 0; i < count; i++) {
                r.skip(2);                           // access_flags
                String name = utf8[r.u2()];
                String descriptor = utf8[r.u2()];
                int attrCount = r.u2();
                for (int a = 0; a < attrCount; a++) {
                    String attrName = utf8[r.u2()];
                    int length = r.u4();
                    int end = r.at + length;
                    if (pass == 1 && "Code".equals(attrName)
                            && METHOD.equals(name) && DESCRIPTOR.equals(descriptor)) {
                        r.skip(4);                   // max_stack, max_locals
                        int codeLength = r.u4();
                        // 본문이 정확히 `iconst_1; ireturn` 일 때만 손댄다.
                        if (codeLength == 2 && (cf[r.at] & 0xFF) == 0x04
                                && (cf[r.at + 1] & 0xFF) == 0xAC) {
                            cf[r.at] = 0x03;         // iconst_0
                            return cf;
                        }
                        return null;                 // 모양이 다르면 건드리지 않는다
                    }
                    r.at = end;
                }
            }
        }
        return null;
    }

    private static void readGuiFloor() {
        String spec = System.getProperty("flame.guiFloor");
        if (spec == null) return;
        int x = spec.indexOf('x');
        if (x <= 0) return;
        try {
            guiFloorW = Integer.parseInt(spec.substring(0, x));
            guiFloorH = Integer.parseInt(spec.substring(x + 1));
        } catch (NumberFormatException ignored) {
            guiFloorW = guiFloorH = 0;
        }
    }

    /**
     * 모든 클래스를 지나가며 {@code calculateScale} 을 찾는다.
     *
     * <p>이름으로 못 거르는 대신(바닐라는 난독화) 서술자로 거르므로 거의 모든 클래스가
     * 메서드 테이블만 훑고 바로 빠진다. 찾는 즉시 멈춘다 —
     * {@code Window} 는 {@code Minecraft.&lt;init&gt;} 에서 바로 만들어지므로 초반에 끝난다.
     */
    private static byte[] patchGui(byte[] classfile) {
        if (guiFloorDone || guiFloorW <= 0 || guiFloorH <= 0) return null;
        byte[] patched;
        try {
            patched = patchGuiFloor(classfile, guiFloorW, guiFloorH);
        } catch (Throwable t) {
            return null;                             // 우리가 볼 클래스가 아니었다
        }
        if (patched == null) return null;
        guiFloorDone = true;
        System.out.println("[FlameHUD] GUI 스케일 하한 320x240 → "
                + guiFloorW + "x" + guiFloorH + " (HUD 확대)");
        return patched;
    }

    /**
     * 매직·상수풀·access/this/super·인터페이스까지 읽고 커서를 필드 테이블 앞에 둔다.
     *
     * @return 인덱스로 찾을 수 있는 Utf8 상수들(다른 태그 자리는 null)
     */
    private static String[] readHeader(Reader r) {
        r.skip(8);                                   // magic, minor, major

        int constantCount = r.u2();
        String[] utf8 = new String[constantCount];
        for (int i = 1; i < constantCount; i++) {
            int tag = r.u1();
            switch (tag) {
                case 1:  utf8[i] = r.utf8(); break;                 // Utf8
                case 7: case 8: case 16: case 19: case 20:
                         r.skip(2); break;
                case 15: r.skip(3); break;                          // MethodHandle
                case 5: case 6:                                     // Long / Double
                         r.skip(8); i++; break;                     //  — 칸을 두 개 먹는다
                default: r.skip(4); break;                          // 나머지는 전부 4바이트
            }
        }

        r.skip(6);                                   // access, this, super
        r.skip(2 * r.u2());                          // interfaces
        return utf8;
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  HUD 크기 상한 풀기
    // ─────────────────────────────────────────────────────────────────────────

    /** `sipush 320` — 가상 화면 최소 **너비**. */
    private static final int FLOOR_W = 320;
    /** `sipush 240` — 가상 화면 최소 **높이**. */
    private static final int FLOOR_H = 240;

    /**
     * 마인크래프트가 GUI 스케일에 거는 하한을 낮춰서 HUD 를 더 키울 수 있게 한다.
     *
     * <p>{@code Window.calculateScale(int guiScale, boolean forceUnicode)} 는 이렇게 생겼다:
     *
     * <pre>
     *   for (i = 1; i != guiScale &amp;&amp; i &lt; fbW &amp;&amp; i &lt; fbH
     *               &amp;&amp; fbW / (i + 1) &gt;= 320 &amp;&amp; fbH / (i + 1) &gt;= 240; ++i);
     * </pre>
     *
     * <p>즉 "가상 화면은 최소 320x240" 이 하드코딩돼 있다. 폰처럼 가로로 긴 화면에서는
     * 높이가 먼저 걸려서 <b>GUI 스케일 상한 = 프레임버퍼높이/240</b> 이 되고,
     * 아이폰 15 가로(높이 615)에서는 스케일 2 에서 막힌다. 슬롯 한 칸이 22pt 라
     * 애플 권장 터치 영역(44pt)의 절반이고, 해상도를 어떻게 조절해도 이 천장은
     * 못 넘는다(최대 1.28배).
     *
     * <p>그래서 저 두 상수를 직접 낮춘다. {@code sipush} 의 피연산자는 상수풀이 아니라
     * Code 안에 그대로 박혀 있어서 2바이트만 고치면 되고, 스택맵 프레임도 안 바뀐다.
     *
     * <p>이름으로 찾지 않는다 — 포지는 공식 이름({@code net.minecraft.client.Window})을
     * 쓰지만 바닐라는 난독화돼 있다. 서술자 {@code (IZ)I} 인 메서드 중 본문에
     * {@code sipush 320} 과 {@code sipush 240} 이 그 순서로 있는 것을 찾는다.
     * 게임 전체에서 사실상 이 메서드 하나뿐이다.
     *
     * @return 고친 클래스 바이트, 해당 메서드가 아니면 null
     */
    static byte[] patchGuiFloor(byte[] cf, int floorW, int floorH) {
        Reader r = new Reader(cf);
        String[] utf8 = readHeader(r);

        for (int pass = 0; pass < 2; pass++) {       // 0 = fields, 1 = methods
            int count = r.u2();
            for (int i = 0; i < count; i++) {
                r.skip(2);                           // access_flags
                r.skip(2);                           // name
                String descriptor = utf8[r.u2()];
                int attrCount = r.u2();
                for (int a = 0; a < attrCount; a++) {
                    String attrName = utf8[r.u2()];
                    int length = r.u4();
                    int end = r.at + length;
                    if (pass == 1 && "Code".equals(attrName) && "(IZ)I".equals(descriptor)) {
                        r.skip(4);                   // max_stack, max_locals
                        int codeLength = r.u4();
                        if (rewriteFloors(cf, r.at, r.at + codeLength, floorW, floorH)) {
                            return cf;
                        }
                    }
                    r.at = end;
                }
            }
        }
        return null;
    }

    /** [from, to) 안에서 `sipush 320` 다음 `sipush 240` 을 찾아 피연산자를 갈아끼운다. */
    private static boolean rewriteFloors(byte[] cf, int from, int to, int floorW, int floorH) {
        int w = indexOfSipush(cf, from, to, FLOOR_W);
        if (w < 0) return false;
        int h = indexOfSipush(cf, w + 3, to, FLOOR_H);
        if (h < 0) return false;

        cf[w + 1] = (byte) (floorW >> 8); cf[w + 2] = (byte) floorW;
        cf[h + 1] = (byte) (floorH >> 8); cf[h + 2] = (byte) floorH;
        return true;
    }

    /** `sipush <value>` (0x11 hi lo) 의 시작 오프셋. 없으면 -1. */
    private static int indexOfSipush(byte[] cf, int from, int to, int value) {
        byte hi = (byte) (value >> 8), lo = (byte) value;
        for (int i = from; i + 2 < to; i++) {
            if ((cf[i] & 0xFF) == 0x11 && cf[i + 1] == hi && cf[i + 2] == lo) return i;
        }
        return -1;
    }

    /** 클래스 파일을 앞에서부터 읽기만 하는 커서. */
    private static final class Reader {
        private final byte[] b;
        int at;

        Reader(byte[] b) { this.b = b; }

        int u1() { return b[at++] & 0xFF; }
        int u2() { return (u1() << 8) | u1(); }
        int u4() { return (u2() << 16) | u2(); }
        void skip(int n) { at += n; }

        String utf8() {
            int length = u2();
            String s = new String(b, at, length, java.nio.charset.StandardCharsets.UTF_8);
            at += length;
            return s;
        }
    }

    private IosFsAgent() {}
}
