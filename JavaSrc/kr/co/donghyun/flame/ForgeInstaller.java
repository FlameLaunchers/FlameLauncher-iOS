package kr.co.donghyun.flame;

import java.io.BufferedReader;
import java.io.InputStreamReader;
import java.lang.reflect.Method;
import java.net.URL;
import java.net.URLClassLoader;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.security.Permission;
import java.util.ArrayList;
import java.util.List;
import java.util.jar.JarFile;
import java.util.jar.Manifest;

/**
 * Forge / NeoForge 설치 프로세서를 **이 JVM 안에서** 실행한다.
 *
 * 데스크톱 런처는 프로세서마다 새 JVM 을 띄우지만 iOS 는 그럴 수 없다.
 * 대신 프로세서 jar 를 URLClassLoader 로 열어 Main-Class 의 main(String[]) 을 직접 부른다.
 *
 * 계획 JSON 은 Swift 쪽(`ForgeInstallPlanner`)이 만든다. 자리표시자 해석·다운로드는
 * 전부 거기서 끝내고, 여기서는 **이미 풀린 절대경로만** 받아 실행만 한다:
 *
 * <pre>
 * { "steps": [ { "jar": "...", "classpath": ["...", ...], "args": ["...", ...] } ] }
 * </pre>
 */
final class ForgeInstaller {

    static void run(Path planFile) throws Exception {
        String json = new String(Files.readAllBytes(planFile), StandardCharsets.UTF_8);
        List<Step> steps = parse(json);
        System.out.println("[FlameForge] 프로세서 " + steps.size() + "개 실행");

        // ⚠️ 프로세서 일부는 실패하면 System.exit 를 부른다. 그대로 두면 게임까지 같이 죽는다.
        //    Java 17/21 은 -Djava.security.manager=allow 가 있어야 설치할 수 있다.
        ExitGuard guard = ExitGuard.install();
        try {
            for (int i = 0; i < steps.size(); i++) {
                Step step = steps.get(i);
                String label = "[FlameForge] (" + (i + 1) + "/" + steps.size() + ") "
                        + Paths.get(step.jar).getFileName();
                // ⚠️ 이미 만들어 둔 산출물이 있으면 건너뛴다. 이 단계들은 결정적이고
                //    (SRG 매핑·바이너리 패치) 한 번 만들면 그대로 쓸 수 있는데,
                //    다시 돌리면 수십 초와 1GB 넘는 메모리를 또 쓴다.
                if (outputsExist(step)) {
                    System.out.println(label + " — 산출물이 있어 건너뜁니다");
                    continue;
                }
                System.out.println(label);
                execute(step);
            }
        } finally {
            guard.remove();
        }
        System.out.println("[FlameForge] 완료");
    }

    /// 이 단계가 만들어 내야 할 파일이 전부 이미 있는가.
    /// `--output` 을 하나도 선언하지 않는 단계는 "있다"로 보지 않는다(항상 실행).
    private static boolean outputsExist(Step step) {
        boolean any = false;
        for (int i = 0; i < step.args.size() - 1; i++) {
            String arg = step.args.get(i);
            if (!"--output".equals(arg) && !"--out".equals(arg)) continue;
            any = true;
            Path out = Paths.get(step.args.get(i + 1));
            try {
                if (!Files.exists(out) || Files.size(out) == 0) return false;
            } catch (Exception e) {
                return false;
            }
        }
        return any;
    }

    private static void execute(Step step) throws Exception {
        List<URL> urls = new ArrayList<>();
        urls.add(Paths.get(step.jar).toUri().toURL());
        for (String cp : step.classpath) {
            urls.add(Paths.get(cp).toUri().toURL());
        }

        String mainClass;
        try (JarFile jar = new JarFile(step.jar)) {
            Manifest mf = jar.getManifest();
            mainClass = mf == null ? null : mf.getMainAttributes().getValue("Main-Class");
        }
        if (mainClass == null) {
            throw new IllegalStateException("Main-Class 가 없는 프로세서: " + step.jar);
        }

        // 부모를 플랫폼 클래스로더로 두어 게임 클래스패스와 섞이지 않게 한다.
        ClassLoader parent = ClassLoader.getSystemClassLoader().getParent();
        try (URLClassLoader loader = new URLClassLoader(urls.toArray(new URL[0]), parent)) {
            Class<?> clazz = Class.forName(mainClass, true, loader);
            Method main = clazz.getMethod("main", String[].class);
            ClassLoader saved = Thread.currentThread().getContextClassLoader();
            Thread.currentThread().setContextClassLoader(loader);
            try {
                main.invoke(null, (Object) step.args.toArray(new String[0]));
            } catch (java.lang.reflect.InvocationTargetException e) {
                Throwable cause = e.getCause();
                if (cause instanceof ExitGuard.ExitAttempt) {
                    int code = ((ExitGuard.ExitAttempt) cause).code;
                    if (code != 0) throw new IllegalStateException(
                            "프로세서가 코드 " + code + " 로 실패했습니다: " + mainClass);
                    return;   // 정상 종료를 exit(0) 으로 알리는 도구도 있다
                }
                throw e;
            } finally {
                Thread.currentThread().setContextClassLoader(saved);
            }
        }
    }

    // MARK: - System.exit 차단

    /** 프로세서가 부르는 System.exit 를 예외로 바꿔 JVM 이 죽지 않게 한다. */
    static final class ExitGuard extends SecurityManager {
        static final class ExitAttempt extends SecurityException {
            final int code;
            ExitAttempt(int code) { super("exit(" + code + ")"); this.code = code; }
        }

        private final SecurityManager previous;
        private boolean active;

        private ExitGuard(SecurityManager previous) { this.previous = previous; }

        static ExitGuard install() {
            ExitGuard guard = new ExitGuard(System.getSecurityManager());
            try {
                System.setSecurityManager(guard);
                guard.active = true;
            } catch (Throwable t) {
                // -Djava.security.manager=allow 가 없거나 Java 25+ 라 설치 못 한 경우.
                // 프로세서가 exit 를 부르면 게임까지 같이 끝난다 — 막을 방법이 없다.
                System.out.println("[FlameForge] exit 차단을 설치하지 못했습니다: " + t);
            }
            return guard;
        }

        void remove() {
            if (!active) return;
            try { System.setSecurityManager(previous); } catch (Throwable ignored) {}
        }

        @Override public void checkExit(int status) { throw new ExitAttempt(status); }
        @Override public void checkPermission(Permission perm) { /* 나머지는 전부 허용 */ }
        @Override public void checkPermission(Permission perm, Object context) { }
    }

    // MARK: - 아주 작은 JSON 읽기
    //
    // 계획 파일은 우리가 만든 것이라 형태가 고정이다. 의존성을 늘리지 않으려고
    // 필요한 만큼만 직접 읽는다(문자열 배열과 객체 배열뿐).

    static final class Step {
        String jar;
        List<String> classpath = new ArrayList<>();
        List<String> args = new ArrayList<>();
    }

    private static List<Step> parse(String json) {
        List<Step> steps = new ArrayList<>();
        Cursor c = new Cursor(json);
        c.seek("\"steps\"");
        c.expect('[');
        while (true) {
            c.skipWhitespace();
            if (c.peek() == ']') { c.next(); break; }
            steps.add(parseStep(c));
            c.skipWhitespace();
            if (c.peek() == ',') c.next();
        }
        return steps;
    }

    private static Step parseStep(Cursor c) {
        Step step = new Step();
        c.expect('{');
        while (true) {
            c.skipWhitespace();
            if (c.peek() == '}') { c.next(); break; }
            String key = c.readString();
            c.skipWhitespace();
            c.expect(':');
            c.skipWhitespace();
            if ("jar".equals(key)) {
                step.jar = c.readString();
            } else if ("classpath".equals(key)) {
                step.classpath = c.readStringArray();
            } else if ("args".equals(key)) {
                step.args = c.readStringArray();
            } else {
                c.skipValue();
            }
            c.skipWhitespace();
            if (c.peek() == ',') c.next();
        }
        return step;
    }

    private static final class Cursor {
        private final String s;
        private int i;

        Cursor(String s) { this.s = s; }

        char peek() { return s.charAt(i); }
        void next() { i++; }

        void skipWhitespace() {
            while (i < s.length() && Character.isWhitespace(s.charAt(i))) i++;
        }

        void expect(char ch) {
            skipWhitespace();
            if (s.charAt(i) != ch) {
                throw new IllegalStateException("계획 파일 형식 오류: " + ch + " 를 기대했습니다 (" + i + ")");
            }
            i++;
        }

        void seek(String token) {
            int at = s.indexOf(token, i);
            if (at < 0) throw new IllegalStateException("계획 파일에 " + token + " 이 없습니다");
            i = at + token.length();
            skipWhitespace();
            expect(':');
        }

        String readString() {
            skipWhitespace();
            expect('"');
            StringBuilder sb = new StringBuilder();
            while (true) {
                char ch = s.charAt(i++);
                if (ch == '"') break;
                if (ch == '\\') {
                    char esc = s.charAt(i++);
                    switch (esc) {
                        case 'n': sb.append('\n'); break;
                        case 't': sb.append('\t'); break;
                        case 'r': sb.append('\r'); break;
                        case 'b': sb.append('\b'); break;
                        case 'f': sb.append('\f'); break;
                        case 'u':
                            sb.append((char) Integer.parseInt(s.substring(i, i + 4), 16));
                            i += 4;
                            break;
                        default: sb.append(esc);
                    }
                } else {
                    sb.append(ch);
                }
            }
            return sb.toString();
        }

        List<String> readStringArray() {
            List<String> out = new ArrayList<>();
            expect('[');
            while (true) {
                skipWhitespace();
                if (peek() == ']') { next(); break; }
                out.add(readString());
                skipWhitespace();
                if (peek() == ',') next();
            }
            return out;
        }

        void skipValue() {
            skipWhitespace();
            char ch = peek();
            if (ch == '"') { readString(); return; }
            if (ch == '[' || ch == '{') {
                char open = ch, close = ch == '[' ? ']' : '}';
                int depth = 0;
                while (i < s.length()) {
                    char cur = s.charAt(i++);
                    if (cur == '"') { i--; readString(); continue; }
                    if (cur == open) depth++;
                    else if (cur == close && --depth == 0) return;
                }
                return;
            }
            while (i < s.length() && ",}]".indexOf(s.charAt(i)) < 0) i++;
        }
    }

    private ForgeInstaller() {}
}
