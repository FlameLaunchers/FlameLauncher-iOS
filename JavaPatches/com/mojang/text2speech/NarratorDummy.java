package com.mojang.text2speech;

/** 컴파일용 껍데기 — 실제로는 launcher.jar 의 것을 쓴다(이 class 파일은 버린다). */
public class NarratorDummy implements Narrator {
    @Override public void say(String message, boolean interrupt) {}
    @Override public void clear() {}
    @Override public boolean active() { return false; }
    @Override public void destroy() {}
}
