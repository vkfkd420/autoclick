Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

Add-Type @"
using System;
using System.Runtime.InteropServices;
using System.Diagnostics;
using System.Threading;
using System.Collections.Concurrent;
public class Clicker {
    [DllImport("user32.dll")] static extern void mouse_event(uint f, uint dx, uint dy, uint d, UIntPtr e);
    [DllImport("user32.dll")] static extern short GetAsyncKeyState(int vKey);
    [DllImport("user32.dll")] static extern bool GetCursorPos(out POINT p);
    [DllImport("user32.dll")] static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("winmm.dll")] static extern uint timeBeginPeriod(uint ms);
    [StructLayout(LayoutKind.Sequential)] struct POINT { public int X, Y; }
    [StructLayout(LayoutKind.Sequential)] struct RECT { public int Left, Top, Right, Bottom; }

    public volatile bool Running;
    public volatile bool Paused;
    public volatile bool NoPositions;
    public volatile bool UsePositions;
    public volatile int IntervalUs = 4000;
    public volatile int Button;
    public volatile bool Suspended;
    public volatile int StartKey = 0x77;
    public volatile int StopKey = 0x77;
    public volatile int RecordKey = 0x75;
    public volatile int[] Pts = new int[0];
    public IntPtr FormHandle;
    public ConcurrentQueue<int[]> Recorded = new ConcurrentQueue<int[]>();

    public void SetPositions(int[] xs, int[] ys) {
        int[] a = new int[xs.Length * 2];
        for (int i = 0; i < xs.Length; i++) { a[2 * i] = xs[i]; a[2 * i + 1] = ys[i]; }
        Pts = a;
    }

    public void Begin() {
        timeBeginPeriod(1);
        Thread c = new Thread(ClickLoop); c.IsBackground = true; c.Priority = ThreadPriority.AboveNormal; c.Start();
        Thread k = new Thread(KeyLoop); k.IsBackground = true; k.Priority = ThreadPriority.AboveNormal; k.Start();
    }

    static bool Pressed(int vk) { return (GetAsyncKeyState(vk) & 0x8000) != 0; }

    static bool Inside(RECT r, int x, int y) {
        return x >= r.Left && x < r.Right && y >= r.Top && y < r.Bottom;
    }

    static bool Match(int code) {
        int vk = code & 0xFFFF;
        int mods = code >> 16;
        if (!Pressed(vk)) return false;
        return Pressed(0x11) == ((mods & 1) != 0)
            && Pressed(0x12) == ((mods & 2) != 0)
            && Pressed(0x10) == ((mods & 4) != 0);
    }

    void KeyLoop() {
        bool startHeld = false, stopHeld = false, recHeld = false, wasSuspended = false;
        while (true) {
            int sv = StartKey, pv = StopKey, rv = RecordKey;
            bool sd = Match(sv), pd = Match(pv), rd = Match(rv);
            if (Suspended) { wasSuspended = true; startHeld = sd; stopHeld = pd; recHeld = rd; Thread.Sleep(5); continue; }
            if (wasSuspended) { wasSuspended = false; startHeld = sd; stopHeld = pd; recHeld = rd; Thread.Sleep(5); continue; }
            bool se = sd && !startHeld, pe = pd && !stopHeld, re = rd && !recHeld;
            startHeld = sd; stopHeld = pd; recHeld = rd;
            if (sv == pv) { if (se) Running = !Running; }
            else { if (se) Running = true; if (pe) Running = false; }
            if (re && rv != sv && rv != pv) {
                POINT p;
                if (GetCursorPos(out p)) Recorded.Enqueue(new int[] { p.X, p.Y });
            }
            Thread.Sleep(5);
        }
    }

    void ClickLoop() {
        Stopwatch sw = Stopwatch.StartNew();
        double last = 0; bool was = false; int idx = 0;
        while (true) {
            if (!Running) { was = false; Paused = false; NoPositions = false; Thread.Sleep(5); continue; }
            double now = sw.Elapsed.TotalMilliseconds;
            double interval = IntervalUs / 1000.0;
            if (!was) { last = now - interval; was = true; idx = 0; }

            RECT r; POINT p;
            bool haveRect = GetWindowRect(FormHandle, out r);
            bool usePos = UsePositions;
            int[] pts = Pts;

            NoPositions = usePos && pts.Length == 0;
            if (NoPositions) { Paused = false; last = now; Thread.Sleep(5); continue; }

            if (!usePos && haveRect && GetCursorPos(out p) && Inside(r, p.X, p.Y)) {
                Paused = true; last = now; Thread.Sleep(5); continue;
            }
            Paused = false;

            int due = (int)((now - last) / interval);
            if (due < 1) { Thread.Sleep(1); continue; }
            if (due > 1000) { due = 1000; last = now; } else { last += due * interval; }

            uint down = Button == 0 ? 0x0002u : 0x0008u;
            uint up = Button == 0 ? 0x0004u : 0x0010u;
            for (int i = 0; i < due && Running; i++) {
                if (usePos) {
                    int n = pts.Length / 2;
                    int k = idx % n; idx++;
                    int x = pts[2 * k], y = pts[2 * k + 1];
                    if (haveRect && Inside(r, x, y)) continue;
                    SetCursorPos(x, y);
                }
                mouse_event(down, 0, 0, 0, UIntPtr.Zero);
                mouse_event(up, 0, 0, 0, UIntPtr.Zero);
            }
        }
    }
}
"@

Add-Type -ReferencedAssemblies System.Windows.Forms,System.Drawing -TypeDefinition @"
using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Windows.Forms;
using System.Runtime.InteropServices;

public class Marker : Form {
    [StructLayout(LayoutKind.Sequential)] struct PT { public int x, y; }
    [StructLayout(LayoutKind.Sequential)] struct SZ { public int cx, cy; }
    [StructLayout(LayoutKind.Sequential, Pack = 1)] struct BLEND { public byte Op, Flags, Alpha, Format; }
    [DllImport("user32.dll", SetLastError = true)]
    static extern bool UpdateLayeredWindow(IntPtr hwnd, IntPtr hdcDst, ref PT pptDst, ref SZ psize, IntPtr hdcSrc, ref PT pptSrc, int crKey, ref BLEND pblend, int dwFlags);
    [DllImport("user32.dll")] static extern IntPtr GetDC(IntPtr h);
    [DllImport("user32.dll")] static extern int ReleaseDC(IntPtr h, IntPtr dc);
    [DllImport("gdi32.dll")] static extern IntPtr CreateCompatibleDC(IntPtr dc);
    [DllImport("gdi32.dll")] static extern bool DeleteDC(IntPtr dc);
    [DllImport("gdi32.dll")] static extern IntPtr SelectObject(IntPtr dc, IntPtr obj);
    [DllImport("gdi32.dll")] static extern bool DeleteObject(IntPtr obj);

    public const int Canvas = 96;
    public int Number;
    readonly Timer tm = new Timer();
    double t = 0;

    public Marker() {
        FormBorderStyle = FormBorderStyle.None;
        ShowInTaskbar = false;
        TopMost = true;
        StartPosition = FormStartPosition.Manual;
        Size = new Size(Canvas, Canvas);
        tm.Interval = 30;
        tm.Tick += delegate { t += 30; Render(); if (t >= 280) tm.Stop(); };
    }
    protected override bool ShowWithoutActivation { get { return true; } }
    protected override CreateParams CreateParams {
        get { CreateParams cp = base.CreateParams; cp.ExStyle |= 0x08000000 | 0x80 | 0x20 | 0x80000; return cp; }
    }
    protected override void OnShown(EventArgs e) { base.OnShown(e); Render(); tm.Start(); }
    protected override void OnFormClosed(FormClosedEventArgs e) { tm.Stop(); base.OnFormClosed(e); }
    protected override void OnPaintBackground(PaintEventArgs e) { }
    protected override void OnPaint(PaintEventArgs e) { }

    void Render() {
        if (!IsHandleCreated) return;
        using (Bitmap bmp = new Bitmap(Canvas, Canvas, System.Drawing.Imaging.PixelFormat.Format32bppArgb)) {
            using (Graphics g = Graphics.FromImage(bmp)) {
                g.SmoothingMode = SmoothingMode.AntiAlias;
                g.TextRenderingHint = System.Drawing.Text.TextRenderingHint.AntiAliasGridFit;
                g.Clear(Color.Transparent);
                Draw(g);
            }
            IntPtr screen = GetDC(IntPtr.Zero);
            IntPtr mem = CreateCompatibleDC(screen);
            IntPtr hbmp = IntPtr.Zero, old = IntPtr.Zero;
            try {
                hbmp = bmp.GetHbitmap(Color.FromArgb(0));
                old = SelectObject(mem, hbmp);
                SZ size = new SZ(); size.cx = Canvas; size.cy = Canvas;
                PT src = new PT();
                PT dst = new PT(); dst.x = Left; dst.y = Top;
                BLEND bl = new BLEND(); bl.Op = 0; bl.Flags = 0; bl.Format = 1;
                bl.Alpha = (byte)(255 * Math.Min(1.0, t / 160.0));
                UpdateLayeredWindow(Handle, screen, ref dst, ref size, mem, ref src, 0, ref bl, 2);
            } finally {
                ReleaseDC(IntPtr.Zero, screen);
                if (hbmp != IntPtr.Zero) { SelectObject(mem, old); DeleteObject(hbmp); }
                DeleteDC(mem);
            }
        }
    }

    void Draw(Graphics g) {
        float cx = Canvas / 2f, cy = Canvas / 2f;
        Color accent = Color.FromArgb(79, 107, 237);
        double k = Math.Min(1.0, t / 220.0);
        float ease = (float)(1 - Math.Pow(1 - k, 3));
        float s = 0.6f + 0.4f * ease;

        using (Brush b1 = new SolidBrush(Color.FromArgb(26, accent)))
            g.FillEllipse(b1, cx - 18 * s, cy - 18 * s, 36 * s, 36 * s);
        using (Brush b2 = new SolidBrush(Color.FromArgb(52, accent)))
            g.FillEllipse(b2, cx - 10.5f * s, cy - 10.5f * s, 21 * s, 21 * s);
        using (Brush wb = new SolidBrush(Color.White))
            g.FillEllipse(wb, cx - 6.3f, cy - 6.3f, 12.6f, 12.6f);
        using (Brush cb = new SolidBrush(accent))
            g.FillEllipse(cb, cx - 4.5f, cy - 4.5f, 9, 9);

        using (FontFamily ff = new FontFamily("Malgun Gothic"))
        using (GraphicsPath tp = new GraphicsPath())
        using (StringFormat sf = new StringFormat()) {
            sf.LineAlignment = StringAlignment.Center;
            tp.AddString(Number.ToString(), ff, (int)FontStyle.Bold, 13f, new RectangleF(cx + 23, cy - 10, 32, 20), sf);
            using (Pen o = new Pen(Color.FromArgb(235, 255, 255, 255), 3.5f)) { o.LineJoin = LineJoin.Round; g.DrawPath(o, tp); }
            using (Brush tb = new SolidBrush(accent)) g.FillPath(tb, tp);
        }
    }
}
public class HotkeyBox : Control {
    public int Code;
    public int PrevCode;
    bool capturing;
    bool hover;
    int previewMods;
    public event EventHandler Captured;
    public event EventHandler CaptureChanged;
    public bool Capturing { get { return capturing; } }
    public string Label { get { return Describe(Code); } }

    static readonly Color cAccent = Color.FromArgb(79, 107, 237);
    static readonly Color cText = Color.FromArgb(31, 36, 48);
    static readonly Color cLine = Color.FromArgb(217, 220, 230);
    static readonly Color cCap = Color.FromArgb(237, 241, 255);
    static readonly Color cHover = Color.FromArgb(247, 248, 253);

    public HotkeyBox() {
        SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.UserPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.Selectable | ControlStyles.ResizeRedraw, true);
        TabStop = true;
        Cursor = Cursors.Hand;
        Size = new Size(130, 28);
        BackColor = Color.White;
        Font = new Font("Malgun Gothic", 9.5f);
    }

    public static string KeyName(int vk) {
        if (vk >= 0x30 && vk <= 0x39) return ((char)vk).ToString();
        if (vk >= 0x41 && vk <= 0x5A) return ((char)vk).ToString();
        if (vk >= 0x70 && vk <= 0x87) return "F" + (vk - 0x6F);
        if (vk >= 0x60 && vk <= 0x69) return "Num " + (vk - 0x60);
        switch (vk) {
            case 0x08: return "Backspace";
            case 0x09: return "Tab";
            case 0x0D: return "Enter";
            case 0x13: return "Pause";
            case 0x14: return "Caps Lock";
            case 0x20: return "Space";
            case 0x21: return "Page Up";
            case 0x22: return "Page Down";
            case 0x23: return "End";
            case 0x24: return "Home";
            case 0x25: return "←";
            case 0x26: return "↑";
            case 0x27: return "→";
            case 0x28: return "↓";
            case 0x2C: return "Print Screen";
            case 0x2D: return "Insert";
            case 0x2E: return "Delete";
            case 0x6A: return "Num *";
            case 0x6B: return "Num +";
            case 0x6D: return "Num -";
            case 0x6E: return "Num .";
            case 0x6F: return "Num /";
            case 0x90: return "Num Lock";
            case 0x91: return "Scroll Lock";
            case 0xBA: return ";";
            case 0xBB: return "=";
            case 0xBC: return ",";
            case 0xBD: return "-";
            case 0xBE: return ".";
            case 0xBF: return "/";
            case 0xC0: return ((char)96).ToString();
            case 0xDB: return "[";
            case 0xDC: return "\\";
            case 0xDD: return "]";
            case 0xDE: return "'";
        }
        return "Key " + vk.ToString("X2");
    }

    static string ModsText(int mods) {
        string s = "";
        if ((mods & 1) != 0) s += "Ctrl + ";
        if ((mods & 2) != 0) s += "Alt + ";
        if ((mods & 4) != 0) s += "Shift + ";
        return s;
    }

    public static string Describe(int code) {
        return ModsText(code >> 16) + KeyName(code & 0xFFFF);
    }

    void BeginCapture() {
        if (capturing) return;
        capturing = true;
        previewMods = 0;
        PrevCode = Code;
        if (CaptureChanged != null) CaptureChanged(this, EventArgs.Empty);
        Invalidate();
    }

    void EndCapture(bool ok) {
        if (!capturing) return;
        capturing = false;
        if (ok && Captured != null) Captured(this, EventArgs.Empty);
        if (CaptureChanged != null) CaptureChanged(this, EventArgs.Empty);
        Invalidate();
    }

    protected override void OnMouseDown(MouseEventArgs e) { base.OnMouseDown(e); Focus(); BeginCapture(); }
    protected override void OnLostFocus(EventArgs e) { base.OnLostFocus(e); EndCapture(false); }
    protected override void OnMouseEnter(EventArgs e) { base.OnMouseEnter(e); hover = true; Invalidate(); }
    protected override void OnMouseLeave(EventArgs e) { base.OnMouseLeave(e); hover = false; Invalidate(); }
    protected override bool IsInputKey(Keys keyData) { return capturing || base.IsInputKey(keyData); }

    protected override void OnKeyUp(KeyEventArgs e) {
        base.OnKeyUp(e);
        if (capturing) {
            Keys m = Control.ModifierKeys;
            previewMods = ((m & Keys.Control) != 0 ? 1 : 0) | ((m & Keys.Alt) != 0 ? 2 : 0) | ((m & Keys.Shift) != 0 ? 4 : 0);
            Invalidate();
        }
    }

    protected override bool ProcessCmdKey(ref Message msg, Keys keyData) {
        if (!capturing) return base.ProcessCmdKey(ref msg, keyData);
        Keys k = keyData & Keys.KeyCode;
        int mods = ((keyData & Keys.Control) != 0 ? 1 : 0) | ((keyData & Keys.Alt) != 0 ? 2 : 0) | ((keyData & Keys.Shift) != 0 ? 4 : 0);
        if (k == Keys.Escape && mods == 0) { EndCapture(false); return true; }
        if (k == Keys.ControlKey || k == Keys.ShiftKey || k == Keys.Menu || k == Keys.LWin || k == Keys.RWin) {
            previewMods = mods;
            Invalidate();
            return true;
        }
        Code = (mods << 16) | (int)k;
        EndCapture(true);
        return true;
    }

    protected override void OnPaint(PaintEventArgs e) {
        Graphics g = e.Graphics;
        g.SmoothingMode = SmoothingMode.AntiAlias;
        g.TextRenderingHint = System.Drawing.Text.TextRenderingHint.ClearTypeGridFit;
        g.Clear(BackColor);
        RectangleF r = new RectangleF(0.5f, 0.5f, Width - 1.5f, Height - 1.5f);
        float d = 12f;
        using (GraphicsPath p = new GraphicsPath()) {
            p.AddArc(r.X, r.Y, d, d, 180, 90);
            p.AddArc(r.Right - d, r.Y, d, d, 270, 90);
            p.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90);
            p.AddArc(r.X, r.Bottom - d, d, d, 90, 90);
            p.CloseFigure();
            Color fill = capturing ? cCap : (hover ? cHover : Color.White);
            using (Brush b = new SolidBrush(fill)) g.FillPath(b, p);
            using (Pen pen = new Pen(capturing ? cAccent : cLine, capturing ? 1.5f : 1f)) g.DrawPath(pen, p);
        }
        string text = capturing ? (previewMods == 0 ? "키를 누르세요…" : ModsText(previewMods) + "…") : Describe(Code);
        using (StringFormat sf = new StringFormat())
        using (Brush tb = new SolidBrush(capturing ? cAccent : cText)) {
            sf.Alignment = StringAlignment.Center;
            sf.LineAlignment = StringAlignment.Center;
            g.DrawString(text, Font, tb, new RectangleF(0, 0, Width, Height), sf);
        }
    }
}

public class PosList : Control {
    class Row { public int X, Y; public float Pos; public float Alpha = 1f; }
    class Ghost { public int X, Y, Num; public float Pos, Alpha; }

    const int RowH = 30;
    const int CloseW = 40;
    readonly List<Row> rows = new List<Row>();
    readonly List<Ghost> ghosts = new List<Ghost>();
    readonly Timer timer = new Timer();
    float scroll = 0f;
    int selected = -1, hover = -1;
    int downIdx = -1, downY = 0;
    bool downOnClose = false;
    bool dragging = false;
    Row dragRow = null;
    int dragFrom = -1, dropIdx = -1;
    float grabDy = 0f;
    int mouseY = 0;

    static readonly Color cAccent = Color.FromArgb(79, 107, 237);
    static readonly Color cText = Color.FromArgb(31, 36, 48);
    static readonly Color cMuted = Color.FromArgb(179, 184, 200);
    static readonly Color cSel = Color.FromArgb(237, 241, 255);
    static readonly Color cHover = Color.FromArgb(247, 248, 253);
    static readonly Color cBadge = Color.FromArgb(230, 235, 255);
    static readonly Color cLine = Color.FromArgb(234, 236, 242);
    Font fBase = new Font("Malgun Gothic", 9.5f);
    Font fSmall = new Font("Malgun Gothic", 8.5f);
    Font fBadge = new Font("Malgun Gothic", 8f, FontStyle.Bold);

    public event EventHandler Changed;
    public event EventHandler HoverChanged;
    public string EmptyText = "";

    public PosList() {
        SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.UserPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.Selectable | ControlStyles.ResizeRedraw, true);
        TabStop = true;
        BackColor = Color.White;
        timer.Interval = 15;
        timer.Tick += delegate { if (!Step()) timer.Stop(); Invalidate(); };
    }

    public int Count { get { return rows.Count; } }
    public bool Dragging { get { return dragging; } }
    public int HoverIndex { get { return hover; } }
    public int SelectedIndex { get { return selected; } set { selected = value; Invalidate(); } }
    public int GetX(int i) { return rows[i].X; }
    public int GetY(int i) { return rows[i].Y; }
    public int[] Xs() { int[] a = new int[rows.Count]; for (int i = 0; i < a.Length; i++) a[i] = rows[i].X; return a; }
    public int[] Ys() { int[] a = new int[rows.Count]; for (int i = 0; i < a.Length; i++) a[i] = rows[i].Y; return a; }

    void RaiseChanged() { if (Changed != null) Changed(this, EventArgs.Empty); }
    void Start() { if (!timer.Enabled) timer.Start(); }
    void ClampScroll() {
        float max = Math.Max(0, rows.Count * RowH - Height);
        if (scroll > max) scroll = max;
        if (scroll < 0) scroll = 0;
    }
    void SetHover(int i) {
        if (i == hover) return;
        hover = i;
        if (HoverChanged != null) HoverChanged(this, EventArgs.Empty);
        Invalidate();
    }

    public void Add(int x, int y) {
        int idx = rows.Count;
        Row r = new Row();
        r.X = x; r.Y = y; r.Pos = idx * RowH + 12; r.Alpha = 0f;
        rows.Add(r);
        selected = idx;
        float bottom = (idx + 1) * RowH;
        if (bottom - scroll > Height) scroll = bottom - Height;
        ClampScroll();
        RaiseChanged();
        Start();
    }

    void AddGhost(Row r, int num) {
        Ghost g = new Ghost();
        g.X = r.X; g.Y = r.Y; g.Pos = r.Pos; g.Alpha = 1f; g.Num = num;
        ghosts.Add(g);
    }

    public void RemoveAt(int i) {
        if (i < 0 || i >= rows.Count) return;
        AddGhost(rows[i], i + 1);
        rows.RemoveAt(i);
        if (selected >= rows.Count) selected = rows.Count - 1;
        ClampScroll();
        SetHover(-1);
        RaiseChanged();
        Start();
    }

    public void Clear() {
        for (int i = 0; i < rows.Count; i++) AddGhost(rows[i], i + 1);
        rows.Clear();
        selected = -1;
        scroll = 0;
        SetHover(-1);
        RaiseChanged();
        Start();
    }

    int SlotOf(int i) {
        if (!dragging) return i;
        if (i == dragFrom) return dropIdx;
        int k = i < dragFrom ? i : i - 1;
        return k < dropIdx ? k : k + 1;
    }

    int RowAt(int y) {
        int s = (int)Math.Floor((y + scroll) / RowH);
        if (s < 0 || s >= rows.Count) return -1;
        return s;
    }

    bool Step() {
        bool moving = false;
        if (dragging) {
            float t = mouseY - grabDy + scroll;
            int di = (int)Math.Floor((t + RowH / 2f) / RowH);
            if (di < 0) di = 0;
            if (di > rows.Count - 1) di = rows.Count - 1;
            dropIdx = di;
            if (mouseY < 14) scroll -= 5; else if (mouseY > Height - 14) scroll += 5;
            ClampScroll();
            moving = true;
        }
        for (int i = 0; i < rows.Count; i++) {
            Row r = rows[i];
            if (dragging && r == dragRow) {
                float t = mouseY - grabDy + scroll;
                r.Pos += (t - r.Pos) * 0.6f;
                continue;
            }
            float target = SlotOf(i) * RowH;
            float d = target - r.Pos;
            if (Math.Abs(d) > 0.4f) { r.Pos += d * 0.3f; moving = true; } else { r.Pos = target; }
            if (r.Alpha < 1f) { r.Alpha = Math.Min(1f, r.Alpha + 0.12f); moving = true; }
        }
        for (int g = ghosts.Count - 1; g >= 0; g--) {
            ghosts[g].Alpha -= 0.14f;
            if (ghosts[g].Alpha <= 0f) ghosts.RemoveAt(g); else moving = true;
        }
        return moving;
    }

    static Color A(Color c, float a) {
        if (a < 0f) a = 0f; if (a > 1f) a = 1f;
        return Color.FromArgb((int)(c.A * a), c);
    }

    static GraphicsPath Round(RectangleF r, float rad) {
        GraphicsPath p = new GraphicsPath();
        float d = rad * 2;
        p.AddArc(r.X, r.Y, d, d, 180, 90);
        p.AddArc(r.Right - d, r.Y, d, d, 270, 90);
        p.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90);
        p.AddArc(r.X, r.Bottom - d, d, d, 90, 90);
        p.CloseFigure();
        return p;
    }

    void DrawRow(Graphics g, int x, int y, float yPos, int num, float alpha, bool sel, bool hov, bool floating) {
        float top = yPos - scroll;
        if (top + RowH < 0 || top > Height) return;
        RectangleF rect = new RectangleF(4, top + 1, Width - 8, RowH - 2);
        if (floating) {
            using (GraphicsPath sp = Round(new RectangleF(rect.X, rect.Y + 3, rect.Width, rect.Height), 8))
            using (Brush sb = new SolidBrush(Color.FromArgb(40, 20, 30, 80))) g.FillPath(sb, sp);
            using (GraphicsPath fp = Round(rect, 8)) {
                using (Brush fb = new SolidBrush(Color.White)) g.FillPath(fb, fp);
                using (Pen bp = new Pen(cAccent, 1.5f)) g.DrawPath(bp, fp);
            }
        } else if (sel) {
            using (GraphicsPath fp = Round(rect, 6)) using (Brush fb = new SolidBrush(A(cSel, alpha))) g.FillPath(fb, fp);
            using (Brush ab = new SolidBrush(A(cAccent, alpha))) g.FillRectangle(ab, 4, top + 6, 3, RowH - 12);
        } else if (hov) {
            using (GraphicsPath fp = Round(rect, 6)) using (Brush fb = new SolidBrush(A(cHover, alpha))) g.FillPath(fb, fp);
        } else {
            using (Pen lp = new Pen(A(cLine, alpha))) g.DrawLine(lp, 12, top + RowH - 1, Width - 12, top + RowH - 1);
        }

        using (StringFormat center = new StringFormat())
        using (StringFormat left = new StringFormat()) {
            center.Alignment = StringAlignment.Center; center.LineAlignment = StringAlignment.Center;
            left.LineAlignment = StringAlignment.Center;
            RectangleF badge = new RectangleF(14, top + 4, 22, 22);
            using (Brush bb = new SolidBrush(A(cBadge, alpha))) g.FillEllipse(bb, badge);
            using (Brush ab = new SolidBrush(A(cAccent, alpha))) g.DrawString(num.ToString(), fBadge, ab, badge, center);
            using (Brush mb = new SolidBrush(A(cMuted, alpha)))
            using (Brush db = new SolidBrush(A(cText, alpha))) {
                g.DrawString("X", fSmall, mb, new RectangleF(52, top, 16, RowH), left);
                g.DrawString(x.ToString(), fBase, db, new RectangleF(68, top, 70, RowH), left);
                g.DrawString("Y", fSmall, mb, new RectangleF(148, top, 16, RowH), left);
                g.DrawString(y.ToString(), fBase, db, new RectangleF(164, top, 70, RowH), left);
                g.DrawString("✕", fSmall, mb, new RectangleF(Width - 38, top, 28, RowH), center);
            }
        }
    }

    protected override void OnPaint(PaintEventArgs e) {
        Graphics g = e.Graphics;
        g.SmoothingMode = SmoothingMode.AntiAlias;
        g.TextRenderingHint = System.Drawing.Text.TextRenderingHint.ClearTypeGridFit;
        g.Clear(Color.White);
        if (rows.Count == 0 && ghosts.Count == 0) {
            using (StringFormat sf = new StringFormat())
            using (Brush b = new SolidBrush(Color.FromArgb(139, 147, 167))) {
                sf.Alignment = StringAlignment.Center; sf.LineAlignment = StringAlignment.Center;
                g.DrawString(EmptyText, fSmall, b, new RectangleF(0, 0, Width, Height), sf);
            }
            return;
        }
        foreach (Ghost gh in ghosts) DrawRow(g, gh.X, gh.Y, gh.Pos, gh.Num, gh.Alpha, false, false, false);
        for (int i = 0; i < rows.Count; i++) {
            if (dragging && rows[i] == dragRow) continue;
            DrawRow(g, rows[i].X, rows[i].Y, rows[i].Pos, SlotOf(i) + 1, rows[i].Alpha, i == selected, i == hover && !dragging, false);
        }
        if (dragging && dragRow != null) DrawRow(g, dragRow.X, dragRow.Y, dragRow.Pos, dropIdx + 1, 1f, false, false, true);

        float content = rows.Count * RowH;
        if (content > Height) {
            float th = Math.Max(20f, Height * Height / content);
            float ty = scroll / (content - Height) * (Height - th);
            using (GraphicsPath tp = Round(new RectangleF(Width - 4, ty, 3, th), 1.5f))
            using (Brush tb = new SolidBrush(Color.FromArgb(200, 205, 220))) g.FillPath(tb, tp);
        }
    }

    protected override void OnMouseDown(MouseEventArgs e) {
        base.OnMouseDown(e);
        Focus();
        downIdx = -1;
        if (e.Button != MouseButtons.Left) return;
        int i = RowAt(e.Y);
        if (i < 0) return;
        downOnClose = e.X >= Width - CloseW;
        downIdx = i; downY = e.Y;
        grabDy = e.Y - (rows[i].Pos - scroll);
        if (!downOnClose) { selected = i; Invalidate(); }
    }

    protected override void OnMouseMove(MouseEventArgs e) {
        base.OnMouseMove(e);
        mouseY = e.Y;
        if (downIdx >= 0 && !downOnClose && (e.Button & MouseButtons.Left) != 0) {
            if (!dragging && Math.Abs(e.Y - downY) >= 4) {
                dragging = true;
                dragFrom = downIdx; dropIdx = downIdx; dragRow = rows[downIdx];
                Cursor = Cursors.SizeAll;
                SetHover(-1);
                Start();
            }
            return;
        }
        if (!dragging) {
            int i = RowAt(e.Y);
            SetHover(i);
            Cursor = (i >= 0 && e.X >= Width - CloseW) ? Cursors.Hand : Cursors.Default;
        }
    }

    protected override void OnMouseUp(MouseEventArgs e) {
        base.OnMouseUp(e);
        if (dragging) {
            dragging = false;
            Cursor = Cursors.Default;
            int from = dragFrom, to = dropIdx;
            dragRow = null; dragFrom = -1; dropIdx = -1;
            if (to >= 0 && to < rows.Count && to != from) {
                Row r = rows[from];
                rows.RemoveAt(from);
                rows.Insert(to, r);
                selected = to;
                RaiseChanged();
            }
            downIdx = -1;
            Start();
            return;
        }
        if (downIdx >= 0 && downOnClose && e.Button == MouseButtons.Left) {
            int i = RowAt(e.Y);
            if (i == downIdx && e.X >= Width - CloseW) RemoveAt(i);
        }
        downIdx = -1;
    }

    protected override void OnMouseLeave(EventArgs e) {
        base.OnMouseLeave(e);
        if (!dragging) SetHover(-1);
    }

    protected override void OnMouseWheel(MouseEventArgs e) {
        base.OnMouseWheel(e);
        scroll -= e.Delta / 120f * RowH;
        ClampScroll();
        Invalidate();
    }

    protected override void OnKeyDown(KeyEventArgs e) {
        base.OnKeyDown(e);
        if (e.KeyCode == Keys.Delete && selected >= 0) RemoveAt(selected);
    }

    protected override void Dispose(bool disposing) {
        if (disposing) { timer.Stop(); timer.Dispose(); fBase.Dispose(); fSmall.Dispose(); fBadge.Dispose(); }
        base.Dispose(disposing);
    }
}
"@

$MIN_MS = 1
$MAX_MS = 500
$MIN_INPUT = 0.1
$script:interval = 4.0
$script:syncingBar = $false
$inv = [System.Globalization.CultureInfo]::InvariantCulture

$cBg     = [System.Drawing.ColorTranslator]::FromHtml("#FFFFFF")
$cText   = [System.Drawing.ColorTranslator]::FromHtml("#1F2430")
$cMuted  = [System.Drawing.ColorTranslator]::FromHtml("#8B93A7")
$cLine   = [System.Drawing.ColorTranslator]::FromHtml("#EAECF2")
$cSoft   = [System.Drawing.ColorTranslator]::FromHtml("#F1F3F9")
$cAccent = [System.Drawing.ColorTranslator]::FromHtml("#4F6BED")
$cStop   = [System.Drawing.ColorTranslator]::FromHtml("#E5484D")

$fontBase = New-Object System.Drawing.Font("맑은 고딕", 9.5)
$fontBig  = New-Object System.Drawing.Font("맑은 고딕", 30, [System.Drawing.FontStyle]::Bold)
$fontBtn  = New-Object System.Drawing.Font("맑은 고딕", 11, [System.Drawing.FontStyle]::Bold)
$fontSmall = New-Object System.Drawing.Font("맑은 고딕", 8.5)
$fontUnit = New-Object System.Drawing.Font("맑은 고딕", 14, [System.Drawing.FontStyle]::Bold)
$fontBadge = New-Object System.Drawing.Font("맑은 고딕", 8, [System.Drawing.FontStyle]::Bold)

$form = New-Object System.Windows.Forms.Form
$form.Text = "오토클릭"
$form.ClientSize = New-Object System.Drawing.Size(320, 438)
$form.FormBorderStyle = "FixedDialog"
$form.MaximizeBox = $false
$form.StartPosition = "CenterScreen"
$form.TopMost = $false
$form.BackColor = $cBg
$form.ForeColor = $cText
$form.Font = $fontBase

try {
    $exePath = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
    if ($exePath -notmatch 'powershell|pwsh') {
        $form.Icon = [System.Drawing.Icon]::ExtractAssociatedIcon($exePath)
    } elseif ($PSScriptRoot -and (Test-Path (Join-Path $PSScriptRoot "autoclick.ico"))) {
        $form.Icon = New-Object System.Drawing.Icon((Join-Path $PSScriptRoot "autoclick.ico"))
    }
} catch {}

function New-Label($text, $x, $y, $color, $font) {
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $text
    $l.Location = New-Object System.Drawing.Point($x, $y)
    $l.AutoSize = $true
    $l.ForeColor = $color
    if ($font) { $l.Font = $font }
    $l
}

function New-Line($y) {
    $p = New-Object System.Windows.Forms.Panel
    $p.Location = New-Object System.Drawing.Point(20, $y)
    $p.Size = New-Object System.Drawing.Size(280, 1)
    $p.BackColor = $cLine
    $p
}

function New-Combo($y, $items, $index, $x = 200, $w = 100) {
    $c = New-Object System.Windows.Forms.ComboBox
    $c.Location = New-Object System.Drawing.Point($x, $y)
    $c.Size = New-Object System.Drawing.Size($w, 26)
    $c.DropDownStyle = "DropDownList"
    $c.FlatStyle = "Flat"
    $c.BackColor = $cBg
    $c.ForeColor = $cText
    [void]$c.Items.AddRange($items)
    $c.SelectedIndex = $index
    $c
}

$txtValue = New-Object System.Windows.Forms.TextBox
$txtValue.Location = New-Object System.Drawing.Point(20, 16)
$txtValue.Size = New-Object System.Drawing.Size(96, 56)
$txtValue.Font = $fontBig
$txtValue.BorderStyle = "None"
$txtValue.BackColor = $cBg
$txtValue.ForeColor = $cText
$txtValue.MaxLength = 5
$txtValue.TextAlign = "Left"

$lblUnit = New-Label "ms" 118 40 $cMuted $fontUnit
$underline = New-Object System.Windows.Forms.Panel
$underline.Location = New-Object System.Drawing.Point(20, 68)
$underline.Size = New-Object System.Drawing.Size(96, 2)
$underline.BackColor = $cLine

$lblCps = New-Label "" 20 80 $cMuted $fontSmall

$bar = New-Object System.Windows.Forms.TrackBar
$bar.AutoSize = $false
$bar.Location = New-Object System.Drawing.Point(12, 104)
$bar.Size = New-Object System.Drawing.Size(296, 30)
$bar.Minimum = $MIN_MS
$bar.Maximum = $MAX_MS
$bar.TickStyle = "None"
$bar.SmallChange = 1
$bar.LargeChange = 10
$bar.Value = 4
$bar.BackColor = $cBg

$lblMin = New-Label "$MIN_MS ms" 20 138 $cMuted $fontSmall
$lblMax = New-Label "$MAX_MS ms" 0 138 $cMuted $fontSmall
$lblMax.AutoSize = $false
$lblMax.TextAlign = "TopRight"
$lblMax.Size = New-Object System.Drawing.Size(100, 18)
$lblMax.Location = New-Object System.Drawing.Point(200, 138)

$line1 = New-Line 172

function New-Hotkey($y, $code) {
    $h = New-Object HotkeyBox
    $h.Location = New-Object System.Drawing.Point(170, $y)
    $h.Size = New-Object System.Drawing.Size(130, 28)
    $h.Code = $code
    $h
}

$lblButton = New-Label "마우스 버튼" 20 190 $cText $null
$cmbButton = New-Combo 186 @("왼쪽", "오른쪽") 0

$lblStartKey = New-Label "시작 키" 20 228 $cText $null
$hkStart = New-Hotkey 222 0x77

$lblStopKey = New-Label "정지 키" 20 266 $cText $null
$hkStop = New-Hotkey 260 0x77

$line2 = New-Line 302

$btn = New-Object System.Windows.Forms.Button
$btn.Location = New-Object System.Drawing.Point(20, 318)
$btn.Size = New-Object System.Drawing.Size(280, 44)
$btn.FlatStyle = "Flat"
$btn.FlatAppearance.BorderSize = 0
$btn.Font = $fontBtn
$btn.BackColor = $cAccent
$btn.ForeColor = [System.Drawing.Color]::White
$btn.Cursor = [System.Windows.Forms.Cursors]::Hand

$lblStatus = New-Label "" 0 370 $cMuted $fontSmall
$lblStatus.AutoSize = $false
$lblStatus.TextAlign = "TopCenter"
$lblStatus.Size = New-Object System.Drawing.Size(320, 18)

$lblPin = New-Object System.Windows.Forms.Label
$lblPin.Size = New-Object System.Drawing.Size(28, 28)
$lblPin.Location = New-Object System.Drawing.Point(280, 10)
$lblPin.Cursor = [System.Windows.Forms.Cursors]::Hand
$lblPin.BackColor = $cBg

$COLLAPSED_H = 438
$EXPANDED_H = 612

$btnAdv = New-Object System.Windows.Forms.Button
$btnAdv.Text = "▸  위치 지정 클릭"
$btnAdv.Location = New-Object System.Drawing.Point(20, 398)
$btnAdv.Size = New-Object System.Drawing.Size(280, 30)
$btnAdv.FlatStyle = "Flat"
$btnAdv.FlatAppearance.BorderSize = 0
$btnAdv.BackColor = $cSoft
$btnAdv.ForeColor = $cText
$btnAdv.TextAlign = "MiddleLeft"
$btnAdv.Padding = New-Object System.Windows.Forms.Padding(8, 0, 0, 0)
$btnAdv.Cursor = [System.Windows.Forms.Cursors]::Hand

$lblAdvState = New-Object System.Windows.Forms.Label
$lblAdvState.Size = New-Object System.Drawing.Size(46, 20)
$lblAdvState.Location = New-Object System.Drawing.Point(246, 403)
$lblAdvState.TextAlign = "MiddleCenter"
$lblAdvState.Font = $fontBadge
$lblAdvState.Cursor = [System.Windows.Forms.Cursors]::Hand

$advPanel = New-Object System.Windows.Forms.Panel
$advPanel.Location = New-Object System.Drawing.Point(0, 434)
$advPanel.Size = New-Object System.Drawing.Size(320, 174)
$advPanel.BackColor = $cBg
$advPanel.Visible = $false

$lblRecKey = New-Label "위치 기록 키" 20 12 $cText $null
$hkRec = New-Hotkey 6 0x75

$lstPos = New-Object PosList
$lstPos.Location = New-Object System.Drawing.Point(20, 44)
$lstPos.Size = New-Object System.Drawing.Size(280, 90)

$btnClear = New-Object System.Windows.Forms.Button
$btnClear.Text = "모두 지우기"
$btnClear.Location = New-Object System.Drawing.Point(206, 140)
$btnClear.Size = New-Object System.Drawing.Size(94, 26)
$btnClear.FlatStyle = "Flat"
$btnClear.FlatAppearance.BorderSize = 0
$btnClear.BackColor = $cBg
$btnClear.ForeColor = $cMuted
$btnClear.Font = $fontSmall
$btnClear.TextAlign = "MiddleRight"
$btnClear.Cursor = [System.Windows.Forms.Cursors]::Hand

$advPanel.Controls.AddRange(@($lblRecKey, $hkRec, $lstPos, $btnClear))

$form.Controls.AddRange(@(
    $txtValue, $lblUnit, $underline, $lblCps, $bar, $lblMin, $lblMax, $line1,
    $lblButton, $cmbButton, $lblStartKey, $hkStart, $lblStopKey, $hkStop,
    $line2, $btn, $lblStatus, $btnAdv, $lblAdvState, $advPanel, $lblPin))
$lblAdvState.BringToFront()

$clicker = New-Object Clicker
$uiTimer = New-Object System.Windows.Forms.Timer
$uiTimer.Interval = 50
$script:shownRunning = $false
$script:typing = $false
$script:msg = ""
$script:msgUntil = 0
$script:usePos = $false
$script:markers = New-Object System.Collections.ArrayList
$script:markerSig = ""

function Format-Ms($ms) { $ms.ToString("0.#", $inv) }

function Set-Interval($ms, $fromText) {
    $ms = [math]::Round([math]::Max($MIN_INPUT, [math]::Min($MAX_MS, $ms)), 1)
    $script:interval = $ms
    $clicker.IntervalUs = [int][math]::Round($ms * 1000)
    $script:syncingBar = $true
    $bar.Value = [int][math]::Max($MIN_MS, [math]::Min($MAX_MS, [math]::Round($ms)))
    $script:syncingBar = $false
    if (-not $fromText) { $txtValue.Text = Format-Ms $ms }
    $lblCps.Text = "초당 약 $([math]::Round(1000 / $ms, 1))회 클릭"
}

function Update-Idle {
    $btn.Text = "시작  ($($hkStart.Label))"
    $btn.BackColor = $cAccent
    $lblStatus.Text = "정지됨"
}

function Update-Running {
    $btn.Text = "정지  ($($hkStop.Label))"
    $btn.BackColor = $cStop
}

function Clear-Markers {
    foreach ($m in $script:markers) { $m.Close(); $m.Dispose() }
    $script:markers.Clear()
    $script:markerSig = ""
}

function Update-Markers {
    $hv = $lstPos.HoverIndex
    $show = $advPanel.Visible -and (-not $clicker.Running) -and (-not $lstPos.Dragging) -and ($hv -ge 0) -and ($hv -lt $lstPos.Count)
    $sig = ""
    if ($show) { $sig = "$hv|$($lstPos.GetX($hv)),$($lstPos.GetY($hv))" }
    if ($sig -eq $script:markerSig) { return }
    Clear-Markers
    $script:markerSig = $sig
    if (-not $show) { return }
    $half = [int]([Marker]::Canvas / 2)
    $m = New-Object Marker
    $m.Number = $hv + 1
    $m.Location = New-Object System.Drawing.Point(($lstPos.GetX($hv) - $half), ($lstPos.GetY($hv) - $half))
    $m.Show()
    [void]$script:markers.Add($m)
}

function Set-Rounded($c, $r) {
    $gp = New-Object System.Drawing.Drawing2D.GraphicsPath
    $d = $r * 2; $w = $c.Width; $h = $c.Height
    $gp.AddArc(0, 0, $d, $d, 180, 90)
    $gp.AddArc($w - $d, 0, $d, $d, 270, 90)
    $gp.AddArc($w - $d, $h - $d, $d, $d, 0, 90)
    $gp.AddArc(0, $h - $d, $d, $d, 90, 90)
    $gp.CloseFigure()
    $c.Region = New-Object System.Drawing.Region($gp)
}

function Update-AdvState {
    if ($script:usePos) {
        $lblAdvState.Text = "켜짐"
        $lblAdvState.BackColor = $cAccent
        $lblAdvState.ForeColor = [System.Drawing.Color]::White
    } else {
        $lblAdvState.Text = "꺼짐"
        $lblAdvState.BackColor = $cSoft
        $lblAdvState.ForeColor = $cMuted
    }
}

function Set-UsePositions($on) {
    $script:usePos = $on
    $clicker.UsePositions = $on
    Update-AdvState
}

function Toggle-Adv {
    $advPanel.Visible = -not $advPanel.Visible
    if ($advPanel.Visible) {
        $btnAdv.Text = "▾  위치 지정 클릭"
        $form.ClientSize = New-Object System.Drawing.Size(320, $EXPANDED_H)
    } else {
        $btnAdv.Text = "▸  위치 지정 클릭"
        $form.ClientSize = New-Object System.Drawing.Size(320, $COLLAPSED_H)
    }
}

function Update-Empty {
    $lstPos.EmptyText = "기록된 위치가 없습니다`n$($hkRec.Label) 키로 커서 위치를 추가하세요"
    $lstPos.Invalidate()
}

function Sync-Positions {
    $clicker.SetPositions($lstPos.Xs(), $lstPos.Ys())
}

function Set-Message($text) {
    $script:msg = $text
    $script:msgUntil = [Environment]::TickCount + 2500
}

$clicker.StartKey = $hkStart.Code
$clicker.StopKey = $hkStop.Code
$clicker.RecordKey = $hkRec.Code
$clicker.FormHandle = $form.Handle
Set-Interval 4 $false
Update-Idle
Update-Empty
Update-AdvState
Set-Rounded $lblAdvState 9

function Parse-Ms($text) {
    $n = 0.0
    if ([double]::TryParse($text, [System.Globalization.NumberStyles]::Float, $inv, [ref]$n)) { return $n }
    return $null
}

function Commit-Value {
    $n = Parse-Ms $txtValue.Text
    if ($null -eq $n) { $n = $script:interval }
    Set-Interval $n $false
}

$bar.Add_ValueChanged({ if (-not $script:syncingBar) { Set-Interval $bar.Value $false } })

$txtValue.Add_KeyPress({
    $c = $_.KeyChar
    if ([char]::IsControl($c) -or [char]::IsDigit($c)) { return }
    if ($c -eq '.' -and (-not $txtValue.Text.Contains('.') -or $txtValue.SelectionLength -eq $txtValue.Text.Length)) { return }
    $_.Handled = $true
})
$txtValue.Add_TextChanged({
    if (-not $txtValue.Focused) { return }
    $n = Parse-Ms $txtValue.Text
    if ($null -ne $n -and $n -ge $MIN_INPUT -and $n -le $MAX_MS) { Set-Interval $n $true }
})
$txtValue.Add_KeyDown({
    if ($_.KeyCode -eq "Return") { $_.SuppressKeyPress = $true; Commit-Value; $bar.Focus() }
    elseif ($_.KeyCode -eq "Up") {
        $_.SuppressKeyPress = $true
        $step = if ($script:interval -lt 1) { 0.1 } else { 1 }
        Set-Interval ($script:interval + $step) $false
    }
    elseif ($_.KeyCode -eq "Down") {
        $_.SuppressKeyPress = $true
        $step = if ($script:interval -le 1) { 0.1 } else { 1 }
        Set-Interval ($script:interval - $step) $false
    }
})
$txtValue.Add_Enter({ $underline.BackColor = $cAccent; $txtValue.SelectAll() })
$txtValue.Add_Leave({ $underline.BackColor = $cLine; Commit-Value })
$txtValue.Add_MouseUp({ if ($txtValue.SelectionLength -eq 0) { $txtValue.SelectAll() } })
$form.Add_Shown({ $txtValue.Focus() })

function Apply-Hotkeys {
    $clicker.StartKey = $hkStart.Code
    $clicker.StopKey = $hkStop.Code
    $clicker.RecordKey = $hkRec.Code
    if ($clicker.Running) { Update-Running } else { Update-Idle }
    Update-Empty
}

function On-HotkeyCaptured($box) {
    $r = $hkRec.Code
    if ($r -eq $hkStart.Code -or $r -eq $hkStop.Code) {
        $box.Code = $box.PrevCode
        $box.Invalidate()
        Set-Message "이미 다른 기능에서 쓰는 키예요"
        return
    }
    Apply-Hotkeys
}

foreach ($hk in $hkStart, $hkStop, $hkRec) {
    $hk.add_Captured({ On-HotkeyCaptured $this })
    $hk.add_CaptureChanged({ $clicker.Suspended = $this.Capturing })
}
$cmbButton.Add_SelectedIndexChanged({ $clicker.Button = $cmbButton.SelectedIndex })

$lblAdvState.Add_Click({ Set-UsePositions (-not $script:usePos) })
$tip = New-Object System.Windows.Forms.ToolTip
$tip.SetToolTip($lblAdvState, "클릭하면 저장한 위치 모드를 켜고 끕니다")
$tip.SetToolTip($txtValue, "0.1ms까지 직접 입력할 수 있어요 (슬라이더는 1ms부터)")
foreach ($hk in $hkStart, $hkStop, $hkRec) {
    $tip.SetToolTip($hk, "클릭한 뒤 원하는 키를 누르세요 (Ctrl, Alt, Shift 조합도 가능). 취소는 Esc")
}

function Update-PinTip {
    $tip.SetToolTip($lblPin, $(if ($form.TopMost) { "항상 맨 앞에 고정됨 - 클릭하면 해제" } else { "클릭하면 항상 맨 앞에 고정" }))
}
Update-PinTip
$lblPin.Add_Click({
    $form.TopMost = -not $form.TopMost
    Update-PinTip
    $lblPin.Invalidate()
})
$lblPin.Add_Paint({
    $g = $_.Graphics
    $g.SmoothingMode = "AntiAlias"
    $on = $form.TopMost
    $col = if ($on) { $cAccent } else { $cMuted }
    $g.TranslateTransform(14, 14)
    if (-not $on) { $g.RotateTransform(40) }
    $pen = New-Object System.Drawing.Pen($col, 1.8)
    $pen.LineJoin = "Round"
    $pen.StartCap = "Round"
    $pen.EndCap = "Round"
    $brush = New-Object System.Drawing.SolidBrush($col)
    if ($on) {
        $g.FillRectangle($brush, -3.5, -9, 7, 7)
        $g.FillRectangle($brush, -6.5, -2, 13, 3)
    } else {
        $g.DrawRectangle($pen, -3.5, -9, 7, 7)
        $g.DrawRectangle($pen, -6.5, -2, 13, 3)
    }
    $g.DrawLine($pen, 0, 1, 0, 9)
    $pen.Dispose()
    $brush.Dispose()
})

$lstPos.add_Changed({ Sync-Positions })
$lstPos.add_HoverChanged({ Update-Markers })
$btnAdv.Add_Click({ Toggle-Adv })
$btnClear.Add_Click({ $lstPos.Clear() })

$uiTimer.Add_Tick({
    Update-Markers
    $pt = $null
    while ($clicker.Recorded.TryDequeue([ref]$pt)) {
        if ($form.Bounds.Contains($pt[0], $pt[1])) {
            Set-Message "이 창 밖에서 기록 키를 눌러 주세요"
        } else {
            $lstPos.Add($pt[0], $pt[1])
            Set-Message "위치 $($lstPos.Count) 기록됨  ($($pt[0]), $($pt[1]))"
        }
    }

    $running = $clicker.Running
    if ($running -ne $script:shownRunning) {
        $script:shownRunning = $running
        $cmbButton.Enabled = -not $running
        if ($running) { Update-Running } else { Update-Idle }
    }

    $text = $null
    if ([Environment]::TickCount -lt $script:msgUntil) { $text = $script:msg }
    elseif ($running) {
        if ($clicker.NoPositions) { $text = "저장된 위치가 없습니다 - $($hkRec.Label) 키로 추가하세요" }
        elseif ($clicker.Paused) { $text = "대기 중 - 커서를 이 창 밖으로 옮기면 클릭합니다" }
        elseif ($clicker.UsePositions) { $text = "클릭 중 - 저장한 위치 $($lstPos.Count)곳을 순서대로" }
        else { $text = "클릭 중 - 이 창 위에서는 클릭하지 않습니다" }
    } else { $text = "정지됨" }
    if ($lblStatus.Text -ne $text) { $lblStatus.Text = $text }
})

$btn.Add_Click({ $clicker.Running = -not $clicker.Running })
$form.Add_FormClosing({ $clicker.Running = $false; $uiTimer.Stop(); Clear-Markers })

$clicker.Begin()
$uiTimer.Start()
[void]$form.ShowDialog()
