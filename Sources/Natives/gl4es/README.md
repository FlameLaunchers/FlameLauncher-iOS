PojavLauncher iOS 의 `Natives/external/gl4es/` 에서 그대로 가져온 파일들.

`tinygl4angle.c` 는 데스크톱 OpenGL 호출을 MetalANGLE(GLES)로 넘기는 얇은 shim 이다.
GLES 함수는 링크가 아니라 `dlsym(RTLD_NEXT/RTLD_DEFAULT)` 으로 찾으므로,
빌드 시점에 ANGLE 프레임워크를 링크할 필요가 없다 — 대신 `gl_bridge.m` 이 런타임에
libEGL/libGLESv2 프레임워크를 먼저 dlopen 한다.

⚠️ arm64 인라인 어셈블리(심볼 별칭)를 쓰기 때문에 이 프로젝트는 arm64 전용이다.
