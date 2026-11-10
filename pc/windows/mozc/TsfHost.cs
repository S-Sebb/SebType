// Typing harness for test.ps1 (#65): a text field of the test's own that talks to Windows' Text Services
// Framework (TSF) directly, so it types into Mozc without the real keyboard. TSF passes keys on only
// while its window has the keyboard focus, so it takes the foreground of the test user's own Remote
// Desktop session, which no one sees. Keys go to the input method through ITfKeystrokeMgr, with this
// thread's key state (Shift, Alt, Caps Lock) set by SetKeyboardState, so the real Caps Lock is never touched. Everything runs
// on one STA thread with a message loop, as TSF and Mozc expect. C# 5: Windows PowerShell 5.1 compiles it.
using System;
using System.Collections.Concurrent;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

namespace SebType {
  [StructLayout(LayoutKind.Sequential)] public struct TS_STATUS { public uint dynamicFlags, staticFlags; }
  [StructLayout(LayoutKind.Sequential)] public struct TS_SELECTION_ACP { public int start, end, activeEnd, interimChar; }
  [StructLayout(LayoutKind.Sequential)] public struct TS_TEXTCHANGE { public int start, oldEnd, newEnd; }
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int left, top, right, bottom; }
  [StructLayout(LayoutKind.Sequential)] public struct TF_PRESERVEDKEY { public uint vk, modifiers; }
  [StructLayout(LayoutKind.Sequential)] public struct TF_INPUTPROCESSORPROFILE {
    public uint profileType; public ushort langid; public Guid clsid, profile, catid;
    public IntPtr hklSubstitute; public uint caps; public IntPtr hkl; public uint flags;
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

  [ComImport, Guid("aa80e7f4-2021-11d2-93e0-0060b067b86e"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  interface ITfDocumentMgr {
    void CreateContext(uint clientId, uint flags, [MarshalAs(UnmanagedType.IUnknown)] object store, out IntPtr context, out uint ecTextStore);
    void Push(IntPtr context);
    void Pop(uint flags);
  }

  [ComImport, Guid("aa80e7f0-2021-11d2-93e0-0060b067b86e"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  interface ITfKeystrokeMgr {
    void AdviseKeyEventSink(uint clientId, IntPtr sink, int foreground);
    void UnadviseKeyEventSink(uint clientId);
    void GetForeground(out Guid clsid);
    void TestKeyDown(IntPtr w, IntPtr l, out int eaten);
    void TestKeyUp(IntPtr w, IntPtr l, out int eaten);
    void KeyDown(IntPtr w, IntPtr l, out int eaten);
    void KeyUp(IntPtr w, IntPtr l, out int eaten);
    [PreserveSig] int GetPreservedKey(IntPtr context, ref TF_PRESERVEDKEY key, out Guid guid);
    void IsPreservedKey(ref Guid guid, ref TF_PRESERVEDKEY key, out int registered);
    void PreserveKey(uint clientId, ref Guid guid, ref TF_PRESERVEDKEY key, IntPtr desc, uint cch);
    void UnpreserveKey(ref Guid guid, ref TF_PRESERVEDKEY key);
    void SetPreservedKeyDescription(ref Guid guid, IntPtr desc, uint cch);
    void GetPreservedKeyDescription(ref Guid guid, out IntPtr desc);
    void SimulatePreservedKey(IntPtr context, ref Guid guid, out int eaten);
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
    public int RequestLock(uint flags, out int hrSession) {
      if (sink == null) { hrSession = E_INVALIDARG; return S_OK; }
      if (lockFlags != 0) {
        if ((flags & TS_LF_SYNC) != 0) { hrSession = TS_E_SYNCHRONOUS; return S_OK; }
        pendingLock = flags & TS_LF_READWRITE; hrSession = TS_S_ASYNC; return S_OK;
      }
      lockFlags = flags & TS_LF_READWRITE;
      hrSession = sink.OnLockGranted(lockFlags);
      lockFlags = 0;
      while (pendingLock != 0) {
        lockFlags = pendingLock; pendingLock = 0;
        sink.OnLockGranted(lockFlags);
        lockFlags = 0;
      }
      return S_OK;
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
    public int RequestSupportedAttrs(uint flags, uint count, IntPtr attrs) { return S_OK; }
    public int RequestAttrsAtPosition(int pos, uint count, IntPtr attrs, uint flags) { return S_OK; }
    public int RequestAttrsTransitioningAtPosition(int pos, uint count, IntPtr attrs, uint flags) { return S_OK; }
    public int FindNextAttrTransition(int start, int halt, uint count, IntPtr attrs, uint flags, out int next, out int found, out int offset) {
      next = halt; found = 0; offset = 0; return S_OK;
    }
    public int RetrieveRequestedAttrs(uint count, IntPtr vals, out uint fetched) { fetched = 0; return S_OK; }
    public int GetEndACP(out int acp) { acp = Text.Length; return (lockFlags & TS_LF_READ) == 0 ? TS_E_NOLOCK : S_OK; }
    public int GetActiveView(out uint view) { view = 1; return S_OK; }
    public int GetACPFromPoint(uint view, IntPtr pt, uint flags, out int acp) { acp = 0; return S_OK; }
    public int GetTextExt(uint view, int start, int end, out RECT rc, out int clipped) {
      rc = new RECT { left = 20, top = 20, right = 30, bottom = 40 }; clipped = 0; return S_OK;
    }
    public int GetScreenExt(uint view, out RECT rc) { rc = new RECT { right = 640, bottom = 200 }; return S_OK; }
    public int GetWnd(uint view, out IntPtr hwnd) { hwnd = Hwnd; return S_OK; }

    TS_TEXTCHANGE Replace(int start, int end, string s) {
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

  public static class TsfHost {
    [StructLayout(LayoutKind.Sequential)] struct MSG { public IntPtr hwnd; public uint message; public IntPtr wParam, lParam; public uint time; public int x, y; }
    [StructLayout(LayoutKind.Sequential)] struct ICONINFO { public bool fIcon; public int x, y; public IntPtr mask, color; }
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern IntPtr CreateWindowExW(uint ex, string cls, string name, uint style, int x, int y, int w, int h, IntPtr parent, IntPtr menu, IntPtr inst, IntPtr param);
    [DllImport("user32.dll")] static extern bool DestroyWindow(IntPtr h);
    [DllImport("user32.dll")] static extern bool GetMessageW(out MSG m, IntPtr h, uint a, uint b);
    [DllImport("user32.dll")] static extern bool TranslateMessage(ref MSG m);
    [DllImport("user32.dll")] static extern IntPtr DispatchMessageW(ref MSG m);
    [DllImport("user32.dll")] static extern bool PostThreadMessageW(uint thread, uint msg, IntPtr w, IntPtr l);
    [DllImport("user32.dll")] static extern bool GetKeyboardState(byte[] state);
    [DllImport("user32.dll")] static extern bool SetKeyboardState(byte[] state);
    [DllImport("user32.dll")] static extern uint MapVirtualKeyW(uint code, uint type);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int ToUnicode(uint vk, uint scan, byte[] state, StringBuilder buf, int n, uint flags);
    [DllImport("user32.dll")] static extern int GetSystemMetrics(int i);
    [DllImport("user32.dll")] static extern IntPtr LoadImageW(IntPtr inst, IntPtr name, uint type, int cx, int cy, uint flags);
    [DllImport("user32.dll")] static extern bool GetIconInfo(IntPtr icon, out ICONINFO info);
    [DllImport("user32.dll")] static extern bool DestroyIcon(IntPtr icon);
    [DllImport("gdi32.dll")] static extern int GetBitmapBits(IntPtr bmp, int n, byte[] bits);
    [DllImport("gdi32.dll")] static extern bool DeleteObject(IntPtr o);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern IntPtr GetModuleHandleW(string name);
    [DllImport("kernel32.dll")] static extern uint GetCurrentThreadId();
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll", EntryPoint = "SetFocus")] static extern IntPtr SetWindowFocus(IntPtr h);
    [DllImport("user32.dll")] static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
    const uint WM_APP = 0x8000, WM_QUIT = 0x12;
    static readonly Guid CLSID_TF_ThreadMgr = new Guid("529a9e6b-6587-4f23-ab9e-9c7d683e3c50");
    static readonly Guid CLSID_TF_InputProcessorProfiles = new Guid("33c53a50-f456-4884-b049-85fd643ecfed");
    static readonly Guid GUID_TFCAT_TIP_KEYBOARD = new Guid("34745c63-b2f0-4784-8b67-5e12c8701a31");
    static readonly Guid GUID_LBI_INPUTMODE = new Guid("2C77A81E-41CC-4178-A3A7-5F8A987568E6");

    static uint threadId;
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
          SetKeyboardState(new byte[256]);  // a new thread's key state isn't empty (Caps Lock was on, seen on Server 2022)
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
          TranslateMessage(ref m); DispatchMessageW(ref m);
        }
      });
      t.SetApartmentState(ApartmentState.STA);
      t.IsBackground = true;
      t.Start();
      if (!ready.WaitOne(20000)) throw new TimeoutException("the TSF thread didn't start");
      if (err != null) throw err;
    }
    // Gives the window the keyboard focus in this session (the test user's own, which no screen shows).
    // Windows lets a process take the foreground right after it sent input: an Alt tap first.
    public static bool Focus() {
      for (int i = 0; i < 5 && GetForegroundWindow() != store.Hwnd; i++) {
        keybd_event(0x12, 0, 0, UIntPtr.Zero); keybd_event(0x12, 0, 2 /* KEYEVENTF_KEYUP */, UIntPtr.Zero);
        SetForegroundWindow(store.Hwnd);
        Thread.Sleep(300);
      }
      return OnUi(() => { SetWindowFocus(store.Hwnd); bool f; threadMgr.IsThreadFocus(out f); return f; }) && GetForegroundWindow() == store.Hwnd;
    }
    public static void Stop() {
      try { OnUi(() => { docMgr.Pop(1 /* TF_POPF_ALL */); threadMgr.Deactivate(); DestroyWindow(store.Hwnd); return 0; }); } catch { }
      PostThreadMessageW(threadId, WM_QUIT, IntPtr.Zero, IntPtr.Zero);
    }

    static T OnUi<T>(Func<T> f) {
      T r = default(T); Exception err = null; var done = new ManualResetEvent(false);
      queue.Add(() => { try { r = f(); } catch (Exception e) { err = e; } done.Set(); });
      PostThreadMessageW(threadId, WM_APP, IntPtr.Zero, IntPtr.Zero);
      // The first key starts Mozc's server for this user, which can take a while.
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

    public static string Text() { return OnUi(() => store.Text.ToString()); }
    public static void Clear() { OnUi(() => { store.AppEdit(0, store.Text.Length, ""); return 0; }); }
    public static bool CapsLock() { return OnUi(() => { var s = new byte[256]; GetKeyboardState(s); return (s[0x14] & 1) != 0; }); }

    // One key event, as an app's message loop hands it to TSF: preserved keys (Mozc's Alt+`) through
    // SimulatePreservedKey, the rest through TestKeyDown/KeyDown. A character the input method doesn't
    // take is typed into the field, as WM_CHAR would.
    public static void Key(ushort vk, bool down) {
      OnUi(() => {
        var s = new byte[256];
        GetKeyboardState(s);
        Action<int> set = k => { s[k] = (byte)(down ? s[k] | 0x80 : s[k] & 0x7F); };
        set(vk);
        if (vk == 0x10) set(0xA0); else if (vk == 0x11) set(0xA2); else if (vk == 0x12) set(0xA4);
        if (vk == 0x14 && down) s[0x14] ^= 1;
        SetKeyboardState(s);
        bool alt = (s[0x12] & 0x80) != 0;
        uint scan = MapVirtualKeyW(vk, 0);
        var lp = (IntPtr)(long)(1u | (scan << 16) | (alt ? 1u << 29 : 0) | (down ? 0 : 3u << 30));
        var keys = (ITfKeystrokeMgr)threadMgr;
        int eaten;
        if (down) {
          var pk = new TF_PRESERVEDKEY { vk = vk, modifiers = (alt ? 1u : 0) | ((s[0x11] & 0x80) != 0 ? 2u : 0) | ((s[0x10] & 0x80) != 0 ? 4u : 0) };
          Guid g;
          if (keys.GetPreservedKey(context, ref pk, out g) == 0 && g != Guid.Empty) {
            keys.SimulatePreservedKey(context, ref g, out eaten);
            if (eaten != 0) return 0;
          }
          keys.TestKeyDown((IntPtr)vk, lp, out eaten);
          if (eaten != 0) keys.KeyDown((IntPtr)vk, lp, out eaten);
          if (eaten == 0 && !alt) {
            var buf = new StringBuilder(8);
            int n = ToUnicode(vk, scan, s, buf, buf.Capacity, 0);
            if (n > 0 && buf[0] >= ' ') store.AppEdit(store.SelStart, store.SelEnd, buf.ToString(0, n));
          }
        } else {
          keys.TestKeyUp((IntPtr)vk, lp, out eaten);
          if (eaten != 0) keys.KeyUp((IntPtr)vk, lp, out eaten);
        }
        return 0;
      });
    }
    // Presses keys in order and releases them in reverse, e.g. Press(0x12, 0xC0) for Alt+`.
    public static void Press(params ushort[] vks) {
      foreach (var vk in vks) Key(vk, true);
      for (int i = vks.Length - 1; i >= 0; i--) Key(vks[i], false);
      Settle(60);
    }
    public static void Type(string s) {  // a-z, '-' and space
      foreach (var c in s) Press(c == '-' ? (ushort)0xBD : c == ' ' ? (ushort)0x20 : (ushort)char.ToUpperInvariant(c));
    }

    // Which of Mozc's icon resources its input mode button (the tray's あ/a) shows now, or -1.
    public static int TrayIcon(int[] ids) {
      return OnUi(() => {
        var mgr = (ITfLangBarItemMgr)threadMgr;
        var guid = GUID_LBI_INPUTMODE;
        object item;
        Marshal.ThrowExceptionForHR(mgr.GetItem(ref guid, out item));
        IntPtr icon;
        Marshal.ThrowExceptionForHR(((ITfLangBarItemButton)item).GetIcon(out icon));
        var shown = Pixels(icon);
        DestroyIcon(icon);
        IntPtr dll = GetModuleHandleW("mozc_tip64.dll");
        int size = GetSystemMetrics(50);  // SM_CYSMICON, as Mozc loads it
        foreach (var id in ids) {
          IntPtr res = LoadImageW(dll, (IntPtr)id, 1, size, size, 0x2000);  // IMAGE_ICON, LR_CREATEDIBSECTION
          if (res == IntPtr.Zero) continue;
          var px = Pixels(res);
          DestroyIcon(res);
          if (px == shown) return id;
        }
        return -1;
      });
    }
    static string Pixels(IntPtr icon) {
      ICONINFO info;
      if (!GetIconInfo(icon, out info)) return "";
      var bits = new byte[1 << 16];
      int n = GetBitmapBits(info.color, bits.Length, bits);
      DeleteObject(info.color); DeleteObject(info.mask);
      return Convert.ToBase64String(bits, 0, n);
    }
  }
}
