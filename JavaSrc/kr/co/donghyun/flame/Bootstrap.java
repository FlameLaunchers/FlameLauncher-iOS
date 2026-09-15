package kr.co.donghyun.flame;

import java.lang.reflect.Method;
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
            // 프로세서는 산출물(SRG 매핑·패치된 클라이언트 JAR)이 이미 있으면 건너뛴다.
            // 그 판단은 ForgeInstaller.outputsExist 가 **단계별로** 한다 — 전부 있으면
            // 계획을 훑기만 하고 끝나므로 매번 불러도 싸다.
            //
            // ⚠️ 예전에는 그 위에 forge_plan.done 이라는 표시 파일을 두고, 있으면
            //    ForgeInstaller 를 아예 부르지 않았다. 그런데 프로세서가 산출물을 못 만든
            //    채로 정상 반환하면(예: 클래스패스에서 gson 이 빠져 처리 단계가 조용히
            //    아무것도 못 한 경우) 표시만 남고 산출물은 없는 상태로 굳는다.
            //    그러면 게임이 영원히 이렇게 죽고, 재설치 말고는 복구가 안 된다:
            //      IllegalStateException: Could not find net/minecraft/client/Minecraft.class
            //    표시 파일은 "무엇이 끝났는가"를 모르고, 산출물은 안다. 산출물만 믿는다.
            if (Files.exists(path)) {
                ForgeInstaller.run(path);
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
