//
//  bridge_tbl.h — 렌더러 백엔드 함수 테이블.
//  PojavLauncher iOS 의 ctxbridges/bridge_tbl.h 를 옮긴 것.
//
//  ⚠️ 원본은 헤더에 extern 없이 전역을 뒀다(-fcommon 전제). 여기서는 extern 선언 +
//     flame_gl.m 의 단일 정의로 바꿨다.
//
#pragma once

#include <stdbool.h>
#include <stdlib.h>
#include "gl_bridge.h"
#include "osm_bridge.h"

typedef union {
    gl_render_window_t gl;
    osm_render_window_t osm;
} basic_render_window_t;

typedef basic_render_window_t *(*br_init_context_t)(basic_render_window_t *share);
typedef void (*br_make_current_t)(basic_render_window_t *bundle);

extern bool (*br_init)(void);
extern br_init_context_t br_init_context;
extern br_make_current_t br_make_current;
extern void (*br_swap_buffers)(void);
extern void (*br_swap_interval)(int swapInterval);
extern void (*br_terminate)(void);

/// 현재 스레드에 바인딩된 컨텍스트. GL 은 스레드별 커런트 컨텍스트를 갖는다.
extern __thread basic_render_window_t *currentBundle;

static inline basic_render_window_t *br_get_current(void) { return currentBundle; }
