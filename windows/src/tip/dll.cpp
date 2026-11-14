// SebType on Windows: the text service's DLL, its COM class and its registration as Windows' 中文 and
// 日本語 input methods (Decisions #2, #92: short names, no "SebType"). MIT, SebType.
#include "resource.h"
#include "tip.h"

#include <iterator>

namespace sebtype::win {

HINSTANCE dllInstance = nullptr;
std::atomic<long> dllRefs{0};

namespace {

class Factory final : public IClassFactory {
 public:
  STDMETHODIMP QueryInterface(REFIID riid, void **out) override {
    if (riid == IID_IUnknown || riid == IID_IClassFactory) {
      *out = this;
      return S_OK;
    }
    *out = nullptr;
    return E_NOINTERFACE;
  }
  STDMETHODIMP_(ULONG) AddRef() override { return 2; }  // static
  STDMETHODIMP_(ULONG) Release() override { return 1; }
  STDMETHODIMP CreateInstance(IUnknown *outer, REFIID riid, void **out) override {
    *out = nullptr;
    if (outer) return CLASS_E_NOAGGREGATION;
    auto *service = new (std::nothrow) TextService();
    if (!service) return E_OUTOFMEMORY;
    const HRESULT hr = service->QueryInterface(riid, out);
    service->Release();
    return hr;
  }
  STDMETHODIMP LockServer(BOOL lock) override {
    lock ? ++dllRefs : --dllRefs;
    return S_OK;
  }
};

Factory factory;

// What Windows needs to offer the service: a keyboard text service that works in Store apps, shows its
// button in the taskbar's input indicator, and marks its composition's underlines.
const GUID *const kCategories[] = {
    &GUID_TFCAT_TIP_KEYBOARD,
    &GUID_TFCAT_TIPCAP_IMMERSIVESUPPORT,
    &GUID_TFCAT_TIPCAP_SYSTRAYSUPPORT,
    &GUID_TFCAT_DISPLAYATTRIBUTEPROVIDER,
    &GUID_TFCAT_TIPCAP_COMLESS,
};

struct Profile {
  LANGID lang;
  const GUID *guid;
  const wchar_t *name;
  int icon;
};
const Profile kProfiles[] = {
    {kLangZh, &kProfileZh, L"中文", IDI_ZH},
    {kLangJa, &kProfileJa, L"日本語", IDI_HIRA},
};

std::wstring clsidKey() {
  wchar_t clsid[39];
  StringFromGUID2(kClsid, clsid, 39);
  return std::wstring(L"CLSID\\") + clsid;
}

HRESULT registerServer() {
  wchar_t path[MAX_PATH];
  GetModuleFileNameW(dllInstance, path, MAX_PATH);
  HKEY key = nullptr;
  if (RegCreateKeyExW(HKEY_CLASSES_ROOT, (clsidKey() + L"\\InprocServer32").c_str(), 0, nullptr, 0, KEY_WRITE,
                      nullptr, &key, nullptr) != ERROR_SUCCESS)
    return E_FAIL;
  RegSetValueExW(key, nullptr, 0, REG_SZ, reinterpret_cast<const BYTE *>(path),
                 static_cast<DWORD>((wcslen(path) + 1) * sizeof(wchar_t)));
  static const wchar_t kApartment[] = L"Apartment";
  RegSetValueExW(key, L"ThreadingModel", 0, REG_SZ, reinterpret_cast<const BYTE *>(kApartment), sizeof(kApartment));
  RegCloseKey(key);

  ITfInputProcessorProfileMgr *profiles = nullptr;
  HRESULT hr = CoCreateInstance(CLSID_TF_InputProcessorProfiles, nullptr, CLSCTX_INPROC_SERVER,
                                IID_ITfInputProcessorProfileMgr, reinterpret_cast<void **>(&profiles));
  if (FAILED(hr)) return hr;
  for (const Profile &p : kProfiles) {
    hr = profiles->RegisterProfile(kClsid, p.lang, *p.guid, p.name, static_cast<ULONG>(wcslen(p.name)), path,
                                   static_cast<ULONG>(wcslen(path)), static_cast<UINT>(-p.icon), nullptr, 0, TRUE, 0);
    if (FAILED(hr)) break;
  }
  profiles->Release();
  if (FAILED(hr)) return hr;

  ITfCategoryMgr *categories = nullptr;
  hr = CoCreateInstance(CLSID_TF_CategoryMgr, nullptr, CLSCTX_INPROC_SERVER, IID_ITfCategoryMgr,
                        reinterpret_cast<void **>(&categories));
  if (FAILED(hr)) return hr;
  for (const GUID *c : kCategories) categories->RegisterCategory(kClsid, *c, kClsid);
  categories->Release();
  return S_OK;
}

HRESULT unregisterServer() {
  ITfInputProcessorProfileMgr *profiles = nullptr;
  if (SUCCEEDED(CoCreateInstance(CLSID_TF_InputProcessorProfiles, nullptr, CLSCTX_INPROC_SERVER,
                                 IID_ITfInputProcessorProfileMgr, reinterpret_cast<void **>(&profiles)))) {
    for (const Profile &p : kProfiles) profiles->UnregisterProfile(kClsid, p.lang, *p.guid, 0);
    profiles->Release();
  }
  ITfCategoryMgr *categories = nullptr;
  if (SUCCEEDED(CoCreateInstance(CLSID_TF_CategoryMgr, nullptr, CLSCTX_INPROC_SERVER, IID_ITfCategoryMgr,
                                 reinterpret_cast<void **>(&categories)))) {
    for (const GUID *c : kCategories) categories->UnregisterCategory(kClsid, *c, kClsid);
    categories->Release();
  }
  RegDeleteTreeW(HKEY_CLASSES_ROOT, clsidKey().c_str());
  return S_OK;
}

}  // namespace
}  // namespace sebtype::win

using namespace sebtype::win;

BOOL WINAPI DllMain(HINSTANCE instance, DWORD reason, LPVOID) {
  if (reason == DLL_PROCESS_ATTACH) {
    dllInstance = instance;
    DisableThreadLibraryCalls(instance);
  } else if (reason == DLL_PROCESS_DETACH) {
    UnregisterClassW(kWindowClass, instance);  // a reloaded DLL registers it with its own code
  }
  return TRUE;
}

STDAPI DllGetClassObject(REFCLSID clsid, REFIID riid, void **out) {
  if (clsid != kClsid) {
    *out = nullptr;
    return CLASS_E_CLASSNOTAVAILABLE;
  }
  return factory.QueryInterface(riid, out);
}

STDAPI DllCanUnloadNow() { return dllRefs == 0 ? S_OK : S_FALSE; }

STDAPI DllRegisterServer() {
  const HRESULT hr = registerServer();
  if (FAILED(hr)) unregisterServer();
  return hr;
}

STDAPI DllUnregisterServer() { return unregisterServer(); }
