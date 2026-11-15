// A JNIEnv without a Java VM, enough to call the decoders' JNI entry points from C++ (#231).
// Strings and arrays are plain C++ objects; RegisterNatives records each native method by
// "class.method" so the harness calls the decoders' own JNI functions, unchanged.
#pragma once

#include <jni.h>

#include <string>
#include <vector>

namespace fakejni {

struct Obj {
    virtual ~Obj() = default;
};
struct Str : Obj {
    std::string s;
};
template <class T>
struct Arr : Obj {
    std::vector<T> v;
};
struct ObjArr : Obj {
    std::vector<Obj *> v;
};

JNIEnv *env();
// The native method CLASS.NAME as registered, e.g. "org/futo/inputmethod/latin/BinaryDictionary.openNative".
void *method(const std::string &classAndName);

// Objects the native code creates (strings, classes) live until the next clear().
void clear();

inline jstring str(Str &s) { return reinterpret_cast<jstring>(&s); }
inline jobjectArray objs(ObjArr &a) { return reinterpret_cast<jobjectArray>(&a); }
inline jintArray ints(Arr<jint> &a) { return reinterpret_cast<jintArray>(&a); }
inline jfloatArray floats(Arr<jfloat> &a) { return reinterpret_cast<jfloatArray>(&a); }
inline jbooleanArray bools(Arr<jboolean> &a) { return reinterpret_cast<jbooleanArray>(&a); }
inline const std::string *text(jobject o) {
    auto *s = dynamic_cast<Str *>(reinterpret_cast<Obj *>(o));
    return s ? &s->s : nullptr;
}

}  // namespace fakejni
