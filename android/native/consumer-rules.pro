# libsebtype.so builds NativeState through its constructor and finds NativeCore's natives by name.
-keep class dev.sebb.sebtype.core.NativeState { <init>(...); }
-keepclasseswithmembernames class dev.sebb.sebtype.core.NativeCore { native <methods>; }
