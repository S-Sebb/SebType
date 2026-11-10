// Typing harness for test-setup-ime.ps1: a plain Win32 text window of the test's own, keys sent with
// SendInput only while that window is in the foreground, and read-back of its text, its active input
// method and Weasel's language bar icon (through TSF on the window's own thread).
using System;
using System.Collections.Concurrent;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Threading;

namespace SebType {
  [ComImport, Guid("ba468c55-9956-4fb1-a59d-52a7dd7cc6aa"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  interface ITfLangBarItemMgr { [PreserveSig] int EnumItems(out IEnumTfLangBarItems e); }

  [ComImport, Guid("583f34d0-de25-11d2-afdd-00105a2799b5"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  interface IEnumTfLangBarItems {
    void Clone(out IEnumTfLangBarItems e);
    [PreserveSig] int Next(uint n, [MarshalAs(UnmanagedType.IUnknown)] out object item, out uint fetched);
  }

  [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
  struct TF_LANGBARITEMINFO {
    public Guid clsidService, guidItem;
    public uint dwStyle, ulSort;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string szDescription;
  }

  // ITfLangBarItem's methods, then ITfLangBarItemButton's (vtable order from msctf.idl).
  [ComImport, Guid("28c7f1d0-de25-11d2-afdd-00105a2799b5"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  interface ITfLangBarItemButton {
    [PreserveSig] int GetInfo(out TF_LANGBARITEMINFO info);
    void GetStatus(out uint s);
    void Show(int show);
    void GetTooltipString([MarshalAs(UnmanagedType.BStr)] out string s);
    void OnClick(int click, long pt, IntPtr rect);
    void InitMenu(IntPtr menu);
    void OnMenuSelect(uint id);
    [PreserveSig] int GetIcon(out IntPtr icon);
  }

  public class TypingWindow {
    [StructLayout(LayoutKind.Sequential)] struct MSG { public IntPtr hwnd; public uint message; public IntPtr wParam, lParam; public uint time; public int x, y; }
    [StructLayout(LayoutKind.Sequential)] struct KEYBDINPUT { public ushort wVk, wScan; public uint dwFlags, time; public IntPtr extra; }
    [StructLayout(LayoutKind.Sequential)] struct INPUT { public uint type; public KEYBDINPUT ki; public long pad; }
    [StructLayout(LayoutKind.Sequential)] struct ICONINFO { public bool fIcon; public int x, y; public IntPtr hbmMask, hbmColor; }

    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern IntPtr CreateWindowExW(uint ex, string cls, string title, uint style, int x, int y, int w, int h, IntPtr parent, IntPtr menu, IntPtr inst, IntPtr param);
    [DllImport("user32.dll")] static extern int GetMessageW(out MSG m, IntPtr h, uint a, uint b);
    [DllImport("user32.dll")] static extern bool TranslateMessage(ref MSG m);
    [DllImport("user32.dll")] static extern IntPtr DispatchMessageW(ref MSG m);
    [DllImport("user32.dll")] static extern bool PostThreadMessageW(uint thread, uint msg, IntPtr w, IntPtr l);
    [DllImport("user32.dll")] static extern bool DestroyWindow(IntPtr h);
    [DllImport("user32.dll")] static extern void PostQuitMessage(int code);
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] static extern IntPtr SetFocus(IntPtr h);
    [DllImport("user32.dll")] static extern uint SendInput(uint n, INPUT[] inputs, int size);
    [DllImport("user32.dll")] static extern IntPtr GetKeyboardLayout(uint thread);
    [DllImport("user32.dll")] static extern short GetKeyState(int vk);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowTextW(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern bool SetWindowTextW(IntPtr h, string s);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc f, IntPtr l);
    delegate bool EnumProc(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] static extern bool GetIconInfo(IntPtr icon, out ICONINFO info);
    [DllImport("user32.dll")] static extern bool DestroyIcon(IntPtr icon);
    [DllImport("user32.dll")] static extern int GetSystemMetrics(int i);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern IntPtr LoadImageW(IntPtr inst, IntPtr name, uint type, int cx, int cy, uint flags);
    [DllImport("gdi32.dll")] static extern int GetBitmapBits(IntPtr bmp, int n, byte[] bits);
    [DllImport("gdi32.dll")] static extern bool DeleteObject(IntPtr o);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern IntPtr LoadLibraryExW(string path, IntPtr f, uint flags);
    [DllImport("kernel32.dll")] static extern uint GetCurrentThreadId();

    const uint WM_APP = 0x8000, KEYUP = 2, EXTENDED = 1;
    static readonly Guid WeaselClsid = new Guid("A3F4CDED-B1E9-41EE-9CA6-7B4D0DE6CB0A");

    IntPtr hwnd;
    uint thread;
    readonly ConcurrentQueue<Action> work = new ConcurrentQueue<Action>();
    readonly ManualResetEvent ready = new ManualResetEvent(false);
    public string IconDll;  // Weasel's TSF dll, for its icon resources

    public TypingWindow(string title) {
      var t = new Thread(() => {
        thread = GetCurrentThreadId();
        // A top-level EDIT control: Windows' own text box, which reaches Weasel through TSF.
        hwnd = CreateWindowExW(0, "EDIT", title, 0x10CF0004 /* WS_OVERLAPPEDWINDOW|WS_VISIBLE|ES_MULTILINE */,
                               200, 200, 640, 240, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);
        ready.Set();
        MSG m;
        while (GetMessageW(out m, IntPtr.Zero, 0, 0) > 0) {
          if (m.hwnd == IntPtr.Zero && m.message == WM_APP) { Action a; while (work.TryDequeue(out a)) a(); continue; }
          TranslateMessage(ref m);
          DispatchMessageW(ref m);
        }
      });
      t.SetApartmentState(ApartmentState.STA);
      t.IsBackground = true;
      t.Start();
      ready.WaitOne();
    }

    T OnWindowThread<T>(Func<T> f) {
      T result = default(T);
      Exception error = null;
      var done = new ManualResetEvent(false);
      work.Enqueue(() => { try { result = f(); } catch (Exception e) { error = e; } done.Set(); });
      PostThreadMessageW(thread, WM_APP, IntPtr.Zero, IntPtr.Zero);
      if (!done.WaitOne(5000)) throw new TimeoutException("test window thread didn't answer");
      if (error != null) throw error;
      return result;
    }

    public bool IsForeground { get { return GetForegroundWindow() == hwnd; } }

    // Brings the window forward. Windows lets a process do that right after it sent input, so this
    // taps Alt first (no menu: the test window has none).
    public bool Activate() {
      for (int i = 0; i < 5 && !IsForeground; i++) {
        Key(0x12);
        SetForegroundWindow(hwnd);
        Thread.Sleep(300);
      }
      OnWindowThread(() => SetFocus(hwnd));
      return IsForeground;
    }

    void Send(ushort vk, bool up) {
      if (!IsForeground) throw new InvalidOperationException("the test window lost the focus; no keys sent");
      uint flags = up ? KEYUP : 0;
      if (vk == 0x5B) flags |= EXTENDED;
      var input = new INPUT { type = 1, ki = new KEYBDINPUT { wVk = vk, dwFlags = flags } };
      SendInput(1, new[] { input }, Marshal.SizeOf(typeof(INPUT)));
      Thread.Sleep(30);
    }
    void Key(ushort vk) {  // only for Activate: may go to another window
      var down = new INPUT { type = 1, ki = new KEYBDINPUT { wVk = vk } };
      var up = new INPUT { type = 1, ki = new KEYBDINPUT { wVk = vk, dwFlags = KEYUP } };
      SendInput(2, new[] { down, up }, Marshal.SizeOf(typeof(INPUT)));
    }

    public void Tap(ushort vk) { Send(vk, false); Send(vk, true); }
    public void Chord(ushort mod1, ushort mod2, ushort vk) {
      Send(mod1, false); if (mod2 != 0) Send(mod2, false);
      Tap(vk);
      if (mod2 != 0) Send(mod2, true); Send(mod1, true);
    }
    // Lowercase letters, digits and space, as key presses.
    public void Type(string text) {
      foreach (char c in text) Tap(c == ' ' ? (ushort)0x20 : (ushort)char.ToUpperInvariant(c));
    }

    public string Text {
      get { var s = new StringBuilder(4096); GetWindowTextW(hwnd, s, s.Capacity); return s.ToString(); }
      set { SetWindowTextW(hwnd, value); }
    }
    public int LanguageId { get { return (int)((long)GetKeyboardLayout(thread) & 0xFFFF); } }
    public static bool CapsLock { get { return (GetKeyState(0x14) & 1) != 0; } }

    // True while a WeaselServer window (the candidate window) is visible.
    public static bool CandidatesVisible() {
      bool seen = false;
      EnumWindows((h, l) => {
        uint pid;
        if (!IsWindowVisible(h)) return true;
        GetWindowThreadProcessId(h, out pid);
        try { if (Process.GetProcessById((int)pid).ProcessName == "WeaselServer") seen = true; } catch (ArgumentException) { }
        return !seen;
      }, IntPtr.Zero);
      return seen;
    }

    static string IconHash(IntPtr icon) {
      ICONINFO info;
      if (icon == IntPtr.Zero || !GetIconInfo(icon, out info)) return null;
      var bits = new byte[256 * 256 * 4];
      int n = GetBitmapBits(info.hbmColor, bits.Length, bits);
      DeleteObject(info.hbmColor); DeleteObject(info.hbmMask);
      using (var sha = SHA256.Create()) return Convert.ToBase64String(sha.ComputeHash(bits, 0, n));
    }

    // Which of Weasel's icons its language bar button shows: "中" (IDI_ZH 102), "a" (IDI_EN 101),
    // "A" (IDI_EN_CAPS 110, SebType's patch), "?" for another icon, or null with no Weasel button.
    public string LangBarIcon() {
      return OnWindowThread(() => {
        var mgr = (ITfLangBarItemMgr)Activator.CreateInstance(System.Type.GetTypeFromCLSID(new Guid("B9931692-A2B3-4FAB-BF33-9EC6F9FB96AC")));
        IEnumTfLangBarItems items;
        if (mgr.EnumItems(out items) != 0) return null;
        object any; uint got;
        while (items.Next(1, out any, out got) == 0 && got == 1) {
          var item = any as ITfLangBarItemButton;  // other items may be bitmaps or balloons
          TF_LANGBARITEMINFO info;
          if (item == null || item.GetInfo(out info) != 0 || info.clsidService != WeaselClsid) continue;
          IntPtr icon;
          if (item.GetIcon(out icon) != 0) return "?";
          string shown = IconHash(icon);
          DestroyIcon(icon);
          IntPtr dll = LoadLibraryExW(IconDll, IntPtr.Zero, 0x22 /* AS_DATAFILE | AS_IMAGE_RESOURCE */);
          int cx = GetSystemMetrics(49), cy = GetSystemMetrics(50);  // SM_CXSMICON, SM_CYSMICON
          foreach (var known in new[] { Tuple.Create(102, "中"), Tuple.Create(101, "a"), Tuple.Create(110, "A") }) {
            IntPtr res = LoadImageW(dll, (IntPtr)known.Item1, 1, cx, cy, 0);
            string h = IconHash(res);
            if (res != IntPtr.Zero) DestroyIcon(res);
            if (h != null && h == shown) return known.Item2;
          }
          return "?";
        }
        return null;
      });
    }

    public void Close() {
      OnWindowThread(() => { DestroyWindow(hwnd); PostQuitMessage(0); return true; });
    }
  }
}
