// SebType: the JNI glue between the keyboard (NativeCore.kt) and core/. One Core per process, with 中文's
// librime, 日本語's Mozc and English (AOSP's decoder and SebType's model); every call takes one lock, so the
// keyboard's engine thread (NativeCore.post) and the background setup (RimeIceSetup) never run core/ at once.
// A call that changes what is typed returns all of it in one NativeState. MIT, SebType.
#include <android/log.h>
#include <jni.h>
#include <unistd.h>
#include <sebtype/core.h>
#include <sebtype/hosts.h>

#include <memory>
#include <mutex>
#include <cstdio>
#include <cstring>
#include <string>
#include <thread>
#include <vector>

using namespace sebtype;

// librime's plugins are linked in statically, and a static plugin registers only if something references it
// (as the old RimeJni did): rime-ice's Lua filters and the octagram grammar.
extern void rime_require_module_lua();
extern void rime_require_module_octagram();

namespace {

constexpr int kMaxCandidates = 128;  // what the bar scrolls through, as RimeJni gave it

std::mutex lock;
std::unique_ptr<Core> core;
RimePaths rimePaths;
MozcPaths mozcPaths;
EnglishPaths englishPaths;
// The phone's own options over sebtype.conf's: 🌐 drops what is typed (the user, 2026-11-15), and English's
// (setEnglishOptions).
Settings phoneOptions;

Settings forPhone(Settings s) {
  s.commitOnSwitch = false;
  s.autocorrect = phoneOptions.autocorrect;
  s.doubleSpacePeriod = phoneOptions.doubleSpacePeriod;
  s.englishWords = phoneOptions.englishWords;
  return s;
}

// core/ reports what it can't open (English's dictionary, its learned words) on stderr, which Android
// discards: a thread copies it to the system log as errors, where the FUTO app logged the same failures.
void stderrToLog() {
  int fds[2];
  if (pipe(fds) != 0) return;
  dup2(fds[1], STDERR_FILENO);
  close(fds[1]);
  std::thread([fd = fds[0]] {
    FILE *in = fdopen(fd, "r");
    char line[1024];
    while (std::fgets(line, sizeof line, in)) {
      line[std::strcspn(line, "\n")] = 0;
      __android_log_write(ANDROID_LOG_ERROR, "SebType", line);
    }
  }).detach();
}

JavaVM *vm;
jclass nativeCore;
jmethodID englishReady;

// English's model ranking and next words come from its worker thread: the keyboard is told through NativeCore.englishReady,
// which posts to its main thread. The thread is attached once and detached when it ends (ART aborts on a
// thread that ends attached).
void onEnglishReady() {
  struct Attached {
    JNIEnv *env = nullptr;
    ~Attached() {
      if (env) vm->DetachCurrentThread();
    }
  };
  thread_local Attached attached;
  if (!attached.env && vm->AttachCurrentThread(&attached.env, nullptr) != JNI_OK) return;
  attached.env->CallStaticVoidMethod(nativeCore, englishReady);
  if (attached.env->ExceptionCheck()) attached.env->ExceptionClear();
}

std::string str(JNIEnv *env, jstring s) {
  if (!s) return {};
  const char *chars = env->GetStringUTFChars(s, nullptr);
  std::string out(chars);
  env->ReleaseStringUTFChars(s, chars);
  return out;
}

// Java's modified UTF-8 can't carry 4-byte sequences (emoji), so strings go out as UTF-16.
std::u16string utf16(const std::string &s) {
  std::u16string out;
  for (size_t i = 0; i < s.size();) {
    const unsigned char c = s[i];
    char32_t cp;
    int n;
    if (c < 0x80) cp = c, n = 1;
    else if (c >> 5 == 6) cp = c & 0x1f, n = 2;
    else if (c >> 4 == 14) cp = c & 0x0f, n = 3;
    else cp = c & 0x07, n = 4;
    for (int k = 1; k < n && i + k < s.size(); ++k) cp = cp << 6 | (s[i + k] & 0x3f);
    i += n;
    if (cp < 0x10000) {
      out += static_cast<char16_t>(cp);
    } else {
      cp -= 0x10000;
      out += static_cast<char16_t>(0xd800 + (cp >> 10));
      out += static_cast<char16_t>(0xdc00 + (cp & 0x3ff));
    }
  }
  return out;
}

jstring jstr(JNIEnv *env, const std::string &s) {
  const std::u16string u = utf16(s);
  return env->NewString(reinterpret_cast<const jchar *>(u.data()), static_cast<jsize>(u.size()));
}

jobjectArray jstrings(JNIEnv *env, const std::vector<std::string> &list) {
  jobjectArray out = env->NewObjectArray(static_cast<jsize>(list.size()), env->FindClass("java/lang/String"), nullptr);
  for (size_t i = 0; i < list.size(); ++i) {
    jstring s = jstr(env, list[i]);
    env->SetObjectArrayElement(out, static_cast<jsize>(i), s);
    env->DeleteLocalRef(s);
  }
  return out;
}

Lang lang(jint id) { return id == 1 ? Lang::Chinese : id == 2 ? Lang::Japanese : Lang::English; }

std::unique_ptr<Engine> makeEngine(Lang l) {
  if (l == Lang::Chinese) return makeRime(rimePaths);
  if (l == Lang::Japanese) return makeMozc(mozcPaths);
  if (englishPaths.dictionary.empty()) return nullptr;
  return makeEnglish(englishPaths, onEnglishReady);
}

// What is typed after a call: the commit, the edit around it, the preedit (its segments, which are
// highlighted, and the cursor in UTF-16 units), the candidates and the highlighted one.
jobject state(JNIEnv *env, bool taken) {
  const std::string commit = core->takeCommit();
  const Edit edit = core->takeEdit();
  const Preedit p = core->preedit();
  std::vector<std::string> segments;
  std::vector<jboolean> highlights;
  for (const auto &s : p.segments) {
    segments.push_back(s.text);
    highlights.push_back(s.highlight);
  }
  const int cursor = p.cursor < 0 ? -1 : static_cast<int>(utf16(p.text().substr(0, p.cursor)).size());
  std::vector<std::string> texts, comments;
  for (const auto &c : core->candidates(kMaxCandidates)) {
    texts.push_back(c.text);
    comments.push_back(c.comment);
  }
  jbooleanArray highlighted = env->NewBooleanArray(static_cast<jsize>(highlights.size()));
  env->SetBooleanArrayRegion(highlighted, 0, static_cast<jsize>(highlights.size()), highlights.data());

  jclass cls = env->FindClass("dev/sebb/sebtype/core/NativeState");
  jmethodID init = env->GetMethodID(
      cls, "<init>", "(ZLjava/lang/String;III[Ljava/lang/String;[ZI[Ljava/lang/String;[Ljava/lang/String;I)V");
  return env->NewObject(cls, init, taken, jstr(env, commit), edit.deleteBefore, edit.deleteAfter, edit.cursor,
                        jstrings(env, segments), highlighted, cursor, jstrings(env, texts),
                        jstrings(env, comments), core->highlighted());
}

void configure(JNIEnv *env, jclass, jstring rimeShared, jstring rimeUser, jstring rimeLog, jstring mozcProfile,
               jstring conf) {
  std::lock_guard g(lock);
  rimePaths.sharedDir = str(env, rimeShared);
  rimePaths.userDir = str(env, rimeUser);
  rimePaths.logDir = str(env, rimeLog);
  rimePaths.prebuilt = true;
  mozcPaths.profileDir = str(env, mozcProfile);
  mozcPaths.touch = true;
  if (core) return;
  core = std::make_unique<Core>(makeEngine, forPhone(Settings::parse(str(env, conf))));
}

// A changed schema or Mozc data set takes effect when the engine next starts.
void setRimeSchema(JNIEnv *env, jclass, jstring schema) {
  std::lock_guard g(lock);
  const std::string s = str(env, schema);
  if (s == rimePaths.schema) return;
  rimePaths.schema = s;
  core->stop(Lang::Chinese);
}

void setMozcData(JNIEnv *env, jclass, jstring profile, jstring file, jlong offset, jlong length) {
  std::lock_guard g(lock);
  const std::string p = str(env, profile), f = str(env, file);
  if (p == mozcPaths.profileDir && f == mozcPaths.dataFile && offset == mozcPaths.dataOffset &&
      length == mozcPaths.dataLength)
    return;
  mozcPaths.profileDir = p;
  mozcPaths.dataFile = f;
  mozcPaths.dataOffset = offset;
  mozcPaths.dataLength = length;
  core->stop(Lang::Japanese);
}

void setEnglishPaths(JNIEnv *env, jclass, jstring dictionary, jlong offset, jlong length, jstring model,
                     jstring userDir) {
  std::lock_guard g(lock);
  EnglishPaths p{str(env, dictionary), offset, length, str(env, model), str(env, userDir)};
  if (p.dictionary == englishPaths.dictionary && p.dictionaryOffset == englishPaths.dictionaryOffset &&
      p.dictionaryLength == englishPaths.dictionaryLength && p.model == englishPaths.model &&
      p.userDir == englishPaths.userDir)
    return;
  englishPaths = p;
  core->stop(Lang::English);
}

void setSettings(JNIEnv *env, jclass, jstring conf) {
  std::lock_guard g(lock);
  core->setSettings(forPhone(Settings::parse(str(env, conf))));
}

void setEnglishOptions(JNIEnv *env, jclass, jboolean autocorrect, jboolean doubleSpacePeriod, jobjectArray words,
                       jintArray frequencies) {
  std::lock_guard g(lock);
  phoneOptions.autocorrect = autocorrect;
  phoneOptions.doubleSpacePeriod = doubleSpacePeriod;
  phoneOptions.englishWords.clear();
  const jsize n = env->GetArrayLength(words);
  std::vector<jint> f(n);
  env->GetIntArrayRegion(frequencies, 0, n, f.data());
  for (jsize i = 0; i < n; i++) {
    auto word = static_cast<jstring>(env->GetObjectArrayElement(words, i));
    phoneOptions.englishWords.emplace_back(str(env, word), f[i]);
    env->DeleteLocalRef(word);
  }
  if (core) core->setSettings(forPhone(core->settings()));
}

jstring settings(JNIEnv *env, jclass) {
  std::lock_guard g(lock);
  return jstr(env, core->settings().serialize());
}

void selectLanguage(JNIEnv *, jclass, jint l) {
  std::lock_guard g(lock);
  core->selectLanguage(lang(l));
}

void setField(JNIEnv *, jclass, jint field, jboolean learning) {
  std::lock_guard g(lock);
  core->setField(static_cast<Field>(field), learning);
}

void setKeys(JNIEnv *, jclass, jint keys, jboolean landscape) {
  std::lock_guard g(lock);
  core->setKeys(static_cast<Keys>(keys), landscape);
}

jobject key(JNIEnv *env, jclass, jint sym, jint mods) {
  std::lock_guard g(lock);
  const bool taken = core->key({static_cast<uint32_t>(sym), static_cast<uint32_t>(mods), false});
  return state(env, taken);
}

// A tap at (x, y) in the keys' pixels, for English's correction of taps near another key.
jobject keyAt(JNIEnv *env, jclass, jint sym, jint mods, jint x, jint y) {
  std::lock_guard g(lock);
  const bool taken = core->key({static_cast<uint32_t>(sym), static_cast<uint32_t>(mods), false, x, y});
  return state(env, taken);
}

// The letter keys: five ints a key (its character, x, y, width, height), in the keyboard's pixels.
void setLayout(JNIEnv *env, jclass, jint width, jint height, jintArray keys) {
  Layout layout{width, height, {}};
  std::vector<jint> k(env->GetArrayLength(keys));
  env->GetIntArrayRegion(keys, 0, static_cast<jsize>(k.size()), k.data());
  for (size_t i = 0; i + 4 < k.size(); i += 5)
    layout.keys.push_back({static_cast<char32_t>(k[i]), k[i + 1], k[i + 2], k[i + 3], k[i + 4]});
  std::lock_guard g(lock);
  core->setLayout(layout);
}

void setContext(JNIEnv *env, jclass, jstring before) {
  const std::string s = str(env, before);
  std::lock_guard g(lock);
  core->setContext(s);
}

// Types letters into an empty composition, as librime's simulate_key_sequence did for RimeJni.
jobject type(JNIEnv *env, jclass, jstring text) {
  std::lock_guard g(lock);
  core->clear();
  for (char c : str(env, text)) core->key({static_cast<uint32_t>(static_cast<unsigned char>(c)), 0, false});
  return state(env, true);
}

// The background setup's self-test: a language's candidates for [text], typed into its engine without
// making it the current language, in an ordinary text field. What it typed is dropped again.
jobjectArray tryTyping(JNIEnv *env, jclass, jint l, jstring text) {
  std::lock_guard g(lock);
  std::vector<std::string> texts;
  if (Engine *e = core->engine(lang(l))) {
    e->setField(Field::Text);
    e->clear();
    for (char c : str(env, text)) e->key({static_cast<uint32_t>(static_cast<unsigned char>(c)), 0, false});
    for (const auto &c : e->candidates(kMaxCandidates)) texts.push_back(c.text);
    e->clear();
    e->takeCommit();
    e->takeEdit();
    e->setField(core->field());
  }
  return jstrings(env, texts);
}

jobject selectCandidate(JNIEnv *env, jclass, jint index) {
  std::lock_guard g(lock);
  core->selectCandidate(index);
  return state(env, true);
}

jobject moveCursor(JNIEnv *env, jclass, jint position) {
  std::lock_guard g(lock);
  core->moveCursor(position);
  return state(env, true);
}

jobject undo(JNIEnv *env, jclass) {
  std::lock_guard g(lock);
  return state(env, core->undo());
}

jobject flush(JNIEnv *env, jclass) {
  std::lock_guard g(lock);
  core->flush();
  return state(env, true);
}

jobject clear(JNIEnv *env, jclass) {
  std::lock_guard g(lock);
  core->clear();
  return state(env, true);
}

jobject current(JNIEnv *env, jclass) {
  std::lock_guard g(lock);
  return state(env, true);
}

void setAlternate(JNIEnv *, jclass, jboolean on) {
  std::lock_guard g(lock);
  core->setAlternate(on);
}

// Engines: started on first use, stopped to free them or to change their files.
jboolean start(JNIEnv *, jclass, jint l) {
  std::lock_guard g(lock);
  return core->engine(lang(l)) != nullptr;
}

jboolean running(JNIEnv *, jclass, jint l) {
  std::lock_guard g(lock);
  return core->running(lang(l)) != nullptr;
}

jboolean busy(JNIEnv *, jclass, jint l) {
  std::lock_guard g(lock);
  Engine *e = core->running(lang(l));
  return e && e->busy();
}

void stop(JNIEnv *, jclass, jint l) {
  std::lock_guard g(lock);
  core->stop(lang(l));
}

void deploy(JNIEnv *, jclass, jint l) {
  std::lock_guard g(lock);
  if (Engine *e = core->engine(lang(l))) e->deploy();
}

void save(JNIEnv *, jclass, jint l) {
  std::lock_guard g(lock);
  if (Engine *e = core->running(lang(l))) e->save();
}

void forget(JNIEnv *, jclass, jint l) {
  std::lock_guard g(lock);
  if (Engine *e = core->engine(lang(l))) e->forget();
}

jbyteArray importUserDictionary(JNIEnv *env, jclass, jbyteArray text) {
  std::string in(env->GetArrayLength(text), '\0');
  env->GetByteArrayRegion(text, 0, static_cast<jsize>(in.size()), reinterpret_cast<jbyte *>(in.data()));
  std::string out;
  {
    std::lock_guard g(lock);
    out = sebtype::importMozcUserDictionary(in);
  }
  jbyteArray bytes = env->NewByteArray(static_cast<jsize>(out.size()));
  env->SetByteArrayRegion(bytes, 0, static_cast<jsize>(out.size()), reinterpret_cast<const jbyte *>(out.data()));
  return bytes;
}

}  // namespace

extern "C" JNIEXPORT jint JNI_OnLoad(JavaVM *javaVm, void *) {
  vm = javaVm;
  stderrToLog();
  rime_require_module_lua();
  rime_require_module_octagram();
  JNIEnv *env;
  if (vm->GetEnv(reinterpret_cast<void **>(&env), JNI_VERSION_1_6) != JNI_OK) return JNI_ERR;
  constexpr const char *S = "Ldev/sebb/sebtype/core/NativeState;";
  const std::string st = std::string("()") + S, i = std::string("(I)") + S, ii = std::string("(II)") + S,
                    t = std::string("(Ljava/lang/String;)") + S, iiii = std::string("(IIII)") + S;
  const JNINativeMethod methods[] = {
      {"configure", "(Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;)V",
       reinterpret_cast<void *>(configure)},
      {"setRimeSchema", "(Ljava/lang/String;)V", reinterpret_cast<void *>(setRimeSchema)},
      {"setMozcData", "(Ljava/lang/String;Ljava/lang/String;JJ)V", reinterpret_cast<void *>(setMozcData)},
      {"setEnglishPaths", "(Ljava/lang/String;JJLjava/lang/String;Ljava/lang/String;)V",
       reinterpret_cast<void *>(setEnglishPaths)},
      {"setSettings", "(Ljava/lang/String;)V", reinterpret_cast<void *>(setSettings)},
      {"setEnglishOptions", "(ZZ[Ljava/lang/String;[I)V", reinterpret_cast<void *>(setEnglishOptions)},
      {"settings", "()Ljava/lang/String;", reinterpret_cast<void *>(settings)},
      {"selectLanguage", "(I)V", reinterpret_cast<void *>(selectLanguage)},
      {"setField", "(IZ)V", reinterpret_cast<void *>(setField)},
      {"setKeys", "(IZ)V", reinterpret_cast<void *>(setKeys)},
      {"key", ii.c_str(), reinterpret_cast<void *>(key)},
      {"keyAt", iiii.c_str(), reinterpret_cast<void *>(keyAt)},
      {"setLayout", "(II[I)V", reinterpret_cast<void *>(setLayout)},
      {"setContext", "(Ljava/lang/String;)V", reinterpret_cast<void *>(setContext)},
      {"type", t.c_str(), reinterpret_cast<void *>(type)},
      {"tryTyping", "(ILjava/lang/String;)[Ljava/lang/String;", reinterpret_cast<void *>(tryTyping)},
      {"selectCandidate", i.c_str(), reinterpret_cast<void *>(selectCandidate)},
      {"moveCursor", i.c_str(), reinterpret_cast<void *>(moveCursor)},
      {"undo", st.c_str(), reinterpret_cast<void *>(undo)},
      {"flush", st.c_str(), reinterpret_cast<void *>(flush)},
      {"clear", st.c_str(), reinterpret_cast<void *>(clear)},
      {"state", st.c_str(), reinterpret_cast<void *>(current)},
      {"setAlternate", "(Z)V", reinterpret_cast<void *>(setAlternate)},
      {"start", "(I)Z", reinterpret_cast<void *>(start)},
      {"running", "(I)Z", reinterpret_cast<void *>(running)},
      {"busy", "(I)Z", reinterpret_cast<void *>(busy)},
      {"stop", "(I)V", reinterpret_cast<void *>(stop)},
      {"deploy", "(I)V", reinterpret_cast<void *>(deploy)},
      {"save", "(I)V", reinterpret_cast<void *>(save)},
      {"forget", "(I)V", reinterpret_cast<void *>(forget)},
      {"importMozcUserDictionary", "([B)[B", reinterpret_cast<void *>(importUserDictionary)},
  };
  jclass cls = env->FindClass("dev/sebb/sebtype/core/NativeCore");
  if (!cls || env->RegisterNatives(cls, methods, sizeof(methods) / sizeof(methods[0])) != JNI_OK) return JNI_ERR;
  nativeCore = static_cast<jclass>(env->NewGlobalRef(cls));
  englishReady = env->GetStaticMethodID(cls, "englishReady", "()V");
  if (!englishReady) return JNI_ERR;
  return JNI_VERSION_1_6;
}
