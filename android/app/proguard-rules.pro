# The JNI entry point. `readerkit_call` is bound by symbol name from the `.so`, so R8 sees a
# method with no caller; renaming or removing it turns every reader action into an
# UnsatisfiedLinkError at runtime instead of an error at build time.
-keepclasseswithmembernames class dk.yepz.webreader.ReaderBridge {
    native <methods>;
}

# The generated pages call `window.readerHost.postMessage(...)`. The name comes from
# `ReaderChrome.androidBridge` on the Swift side, so the only Kotlin reference to this method
# is the `addJavascriptInterface` registration — not a call R8 can follow.
-keepclassmembers class * {
    @android.webkit.JavascriptInterface <methods>;
}
