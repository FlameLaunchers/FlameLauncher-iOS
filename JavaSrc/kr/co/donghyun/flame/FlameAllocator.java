package kr.co.donghyun.flame;

import org.lwjgl.system.JNI;
import org.lwjgl.system.MemoryUtil;

/**
 * LWJGL 의 네이티브 할당자를 우리 것(`Sources/Natives/flame_alloc.c`)으로 바꾼다.
 *
 * <p>큰 할당을 익명 메모리 대신 <b>파일 기반 매핑</b>에서 잡는다. iOS 의 jetsam 은
 * {@code phys_footprint} 로 판정하는데 거기에는 익명 메모리와 압축분만 들어가고
 * 파일 기반은 들어가지 않는다. 마인크래프트의 {@code NativeImage} 와 GL 스테이징
 * 버퍼가 전부 {@link MemoryUtil} 을 지나가므로, 여기 한 곳만 바꾸면 그만큼이
 * 장부에서 빠진다. (자세한 수치는 flame_alloc.c 주석)
 *
 * <p>함수 포인터는 런처가 프로세스를 띄울 때 {@code -Dflame.alloc.*} 로 넘긴다.
 * dylib 은 JVM 보다 먼저 이 프로세스에 올라와 있으므로 주소가 이미 확정돼 있다.
 *
 * <p>⚠️ LWJGL 은 {@code Class.forName} 으로 이 클래스를 만든다. <b>기본 생성자가
 *    있어야 하고</b>, 실패하면 조용히 기본 할당자로 돌아간다:
 *    "Warning: Failed to instantiate memory allocator: %s. Using the system default."
 *    그래서 생성자에서 던지지 않고, 주소가 없으면 그 사실만 남긴다.
 */
public final class FlameAllocator implements MemoryUtil.MemoryAllocator {

    private static final long MALLOC        = pointer("malloc");
    private static final long CALLOC        = pointer("calloc");
    private static final long REALLOC       = pointer("realloc");
    private static final long FREE          = pointer("free");
    private static final long ALIGNED_ALLOC = pointer("aligned_alloc");
    private static final long ALIGNED_FREE  = pointer("aligned_free");

    private static long pointer(String name) {
        String value = System.getProperty("flame.alloc." + name);
        if (value == null) return 0L;
        try {
            return Long.parseLong(value);
        } catch (NumberFormatException e) {
            return 0L;
        }
    }

    /** 주소가 하나라도 비면 쓸 수 없다 — 그때는 LWJGL 이 기본 할당자를 쓰게 둔다. */
    public static boolean isAvailable() {
        return MALLOC != 0 && CALLOC != 0 && REALLOC != 0
            && FREE != 0 && ALIGNED_ALLOC != 0 && ALIGNED_FREE != 0;
    }

    public FlameAllocator() {
        if (!isAvailable()) {
            throw new IllegalStateException(
                "flame.alloc.* 주소가 없습니다 — 기본 할당자를 씁니다");
        }
        System.out.println("[FlameAlloc] 큰 할당을 파일 기반 매핑으로 돌립니다");
    }

    @Override public long getMalloc()       { return MALLOC; }
    @Override public long getCalloc()       { return CALLOC; }
    @Override public long getRealloc()      { return REALLOC; }
    @Override public long getFree()         { return FREE; }
    @Override public long getAlignedAlloc() { return ALIGNED_ALLOC; }
    @Override public long getAlignedFree()  { return ALIGNED_FREE; }

    @Override public long malloc(long size)              { return JNI.invokePP(size, MALLOC); }
    @Override public long calloc(long num, long size)    { return JNI.invokePPP(num, size, CALLOC); }
    @Override public long realloc(long ptr, long size)   { return JNI.invokePPP(ptr, size, REALLOC); }
    @Override public void free(long ptr)                 { JNI.invokePV(ptr, FREE); }
    @Override public long aligned_alloc(long a, long s)  { return JNI.invokePPP(a, s, ALIGNED_ALLOC); }
    @Override public void aligned_free(long ptr)         { JNI.invokePV(ptr, ALIGNED_FREE); }
}
