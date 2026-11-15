# AOSP LatinIME's decoder

The native decoder of AOSP's keyboard, `native/jni/src/` of
[platform/packages/inputmethods/LatinIME](https://android.googlesource.com/platform/packages/inputmethods/LatinIME)
at `127336e9f29d69607eab55982324b210279ae8c5`, copied unchanged into `src/`. It is never taken from FUTO's tree
(the plan's §4). Apache-2.0, Copyright (c) 2008 The Android Open Source Project: [NOTICE](NOTICE), AOSP's own,
and each file's header.

`core/src/english.cpp` calls it directly, without Java: its JNI glue (`native/jni/*.cpp`) isn't copied. To
check the copy against AOSP: fetch that commit and `diff -r native/jni/src engines/latinime/src`.
