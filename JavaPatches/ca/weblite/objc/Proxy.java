package ca.weblite.objc;

/**
 * Rococoa 의 Objective-C 프록시 — iOS 에서는 **아무것도 하지 않는 스텁**.
 * (자세한 사정은 같은 폴더의 {@link Client} 주석)
 */
public class Proxy {
    public Object send(String selector, Object... args) { return null; }
    public Object sendRaw(String selector, Object... args) { return null; }
    public int sendInt(String selector, Object... args) { return 0; }
    public Proxy sendProxy(String selector, Object... args) { return this; }
}
