package com.mojang.text2speech;

/**
 * 원본은 {@code ca.weblite.objc.NSObject}(Rococoa — 네이티브 ObjC 브릿지)를 상속해서
 * macOS 의 NSSpeechSynthesizer 를 부른다. iOS 에서는 그 브릿지가 없다.
 *
 * <p>스텁의 {@code NarratorOSX} 와 같은 자리다. 이름으로 찾는 코드가 있을 수 있어서
 * 아무 일도 하지 않는 껍데기로 둔다.
 */
public class NarratorMac extends NarratorDummy {
}
