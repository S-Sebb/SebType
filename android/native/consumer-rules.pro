# libsebtype.so builds NativeState through its constructor and registers all of NativeCore's natives by
# name (RegisterNatives fails on one missing), so none may be removed, even where an app calls only some.
-keep class dev.sebb.sebtype.core.NativeState { <init>(...); }
-keep class dev.sebb.sebtype.core.NativeCore { native <methods>; }

# Mozc's user dictionary file is protobuf-lite, which reads its message fields by name.
-keepclassmembers class * extends com.google.protobuf.GeneratedMessageLite {
    <fields>;
}

# English's and 中文's worker threads call them from native code.
-keep class dev.sebb.sebtype.core.NativeCore { void englishReady(); void chineseReady(); }
