//
//  flame_compat.h — 상류(PojavLauncher iOS)에서 그대로 가져온 파일들이 기대하는 최소 헤더.
//
//  dyld_bypass_validation.m / dyld_patch_platform.m 은 dyld 내부를 건드리는 코드라
//  손으로 옮기지 않고 원본 그대로 두었다. 그 두 파일이 include 하는 utils.h 대신
//  필요한 선언만 여기에 모아 두고, 빌드 설정에서 utils.h → flame_compat.h 로 바꿨다.
//
#pragma once

#import <Foundation/Foundation.h>
#include <stdbool.h>

extern BOOL debugLogEnabled, isJailbroken;

#define NSDebugLog(...) if (debugLogEnabled) { NSLog(__VA_ARGS__); }

void init_bypassDyldLibValidation(void);
BOOL PLPatchMachOPlatformForFile(const char *path);
