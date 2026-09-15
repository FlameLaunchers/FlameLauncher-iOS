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

    public static void premain(String args, Instrumentation inst) {
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
            if (!TARGET.equals(className)) return null;
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
