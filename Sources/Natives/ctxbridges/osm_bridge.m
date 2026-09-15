//
//  osm_bridge.m — OSMesa 경로 (Zink over MoltenVK).
//  PojavLauncher iOS 의 ctxbridges/osm_bridge.m 을 옮긴 것.
//
//  OSMesa 는 소프트웨어 프레임버퍼에 그린다(Zink 를 쓰면 실제 래스터화는 Vulkan=MoltenVK 가
//  한다). 화면에 올리는 방법이 EGL 경로와 완전히 달라서, 매 프레임 버퍼를 CGImage 로 감싸
//  레이어 contents 에 붙인다 — 그래서 이 경로의 레이어는 CAMetalLayer 가 아니라 CALayer 다.
//
#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>

#include <dlfcn.h>

#include "bridge_tbl.h"
#include "osm_bridge.h"
#include "../flame_environ.h"

static osmesa_library handle;

static void dlsym_OSMesa(void) {
    const char *name = getenv("POJAV_RENDERER");
    if (!name || !*name) name = RENDERER_NAME_VK_ZINK;
    void *dl = dlopen([NSString stringWithFormat:@"@rpath/%s", name].UTF8String, RTLD_GLOBAL);
    NSCAssert(dl != NULL, @"OSMesa 를 찾지 못했습니다: %s", dlerror());

    handle.OSMesaMakeCurrent = dlsym(dl, "OSMesaMakeCurrent");
    handle.OSMesaGetCurrentContext = dlsym(dl, "OSMesaGetCurrentContext");
    handle.OSMesaCreateContext = dlsym(dl, "OSMesaCreateContext");
    handle.OSMesaDestroyContext = dlsym(dl, "OSMesaDestroyContext");
    handle.OSMesaPixelStore = dlsym(dl, "OSMesaPixelStore");
    handle.glGetString = dlsym(dl, "glGetString");
    handle.glClearColor = dlsym(dl, "glClearColor");
    handle.glClear = dlsym(dl, "glClear");
    handle.glFinish = dlsym(dl, "glFinish");
}

static bool osm_init(void) {
    dlsym_OSMesa();
    return true;   // 그 외 초기화는 컨텍스트 생성 때 한다
}

static osm_render_window_t *osm_init_context(osm_render_window_t *share) {
    osm_render_window_t *window = calloc(1, sizeof(osm_render_window_t));
    OSMesaContext context = handle.OSMesaCreateContext(GL_RGBA, share ? share->context : NULL);
    if (!context) {
        NSLog(@"[FlameOSM] OSMesaCreateContext 실패");
        free(window);
        return NULL;
    }
    window->context = context;
    return window;
}

/// 창 크기가 바뀌었으면 버퍼를 다시 잡고 컨텍스트를 붙인다.
static void osm_apply_current_ll(void) {
    if (currentBundle->osm.width == windowWidth && currentBundle->osm.height == windowHeight) return;

    currentBundle->osm.width = windowWidth;
    currentBundle->osm.height = windowHeight;
    currentBundle->osm.buffer = reallocf(currentBundle->osm.buffer, (size_t)windowWidth * windowHeight * 4);

    handle.OSMesaMakeCurrent(currentBundle->osm.context, currentBundle->osm.buffer,
                             GL_UNSIGNED_BYTE, currentBundle->osm.width, currentBundle->osm.height);
    handle.OSMesaPixelStore(OSMESA_ROW_LENGTH, currentBundle->osm.width);
    // OSMesa 기본은 아래에서 위로 그린다 — 0 으로 두면 위에서 아래(=화면과 같은 방향).
    handle.OSMesaPixelStore(OSMESA_Y_UP, 0);
}

static void osm_make_current(osm_render_window_t *bundle) {
    if (!bundle) {
        if (currentBundle) {
            free(currentBundle->osm.buffer);
            CGColorSpaceRelease(currentBundle->osm.color_space);
            currentBundle->osm.buffer = NULL;
            currentBundle->osm.color_space = NULL;
            currentBundle->osm.width = currentBundle->osm.height = 0;
            currentBundle = NULL;
        }
        handle.OSMesaMakeCurrent(NULL, NULL, 0, 0, 0);
        return;
    }

    currentBundle = (basic_render_window_t *)bundle;
    currentBundle->osm.color_space = CGColorSpaceCreateDeviceRGB();
    osm_apply_current_ll();
}

void osm_swap_buffers(void) {
    if (!currentBundle) return;
    osm_apply_current_ll();
    handle.glFinish();   // 마지막 프레임이 버퍼에 다 써지도록 강제

    osm_render_window_t bundle = currentBundle->osm;
    int w = windowWidth, h = windowHeight;
    dispatch_async(dispatch_get_main_queue(), ^{
        CGDataProviderRef provider =
            CGDataProviderCreateWithData(NULL, bundle.buffer, (size_t)w * h * 4, NULL);
        CGImageRef bitmap = CGImageCreate(w, h, 8, 32, 4 * w, bundle.color_space,
                                          kCGImageAlphaNoneSkipLast | kCGBitmapByteOrderDefault,
                                          provider, NULL, FALSE, kCGRenderingIntentDefault);
        flameSurfaceLayer.contents = (__bridge id)bitmap;
        CGImageRelease(bitmap);
        CGDataProviderRelease(provider);
    });
}

static void osm_swap_interval(int swapInterval) { /* OSMesa 는 vsync 개념이 없다 */ }
static void osm_terminate(void) { /* 해제할 GL 리소스가 없다 */ }

void set_osm_bridge_tbl(void) {
    br_init = osm_init;
    br_init_context = (br_init_context_t)osm_init_context;
    br_make_current = (br_make_current_t)osm_make_current;
    br_swap_buffers = osm_swap_buffers;
    br_swap_interval = osm_swap_interval;
    br_terminate = osm_terminate;
}
