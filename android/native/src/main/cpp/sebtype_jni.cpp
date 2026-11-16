// SebType: the JNI glue between the keyboard (NativeCore.kt) and core/. One Core per process, with 中文's
// librime and 日本語's Mozc; every call takes one lock, so the keyboard's engine thread (NativeCore.post) and
// the background setup (RimeIceSetup) never run core/ at once. A call that changes what is typed returns all
// of it in one NativeState. MIT, SebType.
#include <jni.h>
#include <sebtype/core.h>
#include <sebtype/hosts.h>

#include <memory>
#include <mutex>
#include <string>
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
  return nullptr;
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
  Settings s = Settings::parse(str(env, conf));
  s.commitOnSwitch = false;  // 🌐 drops what is typed (the user, 2026-11-15)
  core = std::make_unique<Core>(makeEngine, s);
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

void setSettings(JNIEnv *env, jclass, jstring conf) {
  std::lock_guard g(lock);
  Settings s = Settings::parse(str(env, conf));
  s.commitOnSwitch = false;
  core->setSettings(s);
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

// Types letters into an empty composition, as librime's simulate_key_sequence did for RimeJni.
jobject type(JNIEnv *env, jclass, jstring text) {
  std::lock_guard g(lock);
  core->focusOut();
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
  core->focusOut();
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

extern "C" JNIEXPORT jint JNI_OnLoad(JavaVM *vm, void *) {
  rime_require_module_lua();
  rime_require_module_octagram();
  JNIEnv *env;
  if (vm->GetEnv(reinterpret_cast<void **>(&env), JNI_VERSION_1_6) != JNI_OK) return JNI_ERR;
  constexpr const char *S = "Ldev/sebb/sebtype/core/NativeState;";
  const std::string st = std::string("()") + S, i = std::string("(I)") + S, ii = std::string("(II)") + S,
                    t = std::string("(Ljava/lang/String;)") + S;
  const JNINativeMethod methods[] = {
      {"configure", "(Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;)V",
       reinterpret_cast<void *>(configure)},
      {"setRimeSchema", "(Ljava/lang/String;)V", reinterpret_cast<void *>(setRimeSchema)},
      {"setMozcData", "(Ljava/lang/String;Ljava/lang/String;JJ)V", reinterpret_cast<void *>(setMozcData)},
      {"setSettings", "(Ljava/lang/String;)V", reinterpret_cast<void *>(setSettings)},
      {"settings", "()Ljava/lang/String;", reinterpret_cast<void *>(settings)},
      {"selectLanguage", "(I)V", reinterpret_cast<void *>(selectLanguage)},
      {"setField", "(IZ)V", reinterpret_cast<void *>(setField)},
      {"setKeys", "(IZ)V", reinterpret_cast<void *>(setKeys)},
      {"key", ii.c_str(), reinterpret_cast<void *>(key)},
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
  return JNI_VERSION_1_6;
}
