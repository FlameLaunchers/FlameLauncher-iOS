package kr.co.donghyun.flame;

import java.lang.reflect.Method;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;

/**
 * 게임보다 먼저 도는 진입점.
 *
 * iOS 는 프로세스를 새로 띄울 수 없어서(fork/exec 불가) Forge·NeoForge 설치가
 * 요구하는 "프로세서" 들을 따로 돌릴 JVM 이 없다. 그래서 게임을 띄우는 바로 그 JVM 에서
 * 마인크래프트보다 먼저 실행한 뒤, 원래 메인 클래스로 넘긴다.
 *
 * 시스템 프로퍼티:
 *   flame.main.class  실제로 실행할 메인 클래스 (필수)
 *   flame.forge.plan  프로세서 실행 계획 JSON 경로 (없으면 그냥 넘긴다)
 */
public final class Bootstrap {
    public static void main(String[] args) throws Throwable {
        String plan = System.getProperty("flame.forge.plan");
        if (plan != null && !plan.isEmpty()) {
            Path path = Paths.get(plan);
            // ⚠️ 프로세서는 **한 번만** 돌린다. 산출물(SRG 매핑·패치된 클라이언트 JAR)은
            //    디스크에 남으므로 다시 만들 이유가 없다. 예전에는 실행할 때마다 6개를
            //    전부 다시 돌려서 매번 수십 초와 1.6GB 를 쓰고, 그 도중에 프로세스가
            //    통째로 사라지는 일이 반복됐다(자바 예외도 크래시 리포트도 안 남는다).
            //    계획 파일 자체는 지우면 안 된다 — 실행할 때마다 클래스패스를 만들 때
            //    설치 전용 라이브러리와 산출물 목록을 여기서 읽는다.
            Path done = path.resolveSibling("forge_plan.done");
            if (Files.exists(path) && !Files.exists(done)) {
                ForgeInstaller.run(path);
                Files.write(done, String.valueOf(Files.getLastModifiedTime(path).toMillis())
                        .getBytes(StandardCharsets.UTF_8));
            }
        }

        String target = System.getProperty("flame.main.class");
        if (target == null || target.isEmpty()) {
            throw new IllegalStateException("flame.main.class 가 지정되지 않았습니다");
        }
        Method main = Class.forName(target).getMethod("main", String[].class);
        main.invoke(null, (Object) args);
    }

    private Bootstrap() {}
}
