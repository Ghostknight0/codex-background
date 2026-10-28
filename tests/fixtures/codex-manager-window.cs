// 提供独立的单实例测试窗口，验证启动按钮调用和窗口显示，不操作真实 Codex。
using System;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

internal static class CodexManagerWindowFixture
{
    private delegate IntPtr WindowProcedure(IntPtr window, uint message, IntPtr wParam, IntPtr lParam);
    private delegate bool WindowVisitor(IntPtr window, IntPtr data);
    private static WindowProcedure callback = HandleMessage;
    private static IntPtr button;

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct WindowClass
    {
        public uint style;
        public WindowProcedure procedure;
        public int classExtra, windowExtra;
        public IntPtr instance, icon, cursor, background;
        public string menuName, className;
    }
    [StructLayout(LayoutKind.Sequential)]
    private struct Message
    {
        public IntPtr window;
        public uint message;
        public IntPtr wParam, lParam;
        public uint time;
        public int x, y;
        public uint extra;
    }
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern ushort RegisterClass(ref WindowClass cls);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern IntPtr CreateWindowEx(uint exStyle, string cls, string title, uint style, int x, int y, int width, int height, IntPtr parent, IntPtr menu, IntPtr instance, IntPtr data);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern IntPtr DefWindowProc(IntPtr window, uint message, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern bool GetMessage(out Message message, IntPtr window, uint min, uint max);
    [DllImport("user32.dll")] private static extern bool TranslateMessage(ref Message message);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern IntPtr DispatchMessage(ref Message message);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr window);
    [DllImport("user32.dll")] private static extern bool ShowWindow(IntPtr window, int command);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern bool SetWindowText(IntPtr window, string text);
    [DllImport("user32.dll")] private static extern bool EnumWindows(WindowVisitor visitor, IntPtr data);
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr window, out uint processId);
    [DllImport("user32.dll")] private static extern bool PostMessage(IntPtr window, uint message, IntPtr wParam, IntPtr lParam);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] private static extern IntPtr GetModuleHandle(string name);

    private static IntPtr HandleMessage(IntPtr window, uint message, IntPtr wParam, IntPtr lParam)
    {
        // 第二次运行只显示原窗口，启动按钮只更新文字作为验证信号。
        if (message == 0x8001) { ShowWindow(window, 4); return IntPtr.Zero; }
        if (message == 0x0111 && wParam.ToInt64() == 1) { SetWindowText(button, "已启动"); return IntPtr.Zero; }
        return DefWindowProc(window, message, wParam, lParam);
    }

    [STAThread]
    private static void Main(string[] args)
    {
        string executable = Process.GetCurrentProcess().MainModule.FileName;
        bool first;
        using (var mutex = new Mutex(true, "CodexBackgroundFixture-" + executable.GetHashCode(), out first))
        {
            if (!first) { ActivateExistingWindow(executable); return; }
            var cls = new WindowClass { procedure = callback, className = "Tauri Window", instance = GetModuleHandle(null) };
            if (RegisterClass(ref cls) == 0) return;
            IntPtr window = CreateWindowEx(0, cls.className, "Codex++", 0x00CF0000, 40, 40, 320, 160, IntPtr.Zero, IntPtr.Zero, cls.instance, IntPtr.Zero);
            if (window == IntPtr.Zero) return;
            string caption = args.Length > 0 && args[0] == "no-start" ? "重启 Codex" : "启动 Codex";
            button = CreateWindowEx(0, "BUTTON", caption, 0x50010000, 20, 20, 180, 40, window, new IntPtr(1), IntPtr.Zero, IntPtr.Zero);
            // 初始保持隐藏，模拟托盘中的 Codex++；由第二次原程序启动请求显示。
            Message message;
            while (GetMessage(out message, IntPtr.Zero, 0, 0)) { TranslateMessage(ref message); DispatchMessage(ref message); }
        }
    }

    private static void ActivateExistingWindow(string executable)
    {
        foreach (Process process in Process.GetProcessesByName(Process.GetCurrentProcess().ProcessName))
        {
            if (process.Id == Process.GetCurrentProcess().Id || process.MainModule.FileName != executable) continue;
            EnumWindows((window, data) => {
                uint owner;
                GetWindowThreadProcessId(window, out owner);
                if (owner == process.Id) PostMessage(window, 0x8001, IntPtr.Zero, IntPtr.Zero);
                return true;
            }, IntPtr.Zero);
        }
    }
}
