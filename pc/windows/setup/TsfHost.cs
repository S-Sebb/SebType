// Text field for test.ps1's typing checks (#65): a window of the test's own with a text store that talks
// to Windows' Text Services Framework (TSF), so the checks can read what SebType composed and committed and
// use its tray menu. The keys themselves are real input: test-tcsbackend.sh's Remote Desktop client types
// them, and they reach the text service through this thread's message loop and TSF's keystroke manager, as
// in any app. Everything runs on one STA thread with a message loop, as TSF and text services expect.
// C# 5: Windows PowerShell 5.1 compiles it.
using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

namespace SebType {
  [StructLayout(LayoutKind.Sequential)] public struct TS_STATUS { public uint dynamicFlags, staticFlags; }
  [StructLayout(LayoutKind.Sequential)] public struct TS_SELECTION_ACP { public int start, end, activeEnd, interimChar; }
  [StructLayout(LayoutKind.Sequential)] public struct TS_TEXTCHANGE { public int start, oldEnd, newEnd; }
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int left, top, right, bottom; }
  [StructLayout(LayoutKind.Sequential)] public struct TF_INPUTPROCESSORPROFILE {
    public uint profileType; public ushort langid; public Guid clsid, profile, catid;
    public IntPtr hklSubstitute; public uint caps; public IntPtr hkl; public uint flags;
  }

  // The field's input scopes, as browsers give them (test-private.ps1, #270).
  [ComVisible(true), Guid("fde1eaee-6924-4cdf-91e7-da38cff5559d"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  public interface ITfInputScope {
    [PreserveSig] int GetInputScopes(out IntPtr scopes, out uint count);
    [PreserveSig] int GetPhrase(out IntPtr phrases, out uint count);
    [PreserveSig] int GetRegularExpression(out IntPtr regex);
    [PreserveSig] int GetSRGS(out IntPtr srgs);
    [PreserveSig] int GetXML(out IntPtr xml);
  }
  [ComVisible(true), ClassInterface(ClassInterfaceType.None)]
  public class InputScopes : ITfInputScope {
    const int E_NOTIMPL = unchecked((int)0x80004001);
    readonly int[] scopes;
    public InputScopes(int[] scopes) { this.scopes = scopes; }
    public int GetInputScopes(out IntPtr p, out uint count) {
      count = (uint)scopes.Length;
      p = Marshal.AllocCoTaskMem(4 * scopes.Length);
      Marshal.Copy(scopes, 0, p, scopes.Length);
      return 0;
    }
    public int GetPhrase(out IntPtr p, out uint count) { p = IntPtr.Zero; count = 0; return E_NOTIMPL; }
    public int GetRegularExpression(out IntPtr s) { s = IntPtr.Zero; return E_NOTIMPL; }
    public int GetSRGS(out IntPtr s) { s = IntPtr.Zero; return E_NOTIMPL; }
    public int GetXML(out IntPtr s) { s = IntPtr.Zero; return E_NOTIMPL; }
  }

  [ComImport, Guid("28888fe3-c2a0-483a-a3ea-8cb1ce51ff3d"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  public interface ITextStoreACP {
    [PreserveSig] int AdviseSink(ref Guid riid, [MarshalAs(UnmanagedType.IUnknown)] object sink, uint mask);
    [PreserveSig] int UnadviseSink([MarshalAs(UnmanagedType.IUnknown)] object sink);
    [PreserveSig] int RequestLock(uint flags, out int hrSession);
    [PreserveSig] int GetStatus(out TS_STATUS status);
    [PreserveSig] int QueryInsert(int start, int end, uint cch, out int resultStart, out int resultEnd);
    [PreserveSig] int GetSelection(uint index, uint count, IntPtr selections, out uint fetched);
    [PreserveSig] int SetSelection(uint count, IntPtr selections);
    [PreserveSig] int GetText(int start, int end, IntPtr plain, uint plainReq, out uint plainRet, IntPtr runs, uint runsReq, out uint runsRet, out int next);
    [PreserveSig] int SetText(uint flags, int start, int end, IntPtr text, uint cch, out TS_TEXTCHANGE change);
    [PreserveSig] int GetFormattedText(int start, int end, out IntPtr data);
    [PreserveSig] int GetEmbedded(int pos, ref Guid service, ref Guid riid, out IntPtr unk);
    [PreserveSig] int QueryInsertEmbedded(ref Guid service, IntPtr format, out int insertable);
    [PreserveSig] int InsertEmbedded(uint flags, int start, int end, IntPtr data, out TS_TEXTCHANGE change);
    [PreserveSig] int InsertTextAtSelection(uint flags, IntPtr text, uint cch, out int start, out int end, out TS_TEXTCHANGE change);
    [PreserveSig] int InsertEmbeddedAtSelection(uint flags, IntPtr data, out int start, out int end, out TS_TEXTCHANGE change);
    [PreserveSig] int RequestSupportedAttrs(uint flags, uint count, IntPtr attrs);
    [PreserveSig] int RequestAttrsAtPosition(int pos, uint count, IntPtr attrs, uint flags);
    [PreserveSig] int RequestAttrsTransitioningAtPosition(int pos, uint count, IntPtr attrs, uint flags);
    [PreserveSig] int FindNextAttrTransition(int start, int halt, uint count, IntPtr attrs, uint flags, out int next, out int found, out int offset);
    [PreserveSig] int RetrieveRequestedAttrs(uint count, IntPtr vals, out uint fetched);
    [PreserveSig] int GetEndACP(out int acp);
    [PreserveSig] int GetActiveView(out uint view);
    [PreserveSig] int GetACPFromPoint(uint view, IntPtr pt, uint flags, out int acp);
    [PreserveSig] int GetTextExt(uint view, int start, int end, out RECT rc, out int clipped);
    [PreserveSig] int GetScreenExt(uint view, out RECT rc);
    [PreserveSig] int GetWnd(uint view, out IntPtr hwnd);
  }

  [ComImport, Guid("22d44c94-a419-4542-a272-ae26093ececf"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  interface ITextStoreACPSink {
    void OnTextChange(uint flags, ref TS_TEXTCHANGE change);
    void OnSelectionChange();
    void OnLayoutChange(int code, uint view);
    void OnStatusChange(uint flags);
    void OnAttrsChange(int start, int end, uint count, IntPtr attrs);
    [PreserveSig] int OnLockGranted(uint flags);
    void OnStartEditTransaction();
    void OnEndEditTransaction();
  }

  [ComImport, Guid("aa80e801-2021-11d2-93e0-0060b067b86e"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  interface ITfThreadMgr {
    void Activate(out uint clientId);
    void Deactivate();
    void CreateDocumentMgr(out ITfDocumentMgr mgr);
    void EnumDocumentMgrs(out IntPtr e);
    void GetFocus(out IntPtr mgr);
    void SetFocus(ITfDocumentMgr mgr);
    void AssociateFocus(IntPtr hwnd, ITfDocumentMgr newMgr, out IntPtr prevMgr);
    void IsThreadFocus(out bool focus);
  }

  [ComImport, Guid("aa80e7f0-2021-11d2-93e0-0060b067b86e"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  interface ITfKeystrokeMgr {
    void AdviseKeyEventSink(uint clientId, IntPtr sink, [MarshalAs(UnmanagedType.Bool)] bool foreground);
    void UnadviseKeyEventSink(uint clientId);
    void GetForeground(out Guid clsid);
    void TestKeyDown(IntPtr w, IntPtr l, [MarshalAs(UnmanagedType.Bool)] out bool eaten);
    void TestKeyUp(IntPtr w, IntPtr l, [MarshalAs(UnmanagedType.Bool)] out bool eaten);
    void KeyDown(IntPtr w, IntPtr l, [MarshalAs(UnmanagedType.Bool)] out bool eaten);
    void KeyUp(IntPtr w, IntPtr l, [MarshalAs(UnmanagedType.Bool)] out bool eaten);
  }

  [ComImport, Guid("7dcf57ac-18ad-438b-824d-979bffb74b7c"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  interface ITfCompartmentMgr {
    void GetCompartment(ref Guid guid, out ITfCompartment compartment);
  }

  [ComImport, Guid("bb08f7a9-607a-4384-8623-056892b64371"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  interface ITfCompartment {
    void SetValue(uint clientId, ref object value);  // unused; keeps GetValue's vtable slot
    void GetValue(out object value);
  }

  [ComImport, Guid("aa80e7f4-2021-11d2-93e0-0060b067b86e"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  interface ITfDocumentMgr {
    void CreateContext(uint clientId, uint flags, [MarshalAs(UnmanagedType.IUnknown)] object store, out IntPtr context, out uint ecTextStore);
    void Push(IntPtr context);
    void Pop(uint flags);
  }

  [ComImport, Guid("71c6e74c-0f28-11d8-a82a-00065b84435c"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  interface ITfInputProcessorProfileMgr {
    void ActivateProfile(uint type, ushort langid, ref Guid clsid, ref Guid profile, IntPtr hkl, uint flags);
    void DeactivateProfile(uint type, ushort langid, ref Guid clsid, ref Guid profile, IntPtr hkl, uint flags);
    void GetProfile(uint type, ushort langid, ref Guid clsid, ref Guid profile, IntPtr hkl, out TF_INPUTPROCESSORPROFILE p);
    void EnumProfiles(ushort langid, out IntPtr e);
    void ReleaseInputProcessor(ref Guid clsid, uint flags);
    void RegisterProfile(ref Guid clsid, ushort langid, ref Guid profile, IntPtr desc, uint cchDesc, IntPtr icon, uint cchIcon, uint iconIndex, IntPtr hklSub, uint pref, int enabled, uint flags);
    void UnregisterProfile(ref Guid clsid, ushort langid, ref Guid profile, uint flags);
    [PreserveSig] int GetActiveProfile(ref Guid catid, out TF_INPUTPROCESSORPROFILE p);
  }

  [ComImport, Guid("1F02B6C5-7842-4EE6-8A0B-9A24183A95CA"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  interface ITfInputProcessorProfiles {
    void Register(ref Guid clsid);
    void Unregister(ref Guid clsid);
    void AddLanguageProfile(ref Guid clsid, ushort langid, ref Guid profile, IntPtr desc, uint cchDesc, IntPtr icon, uint cchIcon, uint iconIndex);
    void RemoveLanguageProfile(ref Guid clsid, ushort langid, ref Guid profile);
    void EnumInputProcessorInfo(out IntPtr e);
    void GetDefaultLanguageProfile(ushort langid, ref Guid catid, out Guid clsid, out Guid profile);
    void SetDefaultLanguageProfile(ushort langid, ref Guid clsid, ref Guid profile);
    void ActivateLanguageProfile(ref Guid clsid, ushort langid, ref Guid profile);
    void GetActiveLanguageProfile(ref Guid clsid, out ushort langid, out Guid profile);
    void GetLanguageProfileDescription(ref Guid clsid, ushort langid, ref Guid profile, [MarshalAs(UnmanagedType.BStr)] out string desc);
    void GetCurrentLanguage(out ushort langid);
    void ChangeCurrentLanguage(ushort langid);
    void GetLanguageList(out IntPtr langids, out uint count);
    void EnumLanguageProfiles(ushort langid, out IntPtr e);
    void EnableLanguageProfile(ref Guid clsid, ushort langid, ref Guid profile, int enable);
    void IsEnabledLanguageProfile(ref Guid clsid, ushort langid, ref Guid profile, out int enabled);
  }

  [ComImport, Guid("ba468c55-9956-4fb1-a59d-52a7dd7cc6aa"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  interface ITfLangBarItemMgr {
    void EnumItems(out IntPtr e);
    [PreserveSig] int GetItem(ref Guid guid, [MarshalAs(UnmanagedType.IUnknown)] out object item);
  }

  [ComImport, Guid("28c7f1d0-de25-11d2-afdd-00105a2799b5"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  interface ITfLangBarItemButton {  // ITfLangBarItem's four methods, then the button's
    void GetInfo(IntPtr info); void GetStatus(out uint status); void Show(int show); void GetTooltipString(IntPtr s);
    void OnClick(int click, long pt, IntPtr area); void InitMenu(IntPtr menu); void OnMenuSelect(uint id);
    [PreserveSig] int GetIcon(out IntPtr icon);
  }

  // The text field: one plain string and a selection, the smallest ITextStoreACP that Mozc can compose
  // and commit into. Edits from the app side (typed characters the input method didn't take, Clear)
  // happen outside a lock and are reported to TSF through the sink.
  [ComVisible(true), ClassInterface(ClassInterfaceType.None)]
  public class TextStore : ITextStoreACP {
    const int S_OK = 0, E_INVALIDARG = unchecked((int)0x80070057), E_NOTIMPL = unchecked((int)0x80004001);
    const int TS_E_NOLOCK = unchecked((int)0x80040201), TS_E_SYNCHRONOUS = unchecked((int)0x80040205), TS_S_ASYNC = 0x00040300;
    const int CONNECT_E_ADVISELIMIT = unchecked((int)0x80040201);
    const uint TS_LF_SYNC = 1, TS_LF_READ = 2, TS_LF_READWRITE = 6, TS_IAS_QUERYONLY = 2;
    public readonly StringBuilder Text = new StringBuilder();
    public int SelStart, SelEnd;
    public IntPtr Hwnd;
    ITextStoreACPSink sink;
    uint lockFlags, pendingLock;

    public int AdviseSink(ref Guid riid, object s, uint mask) {
      if (sink != null) return CONNECT_E_ADVISELIMIT;
      sink = (ITextStoreACPSink)s; return S_OK;
    }
    public int UnadviseSink(object s) { sink = null; return S_OK; }
    // A lock that may wait waits for GrantPending, as in an app that grants it from its message loop, after
    // it handled the key (#275); one that may not is granted at once all the same.
    public bool Defer;
    public int RequestLock(uint flags, out int hrSession) {
      if (sink == null) { hrSession = E_INVALIDARG; return S_OK; }
      if (lockFlags != 0 || (Defer && (flags & TS_LF_SYNC) == 0)) {
        if ((flags & TS_LF_SYNC) != 0) { hrSession = TS_E_SYNCHRONOUS; return S_OK; }
        pendingLock |= flags & TS_LF_READWRITE; hrSession = TS_S_ASYNC; return S_OK;
      }
      lockFlags = flags & TS_LF_READWRITE;
      hrSession = sink.OnLockGranted(lockFlags);
      lockFlags = 0;
      GrantPending();
      return S_OK;
    }
    public void GrantPending() {
      while (pendingLock != 0) {
        lockFlags = pendingLock; pendingLock = 0;
        sink.OnLockGranted(lockFlags);
        lockFlags = 0;
      }
    }
    public int GetStatus(out TS_STATUS status) { status = new TS_STATUS(); return S_OK; }
    public int QueryInsert(int start, int end, uint cch, out int resultStart, out int resultEnd) {
      resultStart = start; resultEnd = end; return S_OK;
    }
    public int GetSelection(uint index, uint count, IntPtr selections, out uint fetched) {
      fetched = 0;
      if ((lockFlags & TS_LF_READ) == 0) return TS_E_NOLOCK;
      if (count == 0) return S_OK;
      var sel = new TS_SELECTION_ACP { start = SelStart, end = SelEnd, activeEnd = 2 /* TS_AE_END */ };
      Marshal.StructureToPtr(sel, selections, false);
      fetched = 1; return S_OK;
    }
    public int SetSelection(uint count, IntPtr selections) {
      if ((lockFlags & TS_LF_READWRITE) != TS_LF_READWRITE) return TS_E_NOLOCK;
      if (count > 0) {
        var sel = (TS_SELECTION_ACP)Marshal.PtrToStructure(selections, typeof(TS_SELECTION_ACP));
        SelStart = sel.start; SelEnd = sel.end;
      }
      return S_OK;
    }
    public int GetText(int start, int end, IntPtr plain, uint plainReq, out uint plainRet, IntPtr runs, uint runsReq, out uint runsRet, out int next) {
      plainRet = 0; runsRet = 0; next = start;
      if ((lockFlags & TS_LF_READ) == 0) return TS_E_NOLOCK;
      if (end < 0 || end > Text.Length) end = Text.Length;
      if (start < 0 || start > end) return E_INVALIDARG;
      int n = Math.Min(end - start, (int)plainReq);
      if (n > 0 && plain != IntPtr.Zero) Marshal.Copy(Text.ToString(start, n).ToCharArray(), 0, plain, n);
      plainRet = (uint)n;
      if (runsReq > 0 && runs != IntPtr.Zero && n > 0) {
        Marshal.WriteInt32(runs, n); Marshal.WriteInt32(runs, 4, 0);  // TS_RUNINFO: n characters of TS_RT_PLAIN
        runsRet = 1;
      }
      next = start + n; return S_OK;
    }
    public int SetText(uint flags, int start, int end, IntPtr text, uint cch, out TS_TEXTCHANGE change) {
      change = new TS_TEXTCHANGE();
      if ((lockFlags & TS_LF_READWRITE) != TS_LF_READWRITE) return TS_E_NOLOCK;
      if (start < 0 || end > Text.Length || start > end) return E_INVALIDARG;
      change = Replace(start, end, cch == 0 ? "" : Marshal.PtrToStringUni(text, (int)cch));
      return S_OK;
    }
    public int GetFormattedText(int start, int end, out IntPtr data) { data = IntPtr.Zero; return E_NOTIMPL; }
    public int GetEmbedded(int pos, ref Guid service, ref Guid riid, out IntPtr unk) { unk = IntPtr.Zero; return E_NOTIMPL; }
    public int QueryInsertEmbedded(ref Guid service, IntPtr format, out int insertable) { insertable = 0; return S_OK; }
    public int InsertEmbedded(uint flags, int start, int end, IntPtr data, out TS_TEXTCHANGE change) { change = new TS_TEXTCHANGE(); return E_NOTIMPL; }
    public int InsertTextAtSelection(uint flags, IntPtr text, uint cch, out int start, out int end, out TS_TEXTCHANGE change) {
      start = SelStart; end = SelEnd; change = new TS_TEXTCHANGE();
      if ((flags & TS_IAS_QUERYONLY) != 0) return S_OK;
      if ((lockFlags & TS_LF_READWRITE) != TS_LF_READWRITE) return TS_E_NOLOCK;
      change = Replace(SelStart, SelEnd, cch == 0 ? "" : Marshal.PtrToStringUni(text, (int)cch));
      start = change.start; end = change.newEnd; return S_OK;
    }
    public int InsertEmbeddedAtSelection(uint flags, IntPtr data, out int start, out int end, out TS_TEXTCHANGE change) {
      start = end = 0; change = new TS_TEXTCHANGE(); return E_NOTIMPL;
    }
    // The field's input scopes (GUID_PROP_INPUTSCOPE), the one attribute this store has: none while Scopes is
    // null. TSF asks for attributes, then retrieves the ones asked for.
    public static int[] Scopes;
    static readonly Guid InputScopeAttr = new Guid("1713dd5a-68e7-4a5b-9af6-592a595c778d");
    bool scopesAsked;
    void Ask(uint count, IntPtr attrs) {
      scopesAsked = false;
      for (int i = 0; i < count; i++) {
        var id = new byte[16];
        Marshal.Copy(attrs + 16 * i, id, 0, 16);
        if (new Guid(id) == InputScopeAttr) scopesAsked = Scopes != null;
      }
    }
    public int RequestSupportedAttrs(uint flags, uint count, IntPtr attrs) { Ask(count, attrs); return S_OK; }
    public int RequestAttrsAtPosition(int pos, uint count, IntPtr attrs, uint flags) { Ask(count, attrs); return S_OK; }
    public int RequestAttrsTransitioningAtPosition(int pos, uint count, IntPtr attrs, uint flags) { return S_OK; }
    public int FindNextAttrTransition(int start, int halt, uint count, IntPtr attrs, uint flags, out int next, out int found, out int offset) {
      next = halt; found = 0; offset = 0; return S_OK;
    }
    // TS_ATTRVAL: the attribute's GUID, an overlap id, then a VARIANT (here VT_UNKNOWN) at 8-byte alignment.
    public int RetrieveRequestedAttrs(uint count, IntPtr vals, out uint fetched) {
      fetched = 0;
      if (!scopesAsked || count == 0) return S_OK;
      scopesAsked = false;
      Marshal.Copy(InputScopeAttr.ToByteArray(), 0, vals, 16);
      Marshal.WriteInt32(vals + 16, 0);
      Marshal.GetNativeVariantForObject(new UnknownWrapper(new InputScopes(Scopes)), vals + 24);
      fetched = 1;
      return S_OK;
    }
    public int GetEndACP(out int acp) { acp = Text.Length; return (lockFlags & TS_LF_READ) == 0 ? TS_E_NOLOCK : S_OK; }
    public int GetActiveView(out uint view) { view = 1; return S_OK; }
    public int GetACPFromPoint(uint view, IntPtr pt, uint flags, out int acp) { acp = 0; return S_OK; }
    // The text's place on the screen, where the input method puts its window (test-paging.ps1 moves it).
    public static int CaretX = 20, CaretY = 20;
    public int GetTextExt(uint view, int start, int end, out RECT rc, out int clipped) {
      rc = new RECT { left = CaretX, top = CaretY, right = CaretX + 10, bottom = CaretY + 20 }; clipped = 0; return S_OK;
    }
    public int GetScreenExt(uint view, out RECT rc) { rc = new RECT { right = 640, bottom = 200 }; return S_OK; }
    public int GetWnd(uint view, out IntPtr hwnd) { hwnd = Hwnd; return S_OK; }

    TS_TEXTCHANGE Replace(int start, int end, string s) {
      TsfHost.Mark(TsfHost.edits);
      Text.Remove(start, end - start).Insert(start, s);
      SelStart = SelEnd = start + s.Length;
      return new TS_TEXTCHANGE { start = start, oldEnd = end, newEnd = start + s.Length };
    }
    // An edit by the app itself, outside any lock (TSF then reads the new text under a lock of its own).
    public void AppEdit(int start, int end, string s) {
      var change = Replace(start, end, s);
      if (sink != null) { sink.OnTextChange(0, ref change); sink.OnSelectionChange(); }
    }
  }

  // Windows' display state as it reports it, at once on registering and at each change: 0 off, 1 on, 2 dimmed.
  public static class Display {
    delegate uint Callback(IntPtr context, uint type, IntPtr setting);
    [StructLayout(LayoutKind.Sequential)] struct Recipient { public Callback callback; public IntPtr context; }
    [DllImport("powrprof.dll")] static extern uint PowerSettingRegisterNotification(ref Guid setting, uint flags, IntPtr recipient, out IntPtr handle);
    static Callback kept; static IntPtr recipient;
    public static readonly List<string> States = new List<string>();
    public static int Last = -1, Lit = 0;
    public static void Watch() {
      kept = (c, type, s) => {
        if (type == 0x8013 /* PBT_POWERSETTINGCHANGE */ && s != IntPtr.Zero) {
          int state = Marshal.ReadInt32(s, 20);  // after the GUID and DataLength
          lock (States) { States.Add(DateTime.Now.ToString("HH:mm:ss.fff") + " " + state); Last = state; if (state != 0) Lit++; }
        }
        return 0;
      };
      recipient = Marshal.AllocHGlobal(Marshal.SizeOf(typeof(Recipient)));
      Marshal.StructureToPtr(new Recipient { callback = kept }, recipient, false);
      var guid = new Guid("6fe69556-704a-47a0-8f24-c28d936fda47");
      IntPtr handle;
      uint err = PowerSettingRegisterNotification(ref guid, 2 /* DEVICE_NOTIFY_CALLBACK */, recipient, out handle);
      if (err != 0) throw new Exception("PowerSettingRegisterNotification failed: " + err);
    }
  }

  public static class TsfHost {
    [StructLayout(LayoutKind.Sequential)] struct MSG { public IntPtr hwnd; public uint message; public IntPtr wParam, lParam; public uint time; public int x, y; }
    [StructLayout(LayoutKind.Sequential)] struct RECT { public int L, T, R, B; }
    [StructLayout(LayoutKind.Sequential)] struct POINT { public int X, Y; }
    [DllImport("user32.dll")] static extern bool GetCursorPos(out POINT p);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern IntPtr CreateWindowExW(uint ex, string cls, string name, uint style, int x, int y, int w, int h, IntPtr parent, IntPtr menu, IntPtr inst, IntPtr param);
    [DllImport("user32.dll")] static extern bool DestroyWindow(IntPtr h);
    [DllImport("user32.dll")] static extern bool GetMessageW(out MSG m, IntPtr h, uint a, uint b);
    [DllImport("user32.dll")] static extern bool TranslateMessage(ref MSG m);
    [DllImport("user32.dll")] static extern IntPtr DispatchMessageW(ref MSG m);
    [DllImport("user32.dll")] static extern bool PostThreadMessageW(uint thread, uint msg, IntPtr w, IntPtr l);
    [DllImport("user32.dll")] static extern bool GetKeyboardState(byte[] state);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, IntPtr pid);
    [DllImport("user32.dll")] static extern IntPtr GetKeyboardLayout(uint thread);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern IntPtr FindWindowExW(IntPtr parent, IntPtr after, string cls, string name);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern IntPtr SendMessageW(IntPtr h, uint msg, IntPtr w, StringBuilder l);
    [DllImport("user32.dll", EntryPoint = "SendMessageW")] static extern IntPtr SendMessagePtr(IntPtr h, uint msg, IntPtr w, IntPtr l);
    [DllImport("user32.dll")] static extern bool PostMessageW(IntPtr h, uint msg, IntPtr w, IntPtr l);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] static extern bool DestroyIcon(IntPtr h);
    delegate bool EnumProc(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] static extern bool EnumThreadWindows(uint thread, EnumProc f, IntPtr l);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] static extern IntPtr SetThreadDpiAwarenessContext(IntPtr context);
    [DllImport("user32.dll")] static extern uint GetDpiForSystem();
    // The screen's own pixels: PowerShell isn't DPI-aware, so at 150 % Windows would hand it a scaled-down
    // copy of the screen. Per-monitor aware (v2) for the call only; TSF and the field keep the process's own.
    static T Physical<T>(Func<T> f) {
      var old = SetThreadDpiAwarenessContext((IntPtr)(-4));
      try { return f(); } finally { SetThreadDpiAwarenessContext(old); }
    }
    public static uint Dpi() { return Physical(() => GetDpiForSystem()); }
    [DllImport("user32.dll")] static extern int GetSystemMetricsForDpi(int index, uint dpi);
    [DllImport("user32.dll")] static extern IntPtr GetWindowDpiAwarenessContext(IntPtr h);
    [DllImport("user32.dll")] static extern int GetAwarenessFromDpiAwarenessContext(IntPtr context);
    // The small icon's size at the screen's scaling (SM_CXSMICON), which the taskbar draws the button at.
    public static int IconSize() { return GetSystemMetricsForDpi(49, Dpi()); }
    // The candidate window's DPI awareness at its last picture: 0 unaware (Windows stretches it, in this
    // DPI-unaware PowerShell), 1 system, 2 per monitor.
    public static int PopupAwareness = -1;
    [DllImport("user32.dll")] static extern int GetMenuItemCount(IntPtr menu);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetMenuStringW(IntPtr menu, uint item, StringBuilder s, int n, uint flags);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern IntPtr GetModuleHandleW(string name);
    [DllImport("kernel32.dll")] static extern uint GetCurrentThreadId();
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll", EntryPoint = "SetFocus")] static extern IntPtr SetWindowFocus(IntPtr h);
    [DllImport("user32.dll")] static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
    [DllImport("user32.dll")] static extern uint MapVirtualKeyW(uint code, uint type);
    [DllImport("user32.dll")] static extern bool AttachThreadInput(uint from, uint to, bool attach);
    [DllImport("user32.dll")] static extern bool BringWindowToTop(IntPtr h);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    const uint WM_APP = 0x8000, WM_QUIT = 0x12, WM_CHAR = 0x102, WM_GETTEXT = 0xD;
    static readonly Guid CLSID_TF_ThreadMgr = new Guid("529a9e6b-6587-4f23-ab9e-9c7d683e3c50");
    static readonly Guid CLSID_TF_InputProcessorProfiles = new Guid("33c53a50-f456-4884-b049-85fd643ecfed");
    static readonly Guid GUID_TFCAT_TIP_KEYBOARD = new Guid("34745c63-b2f0-4784-8b67-5e12c8701a31");
    static readonly Guid GUID_LBI_INPUTMODE = new Guid("2C77A81E-41CC-4178-A3A7-5F8A987568E6");

    static uint threadId;

    // Timing for compare.ps1 (#54): when each key went down, from a low-level keyboard hook that sees it
    // as it enters the session's input, and when the text store changed (the input method's composition
    // or commit), on one Stopwatch clock.
    internal static readonly List<long> keys = new List<long>(), edits = new List<long>();
    internal static void Mark(List<long> l) { var t = System.Diagnostics.Stopwatch.GetTimestamp(); lock (l) l.Add(t); }
    delegate IntPtr HookProc(int code, IntPtr w, IntPtr l);
    [DllImport("user32.dll")] static extern IntPtr SetWindowsHookExW(int id, HookProc f, IntPtr mod, uint thread);
    [DllImport("user32.dll")] static extern IntPtr CallNextHookEx(IntPtr h, int code, IntPtr w, IntPtr l);
    static HookProc hookProc;  // kept alive while the hook is set
    public static void StartTiming() {
      var ready = new ManualResetEvent(false);
      var t = new Thread(() => {
        hookProc = (code, w, l) => {
          if (code >= 0 && ((int)w == 0x100 || (int)w == 0x104)) Mark(keys);  // WM_KEYDOWN, WM_SYSKEYDOWN
          return CallNextHookEx(IntPtr.Zero, code, w, l);
        };
        SetWindowsHookExW(13 /* WH_KEYBOARD_LL */, hookProc, GetModuleHandleW(null), 0);
        ready.Set();
        MSG m;
        while (GetMessageW(out m, IntPtr.Zero, 0, 0)) { }
      });
      t.IsBackground = true;
      t.Start();
      ready.WaitOne(5000);
    }
    [DllImport("imm32.dll")] static extern IntPtr ImmGetContext(IntPtr h);
    [DllImport("imm32.dll")] static extern bool ImmSetOpenStatus(IntPtr imc, bool open);
    [DllImport("imm32.dll")] static extern bool ImmReleaseContext(IntPtr h, IntPtr imc);
    // Turns the active input method on (its own language's mode, not English), as its on/off key would.
    public static void Open() {
      OnUi(() => { var c = ImmGetContext(store.Hwnd); ImmSetOpenStatus(c, true); ImmReleaseContext(store.Hwnd, c); return 0; });
    }
    static readonly Guid GUID_COMPARTMENT_KEYBOARD_INPUTMODE_CONVERSION = new Guid("ccf05dd8-4a87-11d7-a6e2-00065b84435c");
    // TSF's conversion mode for this thread (TF_CONVERSIONMODE_*): its low bit is 中 or かな, 0 English.
    static int ConversionMode() {
      var guid = GUID_COMPARTMENT_KEYBOARD_INPUTMODE_CONVERSION;
      ITfCompartment c; ((ITfCompartmentMgr)threadMgr).GetCompartment(ref guid, out c);
      object v; c.GetValue(out v); return v is int ? (int)v : 0;
    }
    public static int Mode() { return OnUi(ConversionMode); }
    // The key-down and text-change times since the last call, in ms on one clock: "keys|edits", comma-separated.
    public static string TakeTimes() {
      Func<List<long>, string> f = l => {
        lock (l) {
          var s = string.Join(",", l.ConvertAll(t => (t * 1000.0 / System.Diagnostics.Stopwatch.Frequency).ToString("F2", System.Globalization.CultureInfo.InvariantCulture)));
          l.Clear(); return s;
        }
      };
      return f(keys) + "|" + f(edits);
    }
    static readonly BlockingCollection<Action> queue = new BlockingCollection<Action>();
    static TextStore store;
    static ITfThreadMgr threadMgr;
    static ITfDocumentMgr docMgr;
    static IntPtr context;

    // Starts the thread, its hidden window (never shown) and the text field, with focus in TSF.
    public static void Start() {
      var ready = new ManualResetEvent(false);
      Exception err = null;
      var t = new Thread(() => {
        threadId = GetCurrentThreadId();
        try {
          store = new TextStore();
          // WS_OVERLAPPEDWINDOW | WS_VISIBLE: TSF passes keys on only while this thread has the keyboard focus
          store.Hwnd = CreateWindowExW(0, "STATIC", "SebType Mozc test", 0x10CF0000, 0, 0, 640, 200, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);
          threadMgr = (ITfThreadMgr)Activator.CreateInstance(System.Type.GetTypeFromCLSID(CLSID_TF_ThreadMgr));
          uint clientId, ec;
          threadMgr.Activate(out clientId);
          threadMgr.CreateDocumentMgr(out docMgr);
          docMgr.CreateContext(clientId, 0, store, out context, out ec);
          docMgr.Push(context);
          IntPtr prev;
          threadMgr.AssociateFocus(store.Hwnd, docMgr, out prev);
          threadMgr.SetFocus(docMgr);
        } catch (Exception e) { err = e; }
        ready.Set();
        MSG m;
        while (GetMessageW(out m, IntPtr.Zero, 0, 0)) {
          if (m.hwnd == IntPtr.Zero && m.message == WM_APP) { Action a; while (queue.TryTake(out a)) a(); continue; }
          // A character the input method let through goes into the field, as an edit control would take it.
          if (m.message == WM_CHAR && (char)m.wParam >= ' ') { store.AppEdit(store.SelStart, store.SelEnd, ((char)m.wParam).ToString()); continue; }
          TranslateMessage(ref m); DispatchMessageW(ref m);
        }
      });
      t.SetApartmentState(ApartmentState.STA);
      t.IsBackground = true;
      t.Start();
      if (!ready.WaitOne(20000)) throw new TimeoutException("the TSF thread didn't start");
      if (err != null) throw err;
    }
    // Brings a window to the front of this session (the test user's own, which no screen shows), where
    // the Remote Desktop client's keys go. Windows lets a process take the foreground right after it sent
    // input: an Alt tap first.
    public static bool Foreground(IntPtr h) {
      // Up to 6 s: right after another window closes, Windows can refuse for a while (seen on TCSBackEnd).
      for (int i = 0; i < 20 && GetForegroundWindow() != h; i++) {
        if (!NoInput) { keybd_event(0x12, 0, 0, UIntPtr.Zero); keybd_event(0x12, 0, 2 /* KEYEVENTF_KEYUP */, UIntPtr.Zero); }
        // Without input: joined for a moment to the input of the window in front, which may hand it on.
        uint pid, front = NoInput ? GetWindowThreadProcessId(GetForegroundWindow(), out pid) : 0, self = GetCurrentThreadId();
        bool joined = front != 0 && front != self && AttachThreadInput(self, front, true);
        SetForegroundWindow(h);
        if (joined) { BringWindowToTop(h); AttachThreadInput(self, front, false); }
        Thread.Sleep(300);
      }
      return GetForegroundWindow() == h;
    }
    // No input of the test's own (#277: a PC whose screen must stay off, which any input in the session
    // lights): Foreground takes no Alt tap but joins the input of the window in front for a moment, and keys
    // go through Key, to TSF's keystroke manager, not into the session's input.
    public static bool NoInput;
    // A key (a virtual-key code) down and up through TSF, as the message loop passes a real one; a letter
    // or space the input method lets through goes into the field. True when the input method took it.
    public static bool Key(byte vk) {
      return OnUi(() => {
        var keys = (ITfKeystrokeMgr)threadMgr;
        long scan = MapVirtualKeyW(vk, 0) << 16;
        bool eaten, up;
        keys.KeyDown((IntPtr)vk, (IntPtr)(1 | scan), out eaten);
        keys.KeyUp((IntPtr)vk, (IntPtr)(1 | scan | 0xC0000000L), out up);
        if (!eaten && (vk == 0x20 || (vk >= 0x41 && vk <= 0x5A)))
          store.AppEdit(store.SelStart, store.SelEnd, (vk == 0x20 ? ' ' : (char)(vk + 32)).ToString());
        store.GrantPending();
        return eaten;
      });
    }
    // Locks that may wait are granted only after the app handled the key (TextStore.Defer).
    public static bool DeferLocks { set { OnUi(() => { store.Defer = value; store.GrantPending(); return 0; }); } }
    static ITfDocumentMgr otherMgr;
    // TSF's focus on another document and back, as a click into another field moves it.
    public static void Away(bool away) {
      OnUi(() => {
        if (otherMgr == null) threadMgr.CreateDocumentMgr(out otherMgr);
        threadMgr.SetFocus(away ? otherMgr : docMgr);
        return 0;
      });
    }
    // Which window is in front (its process) and whether TSF's thread has the focus: why Focus failed.
    public static string FocusState() {
      uint pid; GetWindowThreadProcessId(GetForegroundWindow(), out pid);
      string name; try { name = System.Diagnostics.Process.GetProcessById((int)pid).ProcessName; } catch { name = "pid " + pid; }
      return "in front: " + (GetForegroundWindow() == store.Hwnd ? "the test field" : name) +
             ", TSF thread focus: " + OnUi(() => { bool f; threadMgr.IsThreadFocus(out f); return f; });
    }
    // The text field's window in front, with the keyboard focus, and TSF's focus on its document.
    public static bool Focus() {
      return Foreground(store.Hwnd) && OnUi(() => { SetWindowFocus(store.Hwnd); bool f; threadMgr.IsThreadFocus(out f); return f; });
    }
    // The language of the keyboard input method active in a window's thread, e.g. 0x0411 for Japanese.
    public static int Language(IntPtr h) { return (int)GetKeyboardLayout(GetWindowThreadProcessId(h, IntPtr.Zero)) & 0xFFFF; }
    // The text of a window's edit control (Notepad's).
    public static string EditText(IntPtr h) {
      var buf = new StringBuilder(4096);
      SendMessageW(FindWindowExW(h, IntPtr.Zero, "Edit", null), WM_GETTEXT, (IntPtr)buf.Capacity, buf);
      return buf.ToString();
    }
    public static void Stop() {
      try { OnUi(() => { docMgr.Pop(1 /* TF_POPF_ALL */); threadMgr.Deactivate(); DestroyWindow(store.Hwnd); return 0; }); } catch { }
      PostThreadMessageW(threadId, WM_QUIT, IntPtr.Zero, IntPtr.Zero);
    }

    static T OnUi<T>(Func<T> f) {
      T r = default(T); Exception err = null; var done = new ManualResetEvent(false);
      queue.Add(() => { try { r = f(); } catch (Exception e) { err = e; } done.Set(); });
      PostThreadMessageW(threadId, WM_APP, IntPtr.Zero, IntPtr.Zero);
      // The first key starts SebType's server (and Mozc in it) for this user, which can take a while.
      if (!done.WaitOne(60000)) throw new TimeoutException("the TSF thread didn't answer in a minute");
      if (err != null) throw err;
      return r;
    }
    // Lets the input method's own posted messages run (Mozc updates the tray and commits through them).
    public static void Settle(int ms) { Thread.Sleep(ms); OnUi(() => 0); }

    // Makes the given input method the active one for this process only (TF_IPPMF_FORPROCESS).
    public static void Activate(ushort langid, Guid clsid, Guid profile) {
      OnUi(() => {
        var mgr = (ITfInputProcessorProfileMgr)Activator.CreateInstance(System.Type.GetTypeFromCLSID(CLSID_TF_InputProcessorProfiles));
        mgr.ActivateProfile(1 /* TF_PROFILETYPE_INPUTPROCESSOR */, langid, ref clsid, ref profile, IntPtr.Zero, 0x10000000 | 0x4);
        return 0;
      });
    }
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern IntPtr LoadKeyboardLayout(string klid, uint flags);
    // The same for a plain keyboard layout, by its id as the language list has it ("00000409").
    public static void ActivateLayout(ushort langid, string klid) {
      OnUi(() => {
        var mgr = (ITfInputProcessorProfileMgr)Activator.CreateInstance(System.Type.GetTypeFromCLSID(CLSID_TF_InputProcessorProfiles));
        Guid none = Guid.Empty, noProfile = Guid.Empty;
        mgr.ActivateProfile(2 /* TF_PROFILETYPE_KEYBOARDLAYOUT */, langid, ref none, ref noProfile, LoadKeyboardLayout(klid, 0), 0x10000000 | 0x4);
        return 0;
      });
    }
    // "<langid hex> <clsid>" of the active keyboard input method, e.g. "0411 {10A67BC8-...}".
    public static string Active() {
      return OnUi(() => {
        var mgr = (ITfInputProcessorProfileMgr)Activator.CreateInstance(System.Type.GetTypeFromCLSID(CLSID_TF_InputProcessorProfiles));
        var cat = GUID_TFCAT_TIP_KEYBOARD;
        TF_INPUTPROCESSORPROFILE p;
        Marshal.ThrowExceptionForHR(mgr.GetActiveProfile(ref cat, out p));
        return string.Format("{0:x4} {1}", p.langid, p.clsid.ToString("B").ToUpperInvariant());
      });
    }
    // The name Windows shows for an input method (Win+Space, the language settings).
    public static string Description(ushort langid, Guid clsid, Guid profile) {
      return OnUi(() => {
        var p = (ITfInputProcessorProfiles)Activator.CreateInstance(System.Type.GetTypeFromCLSID(CLSID_TF_InputProcessorProfiles));
        string d; p.GetLanguageProfileDescription(ref clsid, langid, ref profile, out d);
        return d;
      });
    }

    // Whether an input method is on for this user (in its language's list), and turning it on or off.
    public static bool Enabled(ushort langid, Guid clsid, Guid profile) {
      return OnUi(() => {
        var p = (ITfInputProcessorProfiles)Activator.CreateInstance(System.Type.GetTypeFromCLSID(CLSID_TF_InputProcessorProfiles));
        int on; p.IsEnabledLanguageProfile(ref clsid, langid, ref profile, out on);
        return on != 0;
      });
    }
    public static void Enable(ushort langid, Guid clsid, Guid profile, bool on) {
      OnUi(() => {
        var p = (ITfInputProcessorProfiles)Activator.CreateInstance(System.Type.GetTypeFromCLSID(CLSID_TF_InputProcessorProfiles));
        p.EnableLanguageProfile(ref clsid, langid, ref profile, on ? 1 : 0);
        return 0;
      });
    }

    public static string Text() { return OnUi(() => store.Text.ToString()); }
    public static void Clear() { OnUi(() => { store.AppEdit(0, store.Text.Length, ""); return 0; }); }
    public static bool CapsLock() { return OnUi(() => { var s = new byte[256]; GetKeyboardState(s); return (s[0x14] & 1) != 0; }); }

    // The active input method's input mode button: the tray's 中/a or あ/a.
    static ITfLangBarItemButton InputModeButton() {
      var guid = GUID_LBI_INPUTMODE;
      object item;
      Marshal.ThrowExceptionForHR(((ITfLangBarItemMgr)threadMgr).GetItem(ref guid, out item));
      return (ITfLangBarItemButton)item;
    }
    // Opens the input mode button's menu, as a right-click on the tray icon does, and returns its items
    // ("|" between them). Then picks the first item (pick) or closes the menu. shot: a PNG file for a
    // picture of the test window with the menu open, or null.
    public static string TrayPopup(bool pick, string shot) {
      string items = null;
      var watcher = new Thread(() => {
        for (int i = 0; i < 100 && items == null; i++) {
          Thread.Sleep(50);
          IntPtr w = IntPtr.Zero;
          while ((w = FindWindowExW(IntPtr.Zero, w, "#32768", null)) != IntPtr.Zero &&
                 !(IsWindowVisible(w) && GetWindowThreadProcessId(w, IntPtr.Zero) == threadId)) { }
          if (w == IntPtr.Zero) continue;
          IntPtr menu = SendMessagePtr(w, 0x01E1 /* MN_GETHMENU */, IntPtr.Zero, IntPtr.Zero);
          var labels = new List<string>();
          for (int k = 0; k < GetMenuItemCount(menu); k++) {
            var s = new StringBuilder(256);
            GetMenuStringW(menu, (uint)k, s, s.Capacity, 0x400 /* MF_BYPOSITION */);
            labels.Add(s.ToString());
          }
          if (shot != null) { Thread.Sleep(300); Picture(w, shot); }  // after the menu's fade-in
          if (pick) PostMessageW(w, 0x100 /* WM_KEYDOWN */, (IntPtr)0x28 /* VK_DOWN */, IntPtr.Zero);
          PostMessageW(w, 0x100, (IntPtr)(pick ? 0x0D /* VK_RETURN */ : 0x1B /* VK_ESCAPE */), IntPtr.Zero);
          items = string.Join("|", labels);
        }
      });
      watcher.Start();
      OnUi(() => {
        RECT r; GetWindowRect(store.Hwnd, out r);
        long pt = ((long)(r.T + 40) << 32) | (uint)(r.L + 40);  // a POINT: x, then y
        InputModeButton().OnClick(1 /* TF_LBI_CLK_RIGHT */, pt, IntPtr.Zero);
        return 0;
      });
      watcher.Join();
      Settle(300);
      return items ?? "no menu";
    }
    static void Picture(IntPtr menu, string path) {
      RECT a, b; GetWindowRect(store.Hwnd, out a); GetWindowRect(menu, out b);
      int l = Math.Min(a.L, b.L), t = Math.Min(a.T, b.T);
      using (var bmp = new System.Drawing.Bitmap(Math.Max(a.R, b.R) - l, Math.Max(a.B, b.B) - t)) {
        using (var g = System.Drawing.Graphics.FromImage(bmp)) g.CopyFromScreen(l, t, 0, 0, bmp.Size);
        bmp.Save(path, System.Drawing.Imaging.ImageFormat.Png);
      }
    }
    // Saves the input mode button's icon (what the taskbar's input indicator shows) as a PNG, 64 px (#275).
    public static void ButtonIcon(string path) {
      OnUi(() => {
        IntPtr h;
        Marshal.ThrowExceptionForHR(InputModeButton().GetIcon(out h));
        // At the size the text service gave, pixel for pixel: the size the taskbar gets.
        using (var icon = System.Drawing.Icon.FromHandle(h))
        using (var bmp = icon.ToBitmap()) bmp.Save(path, System.Drawing.Imaging.ImageFormat.Png);
        DestroyIcon(h);
        return 0;
      });
    }
    // Saves the right end of the taskbar, with the input indicator, as a PNG (#275).
    public static void Taskbar(string path, int width) {
      Physical(() => {
        RECT r; GetWindowRect(FindWindowExW(IntPtr.Zero, IntPtr.Zero, "Shell_TrayWnd", null), out r);
        using (var bmp = new System.Drawing.Bitmap(width, r.B - r.T)) {
          using (var g = System.Drawing.Graphics.FromImage(bmp)) g.CopyFromScreen(r.R - width, r.T, 0, 0, bmp.Size);
          bmp.Save(path, System.Drawing.Imaging.ImageFormat.Png);
        }
        return 0;
      });
    }
    // Saves the input method's candidate window, the visible window other than the field that its code
    // (in this thread, as TSF loads it) shows, as a PNG; returns its size, or null without one. The size
    // says when the mouse pointer is over it: a capture leaves the pointer out, but some pointers show.
    public static string CandidateWindow(string path) {
      IntPtr w = IntPtr.Zero;
      OnUi(() => { EnumThreadWindows(threadId, (h, l) => { if (h != store.Hwnd && IsWindowVisible(h)) w = h; return w == IntPtr.Zero; }, IntPtr.Zero); return 0; });
      if (w == IntPtr.Zero) return null;
      PopupAwareness = GetAwarenessFromDpiAwarenessContext(GetWindowDpiAwarenessContext(w));
      return Physical(() => {
        RECT r; GetWindowRect(w, out r);
        using (var bmp = new System.Drawing.Bitmap(r.R - r.L, r.B - r.T)) {
          using (var g = System.Drawing.Graphics.FromImage(bmp)) g.CopyFromScreen(r.L, r.T, 0, 0, bmp.Size);
          bmp.Save(path, System.Drawing.Imaging.ImageFormat.Png);
        }
        POINT p;
        bool pointer = GetCursorPos(out p) && p.X >= r.L && p.X < r.R && p.Y >= r.T && p.Y < r.B;
        return (r.R - r.L) + "x" + (r.B - r.T) + (pointer ? " (pointer over it at " + (p.X - r.L) + "," + (p.Y - r.T) + ")" : "");
      });
    }
  }
}
