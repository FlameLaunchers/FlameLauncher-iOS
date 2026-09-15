#!/bin/bash
#
# MobileGlues 를 iOS(arm64) 용으로 빌드해 Runtime/Frameworks 에 넣는다.
#
# ── 왜 직접 빌드하는가 ────────────────────────────────────────────────────────
# MobileGlues 는 업스트림 CMake 에 iOS 타깃이 있다(`if(MACOS)` 블록이 MetalANGLE 의
# libEGL/libGLESv2 프레임워크와 Metal 을 링크한다). 그런데 릴리스는 APK 뿐이라
# iOS dylib 은 아무도 배포하지 않는다 — PojavLauncher iOS·Amethyst 도 안 넣는다.
#
# ── 세 군데를 고쳐야 컴파일된다 ───────────────────────────────────────────────
# iOS 분기가 실제로 컴파일된 적이 없어서 셋이 막혀 있다. 전부 **기계적인 수정**이고
# 동작을 바꾸지 않는다:
#   1) gl/framebuffer.cpp  __attribute__((alias)) 는 Mach-O 에 없다.
#                          multidraw.cpp / enable.cpp 는 이미 __APPLE__ 에서
#                          전달 함수로 바꿔 뒀는데 이 파일만 빠졌다 — 같게 맞춘다.
#   2) egl/trace.h         __NR_gettid 는 리눅스 syscall 번호다.
#                          Darwin 에서는 pthread_threadid_np 를 쓴다.
#   3) CMakeLists.txt      -Wl,-Bsymbolic-functions 는 GNU ld 전용이라 Apple ld 가
#                          거부한다. Mach-O 는 2단계 네임스페이스라 필요도 없다.
#
# ── 그리고 iOS 에서만 드러나는 버그 하나 ──────────────────────────────────────
#   4) gl/framebuffer.cpp  glFramebufferTexture 는 **ES 3.2** 진입점인데 호스트로
#                          그냥 통과시킨다. 안드로이드 호스트는 3.2 라 드러나지 않지만
#                          iOS 의 호스트는 ANGLE Metal = **ES 3.0** 이다. ANGLE 은
#                          심볼을 내보내되(3.2 API 전체를 export 한다) ES 3.0
#                          컨텍스트에서는 호출을 거부하므로 **아무것도 붙지 않는다**.
#                          Iris 는 DSA 경로로 glNamedFramebufferTexture → 이 함수를
#                          부르고, 결과를 확인해 36055
#                          (GL_FRAMEBUFFER_INCOMPLETE_MISSING_ATTACHMENT)를 받고
#                          "Failed to create shader rendering pipeline" 로 셰이더를 끈다.
#                          ES 3.2 미만에서는 2D/레이어 진입점으로 내려준다.
#
# 사용:  Scripts/build-mobileglues.sh [ref]
set -euo pipefail

REPO="https://github.com/MobileGL-Dev/MobileGlues.git"
REF="${1:-main}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

command -v cmake >/dev/null || { echo "cmake 가 필요합니다: brew install cmake"; exit 1; }
command -v ninja >/dev/null || { echo "ninja 가 필요합니다: brew install ninja"; exit 1; }

echo "▸ MobileGlues ($REF) 받는 중… (glslang / SPIRV-Cross 서브모듈 포함)"
git clone --depth 1 --branch "$REF" --recurse-submodules --shallow-submodules \
  "$REPO" "$WORK/src" >/dev/null 2>&1
SRC="$WORK/src/MobileGlues-cpp"

echo "▸ 패치 적용"
python3 - "$SRC" <<'PY'
import pathlib, sys
src = pathlib.Path(sys.argv[1])

# 1) Mach-O 에는 alias 속성이 없다 — 전달 함수로 바꾼다.
p = src / "gl/framebuffer.cpp"
s = p.read_text()
old = '''extern "C" {
GLAPI GLAPIENTRY void glDeleteFramebuffersARB(GLsizei n, const GLuint* names) __attribute__((alias("glDeleteFramebuffers")));'''
assert old in s, "framebuffer.cpp: alias 블록을 못 찾았습니다 (업스트림이 바뀜)"
if True:
    body = s.split('extern "C" {', 1)[1]
    head, rest = s.split('extern "C" {', 1)
    block, tail = rest.split('\n}', 1)
    s = (head + "#ifndef __APPLE__\n" + 'extern "C" {' + block + "\n}\n#else\n"
         + 'extern "C" {\n'
           'GLAPI GLAPIENTRY void glDeleteFramebuffersARB(GLsizei n, const GLuint* names) {\n'
           '    glDeleteFramebuffers(n, names);\n'
           '}\n'
           'GLAPI GLAPIENTRY void glFramebufferRenderbufferARB(GLenum target, GLenum attachment,\n'
           '                                                   GLenum renderbuffertarget, GLuint renderbuffer) {\n'
           '    glFramebufferRenderbuffer(target, attachment, renderbuffertarget, renderbuffer);\n'
           '}\n'
           'GLAPI GLAPIENTRY void glFramebufferTextureLayerARB(GLenum target, GLenum attachment, GLuint texture,\n'
           '                                                   GLint level, GLint layer) {\n'
           '    glFramebufferTextureLayer(target, attachment, texture, level, layer);\n'
           '}\n'
           '}\n#endif' + tail)
    p.write_text(s)
    print("  framebuffer.cpp")

# 2) __NR_gettid 는 리눅스 전용.
p = src / "egl/trace.h"
s = p.read_text()
old = "    return (int)syscall(__NR_gettid);"
assert old in s, "egl/trace.h: __NR_gettid 를 못 찾았습니다 (업스트림이 바뀜)"
if True:
    s = s.replace(old, """#ifdef __APPLE__
    uint64_t tid = 0;
    pthread_threadid_np(NULL, &tid);
    return (int)tid;
#else
    return (int)syscall(__NR_gettid);
#endif""")
    if "#include <pthread.h>" not in s:
        s = s.replace("#define MG_EGL_TRACE 0", "#include <pthread.h>\n\n#define MG_EGL_TRACE 0", 1)
    p.write_text(s)
    print("  egl/trace.h")

# 4) glFramebufferTexture 는 ES 3.2 진입점이다 — 3.0 호스트에서는 내려서 붙인다.
#    ⚠️ 호출 지점이 **두 곳**이다. 공개 진입점만 고치면 월드는 그려지는데 손이 사라진다
#       (reattach 는 glDrawBuffers 셔플이 부른다 — 아래 설명 참고).
p = src / "gl/framebuffer.cpp"
s = p.read_text()

HELPER = """// ES 3.2 의 glFramebufferTexture 를 그 아래 호스트에서도 되게 한다.
//
// ⚠️ ANGLE 은 백엔드와 무관하게 3.2 API 심볼을 전부 내보낸다. 그래서 dlsym 은 성공하고
//    호출도 되지만, ES 3.0 컨텍스트에서는 거부되어 **아무것도 붙지 않는다.**
//    붙은 줄 알고 진행하면 그 패스는 아무 데도 그리지 않는다.
//    안드로이드(호스트 3.2)에서는 절대 드러나지 않고, ANGLE Metal(3.0)에서만 터진다.
static void mg_attach_whole_texture(GLenum target, GLenum attachment,
                                    GLuint texture, GLint level) {
    if (hardware && hardware->es_version >= 320) {
        GLES.glFramebufferTexture(target, attachment, texture, level);
        return;
    }
    // 레이어드 렌더링은 3.2 미만에서 불가능하다. 비레이어드 텍스처라면 해당 레벨 하나를
    // 붙이는 것과 같은 의미다.
    GLenum textarget = GL_TEXTURE_2D;
    if (TextureObject* obj = mgGetTexObjectByID(texture))
        textarget = ConvertTextureTargetToGLEnum(obj->target);

    if (textarget == GL_TEXTURE_2D_ARRAY || textarget == GL_TEXTURE_3D)
        GLES.glFramebufferTextureLayer(target, attachment, texture, level, 0);
    else
        GLES.glFramebufferTexture2D(target, attachment, textarget, texture, level);
}

"""

anchor = "// Put a recorded attachment onto a (possibly different) attachment point, the"
assert anchor in s, "framebuffer.cpp: reattach 주석을 못 찾았습니다 (업스트림이 바뀜)"
s = s.replace(anchor, HELPER + anchor, 1)

# (a) 공개 진입점
old = """    update_attachment(target, attachment, {attach_kind_t::TextureAll, 0, texture, level, 0});
    GLES.glFramebufferTexture(target, attachment, texture, level);
}"""
new = """    update_attachment(target, attachment, {attach_kind_t::TextureAll, 0, texture, level, 0});
    mg_attach_whole_texture(target, attachment, texture, level);
}"""
assert old in s, "framebuffer.cpp: glFramebufferTexture 본문을 못 찾았습니다 (업스트림이 바뀜)"
s = s.replace(old, new, 1)

# (b) 셔플 복구 경로 — 셰이더에서 손이 사라지던 진짜 원인
old = """    case attach_kind_t::TextureAll:
        GLES.glFramebufferTexture(target, attachment, a.texture, a.level);
        break;"""
new = """    case attach_kind_t::TextureAll:
        // ⚠️ 여기가 빠지면 **월드는 그려지는데 손만 사라진다.** 월드는 draw buffer 구성이
        //    고정이라 셔플이 없고, gbuffers_hand 는 별도 구성이라 셔플 → 복구를 탄다.
        //    복구에서 어태치먼트가 유실되면 그 패스만 아무 데도 안 그린다.
        mg_attach_whole_texture(target, attachment, a.texture, a.level);
        break;"""
assert old in s, "framebuffer.cpp: reattach 의 TextureAll 분기를 못 찾았습니다 (업스트림이 바뀜)"
s = s.replace(old, new, 1)

if '#include "texture.h"' not in s:
    s = s.replace('#include "framebuffer.h"', '#include "framebuffer.h"\n#include "texture.h"', 1)
p.write_text(s)
print("  framebuffer.cpp: glFramebufferTexture ES3.0 폴백 (진입점 + 셔플 복구)")

# 5) 애플 분기는 config.json 을 **아예 읽지 않는다** — init_settings 가 전부 하드코딩이다.
#    그래서 MG_DIR_PATH/config.json 을 써 줘도 아무 효과가 없다(로그의 설정값이 그 블록과
#    정확히 일치하는 것으로 확인). 런처가 조절해야 하는 값만 config 로 덮어쓸 수 있게 연다.
p = src / "config/settings.cpp"
s = p.read_text()
old = """    global_settings.hide_mg_env_level = HideMGEnvLevel::Disabled;

#else"""
new = """    global_settings.hide_mg_env_level = HideMGEnvLevel::Disabled;

    // ⚠️ 위는 전부 하드코딩이라 config.json 이 통째로 무시된다. 런처가 런타임에 바꿔야 하는
    //    값만 여기서 덮어쓴다. 키가 없거나(-1) 파일이 없으면 위 기본값 그대로 간다.
    //
    //    ext_direct_state_access 가 특히 중요하다: 켜져 있으면 MobileGlues 가
    //    GL_ARB_direct_state_access 를 광고하고, Iris 가 그걸 보고 DSA 경로
    //    (glNamedFramebufferTexture → glFramebufferTexture)를 탄다. 그런데
    //    glFramebufferTexture 는 ES 3.2 진입점이고 ANGLE Metal 은 ES 3.0 이다.
    if (initialized || config_refresh()) {
        int dsa = config_get_int("enableExtDirectStateAccess");
        if (dsa >= 0) global_settings.ext_direct_state_access = (dsa > 0);

        int computeShader = config_get_int("enableExtComputeShader");
        if (computeShader >= 0) global_settings.ext_compute_shader = (computeShader > 0);
    }

#else"""
assert old in s, "settings.cpp: 애플 분기 끝을 못 찾았습니다 (업스트림이 바뀜)"
s = s.replace(old, new, 1)
p.write_text(s)
print("  config/settings.cpp: 애플에서도 config.json 반영")

# 6) GL 오류 로그를 **상시로 켠다**(LOG_E / LOG_F 만).
#    CHECK_GL_ERROR 매크로는 이미 226곳에서 glGetError() 를 부르고 있는데, 로그 매크로가
#    GLOBAL_DEBUG 로 막혀 있어 결과를 통째로 버린다 — 비용은 다 치르고 정보만 안 얻는 상태다.
#    LOG_D(호출마다 찍는 폭주 로그)는 그대로 끄고 오류만 살린다.
#    이게 꺼져 있어서 ES 3.2 진입점 문제들을 눈으로 못 보고 한참 헤맸다.
p = src / "gl/log.h"
s = p.read_text()
old = """#define LOG_E(...)                                                                                                     \\
    if (DEBUG || GLOBAL_DEBUG) {                                                                                       \\
        __android_log_print(ANDROID_LOG_ERROR, RENDERERNAME, __VA_ARGS__);                                             \\"""
new = """#define LOG_E(...)                                                                                                     \\
    if (true) {                                                                                                        \\
        __android_log_print(ANDROID_LOG_ERROR, RENDERERNAME, __VA_ARGS__);                                             \\"""
assert old in s, "log.h: LOG_E 정의를 못 찾았습니다 (업스트림이 바뀜)"
s = s.replace(old, new, 1)

old = """#define LOG_F(...)                                                                                                     \\
    if (DEBUG || GLOBAL_DEBUG) {                                                                                       \\
        __android_log_print(ANDROID_LOG_FATAL, RENDERERNAME, __VA_ARGS__);                                             \\"""
new = """#define LOG_F(...)                                                                                                     \\
    if (true) {                                                                                                        \\
        __android_log_print(ANDROID_LOG_FATAL, RENDERERNAME, __VA_ARGS__);                                             \\"""
assert old in s, "log.h: LOG_F 정의를 못 찾았습니다 (업스트림이 바뀜)"
s = s.replace(old, new, 1)
p.write_text(s)
print("  gl/log.h: GL 오류 로그 상시 켜기")

# 8) ES 컨텍스트를 **3.2 로 올려서 요청**한다.
#
#    MobileGlues 는 EGL_CONTEXT_CLIENT_VERSION=3 만 주고 EGL_CONTEXT_MINOR_VERSION 을
#    안 준다. EGL 기본값이 0 이므로 **항상 ES 3.0 컨텍스트**가 나온다.
#    안드로이드는 드라이버가 3.2 를 주는 경우가 많아 드러나지 않지만, ANGLE Metal 은
#    요청한 그대로 3.0 을 준다 — 그래서 iOS 에서만 3.1/3.2 경로가 통째로 막혀 있었다:
#      · glFramebufferTexture (ES 3.2 진입점) 가 조용히 거부됨
#      · emulate_texture_buffer 가 켜져 텍스처 유닛 15(= Iris 의 noisetex) 를 뺏김
#      · GL_ARB_vertex_attrib_binding 광고 안 함
#    3.2 → 3.1 → 3.0 순으로 내려가며 시도한다.
p = src / "egl/loader.cpp"
s = p.read_text()
old = "    EGLint ctxAttribs[] = {EGL_CONTEXT_CLIENT_VERSION, 3, EGL_NONE};"
new = ("    EGLint ctxAttribs[] = {EGL_CONTEXT_CLIENT_VERSION, 3, EGL_CONTEXT_MINOR_VERSION, 2, EGL_NONE};")
assert old in s, "egl/loader.cpp: 프로브 컨텍스트 속성을 못 찾았습니다 (업스트림이 바뀜)"
s = s.replace(old, new, 1)

old = """    eglContext = egl_eglCreateContext(eglDisplay, pbufConfig, EGL_NO_CONTEXT, ctxAttribs);
    if (eglContext == EGL_NO_CONTEXT) {"""
new = """    eglContext = egl_eglCreateContext(eglDisplay, pbufConfig, EGL_NO_CONTEXT, ctxAttribs);
    // 3.2 를 안 주는 호스트면 3.1, 그것도 안 되면 3.0 으로 내려간다.
    for (EGLint minor = 1; eglContext == EGL_NO_CONTEXT && minor >= 0; --minor) {
        ctxAttribs[3] = minor;
        eglContext = egl_eglCreateContext(eglDisplay, pbufConfig, EGL_NO_CONTEXT, ctxAttribs);
    }
    if (eglContext == EGL_NO_CONTEXT) {"""
assert old in s, "egl/loader.cpp: 프로브 컨텍스트 생성부를 못 찾았습니다"
s = s.replace(old, new, 1)
p.write_text(s)
print("  egl/loader.cpp: 프로브 컨텍스트 ES 3.2 요청 (3.1/3.0 폴백)")

# 앱이 만드는 **실제** 컨텍스트도 같이 올린다.
p = src / "egl/egl.cpp"
s = p.read_text()
old = """        rewritten.push_back(EGL_CONTEXT_CLIENT_VERSION);
        rewritten.push_back(kBackendDesktopGlClientVersion);
        rewritten.push_back(EGL_NONE);
        *backend_attributes = std::move(rewritten);
        return true;"""
new = """        rewritten.push_back(EGL_CONTEXT_CLIENT_VERSION);
        rewritten.push_back(kBackendDesktopGlClientVersion);
        // ⚠️ 마이너 버전을 안 주면 EGL 기본값 0 → ES 3.0 이 나온다. 데스크톱 GL 을
        //    흉내내려면 3.1/3.2 기능이 필요하므로 최대치를 요청한다(아래에서 폴백).
        rewritten.push_back(EGL_CONTEXT_MINOR_VERSION);
        rewritten.push_back(2);
        rewritten.push_back(EGL_NONE);
        *backend_attributes = std::move(rewritten);
        return true;"""
assert old in s, "egl/egl.cpp: 백엔드 속성 조립부를 못 찾았습니다 (업스트림이 바뀜)"
s = s.replace(old, new, 1)

old = """        EGLContext context = egl_eglCreateContext(dpy, config, share_context, backend_attributes.data());"""
new = """        EGLContext context = egl_eglCreateContext(dpy, config, share_context, backend_attributes.data());
        // 3.2 를 못 주는 호스트면 3.1 → 3.0 으로 내려간다. 마이너 버전은 항상 마지막에서
        // 두 번째 값이다(바로 위에서 EGL_NONE 직전에 넣었다).
        if (context == EGL_NO_CONTEXT && backend_attributes.size() >= 2) {
            EGLint& minor = backend_attributes[backend_attributes.size() - 2];
            for (EGLint want = 1; context == EGL_NO_CONTEXT && want >= 0; --want) {
                minor = want;
                context = egl_eglCreateContext(dpy, config, share_context, backend_attributes.data());
            }
        }"""
assert old in s, "egl/egl.cpp: eglCreateContext 호출부를 못 찾았습니다"
s = s.replace(old, new, 1)
p.write_text(s)
print("  egl/egl.cpp: 실제 컨텍스트 ES 3.2 요청 (3.1/3.0 폴백)")

# 10) 정수 정점 속성의 **부호를 셰이더 선언에 맞춘다**. (실제 수정)
#
#     ANGLE Metal 이 직접 알려준 실패 사유:
#       "Cannot convert attribute from MTLAttributeFormatUShort4 to a signed integer type"
#       (mtl_pipeline_cache.mm, CreateRenderPipelineState)
#
#     Iris 의 확장 엔티티 포맷은 iris_Entity 를 셰이더에서 ivec3(부호 있음)로 선언하고
#     정점 배열은 GL_UNSIGNED_SHORT(부호 없음)로 공급한다. GL/GLES 는 이 조합을 허용하고
#     안드로이드 드라이버도 받아주지만, **Metal 은 정점 포맷의 부호가 셰이더와 같아야 한다.**
#     그래서 ANGLE 이 렌더 파이프라인 생성 자체를 실패시키고, 그 프로그램의 모든 드로우가
#     GL_INVALID_OPERATION 으로 거부된다 — 손·아이템·엔티티·입자가 통째로 사라진다.
#     지형은 Sodium 포맷이라 부호가 맞아서 멀쩡하다(그래서 월드만 보였다).
#
#     ⚠️ 일괄 변환은 안 된다. Sodium 은 uvec 속성에 부호 없는 타입을 정상적으로 쓴다.
#        반드시 **셰이더가 선언한 부호**를 보고 그쪽에 맞춰야 한다.
p = src / "gl/drawing.cpp"
s = p.read_text()
old = "void prepareForDraw() {"
new = """// GL 은 정수 정점 속성의 부호가 셰이더 선언과 달라도 받아주지만 Metal 은 아니다.
static GLenum mg_match_sign(GLenum type, bool want_signed) {
    if (want_signed) switch (type) {
        case GL_UNSIGNED_BYTE: return GL_BYTE;
        case GL_UNSIGNED_SHORT: return GL_SHORT;
        case GL_UNSIGNED_INT: return GL_INT;
        default: return type;
    }
    switch (type) {
        case GL_BYTE: return GL_UNSIGNED_BYTE;
        case GL_SHORT: return GL_UNSIGNED_SHORT;
        case GL_INT: return GL_UNSIGNED_INT;
        default: return type;
    }
}

// 프로그램의 정수 속성 목록: (위치, 셰이더가 부호 있는 타입으로 선언했는가).
// 링크 결과에만 의존하므로 프로그램당 한 번만 만든다.
static const std::vector<std::pair<GLint, bool>>& mg_integer_attributes(GLuint program) {
    static UnorderedMap<GLuint, std::vector<std::pair<GLint, bool>>> cache;
    auto it = cache.find(program);
    if (it != cache.end()) return it->second;

    std::vector<std::pair<GLint, bool>> list;
    GLint nattr = 0, maxlen = 0;
    GLES.glGetProgramiv(program, GL_ACTIVE_ATTRIBUTES, &nattr);
    GLES.glGetProgramiv(program, GL_ACTIVE_ATTRIBUTE_MAX_LENGTH, &maxlen);
    std::vector<char> name((size_t)(maxlen > 0 ? maxlen : 64) + 1);
    for (GLint i = 0; i < nattr; i++) {
        GLsizei len = 0;
        GLint size = 0;
        GLenum type = 0;
        GLES.glGetActiveAttrib(program, (GLuint)i, (GLsizei)name.size(), &len, &size, &type, name.data());
        bool is_signed;
        switch (type) {
            case GL_INT: case GL_INT_VEC2: case GL_INT_VEC3: case GL_INT_VEC4:
                is_signed = true;
                break;
            case GL_UNSIGNED_INT: case GL_UNSIGNED_INT_VEC2:
            case GL_UNSIGNED_INT_VEC3: case GL_UNSIGNED_INT_VEC4:
                is_signed = false;
                break;
            default:
                continue;   // 실수형 속성은 Metal 이 알아서 변환한다
        }
        GLint loc = GLES.glGetAttribLocation(program, name.data());
        if (loc >= 0) list.emplace_back(loc, is_signed);
    }
    return cache.emplace(program, std::move(list)).first->second;
}

// 부호가 어긋난 정수 속성을 셰이더 쪽 부호로 다시 지정한다.
// 값 자체는 그대로다 — 같은 비트를 어떻게 읽을지만 바뀐다.
static void mg_fix_integer_attribute_signedness(GLuint program) {
    const auto& attrs = mg_integer_attributes(program);
    if (attrs.empty()) return;

    GLint saved_array_buffer = -1;
    for (const auto& entry : attrs) {
        const GLint loc = entry.first;
        GLint integer = 0, type = 0;
        GLES.glGetVertexAttribiv((GLuint)loc, GL_VERTEX_ATTRIB_ARRAY_INTEGER, &integer);
        if (!integer) continue;   // glVertexAttribPointer 로 지정된 것은 건드리지 않는다
        GLES.glGetVertexAttribiv((GLuint)loc, GL_VERTEX_ATTRIB_ARRAY_TYPE, &type);
        const GLenum fixed = mg_match_sign((GLenum)type, entry.second);
        if (fixed == (GLenum)type) continue;

        GLint size = 0, stride = 0, buffer = 0;
        void* offset = nullptr;
        GLES.glGetVertexAttribiv((GLuint)loc, GL_VERTEX_ATTRIB_ARRAY_SIZE, &size);
        GLES.glGetVertexAttribiv((GLuint)loc, GL_VERTEX_ATTRIB_ARRAY_STRIDE, &stride);
        GLES.glGetVertexAttribiv((GLuint)loc, GL_VERTEX_ATTRIB_ARRAY_BUFFER_BINDING, &buffer);
        GLES.glGetVertexAttribPointerv((GLuint)loc, GL_VERTEX_ATTRIB_ARRAY_POINTER, &offset);
        if (!buffer) continue;    // 클라이언트 배열은 VAO 안에서 어차피 못 쓴다

        if (saved_array_buffer < 0) GLES.glGetIntegerv(GL_ARRAY_BUFFER_BINDING, &saved_array_buffer);
        GLES.glBindBuffer(GL_ARRAY_BUFFER, (GLuint)buffer);
        GLES.glVertexAttribIPointer((GLuint)loc, size, fixed, stride, offset);
    }
    if (saved_array_buffer >= 0) GLES.glBindBuffer(GL_ARRAY_BUFFER, (GLuint)saved_array_buffer);
}

void prepareForDraw() {
    if (gl_state->current_program) mg_fix_integer_attribute_signedness(gl_state->current_program);"""
assert old in s, "drawing.cpp: prepareForDraw 를 못 찾았습니다"
s = s.replace(old, new, 1)
p.write_text(s)
print("  gl/drawing.cpp: 정수 정점 속성 부호 정합 (실제 수정)")

# 11) glGetIntegerv(GL_MAJOR/MINOR_VERSION) 을 **문자열 버전과 일치**시킨다.
#
#     MobileGlues 는 glGetString(GL_VERSION) 으로 "4.0.0 MobileGlues" 를 광고하면서,
#     정수 질의는 ES 컨텍스트일 때 드라이버로 넘겨 **3.0** 을 돌려준다. 두 답이 모순이다.
#
#     LWJGL 3.4.1 은 정수 질의를 **먼저** 믿는다 (opengl/GL.java):
#         callPV(GL_MAJOR_VERSION, …, GetIntegerv);
#         if (no error && 3 <= major) { …이 값을 쓴다… }
#         else { …문자열 파싱으로 폴백… }
#     그래서 major=3, minor=0 → GL 3.0 으로 판정하고 GL 3.3+ 진입점을 **하나도 매핑하지
#     않는다.** MobileGlues 가 glGenSamplers 를 내보내는데도 포인터가 0 이라
#     마인크래프트 26.2 가 부팅 중에 죽는다:
#         FATAL ERROR in native method: … at org.lwjgl.opengl.GL33C.nglGenSamplers
#
#     앱은 MobileGlues 를 통해 **데스크톱 GL API** 를 쓰고 있다. 그러면 버전 질의도
#     에뮬레이트하는 데스크톱 버전으로 답해야 한다 — 문자열이 이미 그렇게 답하고 있다.
p = src / "gl/getter.cpp"
s = p.read_text()

# [진단용] 버전 정수에 누가 무엇을 답했는지. LWJGL 은 이 값으로 지원 GL 버전 집합을
# 만들기 때문에, 여기서 3 이 나가면 GL 3.3+ 진입점이 통째로 안 잡힌다.
marker = "Version GLVersion;"
assert marker in s, "getter.cpp: GLVersion 정의를 못 찾았습니다 (업스트림이 바뀜)"
s = s.replace(marker, marker + """

#define MG_LOG_VERSION_ANSWER(which, branch, value)                                   \\
    do {                                                                              \\
        static int mg_version_logs = 0;                                               \\
        if (mg_version_logs < 8) {                                                    \\
            mg_version_logs++;                                                        \\
            LOG_W_FORCE("MGVER GL_%s_VERSION -> %d  (분기=%s)", which, (int)(value), branch) \\
        }                                                                             \\
    } while (0)""", 1)

old = """        if (g_current_ctx && g_current_ctx->client_type == EGL_OPENGL_API) {
            (*params) = g_current_ctx->granted_major;
        } else if (g_current_ctx) {
            GLES.glGetIntegerv(GL_MAJOR_VERSION, params);
        } else {
            (*params) = GLVersion.Major;
        }"""
new = """        if (g_current_ctx && g_current_ctx->client_type == EGL_OPENGL_API) {
            (*params) = g_current_ctx->granted_major;
            MG_LOG_VERSION_ANSWER("MAJOR", "granted(desktop)", *params);
        } else {
            // ⚠️ 드라이버(호스트 ES)로 넘기지 않는다. 그러면 GL_VERSION 문자열이 말하는
            //    데스크톱 버전과 답이 달라지고, 정수 질의를 먼저 믿는 로더는 GL 3.3+ 를
            //    통째로 못 쓰게 된다(위 설명 참고).
            (*params) = GLVersion.Major;
            MG_LOG_VERSION_ANSWER("MAJOR", g_current_ctx ? "GLVersion(es-ctx)" : "GLVersion(no-ctx)", *params);
        }"""
assert old in s, "getter.cpp: GL_MAJOR_VERSION 분기를 못 찾았습니다 (업스트림이 바뀜)"
s = s.replace(old, new, 1)

old = """        if (g_current_ctx && g_current_ctx->client_type == EGL_OPENGL_API) {
            (*params) = g_current_ctx->granted_minor;
        } else if (g_current_ctx) {
            GLES.glGetIntegerv(GL_MINOR_VERSION, params);
        } else {
            (*params) = GLVersion.Minor;
        }"""
new = """        if (g_current_ctx && g_current_ctx->client_type == EGL_OPENGL_API) {
            (*params) = g_current_ctx->granted_minor;
            MG_LOG_VERSION_ANSWER("MINOR", "granted(desktop)", *params);
        } else {
            (*params) = GLVersion.Minor;   // 위와 같은 이유
            MG_LOG_VERSION_ANSWER("MINOR", g_current_ctx ? "GLVersion(es-ctx)" : "GLVersion(no-ctx)", *params);
        }"""
assert old in s, "getter.cpp: GL_MINOR_VERSION 분기를 못 찾았습니다 (업스트림이 바뀜)"
s = s.replace(old, new, 1)
p.write_text(s)
print("  gl/getter.cpp: 버전 정수 질의를 문자열과 일치시킴")

# 12) glGetTexLevelParameteriv 를 ES 3.0 에서도 답하게 한다.
#
#     ⚠️ glGetTexLevelParameteriv 는 **ES 3.1 진입점**이다. ES 3.0 호스트(ANGLE Metal)에서는
#        호출이 거부되고 params 가 손도 안 닿은 채 돌아온다 → 호출자는 0 을 읽는다.
#        마인크래프트 1.21.6 부터 blaze3d 가 이 값으로 텍스처 포맷을 판정해서, NeoForge 의
#        로딩 오버레이가 부팅 직후 죽었다:
#          IllegalArgumentException: Couldn't find a matching vanilla TextureFormat
#            for OpenGL internal format id 0
#            at com.mojang.blaze3d.opengl.GlDevice.createExternalTexture
#
#     MobileGlues 는 TextureObject 에 internal_format/width/height/depth 를 이미 추적한다.
#     드라이버에 물을 수 없을 때는 그 기록으로 답한다.
p = src / "gl/texture.cpp"
s = p.read_text()
old = """    LOG_D("es.glGetTexLevelParameteriv,target: %s, level: %d, pname: %s", glEnumToString(target), level,
          glEnumToString(pname))
    GLES.glGetTexLevelParameteriv(target, level, pname, params);"""
new = """    // ES 3.1 미만에는 이 진입점이 없다 — 넘기면 값이 안 채워져 호출자가 0 을 읽는다.
    // 우리가 들고 있는 텍스처 기록으로 답한다(위 설명 참고).
    if (hardware && hardware->es_version < 310) {
        if (TextureObject* obj = mgGetTexObjectByTarget(target)) {
            switch (pname) {
            case GL_TEXTURE_INTERNAL_FORMAT:
                (*params) = (GLint)obj->internal_format;
                return;
            case GL_TEXTURE_WIDTH:
                (*params) = nlevel(obj->width, level);
                return;
            case GL_TEXTURE_HEIGHT:
                (*params) = nlevel(obj->height, level);
                return;
            case GL_TEXTURE_DEPTH:
                (*params) = obj->depth > 0 ? nlevel(obj->depth, level) : 0;
                return;
            default:
                break;
            }
        }
    }

    LOG_D("es.glGetTexLevelParameteriv,target: %s, level: %d, pname: %s", glEnumToString(target), level,
          glEnumToString(pname))
    GLES.glGetTexLevelParameteriv(target, level, pname, params);"""
assert old in s, "glGetTexLevelParameteriv 폴스루를 못 찾았습니다 (업스트림이 바뀜)"
s = s.replace(old, new, 1)
p.write_text(s)
print("  gl/texture.cpp: ES3.0 에서 텍스처 레벨 질의 답하기")

# 13) glGenerateMipmap 전에 렌더 패스를 닫는다 (Apple GPU 드라이버 크래시 우회).
#
#     ANGLE Metal 은 이 호출에서 렌더 인코더를 끝내고 블릿 인코더로 넘어간다:
#       TextureMtl::generateMipmap → ContextMtl::endEncoding → getBlitCommandEncoder
#     Iris 의 컴포지트 패스처럼 **방금 렌더 타깃으로 쓴 텍스처**에 걸면 그 전환 도중
#     Apple GPU 드라이버가 죽는다. 실측 스택:
#       C [AGXMetalG15+0x3f0da4]
#       C [libGLESv2] RenderCommandEncoder::encodeMetalEncoder()
#       C [libGLESv2] TextureMtl::generateMipmap()
#       J org.lwjgl.opengl.GL30C.glGenerateMipmap
#       J net.irisshaders.iris.pipeline.CompositeRenderer.renderAll
#     (셰이더를 켜고 95초쯤 플레이하다 SIGSEGV)
#
#     먼저 flush 해서 렌더 패스를 정상적으로 닫아 두면 위험한 전환을 피한다.
#
#     ⚠️ 조건을 최대한 좁힌다. 처음엔 "기본 프레임버퍼가 아니면" 으로 걸었는데, Iris
#        컴포지트 체인에서는 그게 거의 항상 참이라 실측 **초당 81~109회** flush 가 나왔다.
#        flush 는 커맨드 버퍼 커밋이라 그 자체로 프레임이 끊긴다 (사용자 제보와 일치).
#        위험한 건 방금 그린 대상에 다시 밉맵을 거는 경우뿐이므로, 밉맵 대상 텍스처가
#        **지금 draw 프레임버퍼의 컬러 어태치먼트**일 때만 flush 한다.
# 13a) "이 텍스처가 지금 draw 프레임버퍼에 붙어 있나?" 를 물어볼 수단이 없어서 만든다.
p = src / "gl/framebuffer.h"
s = p.read_text()
anchor = "bool mg_draw_framebuffer_all_none();"
assert anchor in s, "framebuffer.h: mg_draw_framebuffer_all_none 선언을 못 찾았습니다 (업스트림이 바뀜)"
s = s.replace(anchor, anchor + """

// 지금 바인드된 draw 프레임버퍼의 컬러 어태치먼트 중에 이 텍스처가 있는가.
// glGenerateMipmap 우회(아래)가 "방금 그린 대상에 다시 밉맵을 건다" 는 위험한
// 경우만 골라내려고 쓴다. 렌더버퍼는 제외한다 -- 이름 공간이 텍스처와 달라서
// 번호가 겹치면 엉뚱하게 맞아버린다.
bool mg_draw_framebuffer_has_texture(GLuint texture);""", 1)
p.write_text(s)

p = src / "gl/framebuffer.cpp"
s = p.read_text()
anchor = "void ensure_max_attachments() {"
assert anchor in s, "framebuffer.cpp: ensure_max_attachments 를 못 찾았습니다 (업스트림이 바뀜)"
s = s.replace(anchor, """bool mg_draw_framebuffer_has_texture(GLuint texture) {
    if (texture == 0 || current_draw_fbo == 0) return false;
    const auto it = framebuffers.find(current_draw_fbo);
    if (it == framebuffers.end()) return false;
    for (const attachment_t& a : it->second->color_attachments) {
        if (a.kind == attach_kind_t::None) continue;
        if (a.kind == attach_kind_t::Renderbuffer) continue;
        if (a.texture == texture) return true;
    }
    return false;
}
""" + anchor, 1)
p.write_text(s)
print("  gl/framebuffer.{h,cpp}: draw 프레임버퍼 텍스처 조회 추가")

# 13b) glGenerateMipmap 전에 렌더 패스를 닫는다 (Apple GPU 드라이버 크래시 우회).
p = src / "gl/gl_native.cpp"
s = p.read_text()
old = "NATIVE_FUNCTION_HEAD(void, glGenerateMipmap, GLenum target) NATIVE_FUNCTION_END_NO_RETURN(void, glGenerateMipmap, target)"
new = """static GLenum mg_texture_binding_of(GLenum target) {
    switch (target) {
        case GL_TEXTURE_2D:       return GL_TEXTURE_BINDING_2D;
        case GL_TEXTURE_3D:       return GL_TEXTURE_BINDING_3D;
        case GL_TEXTURE_2D_ARRAY: return GL_TEXTURE_BINDING_2D_ARRAY;
        case GL_TEXTURE_CUBE_MAP: return GL_TEXTURE_BINDING_CUBE_MAP;
        default:                  return 0;
    }
}

extern "C" GLAPI GLAPIENTRY void glGenerateMipmap(GLenum target) {
    GLenum binding = mg_texture_binding_of(target);
    if (binding != 0) {
        GLint tex = 0;
        GLES.glGetIntegerv(binding, &tex);
        if (mg_draw_framebuffer_has_texture((GLuint)tex)) GLES.glFlush();
    }
    GLES.glGenerateMipmap(target);
    CHECK_GL_ERROR
}"""
assert old in s, "gl_native.cpp: glGenerateMipmap 패스스루를 못 찾았습니다 (업스트림이 바뀜)"
s = s.replace(old, new, 1)
assert '#include "mg.h"' in s, "gl_native.cpp: include 블록을 못 찾았습니다 (업스트림이 바뀜)"
if '#include "framebuffer.h"' not in s:
    s = s.replace('#include "mg.h"', '#include "mg.h"\n#include "framebuffer.h"', 1)
p.write_text(s)
print("  gl/gl_native.cpp: 렌더 타깃에 건 밉맵만 렌더 패스 닫기")

# 14) glXGetProcAddress 의 애플 분기가 **자기 자신을 건너뛴다**.
#
#     glx/lookup.cpp:
#         #ifdef __APPLE__
#             return dlsym((void*)(~(uintptr_t)0), real_func_name.c_str());
#
#     ~0 == (void*)-1 인데, 이 값의 뜻이 플랫폼마다 다르다:
#         안드로이드(LP64):  RTLD_DEFAULT   — 전역에서 찾기        (의도한 것)
#         애플:              RTLD_NEXT      — **나를 건너뛰고** 다음 객체에서 찾기
#     그래서 애플에서는 MobileGlues 가 자기 gl* 을 절대 돌려주지 않고 ANGLE 것을 준다.
#
#     LWJGL 3.3.3 은 이 경로를 아예 안 탄다 — iOS 에서 GetProcAddress 후보
#     (glX/wgl/OSMesa)가 하나도 안 잡혀서 dlsym(라이브러리 핸들)로 직행한다.
#     3.4.1 이 후보에 eglGetProcAddress 를 추가하면서 이 버그를 밟았다:
#         GL.java: if (GetProcAddress == NULL)
#                      GetProcAddress = library.getFunctionAddress("eglGetProcAddress");
#     MobileGlues 가 eglGetProcAddress 를 내보내므로 LWJGL 이 **모든 GL 함수**를
#     그걸로 해석하게 되고, GL 이름은 glXGetProcAddress 로 넘어가 ANGLE 로 빠진다.
#
#     증상(마인크래프트 26.2):
#       - glGetIntegerv 가 ANGLE 로 가서 GL 버전이 ES 3.0 으로 잡힌다
#         → LWJGL 의 지원 집합에 OpenGL33 이 안 들어감
#         → check_GL33 이 조용히 돌아서고 glGenSamplers 포인터가 0
#         → FATAL ERROR in native method … GL33C.nglGenSamplers
#       - 이 레이어의 다른 패치들(ES3.0 텍스처 레벨 질의 등)도 통째로 안 걸린다
#         ("OpenGL ES 3.1 Required" 가 계속 찍힌 이유)
#
#     RTLD_SELF 는 "나와 그 뒤 객체를 찾는다" 이다 — 우리 것을 먼저 주고,
#     구현하지 않은 건 그대로 ANGLE 로 흘려보낸다.
p = src / "glx/lookup.cpp"
s = p.read_text()
old = """#ifdef __APPLE__
    return dlsym((void*)(~(uintptr_t)0), real_func_name.c_str());
#else"""
new = """#ifdef __APPLE__
    // ⚠️ ~0 은 안드로이드에서만 RTLD_DEFAULT 다. 애플에서 (void*)-1 은 RTLD_NEXT 라
    //    **이 레이어를 건너뛰고** 백엔드(ANGLE) 심볼을 돌려준다. RTLD_SELF 가 맞다:
    //    우리 것을 먼저 찾고, 없으면 뒤 객체로 넘어간다.
    void* proc = dlsym(RTLD_SELF, real_func_name.c_str());
    if (!proc) proc = dlsym(RTLD_DEFAULT, real_func_name.c_str());
    return proc;
#else"""
assert old in s, "glx/lookup.cpp: 애플 분기를 못 찾았습니다 (업스트림이 바뀜)"
s = s.replace(old, new, 1)
p.write_text(s)
print("  glx/lookup.cpp: 애플에서 자기 심볼을 먼저 찾게 (RTLD_NEXT → RTLD_SELF)")

# 15) 들어갈 자리가 없는 거대 텍스처는 강제로 줄여서 잡는다.
#
#     서버 리소스팩이 고해상도면 마인크래프트가 블록 아틀라스를 8192x8192 로 만든다.
#     RGBA8 로 268MB 인데, 업로드 버퍼와 GPU 사본이 잠깐 같이 살아 있어 실제로는 두 배가
#     필요하다. iOS 의 jetsam 예산(아이폰 15 = 3071MB) 안에서는 그 순간 프로세스가
#     통째로 죽는다 — 자바 예외도 크래시 리포트도 없이 로그가 그냥 끊긴다. 실측:
#         [FlameMem] 사용 2494 MB · 남은 여유 577 MB
#         Created: 8192x8192x0 minecraft:textures/atlas/blocks.png-atlas
#         (여기서 끝)
#
#     UV 는 정규화 좌표라 텍스처를 절반으로 잡아도 그림은 제자리에 맞는다. 부분 업로드
#     (glTexSubImage2D)의 좌표와 픽셀만 같은 비율로 줄여 주면 된다.
#
#     ⚠️ 무조건 줄이지 않는다. 지금 8192 로 멀쩡히 도는 모드팩까지 흐려질 이유가 없다.
#        **남은 여유로 감당이 안 될 때만** 줄인다. 강제하려면 MG_MAX_TEXTURE_DIM 으로.
p = src / "gl/texture.cpp"
s = p.read_text()

marker = "void glTexImage2D(GLenum target, GLint level, GLint internalFormat, GLsizei width, GLsizei height, GLint border,"
assert marker in s, "texture.cpp: glTexImage2D 를 못 찾았습니다 (업스트림이 바뀜)"

helpers = r"""
// ── 거대 텍스처 축소 ───────────────────────────────────────────────────────
// (자세한 사정은 빌드 스크립트의 패치 15 주석 참고)

#ifdef __APPLE__
#include <os/proc.h>
#endif

namespace {

/// 이 텍스처를 몇 단계(2의 거듭제곱) 줄여서 잡았는지. 0 이면 원본 그대로.
std::unordered_map<GLuint, int>& mg_shrink_table() {
    static std::unordered_map<GLuint, int> table;
    return table;
}

int mg_shrink_of(GLuint texture) {
    auto& table = mg_shrink_table();
    auto it = table.find(texture);
    return it == table.end() ? 0 : it->second;
}

/// 픽셀 하나의 바이트 수. 모르면 0 — 그러면 최근접 샘플로 떨어진다.
int mg_bytes_per_pixel(GLenum format, GLenum type) {
    int channels;
    switch (format) {
        case GL_RED: case GL_RED_INTEGER: case GL_ALPHA: case GL_LUMINANCE: channels = 1; break;
        case GL_RG:  case GL_RG_INTEGER:  case GL_LUMINANCE_ALPHA:          channels = 2; break;
        case GL_RGB: case GL_RGB_INTEGER: case GL_BGR:                      channels = 3; break;
        case GL_RGBA: case GL_RGBA_INTEGER: case GL_BGRA:                   channels = 4; break;
        default: return 0;
    }
    switch (type) {
        case GL_UNSIGNED_BYTE: case GL_BYTE: return channels;
        default: return 0;   // 패킹 타입(5_6_5 등)은 픽셀 단위로 못 쪼갠다
    }
}

/// 이 할당을 감당하려면 몇 단계 줄여야 하는가.
int mg_shrink_needed(GLsizei width, GLsizei height, int bpp) {
    if (width <= 0 || height <= 0) return 0;
    if (bpp <= 0) bpp = 4;

    // 강제 상한(디버그·재현용). 0 이거나 없으면 아래의 여유 기반 판단으로 간다.
    static const long forced = [] {
        const char* v = getenv("MG_MAX_TEXTURE_DIM");
        return v ? strtol(v, nullptr, 10) : 0L;
    }();
    if (forced > 0) {
        int shift = 0;
        while ((width >> shift) > forced || (height >> shift) > forced) {
            if (++shift >= 4) break;
        }
        return shift;
    }

#ifdef __APPLE__
    size_t available = os_proc_available_memory();
    if (available == 0) return 0;
    // 업로드 버퍼와 GPU 사본이 겹치는 순간이 있으므로 두 배로 본다. 남은 여유를
    // 통째로 쓸 수는 없으니 60% 까지만 허용한다 — 나머지는 자바 힙이 계속 쓴다.
    size_t budget = available / 10 * 6;
    size_t need = static_cast<size_t>(width) * static_cast<size_t>(height) * bpp * 2;
    int shift = 0;
    while (need > budget && shift < 3) {
        shift++;
        need >>= 2;
    }
    if (shift > 0) {
        LOG_W_FORCE("MGTEX %dx%d 는 남은 여유 %zuMB 로 감당이 안 됩니다 — %dx%d 로 줄입니다",
                    width, height, available >> 20, width >> shift, height >> shift)
    }
    return shift;
#else
    return 0;
#endif
}

/// 언팩 상태를 읽어 원본 행 간격을 구하고, 우리 버퍼를 넣는 동안 기본값으로 돌려 둔다.
struct mg_unpack_scope {
    GLint row_length = 0, skip_rows = 0, skip_pixels = 0, alignment = 4;
    mg_unpack_scope() {
        GLES.glGetIntegerv(GL_UNPACK_ROW_LENGTH, &row_length);
        GLES.glGetIntegerv(GL_UNPACK_SKIP_ROWS, &skip_rows);
        GLES.glGetIntegerv(GL_UNPACK_SKIP_PIXELS, &skip_pixels);
        GLES.glGetIntegerv(GL_UNPACK_ALIGNMENT, &alignment);
        GLES.glPixelStorei(GL_UNPACK_ROW_LENGTH, 0);
        GLES.glPixelStorei(GL_UNPACK_SKIP_ROWS, 0);
        GLES.glPixelStorei(GL_UNPACK_SKIP_PIXELS, 0);
        GLES.glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
    }
    ~mg_unpack_scope() {
        GLES.glPixelStorei(GL_UNPACK_ROW_LENGTH, row_length);
        GLES.glPixelStorei(GL_UNPACK_SKIP_ROWS, skip_rows);
        GLES.glPixelStorei(GL_UNPACK_SKIP_PIXELS, skip_pixels);
        GLES.glPixelStorei(GL_UNPACK_ALIGNMENT, alignment);
    }
};

/// 2^shift 블록 평균으로 줄인 사본. bpp 를 모르면 최근접 샘플.
/// 반환 버퍼는 tight-packed 다 — 부르는 쪽이 mg_unpack_scope 를 잡고 있어야 한다.
std::vector<unsigned char> mg_downscale(const void* pixels, GLsizei width, GLsizei height, int shift,
                                        int bpp, const mg_unpack_scope& unpack) {
    const int step = 1 << shift;
    // ⚠️ 1 픽셀짜리 업로드처럼 블록보다 작은 경우가 있다. 0 으로 내려보내면 그 자리를
    //    통째로 버리게 되므로(실측: "1x1 업로드를 넣지 못했습니다") 최소 1 로 잡고,
    //    블록이 원본을 넘어가면 넘어간 만큼 잘라서 평균낸다.
    const GLsizei out_w = std::max<GLsizei>(1, width >> shift);
    const GLsizei out_h = std::max<GLsizei>(1, height >> shift);
    std::vector<unsigned char> out(static_cast<size_t>(out_w) * out_h * bpp);

    const GLsizei src_row_pixels = unpack.row_length > 0 ? unpack.row_length : width;
    size_t src_stride = static_cast<size_t>(src_row_pixels) * bpp;
    if (unpack.alignment > 1) {
        size_t a = static_cast<size_t>(unpack.alignment);
        src_stride = (src_stride + a - 1) / a * a;
    }
    const auto* base = static_cast<const unsigned char*>(pixels)
                     + static_cast<size_t>(unpack.skip_rows) * src_stride
                     + static_cast<size_t>(unpack.skip_pixels) * bpp;

    for (GLsizei y = 0; y < out_h; ++y) {
        for (GLsizei x = 0; x < out_w; ++x) {
            unsigned char* dst = out.data() + (static_cast<size_t>(y) * out_w + x) * bpp;
            const GLsizei y0 = y * step, y1 = std::min<GLsizei>(y0 + step, height);
            const GLsizei x0 = x * step, x1 = std::min<GLsizei>(x0 + step, width);
            const unsigned count = static_cast<unsigned>((y1 - y0) * (x1 - x0));
            for (int c = 0; c < bpp; ++c) {
                unsigned sum = 0;
                for (GLsizei sy = y0; sy < y1; ++sy) {
                    const auto* row = base + static_cast<size_t>(sy) * src_stride;
                    for (GLsizei sx = x0; sx < x1; ++sx) {
                        sum += row[static_cast<size_t>(sx) * bpp + c];
                    }
                }
                dst[c] = static_cast<unsigned char>(count ? sum / count : 0);
            }
        }
    }
    return out;
}

} // namespace

"""
s = s.replace(marker, helpers + marker, 1)

# glTexImage2D — 크기를 줄여 잡고 기록한다.
old = """    GET_TEXTURE_OBJECT(target);
    tex->target = ConvertGLEnumToTextureTarget(target);
    tex->internal_format = internalFormat;
    tex->width = width;
    tex->height = height;"""
new = """    GET_TEXTURE_OBJECT(target);

    // 여기서만 줄인다 — 2D 레벨 0, 픽셀 버퍼 없이. (패치 15)
    std::vector<unsigned char> shrunk;
    const void* upload = fix.pixels;
    if (target == GL_TEXTURE_2D && level == 0) {
        GLint pbo = 0;
        GLES.glGetIntegerv(GL_PIXEL_UNPACK_BUFFER_BINDING, &pbo);
        const int bpp = mg_bytes_per_pixel(format, type);
        const int shift = pbo != 0 ? 0 : mg_shrink_needed(width, height, bpp);
        if (shift > 0) {
            if (fix.has_data() && fix.pixels != nullptr && bpp > 0) {
                mg_unpack_scope unpack;
                shrunk = mg_downscale(fix.pixels, width, height, shift, bpp, unpack);
                upload = shrunk.data();
                width >>= shift;
                height >>= shift;
                GLES.glTexImage2D(target, level, internalFormat, width, height, border, format, type, upload);
                mg_shrink_table()[tex->texture] = shift;
                tex->target = ConvertGLEnumToTextureTarget(target);
                tex->internal_format = internalFormat;
                tex->width = width;
                tex->height = height;
                tex->depth = 1;
                tex->swizzle_param[0] = GL_RED;
                tex->swizzle_param[1] = GL_GREEN;
                tex->swizzle_param[2] = GL_BLUE;
                tex->swizzle_param[3] = GL_ALPHA;
                tex->format = format;
                CHECK_GL_ERROR
                return;
            }
            if (!fix.has_data()) {   // 자리만 잡는 경우 — 마인크래프트 아틀라스가 이 길로 온다
                width >>= shift;
                height >>= shift;
                mg_shrink_table()[tex->texture] = shift;
            }
        } else {
            mg_shrink_table().erase(tex->texture);
        }
    }

    tex->target = ConvertGLEnumToTextureTarget(target);
    tex->internal_format = internalFormat;
    tex->width = width;
    tex->height = height;"""
assert old in s, "texture.cpp: glTexImage2D 의 텍스처 기록부를 못 찾았습니다 (업스트림이 바뀜)"
s = s.replace(old, new, 1)

old = "    GLES.glTexImage2D(target, level, internalFormat, width, height, border, format, type, fix.pixels);\n\n    CHECK_GL_ERROR\n}"
new = "    GLES.glTexImage2D(target, level, internalFormat, width, height, border, format, type, upload);\n\n    CHECK_GL_ERROR\n}"
assert old in s, "texture.cpp: glTexImage2D 의 드라이버 호출을 못 찾았습니다 (업스트림이 바뀜)"
s = s.replace(old, new, 1)

# glTexSubImage2D — 줄여 잡은 텍스처면 좌표와 픽셀을 같이 줄인다.
old = """    GLES.glTexSubImage2D(target, level, xoffset, yoffset, width, height, fix.format, fix.type, fix.pixels);

    CHECK_GL_ERROR
}"""
new = """    // 줄여 잡은 텍스처(패치 15)에는 좌표와 픽셀을 같은 비율로 줄여 넣는다.
    TextureObject* shrunk_tex = (target == GL_TEXTURE_2D && level == 0) ? mgGetTexObjectByTarget(target) : nullptr;
    const int shift = shrunk_tex ? mg_shrink_of(shrunk_tex->texture) : 0;
    if (shift > 0) {
        GLint pbo = 0;
        GLES.glGetIntegerv(GL_PIXEL_UNPACK_BUFFER_BINDING, &pbo);
        const int bpp = mg_bytes_per_pixel(fix.format, fix.type);
        // 픽셀 버퍼 업로드나 쪼갤 수 없는 픽셀 포맷은 줄일 방법이 없다. 잘못된 크기로
        // 넣느니 건너뛴다 — 그 자리는 비어 보이지만 프로세스는 살아 있다.
        if (pbo != 0 || bpp <= 0) {
            LOG_W_FORCE("MGTEX 줄인 텍스처에 %dx%d 업로드를 넣지 못했습니다 (pbo=%d bpp=%d)",
                        width, height, pbo, bpp)
            CHECK_GL_ERROR
            return;
        }
        mg_unpack_scope unpack;
        std::vector<unsigned char> small = mg_downscale(fix.pixels, width, height, shift, bpp, unpack);
        GLES.glTexSubImage2D(target, level, xoffset >> shift, yoffset >> shift,
                             std::max<GLsizei>(1, width >> shift), std::max<GLsizei>(1, height >> shift),
                             fix.format, fix.type, small.data());
        CHECK_GL_ERROR
        return;
    }

    GLES.glTexSubImage2D(target, level, xoffset, yoffset, width, height, fix.format, fix.type, fix.pixels);

    CHECK_GL_ERROR
}"""
assert old in s, "texture.cpp: glTexSubImage2D 의 드라이버 호출을 못 찾았습니다 (업스트림이 바뀜)"
s = s.replace(old, new, 1)
# 텍스처 이름은 재사용된다. 지운 텍스처의 축소 기록이 남아 있으면 그 id 로 새로
# 만든 텍스처에 엉뚱한 배율이 붙는다.
old = """void glDeleteTextures(GLsizei n, const GLuint* textures) {"""
new = """void glDeleteTextures(GLsizei n, const GLuint* textures) {
    if (textures) {
        for (GLsizei i = 0; i < n; ++i) mg_shrink_table().erase(textures[i]);
    }
"""
assert old in s, "texture.cpp: glDeleteTextures 를 못 찾았습니다 (업스트림이 바뀜)"
s = s.replace(old, new, 1)

# glTexStorage2D 로 정의된 텍스처는 축소 대상이 아니다 — 남은 기록을 지운다.
old = """void glTexStorage2D(GLenum target, GLsizei levels, GLenum internalFormat, GLsizei width, GLsizei height) {"""
new = """void glTexStorage2D(GLenum target, GLsizei levels, GLenum internalFormat, GLsizei width, GLsizei height) {
    if (TextureObject* prev = mgGetTexObjectByTarget(target)) mg_shrink_table().erase(prev->texture);
"""
assert old in s, "texture.cpp: glTexStorage2D 를 못 찾았습니다 (업스트림이 바뀜)"
s = s.replace(old, new, 1)

p.write_text(s)
print("  gl/texture.cpp: 자리 없는 거대 텍스처 축소")

# 3) -Bsymbolic-functions 는 GNU ld 전용.
p = src / "CMakeLists.txt"
s = p.read_text()
old = "    target_link_options(${CMAKE_PROJECT_NAME} PRIVATE -Wl,-Bsymbolic-functions)\nendif()"
assert old in s, "CMakeLists.txt: -Bsymbolic-functions 를 못 찾았습니다 (업스트림이 바뀜)"
if True:
    s = s.replace(old, """    if(NOT APPLE)
        target_link_options(${CMAKE_PROJECT_NAME} PRIVATE -Wl,-Bsymbolic-functions)
    endif()
endif()""")
    p.write_text(s)
    print("  CMakeLists.txt")
PY

echo "▸ 빌드 (arm64, iOS 14+)"
cmake -S "$SRC" -B "$SRC/build-ios" -G Ninja \
  -DCMAKE_SYSTEM_NAME=iOS \
  -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 \
  -DMACOS=ON \
  -DCMAKE_BUILD_TYPE=Release >/dev/null
cmake --build "$SRC/build-ios" -j"$(sysctl -n hw.ncpu)" >/dev/null

DYLIB="$SRC/build-ios/libmobileglues.dylib"
[ -f "$DYLIB" ] || { echo "빌드 산출물이 없습니다"; exit 1; }

# 우리 앱은 이 두 프레임워크를 Frameworks/ 에 넣고 @rpath 로 연다. install name 이
# 어긋나면 dyld 가 못 찾는다 — 링크된 값을 확인만 하고 넘어간다.
otool -L "$DYLIB" | grep -q "@rpath/libEGL.framework/libEGL" \
  || { echo "libEGL 의존성이 @rpath 가 아닙니다"; exit 1; }

cp "$DYLIB" "$ROOT/Runtime/Frameworks/libmobileglues.dylib"
echo
echo "완료: Runtime/Frameworks/libmobileglues.dylib ($(du -h "$DYLIB" | cut -f1))"
echo "  gl*  $(nm -gU "$DYLIB" | grep -c ' _gl[A-Z]')개 / egl* $(nm -gU "$DYLIB" | grep -c ' _egl[A-Z]')개"
