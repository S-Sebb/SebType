#include "fake_jni.h"

#include <cstdarg>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <map>
#include <memory>
#include <utility>

namespace fakejni {
namespace {

std::map<std::string, void *> methods;
std::vector<std::unique_ptr<Obj>> made;

template <class T>
T *as(void *o) {
    auto *r = dynamic_cast<T *>(reinterpret_cast<Obj *>(o));
    if (!r) {
        fprintf(stderr, "fake JNI: wrong object type\n");
        abort();
    }
    return r;
}

// Every JNI function the decoders don't use on the harness's paths stops the run and names its slot.
template <size_t I>
void unimplemented() {
    fprintf(stderr, "fake JNI: function slot %zu is not implemented\n", I);
    abort();
}
template <size_t... I>
void fillUnimplemented(void **slots, std::index_sequence<I...>) {
    ((slots[I] = reinterpret_cast<void *>(&unimplemented<I>)), ...);
}

struct Cls : Obj {
    std::string name;
};
jclass FindClass(JNIEnv *, const char *name);

jclass FindClass(JNIEnv *, const char *name) {
    auto *c = new Cls;
    c->name = name;
    made.emplace_back(c);
    return reinterpret_cast<jclass>(c);
}
jint RegisterNatives(JNIEnv *, jclass clazz, const JNINativeMethod *ms, jint n) {
    for (jint i = 0; i < n; i++) methods[as<Cls>(clazz)->name + "." + ms[i].name] = ms[i].fnPtr;
    return JNI_OK;
}
jboolean ExceptionCheck(JNIEnv *) { return JNI_FALSE; }
void ExceptionClear(JNIEnv *) {}
void DeleteLocalRef(JNIEnv *, jobject) {}

// The harness's strings are ASCII, so UTF-16 and UTF-8 lengths and offsets are the same.
jsize GetStringLength(JNIEnv *, jstring s) { return as<Str>(s)->s.size(); }
jsize GetStringUTFLength(JNIEnv *, jstring s) { return as<Str>(s)->s.size(); }
void GetStringUTFRegion(JNIEnv *, jstring s, jsize start, jsize len, char *buf) {
    memcpy(buf, as<Str>(s)->s.data() + start, len);
}
const char *GetStringUTFChars(JNIEnv *, jstring s, jboolean *isCopy) {
    if (isCopy) *isCopy = JNI_FALSE;
    return as<Str>(s)->s.c_str();
}
void ReleaseStringUTFChars(JNIEnv *, jstring, const char *) {}
jstring NewStringUTF(JNIEnv *, const char *utf) {
    auto *s = new Str;
    s->s = utf;
    made.emplace_back(s);
    return reinterpret_cast<jstring>(s);
}

// FUTO's string2jstring makes its strings through java.nio: a direct buffer, Charset.decode and toString.
jobject NewDirectByteBuffer(JNIEnv *, void *address, jlong capacity) {
    auto *s = new Str;
    s->s.assign(static_cast<const char *>(address), capacity);
    made.emplace_back(s);
    return reinterpret_cast<jobject>(s);
}
jmethodID GetMethodID(JNIEnv *, jclass, const char *, const char *) {
    return reinterpret_cast<jmethodID>(1);
}
// C++'s JNIEnv wrappers call the va_list variants.
jobject CallStaticObjectMethodV(JNIEnv *e, jclass, jmethodID, va_list) {
    return FindClass(e, "java/nio/charset/Charset");  // Charset.forName
}
jobject CallObjectMethodV(JNIEnv *, jobject o, jmethodID, va_list args) {
    if (dynamic_cast<Str *>(reinterpret_cast<Obj *>(o))) return o;  // CharBuffer.toString
    return va_arg(args, jobject);                                    // Charset.decode(buffer)
}
// AOSP's LogUtils logs through android.util.Log.i(tag, message).
jint CallStaticIntMethodV(JNIEnv *, jclass, jmethodID, va_list args) {
    va_arg(args, jstring);
    fprintf(stderr, "%s\n", as<Str>(va_arg(args, jstring))->s.c_str());
    return 0;
}

jsize GetArrayLength(JNIEnv *, jarray a) {
    auto *o = reinterpret_cast<Obj *>(a);
    if (auto *x = dynamic_cast<Arr<jint> *>(o)) return x->v.size();
    if (auto *x = dynamic_cast<Arr<jfloat> *>(o)) return x->v.size();
    if (auto *x = dynamic_cast<Arr<jboolean> *>(o)) return x->v.size();
    return as<ObjArr>(a)->v.size();
}
jobject GetObjectArrayElement(JNIEnv *, jobjectArray a, jsize i) {
    return reinterpret_cast<jobject>(as<ObjArr>(a)->v.at(i));
}
void SetObjectArrayElement(JNIEnv *, jobjectArray a, jsize i, jobject o) {
    as<ObjArr>(a)->v.at(i) = reinterpret_cast<Obj *>(o);
}

template <class T, class J>
void GetRegion(JNIEnv *, J a, jsize start, jsize len, T *buf) {
    auto &v = as<Arr<T>>(a)->v;
    if (start < 0 || len < 0 || size_t(start + len) > v.size()) abort();
    std::copy(v.begin() + start, v.begin() + start + len, buf);
}
template <class T, class J>
void SetRegion(JNIEnv *, J a, jsize start, jsize len, const T *buf) {
    auto &v = as<Arr<T>>(a)->v;
    if (start < 0 || len < 0 || size_t(start + len) > v.size()) abort();
    std::copy(buf, buf + len, v.begin() + start);
}
template <class T, class J>
T *GetElements(JNIEnv *, J a, jboolean *isCopy) {
    if (isCopy) *isCopy = JNI_FALSE;
    return as<Arr<T>>(a)->v.data();
}
template <class T, class J>
void ReleaseElements(JNIEnv *, J, T *, jint) {}

JNINativeInterface_ makeTable() {
    JNINativeInterface_ t;
    constexpr size_t slots = sizeof(t) / sizeof(void *);
    fillUnimplemented(reinterpret_cast<void **>(&t), std::make_index_sequence<slots>());
    t.FindClass = FindClass;
    t.RegisterNatives = RegisterNatives;
    t.ExceptionCheck = ExceptionCheck;
    t.ExceptionClear = ExceptionClear;
    t.DeleteLocalRef = DeleteLocalRef;
    t.GetStringLength = GetStringLength;
    t.GetStringUTFLength = GetStringUTFLength;
    t.GetStringUTFRegion = GetStringUTFRegion;
    t.GetStringUTFChars = GetStringUTFChars;
    t.ReleaseStringUTFChars = ReleaseStringUTFChars;
    t.NewStringUTF = NewStringUTF;
    t.NewDirectByteBuffer = NewDirectByteBuffer;
    t.GetMethodID = GetMethodID;
    t.GetStaticMethodID = GetMethodID;
    t.CallStaticObjectMethodV = CallStaticObjectMethodV;
    t.CallObjectMethodV = CallObjectMethodV;
    t.CallStaticIntMethodV = CallStaticIntMethodV;
    t.GetArrayLength = GetArrayLength;
    t.GetObjectArrayElement = GetObjectArrayElement;
    t.SetObjectArrayElement = SetObjectArrayElement;
    t.GetIntArrayRegion = GetRegion<jint, jintArray>;
    t.SetIntArrayRegion = SetRegion<jint, jintArray>;
    t.GetFloatArrayRegion = GetRegion<jfloat, jfloatArray>;
    t.SetFloatArrayRegion = SetRegion<jfloat, jfloatArray>;
    t.GetBooleanArrayRegion = GetRegion<jboolean, jbooleanArray>;
    t.SetBooleanArrayRegion = SetRegion<jboolean, jbooleanArray>;
    t.GetIntArrayElements = GetElements<jint, jintArray>;
    t.ReleaseIntArrayElements = ReleaseElements<jint, jintArray>;
    t.GetFloatArrayElements = GetElements<jfloat, jfloatArray>;
    t.ReleaseFloatArrayElements = ReleaseElements<jfloat, jfloatArray>;
    return t;
}

}  // namespace

JNIEnv *env() {
    static JNINativeInterface_ table = makeTable();
    static JNIEnv e{&table};
    return &e;
}

void *method(const std::string &classAndName) {
    auto it = methods.find(classAndName);
    if (it == methods.end()) {
        fprintf(stderr, "fake JNI: no native method %s registered\n", classAndName.c_str());
        abort();
    }
    return it->second;
}

void clear() { made.clear(); }

}  // namespace fakejni
