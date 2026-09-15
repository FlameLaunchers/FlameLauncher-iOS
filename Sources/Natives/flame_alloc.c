// 큰 네이티브 할당을 **파일 기반 매핑**으로 돌려 jetsam 장부에서 빼는 할당자.
//
// ⚠️ 왜 필요한가
//    아이폰 15 의 jetsam 한도는 3071 MB 고, 그 판정 기준은 `phys_footprint` 다.
//    footprint 는 **익명(anonymous) 메모리와 압축분**만 센다 — 파일 기반(external)은
//    안 센다. 실측(바닐라 1.21.4 + 서버 리소스팩, 죽기 직전):
//
//        footprint 2759 MB = 익명 1135 + 압축 1528 · 파일기반 27
//          tag 0 (JVM 힙·JIT)                1294 MB
//          malloc_small (스프라이트 수천 장)   781 MB
//          malloc_large (아틀라스 256 포함)    697 MB
//
//    마인크래프트의 `NativeImage` 와 GL 스테이징 버퍼는 전부 LWJGL 의
//    `MemoryUtil` 을 지나간다. LWJGL 은 `-Dorg.lwjgl.system.allocator=<클래스>` 로
//    할당자를 통째로 갈아끼울 수 있으므로, 큰 덩어리만 파일 매핑으로 돌리면
//    그만큼이 footprint 에서 빠진다. 힙(JVM)은 못 옮기지만 나머지는 옮길 수 있다.
//
// ⚠️ 왜 "큰 것만" 인가
//    파일 하나당 open+ftruncate+mmap 이 든다. 작은 할당까지 보내면 그 비용이
//    할당 자체보다 커진다. 임계값 위만 보내고 아래는 그냥 malloc 에 맡긴다.
//    (임계값은 FLAME_ALLOC_MMAP_MIN 으로 조절한다)
//
// ⚠️ 해제한 매핑은 **작은 수만큼 캐시**한다. 청크 메시 버퍼처럼 매 프레임 늘었다
//    줄었다 하는 할당이 있어서, 매번 파일을 새로 만들면 프레임이 무너진다.

#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <unistd.h>
#include <fcntl.h>
#include <limits.h>
#include <sys/mman.h>
#include <os/lock.h>

#define FLAME_MAGIC        0x464C414Du   // 'FLAM'
#define FLAME_KIND_MALLOC  0u
#define FLAME_KIND_MAPPED  1u

/// 반환 포인터 바로 앞에 둔다. 32바이트라 16바이트 정렬이 유지된다.
typedef struct {
    uint32_t magic;
    uint32_t kind;
    size_t   size;     // 호출자가 요청한 크기(realloc 의 복사량)
    void    *base;     // 실제 할당 시작(정렬 보정 전)
    size_t   maplen;   // kind==MAPPED 일 때 munmap 길이
} FlameHdr;

_Static_assert(sizeof(FlameHdr) == 32, "헤더가 32바이트여야 정렬이 유지된다");

static size_t flame_page(void) {
    static size_t page = 0;
    if (page == 0) page = (size_t)getpagesize();
    return page;
}

static size_t flame_threshold(void) {
    static size_t threshold = 0;
    if (threshold == 0) {
        const char *v = getenv("FLAME_ALLOC_MMAP_MIN");
        long parsed = v ? strtol(v, NULL, 10) : 0;
        threshold = parsed > 0 ? (size_t)parsed : (256u * 1024u);
        // ⚠️ 환경변수는 인자와 달리 부팅 로그에 안 찍힌다. 값이 실제로 먹었는지
        //    확인할 길이 없어서 한 번 남긴다(임계값을 바꿔도 효과가 없어 보일 때
        //    "안 걸린 것"과 "걸렸는데 효과가 없는 것"을 구분해야 한다).
        printf("[FlameAlloc] 파일 매핑 임계값 %zu KB%s\n",
               threshold >> 10, v ? " (환경변수)" : " (기본값)");
        fflush(stdout);
    }
    return threshold;
}

// ── 해제한 매핑 캐시 ────────────────────────────────────────────────────────

#define FLAME_CACHE_MAX 24

typedef struct { void *base; size_t len; } FlameCached;

static FlameCached  g_cache[FLAME_CACHE_MAX];
static int          g_cacheCount = 0;
static os_unfair_lock g_cacheLock = OS_UNFAIR_LOCK_INIT;

/// 통계(진단용). 지금 파일 기반으로 들고 있는 바이트.
static _Atomic(uint64_t) g_mappedBytes = 0;
static _Atomic(uint64_t) g_mapFailures = 0;

uint64_t flame_alloc_mapped_bytes(void) { return g_mappedBytes; }
uint64_t flame_alloc_map_failures(void) { return g_mapFailures; }

/// @param need  들어올 때는 필요한 길이, 나갈 때는 **실제로 준 매핑의 길이**.
///
/// ⚠️ 이 되돌림이 없으면 나중에 `munmap` 을 짧게 불러서 매핑이 조각난 채 샌다.
static void *flame_cacheTake(size_t *need) {
    void *found = NULL;
    os_unfair_lock_lock(&g_cacheLock);
    for (int i = 0; i < g_cacheCount; i++) {
        // 너무 큰 것을 재사용하면 낭비가 누적된다. 두 배까지만 받는다.
        if (g_cache[i].len >= *need && g_cache[i].len <= *need * 2) {
            found = g_cache[i].base;
            *need = g_cache[i].len;
            g_cache[i] = g_cache[--g_cacheCount];
            break;
        }
    }
    os_unfair_lock_unlock(&g_cacheLock);
    return found;
}

/// @return 캐시에 넣었으면 1, 자리가 없어 호출자가 munmap 해야 하면 0
static int flame_cachePut(void *base, size_t len) {
    int stored = 0;
    os_unfair_lock_lock(&g_cacheLock);
    if (g_cacheCount < FLAME_CACHE_MAX) {
        g_cache[g_cacheCount].base = base;
        g_cache[g_cacheCount].len  = len;
        g_cacheCount++;
        stored = 1;
    }
    os_unfair_lock_unlock(&g_cacheLock);
    return stored;
}

// ── 파일 기반 매핑 ──────────────────────────────────────────────────────────

/// 이름 없는 파일을 만들어 그만큼 매핑한다.
///
/// ⚠️ 만들자마자 `unlink` 한다. 매핑이 살아 있는 동안 파일은 유지되고, 프로세스가
///    어떻게 끝나든(jetsam 포함) 커널이 알아서 지운다 — 찌꺼기가 남지 않는다.
/// @param total   들어올 때 필요한 길이, 나갈 때 실제 매핑 길이.
/// @param zeroed  새로 만든 매핑이면 1(커널이 0 으로 준다), 재사용이면 0.
static void *flame_mapNew(size_t *total, int *zeroed) {
    void *reused = flame_cacheTake(total);
    if (reused) { *zeroed = 0; return reused; }
    *zeroed = 1;

    const char *tmp = getenv("TMPDIR");
    if (!tmp || !*tmp) tmp = "/tmp/";
    size_t tmpLen = strlen(tmp);
    const char *sep = (tmp[tmpLen - 1] == '/') ? "" : "/";

    static _Atomic(uint64_t) counter = 0;
    char path[PATH_MAX];
    int written = snprintf(path, sizeof path, "%s%sflame_alloc_%d_%llu",
                           tmp, sep, (int)getpid(), (unsigned long long)(counter++));
    if (written <= 0 || (size_t)written >= sizeof path) return NULL;

    int fd = open(path, O_RDWR | O_CREAT | O_EXCL, 0600);
    if (fd < 0) return NULL;
    unlink(path);

    if (ftruncate(fd, (off_t)*total) != 0) { close(fd); return NULL; }
    void *base = mmap(NULL, *total, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    close(fd);
    if (base == MAP_FAILED) return NULL;
    return base;
}

static void flame_mapRelease(void *base, size_t len) {
    if (!flame_cachePut(base, len)) munmap(base, len);
}

// ── 할당자 본체 ────────────────────────────────────────────────────────────

// 서로 부르므로 앞서 선언해 둔다.
void *flame_malloc(size_t size);
void *flame_calloc(size_t num, size_t size);
void *flame_realloc(void *p, size_t size);
void  flame_free(void *p);
void *flame_aligned_alloc(size_t alignment, size_t size);
void  flame_aligned_free(void *p);

static void flame_fill(FlameHdr *h, uint32_t kind, size_t size, void *base, size_t maplen) {
    h->magic  = FLAME_MAGIC;
    h->kind   = kind;
    h->size   = size;
    h->base   = base;
    h->maplen = maplen;
}

/// 정렬 보정까지 포함한 공통 경로. alignment 는 2의 거듭제곱이어야 한다.
/// @param zeroed  (선택) 돌려준 메모리가 0 으로 채워져 있으면 1. calloc 이 쓴다.
static void *flame_allocAligned(size_t alignment, size_t size, int *zeroed) {
    if (zeroed) *zeroed = 0;
    if (size == 0) size = 1;
    if (alignment < 16) alignment = 16;

    // 헤더 + 정렬 여유. 정렬이 16이면 여유가 필요 없다(헤더가 이미 32의 배수).
    size_t slack = (alignment > 16) ? alignment : 0;

    if (size >= flame_threshold()) {
        size_t page  = flame_page();
        size_t total = sizeof(FlameHdr) + slack + size;
        total = (total + page - 1) & ~(page - 1);

        int fresh = 0;
        void *base = flame_mapNew(&total, &fresh);
        if (base) {
            uintptr_t payload = (uintptr_t)base + sizeof(FlameHdr);
            payload = (payload + alignment - 1) & ~(uintptr_t)(alignment - 1);
            flame_fill((FlameHdr *)(payload - sizeof(FlameHdr)),
                       FLAME_KIND_MAPPED, size, base, total);
            g_mappedBytes += total;
            // 새 매핑만 0 이 보장된다. 재사용한 것에는 이전 내용이 남아 있다.
            if (zeroed) *zeroed = fresh;
            return (void *)payload;
        }
        // 디스크가 없거나 매핑에 실패했다. 조용히 malloc 으로 떨어진다 —
        // 여기서 실패를 전파하면 게임이 죽는다. 다만 횟수는 세어 둔다.
        g_mapFailures += 1;
    }

    void *base = malloc(sizeof(FlameHdr) + slack + size);
    if (!base) return NULL;
    uintptr_t payload = (uintptr_t)base + sizeof(FlameHdr);
    payload = (payload + alignment - 1) & ~(uintptr_t)(alignment - 1);
    flame_fill((FlameHdr *)(payload - sizeof(FlameHdr)),
               FLAME_KIND_MALLOC, size, base, 0);
    return (void *)payload;
}

static FlameHdr *flame_header(void *p) {
    FlameHdr *h = (FlameHdr *)((uintptr_t)p - sizeof(FlameHdr));
    // ⚠️ 우리가 준 적 없는 포인터가 들어오면 그냥 지나간다. LWJGL 은 할당자를
    //    갈아끼우기 전에 잡은 메모리를 뒤늦게 해제할 수 있다.
    return h->magic == FLAME_MAGIC ? h : NULL;
}

void *flame_malloc(size_t size) {
    return flame_allocAligned(16, size, NULL);
}

void *flame_calloc(size_t num, size_t size) {
    size_t total = num * size;
    if (num != 0 && total / num != size) return NULL;   // 곱셈 넘침
    int zeroed = 0;
    void *p = flame_allocAligned(16, total, &zeroed);
    // ⚠️ 새로 만든 파일 매핑만 커널이 0 으로 준다. malloc 경로와 **재사용한 매핑**은
    //    아니다 — 재사용을 0 으로 안 밀면 이전 텍스처 찌꺼기가 그대로 보인다.
    if (p && !zeroed) memset(p, 0, total);
    return p;
}

void *flame_realloc(void *p, size_t size) {
    if (!p) return flame_malloc(size);
    FlameHdr *h = flame_header(p);
    if (!h) return realloc(p, size);          // 우리 것이 아니다

    if (size == 0) { flame_free(p); return NULL; }
    if (size <= h->size) { h->size = size; return p; }   // 줄이는 건 제자리에서

    void *fresh = flame_malloc(size);
    if (!fresh) return NULL;
    memcpy(fresh, p, h->size);
    flame_free(p);
    return fresh;
}

void flame_free(void *p) {
    if (!p) return;
    FlameHdr *h = flame_header(p);
    if (!h) { free(p); return; }

    uint32_t kind = h->kind;
    void *base = h->base;
    size_t maplen = h->maplen;
    h->magic = 0;                              // 이중 해제를 바로 드러나게 한다

    if (kind == FLAME_KIND_MAPPED) {
        g_mappedBytes -= maplen;
        flame_mapRelease(base, maplen);
    } else {
        free(base);
    }
}

void *flame_aligned_alloc(size_t alignment, size_t size) {
    return flame_allocAligned(alignment, size, NULL);
}

void flame_aligned_free(void *p) {
    flame_free(p);
}

/// LWJGL 에 넘길 함수 포인터 여섯 개.
/// 순서: malloc, calloc, realloc, free, aligned_alloc, aligned_free.
void flame_alloc_pointers(uint64_t out[6]) {
    out[0] = (uint64_t)(uintptr_t)&flame_malloc;
    out[1] = (uint64_t)(uintptr_t)&flame_calloc;
    out[2] = (uint64_t)(uintptr_t)&flame_realloc;
    out[3] = (uint64_t)(uintptr_t)&flame_free;
    out[4] = (uint64_t)(uintptr_t)&flame_aligned_alloc;
    out[5] = (uint64_t)(uintptr_t)&flame_aligned_free;
}
