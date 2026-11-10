#Requires AutoHotkey v2.0
#SingleInstance Force
;@Ahk2Exe-SetName Mouse Mode
;@Ahk2Exe-SetDescription Mouse-only accessibility tool
;@Ahk2Exe-SetVersion 0.5.2
;@Ahk2Exe-SetMainIcon mousemode.ico
CoordMode("Mouse", "Screen")        ; use real screen position so the menu opens under the cursor

; ================= SETTINGS (read from settings.ini) =================
iniFile := A_ScriptDir "\settings.ini"
if !FileExist(iniFile) {
    IniWrite("^!o", iniFile, "General", "toggleKey")     ; ^ = Ctrl, ! = Alt, + = Shift, # = Win
    IniWrite("500", iniFile, "General", "holdMs")        ; hold time in milliseconds
    IniWrite("1", iniFile, "General", "colorCursor")     ; 1 = blue/red cursor, 0 = normal cursor
}
toggleKey   := IniRead(iniFile, "General", "toggleKey", "^!o")
holdMs      := Integer(IniRead(iniFile, "General", "holdMs", "500"))
colorCursor := (IniRead(iniFile, "General", "colorCursor", "1") = "1")
cursorFile  := A_Temp "\mousemode.cur"
FileInstall("mousemode.cur", cursorFile, 1)     ; packs the cursor file inside the .exe when compiled
wordsFile := A_Temp "\mousemode_words.txt"
try FileInstall("words.txt", wordsFile, 1)      ; word list for swipe typing, packed inside the .exe
if (!A_IsCompiled && FileExist(A_ScriptDir "\mousemode.ico"))
    TraySetIcon(A_ScriptDir "\mousemode.ico")
global cur1 := HexInt(IniRead(iniFile, "Cursor", "color1", "1E64FF"), 0x1E64FF)   ; cursor color 1
global cur2 := HexInt(IniRead(iniFile, "Cursor", "color2", "E61E1E"), 0xE61E1E)   ; cursor color 2
global curSize    := IniInt("size", 1, 1, 4)        ; 1 small, 2 medium, 3 large, 4 extra large
global curStyle   := IniInt("style", 1, 1, 3)       ; 1 left|right, 2 top|bottom, 3 solid
global curOutline := IniInt("outline", 1, 1, 3)     ; 1 black, 2 white, 3 none
global cg := 0                                      ; the "Customize cursor" window (0 = closed)

; ---- circle to search state ----
global csActive := false, csBmp := 0, csBase := 0, csFrame := 0, csGui := 0
global csL := 0, csT := 0, csW := 0, csH := 0
global csDown := false, csIgnore := false, csPts := [], csStartTick := 0, csPanel := 0

; PowerShell script that reads text from a picture with Windows' built-in OCR
global OCR_SCRIPT := "
(
Add-Type -AssemblyName System.Runtime.WindowsRuntime
$null = [Windows.Storage.StorageFile, Windows.Storage, ContentType = WindowsRuntime]
$null = [Windows.Media.Ocr.OcrEngine, Windows.Foundation, ContentType = WindowsRuntime]
$null = [Windows.Graphics.Imaging.BitmapDecoder, Windows.Foundation, ContentType = WindowsRuntime]
$null = [Windows.Graphics.Imaging.SoftwareBitmap, Windows.Foundation, ContentType = WindowsRuntime]
$null = [Windows.Storage.Streams.RandomAccessStream, Windows.Storage.Streams, ContentType = WindowsRuntime]
$asTask = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object { $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -like 'IAsyncOperation*' })[0]
function Await($op, $type) {
    $task = $asTask.MakeGenericMethod($type).Invoke($null, @($op))
    $task.Wait(-1) | Out-Null
    $task.Result
}
try {
    $file = Await ([Windows.Storage.StorageFile]::GetFileFromPathAsync($args[0])) ([Windows.Storage.StorageFile])
    $stream = Await ($file.OpenAsync([Windows.Storage.FileAccessMode]::Read)) ([Windows.Storage.Streams.IRandomAccessStream])
    $decoder = Await ([Windows.Graphics.Imaging.BitmapDecoder]::CreateAsync($stream)) ([Windows.Graphics.Imaging.BitmapDecoder])
    $bitmap = Await ($decoder.GetSoftwareBitmapAsync()) ([Windows.Graphics.Imaging.SoftwareBitmap])
    $engine = [Windows.Media.Ocr.OcrEngine]::TryCreateFromUserProfileLanguages()
    $result = Await ($engine.RecognizeAsync($bitmap)) ([Windows.Media.Ocr.OcrResult])
    [IO.File]::WriteAllText($args[1], $result.Text, [Text.Encoding]::UTF8)
} catch { }
)"

; Temporary web page that sends the circled picture to Google Lens by itself (no pasting)
global LENS_HTML := "
(
<!doctype html>
<html><head><meta charset='utf-8'>
<title>Searching by image...</title>
<style>
body{font-family:Segoe UI,Arial,sans-serif;background:#121418;color:#fff;text-align:center;padding-top:50px}
img{max-width:420px;max-height:260px;border-radius:12px;border:1px solid #333}
a{color:#8ab4f8}
#m{display:none;margin-top:24px;color:#cbd0da}
</style></head>
<body>
<h2>Searching Google for your picture...</h2>
<img id='p' alt=''>
<div id='m'>Still here? The picture is also on your clipboard: open <a href='https://lens.google.com/'>lens.google.com</a> and press Ctrl+V.</div>
<form id='f' method='POST' enctype='multipart/form-data' target='_self'>
<input type='file' name='encoded_image' id='i'>
<input type='hidden' name='processed_image_dimensions' value='__W__,__H__'>
</form>
<script>
var b64 = '__B64__';
document.getElementById('p').src = 'data:image/png;base64,' + b64;
setTimeout(function () { document.getElementById('m').style.display = 'block'; }, 6000);
try {
  var bin = atob(b64), n = bin.length, u = new Uint8Array(n);
  for (var k = 0; k < n; k++) u[k] = bin.charCodeAt(k);
  var file = new File([u], 'circle.png', {type: 'image/png'});
  var dt = new DataTransfer();
  dt.items.add(file);
  document.getElementById('i').files = dt.files;
  var f = document.getElementById('f');
  f.action = 'https://lens.google.com/upload?ep=ccm&s=&st=' + Date.now();
  f.submit();
} catch (e) {
  document.getElementById('m').style.display = 'block';
}
</script>
</body></html>
)"

; ---- clipboard history state ----
global clipItems := [], clipPaused := false, clipSkipUntil := 0
global clipOpen := false, clipGui := 0, clipSurf := 0
global clipX := 0, clipY := 0, clipW := 0, clipH := 0, clipScroll := 0
global clipHZone := "", clipHRow := 0
global clipDown := false, clipDownZone := "", clipDownRow := 0, clipDragging := false, clipIgnore := false
global clipDragOX := 0, clipDragOY := 0

; ---- swipe keyboard state ----
global kbOpen := false, kbGui := 0, kbBase := 0, kbFrame := 0
global kbX := 0, kbY := 0, kbW := 0, kbH := 0
global kbKeys := [], kbCenters := Map(), kbDict := 0
global kbLayer := "abc", kbShift := false
global kbDown := false, kbIgnore := false, kbDragging := false, kbRepeating := false
global kbStartIdx := 0, kbStartTick := 0, kbLastRep := 0, kbHover := 0
global kbPts := [], kbPathLen := 0, kbTouched := []
global kbDragOffX := 0, kbDragOffY := 0
global kbAlts := [], kbLastTyped := "", kbAfterSwipe := false
global presets := [
    {n: "Blue / Red (default)",           a: 0x1E64FF, b: 0xE61E1E, st: 1, ol: 1},
    {n: "Green / Yellow",                 a: 0x22A04B, b: 0xF5D000, st: 1, ol: 1},
    {n: "Black / White",                  a: 0x000000, b: 0xFFFFFF, st: 1, ol: 1},
    {n: "Orange / Purple",                a: 0xFF8A00, b: 0x8A2BE2, st: 1, ol: 1},
    {n: "Yellow / Black (high contrast)", a: 0xFFE600, b: 0x000000, st: 1, ol: 2},
    {n: "Pink / Cyan",                    a: 0xFF4FA3, b: 0x00C2E0, st: 1, ol: 1},
    {n: "Solid red",                      a: 0xE61E1E, b: 0xE61E1E, st: 3, ol: 1},
    {n: "Custom"}
]
StartupKey  := "HKCU\Software\Microsoft\Windows\CurrentVersion\Run"   ; where "Start with Windows" is stored
MAX_CUSTOM  := 3                                          ; how many shortcuts you can add

; ---- your shortcuts (up to 3), saved in settings.ini ----
global customs := []
Loop MAX_CUSTOM {
    i := A_Index
    t := IniRead(iniFile, "Custom", "target" i, "")
    if (t != "")
        customs.Push({target: t, name: IniRead(iniFile, "Custom", "name" i, ""), bmp: 0})
}
if (customs.Length = 0) {                                  ; older single-shortcut setting
    old := IniRead(iniFile, "Custom", "target", "")
    if (old != "")
        customs.Push({target: old, name: IniRead(iniFile, "Custom", "name", ""), bmp: 0})
}
; =====================================================================

global modeOn := false
global scrolled := false

; ================= RADIAL MENU =================
global radItems := []
global radAll := [], radPage := 1, radPages := 1, radLastTick := 0   ; the circle has pages; scroll while it is open to flip
global radOpen := false
global radSel := 0
global radX := 0                            ; which slice's little x badge is under the cursor (0 = none)
global radCX := 0
global radCY := 0
global radS := A_ScreenDPI / 96             ; scale for high-DPI screens
global radW := Round(300 * radS)            ; menu window size

; --- GDI+ (smooth graphics) startup ---
global gdipToken := 0
DllCall("LoadLibrary", "Str", "gdiplus")
gsi := Buffer(24, 0)
NumPut("UInt", 1, gsi, 0)
DllCall("gdiplus\GdiplusStartup", "Ptr*", &gdipToken, "Ptr", gsi, "Ptr", 0)

; --- off-screen drawing surface ---
global radHDC := DllCall("CreateCompatibleDC", "Ptr", 0, "Ptr")
gbi := Buffer(40, 0)
NumPut("UInt", 40, gbi, 0)
NumPut("Int", radW, gbi, 4)
NumPut("Int", -radW, gbi, 8)
NumPut("UShort", 1, gbi, 12)
NumPut("UShort", 32, gbi, 14)
gBits := 0
gHbm := DllCall("CreateDIBSection", "Ptr", radHDC, "Ptr", gbi, "UInt", 0, "Ptr*", &gBits, "Ptr", 0, "UInt", 0, "Ptr")
DllCall("SelectObject", "Ptr", radHDC, "Ptr", gHbm)
global radG := 0
DllCall("gdiplus\GdipCreateFromHDC", "Ptr", radHDC, "Ptr*", &radG)
DllCall("gdiplus\GdipSetSmoothingMode", "Ptr", radG, "Int", 4)       ; anti-alias shapes
DllCall("gdiplus\GdipSetTextRenderingHint", "Ptr", radG, "Int", 4)   ; anti-alias text

; --- build the menu from built-in options + your shortcuts ---
for c in customs {
    LoadIcon(c)
}
BuildItems()

; --- the menu window (per-pixel transparent, click-through, never steals focus) ---
global radGui := Gui("+AlwaysOnTop -Caption +ToolWindow +E0x80000 +E0x20 +E0x08000000")

; ---- Hotkey ----
try Hotkey(toggleKey, ToggleMode)
catch {
    MsgBox("The hotkey '" toggleKey "' in settings.ini is not valid.`nUsing Ctrl+Alt+O instead.")
    Hotkey("^!o", ToggleMode)
}

RebuildTray()
OnClipboardChange(ClipChanged)
OnExit((*) => RestoreCursor())

; ================= FUNCTIONS =================
ToggleMode(*) {
    global modeOn
    modeOn := !modeOn
    CloseRadial()
    if modeOn {
        if colorCursor
            SetCursor()
    } else {
        RestoreCursor()
    }
    A_IconTip := modeOn ? "Mouse Mode: ON" : "Mouse Mode: OFF"
    Notify(modeOn ? "Mouse mode ON" : "Mouse mode OFF", 1200)
}

SetCursor() {
    h := MakeCursorHandle(cur1, cur2, curSize, curStyle, curOutline)
    if !h                                            ; fallback: the packed .cur file
        h := DllCall("LoadCursorFromFile", "Str", cursorFile, "Ptr")
    DllCall("SetSystemCursor", "Ptr", h, "Int", 32512)
}

RestoreCursor() {
    DllCall("SystemParametersInfo", "UInt", 0x57, "UInt", 0, "Ptr", 0, "UInt", 0)
}

Notify(text, ms := 800) {
    ToolTip(text)
    SetTimer(() => ToolTip(), -ms)
}

; Copies the selection. Shows "Copied" only if something was really copied.
CopySelection() {
    global clipSkipUntil
    saved := ClipboardAll()          ; remember what was on the clipboard
    A_Clipboard := ""                ; empty it so we can tell if the copy worked
    Send("^c")
    if ClipWait(0.3)
        ToolTip("Copied")
    else {
        clipSkipUntil := A_TickCount + 400            ; don't record the restore as a new copy
        A_Clipboard := saved         ; nothing selected: put the old clipboard back
    }
}

; ---------- tray menu ----------
RebuildTray() {
    A_TrayMenu.Delete()
    A_TrayMenu.Add("Turn mouse mode ON / OFF", ToggleMode)
    A_TrayMenu.Add()
    A_TrayMenu.Add("Circle to search", CircleStart)
    A_TrayMenu.Add("Clipboard history", ToggleClipboard)
    A_TrayMenu.Add("Record clipboard history", ToggleClipRecord)
    if !clipPaused
        A_TrayMenu.Check("Record clipboard history")
    A_TrayMenu.Add()
    A_TrayMenu.Add("Customize cursor...", ShowCursorGui)
    A_TrayMenu.Add("Add shortcut to menu...", (*) => AddCustom())
    if (customs.Length >= MAX_CUSTOM)
        A_TrayMenu.Disable("Add shortcut to menu...")
    for i, c in customs {
        A_TrayMenu.Add("Remove: " CustomLabel(c), MakeRemover(i))
    }
    A_TrayMenu.Add()
    A_TrayMenu.Add("Start with Windows", ToggleStartup)
    if StartupOn()
        A_TrayMenu.Check("Start with Windows")
    A_TrayMenu.Add("Open settings file", (*) => Run('notepad.exe "' iniFile '"'))
    A_TrayMenu.Add("Reload (after editing settings)", (*) => Reload())
    A_TrayMenu.Add()
    A_TrayMenu.Add("Quit", (*) => ExitApp())
    A_TrayMenu.Default := "Turn mouse mode ON / OFF"
    A_TrayMenu.ClickCount := 1                 ; single click on tray icon toggles
    A_IconTip := modeOn ? "Mouse Mode: ON" : "Mouse Mode: OFF"
}

; ================= SWIPE KEYBOARD =================
MakeSurface(w, h) {
    hdc := DllCall("CreateCompatibleDC", "Ptr", 0, "Ptr")
    bi := Buffer(40, 0)
    NumPut("UInt", 40, bi, 0)
    NumPut("Int", w, bi, 4)
    NumPut("Int", -h, bi, 8)
    NumPut("UShort", 1, bi, 12)
    NumPut("UShort", 32, bi, 14)
    bits := 0
    hbm := DllCall("CreateDIBSection", "Ptr", hdc, "Ptr", bi, "UInt", 0, "Ptr*", &bits, "Ptr", 0, "UInt", 0, "Ptr")
    DllCall("SelectObject", "Ptr", hdc, "Ptr", hbm)
    g := 0
    DllCall("gdiplus\GdipCreateFromHDC", "Ptr", hdc, "Ptr*", &g)
    DllCall("gdiplus\GdipSetSmoothingMode", "Ptr", g, "Int", 4)
    DllCall("gdiplus\GdipSetTextRenderingHint", "Ptr", g, "Int", 4)
    return {hdc: hdc, g: g, w: w, h: h}
}

KRound(g, argb, x, y, w, h, r) {
    path := 0
    DllCall("gdiplus\GdipCreatePath", "Int", 0, "Ptr*", &path)
    d := 2 * r
    DllCall("gdiplus\GdipAddPathArc", "Ptr", path, "Float", x, "Float", y, "Float", d, "Float", d, "Float", 180, "Float", 90)
    DllCall("gdiplus\GdipAddPathArc", "Ptr", path, "Float", x + w - d, "Float", y, "Float", d, "Float", d, "Float", 270, "Float", 90)
    DllCall("gdiplus\GdipAddPathArc", "Ptr", path, "Float", x + w - d, "Float", y + h - d, "Float", d, "Float", d, "Float", 0, "Float", 90)
    DllCall("gdiplus\GdipAddPathArc", "Ptr", path, "Float", x, "Float", y + h - d, "Float", d, "Float", d, "Float", 90, "Float", 90)
    DllCall("gdiplus\GdipClosePathFigure", "Ptr", path)
    b := 0
    DllCall("gdiplus\GdipCreateSolidFill", "UInt", argb, "Ptr*", &b)
    DllCall("gdiplus\GdipFillPath", "Ptr", g, "Ptr", b, "Ptr", path)
    DllCall("gdiplus\GdipDeleteBrush", "Ptr", b)
    DllCall("gdiplus\GdipDeletePath", "Ptr", path)
}

LoadDict() {
    global kbDict
    kbDict := Map()
    if !FileExist(wordsFile)
        return
    rank := 0
    for w in StrSplit(FileRead(wordsFile), "`n", "`r") {
        if (w = "")
            continue
        rank += 1
        if !RegExMatch(w, "^[a-z]{2,}$")
            continue
        key := SubStr(w, 1, 1) SubStr(w, -1)               ; grouped by first + last letter
        if !kbDict.Has(key)
            kbDict[key] := []
        kbDict[key].Push({w: w, r: rank})
    }
}

; Lays out the keys for the current layer (abc or 123)
KbBuild() {
    global kbKeys, kbCenters
    S := radS
    M := 12 * S
    P := 58 * S
    Kk := 52 * S
    W := 600 * S
    keys := []
    sw := (W - 2 * M - 3 * 6 * S) / 4
    Loop 4 {
        i := A_Index
        keys.Push({kind: "sugg", n: i, label: "", x: M + (i - 1) * (sw + 6 * S), y: 38 * S, w: sw, h: 42 * S})
    }
    keys.Push({kind: "close", label: "X", x: W - M - 30 * S, y: 4 * S, w: 30 * S, h: 26 * S})
    if (kbLayer = "abc")
        rows := ["qwertyuiop", "asdfghjkl", "zxcvbnm"]
    else
        rows := ["1234567890", "@#$%&-+()", "*" Chr(34) "':;!?"]
    rowY := [88 * S, 146 * S, 204 * S]
    rowX := [M, M + P / 2, M + 1.5 * P]
    kind := (kbLayer = "abc") ? "letter" : "char"
    for r, str in rows {
        Loop StrLen(str) {
            ch := SubStr(str, A_Index, 1)
            keys.Push({kind: kind, ch: ch, label: ch, x: rowX[r] + (A_Index - 1) * P, y: rowY[r], w: Kk, h: Kk})
        }
    }
    sideW := 1.5 * P - 6 * S
    if (kbLayer = "abc")
        keys.Push({kind: "shift", label: "Shift", x: M, y: rowY[3], w: sideW, h: Kk})
    else
        keys.Push({kind: "char", ch: "/", label: "/", x: M, y: rowY[3], w: sideW, h: Kk})
    endW := W - M - (M + 8.5 * P)
    keys.Push({kind: "bs", label: "Back", x: M + 8.5 * P, y: rowY[3], w: endW, h: Kk})
    y4 := 262 * S
    keys.Push({kind: "layer", label: (kbLayer = "abc") ? "123" : "abc", x: M, y: y4, w: sideW, h: Kk})
    keys.Push({kind: "char", ch: ",", label: ",", x: M + 1.5 * P, y: y4, w: Kk, h: Kk})
    keys.Push({kind: "space", label: "space", x: M + 2.5 * P, y: y4, w: 5 * P - 6 * S, h: Kk})
    keys.Push({kind: "char", ch: ".", label: ".", x: M + 7.5 * P, y: y4, w: Kk, h: Kk})
    keys.Push({kind: "enter", label: "Enter", x: M + 8.5 * P, y: y4, w: endW, h: Kk})
    kbKeys := keys
    if (kbLayer = "abc") {
        kbCenters := Map()
        for k in keys {
            if (k.kind = "letter")
                kbCenters[k.ch] := [k.x + k.w / 2, k.y + k.h / 2]
        }
    }
}

KbKeyAt(lx, ly) {
    pad := 3 * radS                                  ; also covers the small gaps between keys
    for i, k in kbKeys {
        if (k.kind = "sugg" && k.n > kbAlts.Length)
            continue
        if (lx >= k.x - pad && lx < k.x + k.w + pad && ly >= k.y - pad && ly < k.y + k.h + pad)
            return i
    }
    return 0
}

KbLetterAt(lx, ly) {
    if (kbLayer != "abc")
        return ""
    pad := 3 * radS
    for k in kbKeys {
        if (k.kind = "letter" && lx >= k.x - pad && lx < k.x + k.w + pad && ly >= k.y - pad && ly < k.y + k.h + pad)
            return k.ch
    }
    return ""
}

ToggleKeyboard(*) {
    if kbOpen
        KbClose()
    else
        KbOpenNow()
}

KbOpenNow() {
    global kbOpen, kbGui, kbBase, kbFrame, kbW, kbH, kbX, kbY, kbDict, kbLayer, kbShift
    global kbAlts, kbAfterSwipe, kbLastTyped, kbDown, kbIgnore
    S := radS
    kbW := Round(600 * S)
    kbH := Round(326 * S)
    if !IsObject(kbBase) {
        kbBase := MakeSurface(kbW, kbH)
        kbFrame := MakeSurface(kbW, kbH)
    }
    if !IsObject(kbGui)
        kbGui := Gui("+AlwaysOnTop -Caption +ToolWindow +E0x80000 +E0x08000000")   ; never takes focus: typing goes to your app
    if !IsObject(kbDict)
        LoadDict()
    kbLayer := "abc"
    kbShift := false
    kbAlts := []
    kbAfterSwipe := false
    kbLastTyped := ""
    KbBuild()
    if (kbX = 0 && kbY = 0) {
        MonitorGetWorkArea(MonitorGetPrimary(), &l, &t, &r, &b)
        kbX := l + ((r - l) - kbW) // 2
        kbY := b - kbH - Round(10 * S)
    }
    kbGui.Show("NoActivate x" kbX " y" kbY " w" kbW " h" kbH)
    KbRenderBase()
    KbDrawFrame()
    kbOpen := true
    kbDown := false
    kbIgnore := GetKeyState("LButton", "P")
    SetTimer(KbTick, 16)
}

KbClose() {
    global kbOpen, kbDown
    SetTimer(KbTick, 0)
    if IsObject(kbGui)
        kbGui.Hide()
    kbOpen := false
    kbDown := false
}

; ---- drawing ----
KbRenderBase() {
    g := kbBase.g
    S := radS
    DllCall("gdiplus\GdipGraphicsClear", "Ptr", g, "UInt", 0)
    KRound(g, 0xF2121418, 0, 0, kbW, kbH, 16 * S)
    GText("Swipe keyboard  -  slide across the letters to type a word", "Segoe UI", 13 * S, 0xFFA9AFBD, 0, 4 * S, kbW - 40 * S, 26 * S, 0, g)
    for k in kbKeys {
        if (k.kind = "sugg") {
            has := (k.n <= kbAlts.Length)
            KRound(g, has ? ((k.n = 1) ? 0xFF2F7DF6 : 0xFF2A2E38) : 0xFF1C1F27, k.x, k.y, k.w, k.h, 8 * S)
            if has
                GText(kbAlts[k.n], "Segoe UI", 17 * S, 0xFFFFFFFF, k.x, k.y, k.w, k.h, 1, g)
        } else {
            if (k.kind = "shift" && kbShift)
                col := 0xFF2F7DF6
            else if (k.kind = "letter" || k.kind = "char" || k.kind = "space")
                col := 0xFF2E323D
            else
                col := 0xFF3F4452
            KRound(g, col, k.x, k.y, k.w, k.h, 9 * S)
            lbl := k.label
            if (k.kind = "letter" && kbShift)
                lbl := StrUpper(lbl)
            if (lbl != "")
                GText(lbl, "Segoe UI", (k.kind = "letter" || k.kind = "char") ? 21 * S : 14 * S, 0xFFEDEFF4, k.x, k.y, k.w, k.h, 1, g)
        }
    }
    if (kbAlts.Length = 0)
        GText("Word choices appear here", "Segoe UI", 13 * S, 0xFF6B7180, 12 * S, 38 * S, kbW - 24 * S, 42 * S, 0, g)
}

KbDrawFrame() {
    S := radS
    DllCall("BitBlt", "Ptr", kbFrame.hdc, "Int", 0, "Int", 0, "Int", kbW, "Int", kbH
        , "Ptr", kbBase.hdc, "Int", 0, "Int", 0, "UInt", 0xCC0020)
    g := kbFrame.g
    if (kbDown && !kbDragging) {
        if (kbHover > 0) {
            k := kbKeys[kbHover]
            KRound(g, 0xA02F7DF6, k.x, k.y, k.w, k.h, 9 * S)
        }
        n := kbPts.Length // 2
        if (n >= 2) {                                ; the trail of your slide
            pb := Buffer(8 * n)
            Loop n {
                NumPut("Float", kbPts[2 * A_Index - 1], "Float", kbPts[2 * A_Index], pb, (A_Index - 1) * 8)
            }
            pen := 0
            DllCall("gdiplus\GdipCreatePen1", "UInt", 0xD0FFC857, "Float", 6 * S, "Int", 2, "Ptr*", &pen)
            DllCall("gdiplus\GdipSetPenLineCap197819", "Ptr", pen, "Int", 2, "Int", 2, "Int", 2)
            DllCall("gdiplus\GdipSetPenLineJoin", "Ptr", pen, "Int", 2)
            DllCall("gdiplus\GdipDrawLines", "Ptr", g, "Ptr", pen, "Ptr", pb, "Int", n)
            DllCall("gdiplus\GdipDeletePen", "Ptr", pen)
        }
    }
    PresentKb()
}

PresentKb() {
    pt := Buffer(8, 0)
    NumPut("Int", kbX, "Int", kbY, pt)
    sz := Buffer(8, 0)
    NumPut("Int", kbW, "Int", kbH, sz)
    src := Buffer(8, 0)
    bf := Buffer(4, 0)
    NumPut("UChar", 0, "UChar", 0, "UChar", 255, "UChar", 1, bf)
    DllCall("UpdateLayeredWindow", "Ptr", kbGui.Hwnd, "Ptr", 0, "Ptr", pt, "Ptr", sz
        , "Ptr", kbFrame.hdc, "Ptr", src, "UInt", 0, "Ptr", bf, "UInt", 2)
}

; ---- mouse handling (polled, so the keyboard window never needs focus) ----
KbTick() {
    global kbDown, kbIgnore, kbDragging, kbRepeating, kbStartIdx, kbStartTick, kbLastRep, kbHover
    global kbPts, kbPathLen, kbTouched, kbDragOffX, kbDragOffY, kbX, kbY
    MouseGetPos(&mx, &my)
    lx := mx - kbX
    ly := my - kbY
    if !GetKeyState("LButton", "P") {
        if kbDown {
            kbDown := false
            KbRelease(lx, ly)
        }
        kbIgnore := false
        return
    }
    if kbIgnore
        return
    if !kbDown {                                     ; the button was just pressed
        if (lx < 0 || ly < 0 || lx >= kbW || ly >= kbH) {
            kbIgnore := true                         ; that click belongs to another app
            return
        }
        kbDown := true
        kbDragging := false
        kbRepeating := false
        kbPts := [lx, ly]
        kbPathLen := 0
        kbTouched := []
        kbStartTick := A_TickCount
        kbStartIdx := KbKeyAt(lx, ly)
        kbHover := kbStartIdx
        if (kbStartIdx = 0 && ly < 36 * radS) {      ; the top strip is a handle to move the keyboard
            kbDragging := true
            kbDragOffX := lx
            kbDragOffY := ly
        }
        ch := KbLetterAt(lx, ly)
        if (ch != "")
            kbTouched.Push(ch)
        KbDrawFrame()
        return
    }
    if kbDragging {
        kbX := mx - kbDragOffX
        kbY := my - kbDragOffY
        PresentKb()
        return
    }
    if (kbStartIdx > 0 && kbKeys[kbStartIdx].kind = "bs" && A_TickCount - kbStartTick > 450) {
        if (A_TickCount - kbLastRep > 70) {          ; holding Back keeps deleting
            Send("{Backspace}")
            kbLastRep := A_TickCount
            kbRepeating := true
        }
        return
    }
    px := kbPts[kbPts.Length - 1]
    py := kbPts[kbPts.Length]
    if (Abs(lx - px) < 1 && Abs(ly - py) < 1)
        return
    dist := Sqrt((lx - px) * (lx - px) + (ly - py) * (ly - py))
    steps := Max(1, Ceil(dist / (13 * radS)))        ; walk along the move so fast slides don't skip keys
    Loop steps {
        f := A_Index / steps
        ch := KbLetterAt(px + (lx - px) * f, py + (ly - py) * f)
        if (ch != "" && (kbTouched.Length = 0 || kbTouched[kbTouched.Length] != ch))
            kbTouched.Push(ch)
    }
    kbPathLen += dist
    kbPts.Push(lx, ly)
    kbHover := KbKeyAt(lx, ly)
    KbDrawFrame()
}

KbRelease(lx, ly) {
    global kbDragging, kbRepeating, kbPts, kbTouched, kbHover
    if kbDragging {
        kbDragging := false
        return
    }
    if kbRepeating {
        kbRepeating := false
    } else {
        k := (kbStartIdx > 0) ? kbKeys[kbStartIdx] : 0
        swiped := false
        if (IsObject(k) && k.kind = "letter" && kbPathLen > 0.5 * 58 * radS && kbTouched.Length >= 2) {
            swiped := true
            words := DecodeSwipe()
            if (words.Length > 0)
                TypeSwipeWord(words)
            else
                Notify("No match", 700)
        }
        if (!swiped && IsObject(k) && KbKeyAt(lx, ly) = kbStartIdx)
            KbTap(k)
    }
    kbPts := []
    kbTouched := []
    kbHover := 0
    if kbOpen
        KbDrawFrame()
}

; ---- typing ----
KbTap(k) {
    global kbShift, kbLayer, kbAlts, kbLastTyped, kbAfterSwipe
    kind := k.kind
    if (kind = "letter" || kind = "char") {
        ch := k.ch
        if (kind = "letter" && kbShift)
            ch := StrUpper(ch)
        if (kbAfterSwipe && InStr(",.?!;:", ch))
            Send("{Backspace}")                      ; punctuation goes right after the word
        SendText(InStr(",.?!", ch) ? ch " " : ch)
        kbShift := false
        kbAlts := []
        kbAfterSwipe := false
        KbBuild()
        KbRenderBase()
    } else if (kind = "space") {
        if !kbAfterSwipe
            SendText(" ")                            ; (a swiped word already ended with a space)
        kbAfterSwipe := false
        kbAlts := []
        KbRenderBase()
    } else if (kind = "bs") {
        Send("{Backspace}")
        kbAlts := []
        kbAfterSwipe := false
        KbRenderBase()
    } else if (kind = "enter") {
        Send("{Enter}")
        kbAlts := []
        kbAfterSwipe := false
        KbRenderBase()
    } else if (kind = "shift") {
        kbShift := !kbShift
        KbRenderBase()
    } else if (kind = "layer") {
        kbLayer := (kbLayer = "abc") ? "123" : "abc"
        KbBuild()
        KbRenderBase()
    } else if (kind = "close") {
        KbClose()
    } else if (kind = "sugg") {
        if (k.n <= kbAlts.Length) {                  ; pick another word instead of the one typed
            alt := kbAlts[k.n]
            Send("{Backspace " (StrLen(kbLastTyped) + 1) "}")
            SendText(alt " ")
            kbLastTyped := alt
            kbAfterSwipe := true
        }
    }
}

TypeSwipeWord(words) {
    global kbShift, kbAlts, kbLastTyped, kbAfterSwipe
    list := []
    for w in words
        list.Push(kbShift ? StrUpper(SubStr(w, 1, 1)) SubStr(w, 2) : w)
    SendText(list[1] " ")
    kbLastTyped := list[1]
    kbAlts := list
    kbAfterSwipe := true
    kbShift := false
    KbRenderBase()
}

; ---- finding the word: compare the shape of your slide with the ideal path of each word ----
Resample(pts, n) {
    cnt := pts.Length // 2
    out := []
    cum := [0]
    total := 0
    Loop cnt - 1 {
        i := A_Index
        dx := pts[2 * i + 1] - pts[2 * i - 1]
        dy := pts[2 * i + 2] - pts[2 * i]
        total += Sqrt(dx * dx + dy * dy)
        cum.Push(total)
    }
    if (total = 0) {
        Loop n
            out.Push(pts[1], pts[2])
        return out
    }
    seg := 1
    Loop n {
        t := total * (A_Index - 1) / (n - 1)
        while (seg < cnt - 1 && cum[seg + 1] < t)
            seg += 1
        segLen := cum[seg + 1] - cum[seg]
        f := (segLen > 0) ? (t - cum[seg]) / segLen : 0
        out.Push(pts[2 * seg - 1] + f * (pts[2 * seg + 1] - pts[2 * seg - 1])
               , pts[2 * seg] + f * (pts[2 * seg + 2] - pts[2 * seg]))
    }
    return out
}

WordPoly(word) {
    poly := []
    prev := ""
    Loop StrLen(word) {
        ch := SubStr(word, A_Index, 1)
        if (ch = prev)
            continue
        c := kbCenters[ch]
        poly.Push(c[1], c[2])
        prev := ch
    }
    return poly
}

LettersNear(x, y, radius) {
    items := []
    for ch, c in kbCenters {
        dx := c[1] - x
        dy := c[2] - y
        items.Push({ch: ch, d: Sqrt(dx * dx + dy * dy), used: false})
    }
    res := []
    Loop 3 {
        bi := 0
        bd := 1e9
        for i, it in items {
            if (!it.used && it.d < bd) {
                bd := it.d
                bi := i
            }
        }
        if !bi
            break
        items[bi].used := true
        if (bd <= radius || res.Length = 0)
            res.Push(items[bi].ch)
    }
    return res
}

DecodeSwipe() {
    n := kbPts.Length // 2
    if (n < 2 || !IsObject(kbDict) || kbDict.Count = 0)
        return []
    P := 58 * radS
    starts := LettersNear(kbPts[1], kbPts[2], P)
    ends := LettersNear(kbPts[2 * n - 1], kbPts[2 * n], P)
    user := Resample(kbPts, 24)
    top := []
    for a in starts {
        for b in ends {
            key := a b
            if !kbDict.Has(key)
                continue
            for e in kbDict[key] {
                poly := WordPoly(e.w)
                if (poly.Length < 4)
                    continue
                wp := Resample(poly, 24)
                sum := 0
                Loop 24 {
                    i := A_Index
                    dx := user[2 * i - 1] - wp[2 * i - 1]
                    dy := user[2 * i] - wp[2 * i]
                    sum += Sqrt(dx * dx + dy * dy)
                }
                score := sum / 24 / P + 0.04 * Ln(e.r)      ; shape match + a small bonus for common words
                pos := top.Length + 1
                for j, t in top {
                    if (score < t.s) {
                        pos := j
                        break
                    }
                }
                if (pos <= 4) {
                    top.InsertAt(pos, {w: e.w, s: score})
                    if (top.Length > 4)
                        top.Pop()
                }
            }
        }
    }
    words := []
    for t in top
        words.Push(t.w)
    return words
}

; ================= CLIPBOARD HISTORY =================
ToggleClipRecord(*) {
    global clipPaused
    clipPaused := !clipPaused
    RebuildTray()
    Notify(clipPaused ? "Clipboard history paused" : "Clipboard history recording", 1500)
}

; Runs every time something is copied (text only). Kept in memory, never saved to disk.
ClipChanged(dataType) {
    global clipItems
    if (clipPaused || dataType != 1 || A_TickCount < clipSkipUntil)
        return
    fmt := DllCall("RegisterClipboardFormat", "Str", "ExcludeClipboardContentFromMonitorProcessing", "UInt")
    if DllCall("IsClipboardFormatAvailable", "UInt", fmt)      ; password managers ask not to be recorded
        return
    try {
        t := A_Clipboard
    } catch {
        return
    }
    if (Trim(t) = "" || StrLen(t) > 20000)
        return
    pinned := false
    for i, it in clipItems {
        if (it.text == t) {                                    ; same text again: move it to the top
            pinned := it.pinned
            clipItems.RemoveAt(i)
            break
        }
    }
    clipItems.InsertAt(1, {text: t, pinned: pinned})
    count := 0
    i := 1
    while (i <= clipItems.Length) {                            ; keep the newest 30 (pinned ones always stay)
        if !clipItems[i].pinned {
            count += 1
            if (count > 30) {
                clipItems.RemoveAt(i)
                continue
            }
        }
        i += 1
    }
    if clipOpen
        ClipRender()
}

ClipOrder() {                                                  ; pinned first, then newest first
    out := []
    for it in clipItems {
        if it.pinned
            out.Push(it)
    }
    for it in clipItems {
        if !it.pinned
            out.Push(it)
    }
    return out
}

ClipPreview(t) {
    t := Trim(RegExReplace(t, "\s+", " "))
    return (StrLen(t) > 90) ? SubStr(t, 1, 88) "..." : t
}

ClipRect(zone, vi) {
    S := radS
    M := 12 * S
    if (zone = "close")
        return [clipW - M - 30 * S, 7 * S, 30 * S, 26 * S]
    if (zone = "clear")
        return [clipW - M - 30 * S - 8 * S - 70 * S, 7 * S, 70 * S, 26 * S]
    ry := 46 * S + (vi - 1) * 54 * S
    rx := M
    rw := clipW - 2 * M
    if (zone = "row")
        return [rx, ry, rw, 50 * S]
    if (zone = "pin")
        return [rx + rw - 74 * S, ry + 11 * S, 28 * S, 28 * S]
    return [rx + rw - 38 * S, ry + 11 * S, 28 * S, 28 * S]     ; "del"
}

ClipHit(lx, ly) {
    S := radS
    if (ly < 40 * S) {
        for z in ["close", "clear"] {
            r := ClipRect(z, 0)
            if (lx >= r[1] && lx < r[1] + r[3] && ly >= r[2] && ly < r[2] + r[4])
                return [z, 0]
        }
        return ["drag", 0]
    }
    rows := ClipOrder()
    vis := Min(8, rows.Length - clipScroll)
    Loop vis {
        vi := A_Index
        r := ClipRect("row", vi)
        if (lx >= r[1] && lx < r[1] + r[3] && ly >= r[2] && ly < r[2] + r[4]) {
            idx := vi + clipScroll
            for z in ["pin", "del"] {
                b := ClipRect(z, vi)
                if (lx >= b[1] - 4 * S && lx < b[1] + b[3] + 4 * S)
                    return [z, idx]
            }
            return ["row", idx]
        }
    }
    return ["", 0]
}

ClipRender() {
    global clipScroll
    g := clipSurf.g
    S := radS
    M := 12 * S
    rows := ClipOrder()
    clipScroll := Max(0, Min(clipScroll, rows.Length - 8))
    DllCall("gdiplus\GdipGraphicsClear", "Ptr", g, "UInt", 0)
    KRound(g, 0xF2121418, 0, 0, clipW, clipH, 16 * S)
    GText("Clipboard  (" rows.Length ")", "Segoe UI", 16 * S, 0xFFEDEFF4, M, 6 * S, 240 * S, 28 * S, 1, g, 0)

    r := ClipRect("clear", 0)
    KRound(g, (clipHZone = "clear") ? 0xFF4A5060 : 0xFF3A3F4C, r[1], r[2], r[3], r[4], 8 * S)
    GText("Clear", "Segoe UI", 13 * S, 0xFFEDEFF4, r[1], r[2], r[3], r[4], 0, g)
    r := ClipRect("close", 0)
    KRound(g, (clipHZone = "close") ? 0xFFE5484D : 0xFF3A3F4C, r[1], r[2], r[3], r[4], 8 * S)
    GText("X", "Segoe UI", 13 * S, 0xFFEDEFF4, r[1], r[2], r[3], r[4], 0, g)

    if (rows.Length = 0) {
        GText("Nothing copied yet.`nSelect some text and hold right-click to copy it.", "Segoe UI", 14 * S, 0xFF8A90A0
            , M, 120 * S, clipW - 2 * M, 100 * S, 0, g)
    }
    Loop Min(8, rows.Length - clipScroll) {
        vi := A_Index
        idx := vi + clipScroll
        it := rows[idx]
        hov := (clipHRow = idx && clipHZone != "")
        r := ClipRect("row", vi)
        KRound(g, hov ? 0xFF353A48 : 0xFF2A2E38, r[1], r[2], r[3], r[4], 9 * S)
        GText(ClipPreview(it.text), "Segoe UI", 13 * S, 0xFFEDEFF4, r[1] + 12 * S, r[2], r[3] - 12 * S - 86 * S, r[4], 0, g, 0)
        p := ClipRect("pin", vi)
        pc := it.pinned ? 0xFF2F7DF6 : ((hov && clipHZone = "pin") ? 0xFF4A5060 : 0xFF3A3F4C)
        KRound(g, pc, p[1], p[2], p[3], p[4], 8 * S)
        GText(Chr(0xE718), "Segoe MDL2 Assets", 14 * S, 0xFFFFFFFF, p[1], p[2], p[3], p[4], 0, g)
        d := ClipRect("del", vi)
        KRound(g, (hov && clipHZone = "del") ? 0xFFE5484D : 0xFF3A3F4C, d[1], d[2], d[3], d[4], 8 * S)
        GText(Chr(0xE711), "Segoe MDL2 Assets", 12 * S, 0xFFFFFFFF, d[1], d[2], d[3], d[4], 0, g)
    }
    msg := (rows.Length > 8) ? "Scroll the mouse wheel over the list for more" : "Click an item to paste it where you were typing"
    GText(msg, "Segoe UI", 12 * S, 0xFF6B7180, M, 480 * S, clipW - 2 * M, 24 * S, 0, g)
    PresentClip()
}

PresentClip() {
    pt := Buffer(8, 0)
    NumPut("Int", clipX, "Int", clipY, pt)
    sz := Buffer(8, 0)
    NumPut("Int", clipW, "Int", clipH, sz)
    src := Buffer(8, 0)
    bf := Buffer(4, 0)
    NumPut("UChar", 0, "UChar", 0, "UChar", 255, "UChar", 1, bf)
    DllCall("UpdateLayeredWindow", "Ptr", clipGui.Hwnd, "Ptr", 0, "Ptr", pt, "Ptr", sz
        , "Ptr", clipSurf.hdc, "Ptr", src, "UInt", 0, "Ptr", bf, "UInt", 2)
}

ToggleClipboard(*) {
    if clipOpen
        ClipClose()
    else
        ClipOpenNow()
}

ClipOpenNow() {
    global clipOpen, clipGui, clipSurf, clipW, clipH, clipX, clipY, clipScroll
    global clipHZone, clipHRow, clipDown, clipIgnore
    S := radS
    clipW := Round(420 * S)
    clipH := Round(510 * S)
    if !IsObject(clipSurf)
        clipSurf := MakeSurface(clipW, clipH)
    if !IsObject(clipGui)
        clipGui := Gui("+AlwaysOnTop -Caption +ToolWindow +E0x80000 +E0x08000000")   ; never takes focus
    MouseGetPos(&mx, &my)
    l := 0, t := 0, r := A_ScreenWidth, b := A_ScreenHeight
    Loop MonitorGetCount() {                         ; use the screen the cursor is on
        MonitorGetWorkArea(A_Index, &ml, &mt, &mr, &mb)
        if (mx >= ml && mx < mr && my >= mt && my < mb) {
            l := ml, t := mt, r := mr, b := mb
            break
        }
    }
    clipX := Max(l, Min(mx - clipW // 2, r - clipW))
    clipY := Max(t, Min(my - Round(60 * S), b - clipH))
    clipScroll := 0
    clipHZone := ""
    clipHRow := 0
    clipDown := false
    clipGui.Show("NoActivate x" clipX " y" clipY " w" clipW " h" clipH)
    ClipRender()
    clipOpen := true
    clipIgnore := GetKeyState("LButton", "P")
    SetTimer(ClipTick, 20)
}

ClipClose() {
    global clipOpen, clipDown
    SetTimer(ClipTick, 0)
    if IsObject(clipGui)
        clipGui.Hide()
    clipOpen := false
    clipDown := false
}

ClipMouseOver() {
    MouseGetPos(&mx, &my)
    return (mx >= clipX && my >= clipY && mx < clipX + clipW && my < clipY + clipH)
}

ClipScrollBy(d) {
    global clipScroll
    clipScroll += d
    ClipRender()
}

ClipTick() {
    global clipHZone, clipHRow, clipDown, clipDownZone, clipDownRow, clipDragging, clipDragOX, clipDragOY
    global clipX, clipY, clipIgnore
    MouseGetPos(&mx, &my)
    lx := mx - clipX
    ly := my - clipY
    inside := (lx >= 0 && ly >= 0 && lx < clipW && ly < clipH)
    if !GetKeyState("LButton", "P") {
        if clipDown {
            clipDown := false
            if clipDragging {
                clipDragging := false
            } else {
                h := ClipHit(lx, ly)
                if (h[1] = clipDownZone && h[2] = clipDownRow)
                    ClipAct(h[1], h[2])
            }
        }
        clipIgnore := false
        if !clipOpen
            return
        if inside {
            h := ClipHit(lx, ly)
            z := h[1]
            rw := h[2]
        } else {
            z := ""
            rw := 0
        }
        if (z != clipHZone || rw != clipHRow) {
            clipHZone := z
            clipHRow := rw
            ClipRender()
        }
        return
    }
    if clipIgnore
        return
    if !clipDown {
        if !inside {                                 ; a click outside closes it (and still reaches the app)
            ClipClose()
            return
        }
        clipDown := true
        h := ClipHit(lx, ly)
        clipDownZone := h[1]
        clipDownRow := h[2]
        if (clipDownZone = "drag") {
            clipDragging := true
            clipDragOX := lx
            clipDragOY := ly
        }
        return
    }
    if clipDragging {
        clipX := mx - clipDragOX
        clipY := my - clipDragOY
        PresentClip()
    }
}

ClipAct(zone, idx) {
    global clipItems, clipScroll
    rows := ClipOrder()
    if (zone = "close") {
        ClipClose()
    } else if (zone = "clear") {
        keep := []
        for it in clipItems {
            if it.pinned
                keep.Push(it)
        }
        clipItems := keep
        clipScroll := 0
        ClipRender()
    } else if (zone = "pin") {
        rows[idx].pinned := !rows[idx].pinned
        ClipRender()
    } else if (zone = "del") {
        target := ObjPtr(rows[idx])
        for i, it in clipItems {
            if (ObjPtr(it) = target) {
                clipItems.RemoveAt(i)
                break
            }
        }
        ClipRender()
    } else if (zone = "row") {
        ClipPaste(rows[idx].text)
    }
}

ClipPaste(text) {
    ClipClose()
    A_Clipboard := text
    if ClipWait(1)
        Send("^v")                                   ; pastes into the app you were using (focus never left it)
}

; ================= CIRCLE TO SEARCH =================
UrlEncode(str) {
    n := StrPut(str, "UTF-8") - 1
    buf := Buffer(n + 1, 0)
    StrPut(str, buf, "UTF-8")
    out := ""
    Loop n {
        b := NumGet(buf, A_Index - 1, "UChar")
        if ((b >= 48 && b <= 57) || (b >= 65 && b <= 90) || (b >= 97 && b <= 122) || b = 45 || b = 46 || b = 95 || b = 126)
            out .= Chr(b)
        else
            out .= Format("%{:02X}", b)
    }
    return out
}

Base64Encode(buf) {
    size := 0
    DllCall("crypt32\CryptBinaryToStringW", "Ptr", buf, "UInt", buf.Size, "UInt", 0x40000001, "Ptr", 0, "UInt*", &size)
    out := Buffer(size * 2 + 2, 0)
    DllCall("crypt32\CryptBinaryToStringW", "Ptr", buf, "UInt", buf.Size, "UInt", 0x40000001, "Ptr", out, "UInt*", &size)
    return StrGet(out, size, "UTF-16")
}

SavePng(bmp, path) {
    clsid := Buffer(16, 0)
    DllCall("ole32\CLSIDFromString", "WStr", "{557CF406-1A04-11D3-9A73-0000F81EF32E}", "Ptr", clsid)
    return DllCall("gdiplus\GdipSaveImageToFile", "Ptr", bmp, "WStr", path, "Ptr", clsid, "Ptr", 0) = 0
}

; A plain picture with no transparency (24-bit), as a block of memory the clipboard can own
BuildDib(bmp) {
    w := 0, h := 0
    DllCall("gdiplus\GdipGetImageWidth", "Ptr", bmp, "UInt*", &w)
    DllCall("gdiplus\GdipGetImageHeight", "Ptr", bmp, "UInt*", &h)
    b24 := 0
    DllCall("gdiplus\GdipCloneBitmapAreaI", "Int", 0, "Int", 0, "Int", w, "Int", h, "Int", 0x21808, "Ptr", bmp, "Ptr*", &b24)
    if !b24
        return 0
    rect := Buffer(16, 0)
    NumPut("Int", 0, "Int", 0, "Int", w, "Int", h, rect)
    bd := Buffer(32, 0)
    if (DllCall("gdiplus\GdipBitmapLockBits", "Ptr", b24, "Ptr", rect, "UInt", 1, "Int", 0x21808, "Ptr", bd) != 0) {
        DllCall("gdiplus\GdipDisposeImage", "Ptr", b24)
        return 0
    }
    stride := NumGet(bd, 8, "Int")
    scan0 := NumGet(bd, 16, "Ptr")
    rowBytes := ((w * 3 + 3) // 4) * 4
    hMem := DllCall("GlobalAlloc", "UInt", 0x42, "UPtr", 40 + rowBytes * h, "Ptr")     ; movable + zeroed
    p := DllCall("GlobalLock", "Ptr", hMem, "Ptr")
    NumPut("UInt", 40, "Int", w, "Int", h, "UShort", 1, "UShort", 24, "UInt", 0, "UInt", rowBytes * h, p)
    Loop h {                                         ; a DIB stores its rows bottom to top
        DllCall("RtlMoveMemory", "Ptr", p + 40 + (h - A_Index) * rowBytes, "Ptr", scan0 + (A_Index - 1) * stride, "UPtr", w * 3)
    }
    DllCall("GlobalUnlock", "Ptr", hMem)
    DllCall("gdiplus\GdipBitmapUnlockBits", "Ptr", b24, "Ptr", bd)
    DllCall("gdiplus\GdipDisposeImage", "Ptr", b24)
    return hMem
}

ClipSetImage(bmp) {                                  ; puts a picture on the clipboard (PNG + standard picture)
    png := A_Temp "\mm_copy.png"
    pngMem := 0
    if SavePng(bmp, png) {
        try {
            buf := FileRead(png, "RAW")
            pngMem := DllCall("GlobalAlloc", "UInt", 0x2, "UPtr", buf.Size, "Ptr")
            pp := DllCall("GlobalLock", "Ptr", pngMem, "Ptr")
            DllCall("RtlMoveMemory", "Ptr", pp, "Ptr", buf.Ptr, "UPtr", buf.Size)
            DllCall("GlobalUnlock", "Ptr", pngMem)
        } catch {
            pngMem := 0
        }
    }
    dibMem := BuildDib(bmp)
    if (!pngMem && !dibMem)
        return false
    opened := false
    Loop 6 {                                         ; the clipboard can be busy for a moment
        if DllCall("OpenClipboard", "Ptr", 0) {
            opened := true
            break
        }
        Sleep(40)
    }
    if !opened {
        if pngMem
            DllCall("GlobalFree", "Ptr", pngMem)
        if dibMem
            DllCall("GlobalFree", "Ptr", dibMem)
        return false
    }
    DllCall("EmptyClipboard")
    if dibMem {
        if !DllCall("SetClipboardData", "UInt", 8, "Ptr", dibMem, "Ptr")
            DllCall("GlobalFree", "Ptr", dibMem)
    }
    if pngMem {
        fmt := DllCall("RegisterClipboardFormat", "Str", "PNG", "UInt")
        if !DllCall("SetClipboardData", "UInt", fmt, "Ptr", pngMem, "Ptr")
            DllCall("GlobalFree", "Ptr", pngMem)
    }
    DllCall("CloseClipboard")
    return true
}

CsCapture(l, t, w, h) {                              ; picture of one screen
    hdcScreen := DllCall("GetDC", "Ptr", 0, "Ptr")
    hdcMem := DllCall("CreateCompatibleDC", "Ptr", hdcScreen, "Ptr")
    hbm := DllCall("CreateCompatibleBitmap", "Ptr", hdcScreen, "Int", w, "Int", h, "Ptr")
    old := DllCall("SelectObject", "Ptr", hdcMem, "Ptr", hbm, "Ptr")
    DllCall("BitBlt", "Ptr", hdcMem, "Int", 0, "Int", 0, "Int", w, "Int", h, "Ptr", hdcScreen, "Int", l, "Int", t, "UInt", 0x40CC0020)
    DllCall("SelectObject", "Ptr", hdcMem, "Ptr", old)
    bmp := 0
    DllCall("gdiplus\GdipCreateBitmapFromHBITMAP", "Ptr", hbm, "Ptr", 0, "Ptr*", &bmp)
    DllCall("DeleteObject", "Ptr", hbm)
    DllCall("DeleteDC", "Ptr", hdcMem)
    DllCall("ReleaseDC", "Ptr", 0, "Ptr", hdcScreen)
    return bmp
}

CircleStart(*) {
    global csActive, csBmp, csBase, csFrame, csGui, csL, csT, csW, csH, csDown, csIgnore, csPts, csStartTick
    if csActive
        return
    CsPClose()
    Sleep(150)                                       ; let the round menu finish disappearing
    MouseGetPos(&mx, &my)
    l := 0, t := 0, r := A_ScreenWidth, b := A_ScreenHeight
    Loop MonitorGetCount() {                         ; the screen the cursor is on
        MonitorGet(A_Index, &ml, &mt, &mr, &mb)
        if (mx >= ml && mx < mr && my >= mt && my < mb) {
            l := ml, t := mt, r := mr, b := mb
            break
        }
    }
    csL := l, csT := t, csW := r - l, csH := b - t
    csBmp := CsCapture(csL, csT, csW, csH)
    if !csBmp {
        Notify("Could not capture the screen", 1500)
        return
    }
    if (!IsObject(csBase) || csBase.w != csW || csBase.h != csH) {
        csBase := MakeSurface(csW, csH)
        csFrame := MakeSurface(csW, csH)
    }
    if !IsObject(csGui)
        csGui := Gui("+AlwaysOnTop -Caption +ToolWindow +E0x80000 +E0x08000000")
    CsDrawBase()
    csPts := []
    csDown := false
    csIgnore := GetKeyState("LButton", "P")
    csStartTick := A_TickCount
    csGui.Show("NoActivate x" csL " y" csT " w" csW " h" csH)
    CsDrawFrame()
    csActive := true
    SetTimer(CsTick, 16)
}

CsDrawBase() {                                       ; frozen, darkened screen + instructions
    g := csBase.g
    S := radS
    DllCall("gdiplus\GdipDrawImageRectI", "Ptr", g, "Ptr", csBmp, "Int", 0, "Int", 0, "Int", csW, "Int", csH)
    GFillRect(g, 0x8C000000, 0, 0, csW, csH)
    pw := 600 * S
    px := (csW - pw) / 2
    KRound(g, 0xE6121418, px, 24 * S, pw, 44 * S, 22 * S)
    GText("Draw a circle around what you want to search   -   right-click to cancel", "Segoe UI", 15 * S, 0xFFFFFFFF, px, 24 * S, pw, 44 * S, 0, g)
}

CsDrawFrame() {
    DllCall("BitBlt", "Ptr", csFrame.hdc, "Int", 0, "Int", 0, "Int", csW, "Int", csH
        , "Ptr", csBase.hdc, "Int", 0, "Int", 0, "UInt", 0xCC0020)
    n := csPts.Length // 2
    if (n >= 2) {
        S := radS
        pb := Buffer(8 * n)
        Loop n {
            NumPut("Float", csPts[2 * A_Index - 1], "Float", csPts[2 * A_Index], pb, (A_Index - 1) * 8)
        }
        for spec in [[16, 0x403B82F6], [6, 0xFFB6D4FF]] {      ; soft glow + bright line
            pen := 0
            DllCall("gdiplus\GdipCreatePen1", "UInt", spec[2], "Float", spec[1] * S, "Int", 2, "Ptr*", &pen)
            DllCall("gdiplus\GdipSetPenLineCap197819", "Ptr", pen, "Int", 2, "Int", 2, "Int", 2)
            DllCall("gdiplus\GdipSetPenLineJoin", "Ptr", pen, "Int", 2)
            DllCall("gdiplus\GdipDrawLines", "Ptr", csFrame.g, "Ptr", pen, "Ptr", pb, "Int", n)
            DllCall("gdiplus\GdipDeletePen", "Ptr", pen)
        }
    }
    PresentCs()
}

PresentCs() {
    pt := Buffer(8, 0)
    NumPut("Int", csL, "Int", csT, pt)
    sz := Buffer(8, 0)
    NumPut("Int", csW, "Int", csH, sz)
    src := Buffer(8, 0)
    bf := Buffer(4, 0)
    NumPut("UChar", 0, "UChar", 0, "UChar", 255, "UChar", 1, bf)
    DllCall("UpdateLayeredWindow", "Ptr", csGui.Hwnd, "Ptr", 0, "Ptr", pt, "Ptr", sz
        , "Ptr", csFrame.hdc, "Ptr", src, "UInt", 0, "Ptr", bf, "UInt", 2)
}

CsTick() {
    global csDown, csIgnore, csPts
    if !csActive
        return
    if GetKeyState("RButton", "P") {                 ; right-click cancels
        CsCancel()
        return
    }
    MouseGetPos(&mx, &my)
    lx := mx - csL
    ly := my - csT
    if !GetKeyState("LButton", "P") {
        csIgnore := false
        if csDown {                                  ; button released = the circle is finished
            csDown := false
            CsFinish()
        } else if (A_TickCount - csStartTick > 30000) {
            CsCancel()
        }
        return
    }
    if csIgnore
        return
    if !csDown {
        csDown := true
        csPts := [lx, ly]
        return
    }
    px := csPts[csPts.Length - 1]
    py := csPts[csPts.Length]
    if (Abs(lx - px) + Abs(ly - py) < 3)
        return
    csPts.Push(lx, ly)
    CsDrawFrame()
}

CsCancel() {
    global csActive, csBmp, csDown
    SetTimer(CsTick, 0)
    if IsObject(csGui)
        csGui.Hide()
    csActive := false
    csDown := false
    if csBmp {
        DllCall("gdiplus\GdipDisposeImage", "Ptr", csBmp)
        csBmp := 0
    }
}

CsFinish() {
    n := csPts.Length // 2
    if (n < 3) {
        CsCancel()
        return
    }
    minX := csPts[1], maxX := csPts[1], minY := csPts[2], maxY := csPts[2]
    Loop n {
        x := csPts[2 * A_Index - 1]
        y := csPts[2 * A_Index]
        minX := Min(minX, x), maxX := Max(maxX, x)
        minY := Min(minY, y), maxY := Max(maxY, y)
    }
    x0 := Max(0, Floor(minX) - 8)
    y0 := Max(0, Floor(minY) - 8)
    x1 := Min(csW, Ceil(maxX) + 8)
    y1 := Min(csH, Ceil(maxY) + 8)
    w := x1 - x0
    h := y1 - y0
    if (w < 24 || h < 24) {
        CsCancel()
        Notify("Draw a bigger circle around what you want", 1800)
        return
    }
    crop := 0
    DllCall("gdiplus\GdipCloneBitmapAreaI", "Int", x0, "Int", y0, "Int", w, "Int", h, "Int", 0x26200A, "Ptr", csBmp, "Ptr*", &crop)
    rx := csL + x0
    ry := csT + y0
    CsCancel()                                       ; overlay disappears
    if !crop
        return

    k := (h < 160) ? 3 : (h < 400) ? 2 : 1           ; small pictures are enlarged so the text is easier to read
    big := 0
    DllCall("gdiplus\GdipCreateBitmapFromScan0", "Int", w * k, "Int", h * k, "Int", 0, "Int", 0x26200A, "Ptr", 0, "Ptr*", &big)
    bg := 0
    DllCall("gdiplus\GdipGetImageGraphicsContext", "Ptr", big, "Ptr*", &bg)
    DllCall("gdiplus\GdipSetInterpolationMode", "Ptr", bg, "Int", 7)
    DllCall("gdiplus\GdipDrawImageRectI", "Ptr", bg, "Ptr", crop, "Int", 0, "Int", 0, "Int", w * k, "Int", h * k)
    DllCall("gdiplus\GdipDeleteGraphics", "Ptr", bg)
    png := A_Temp "\mm_circle.png"
    SavePng(big, png)
    DllCall("gdiplus\GdipDisposeImage", "Ptr", big)

    ToolTip("Reading text...")
    text := RunOcr(png)
    ToolTip()
    CsShowPanel(crop, text, rx, ry, w, h)
}

RunOcr(png) {                                        ; Windows' built-in text recognition, run locally
    ps := A_Temp "\mm_ocr.ps1"
    out := A_Temp "\mm_ocr.txt"
    q := Chr(34)
    try FileDelete(out)
    try FileDelete(ps)
    FileAppend(OCR_SCRIPT, ps, "UTF-8")
    try RunWait("powershell.exe -NoProfile -ExecutionPolicy Bypass -File " q ps q " " q png q " " q out q, , "Hide")
    txt := ""
    try txt := FileRead(out, "UTF-8")
    return Trim(RegExReplace(txt, "\s+", " "))
}

; ---- the results window ----
CsShowPanel(crop, text, rx, ry, rw, rh) {
    global csPanel
    cw := 0, ch := 0
    DllCall("gdiplus\GdipGetImageWidth", "Ptr", crop, "UInt*", &cw)
    DllCall("gdiplus\GdipGetImageHeight", "Ptr", crop, "UInt*", &ch)
    scale := Min(380 / cw, 150 / ch, 1)
    tw := Max(1, Round(cw * scale))
    th := Max(1, Round(ch * scale))
    thumb := 0
    DllCall("gdiplus\GdipCreateBitmapFromScan0", "Int", tw, "Int", th, "Int", 0, "Int", 0x26200A, "Ptr", 0, "Ptr*", &thumb)
    tg := 0
    DllCall("gdiplus\GdipGetImageGraphicsContext", "Ptr", thumb, "Ptr*", &tg)
    DllCall("gdiplus\GdipSetInterpolationMode", "Ptr", tg, "Int", 7)
    DllCall("gdiplus\GdipDrawImageRectI", "Ptr", tg, "Ptr", crop, "Int", 0, "Int", 0, "Int", tw, "Int", th)
    DllCall("gdiplus\GdipDeleteGraphics", "Ptr", tg)
    hb := 0
    DllCall("gdiplus\GdipCreateHBITMAPFromBitmap", "Ptr", thumb, "Ptr*", &hb, "UInt", 0xFFF0F0F0)
    DllCall("gdiplus\GdipDisposeImage", "Ptr", thumb)

    g := Gui("+AlwaysOnTop", "Circle to Search")
    g.SetFont("s11", "Segoe UI")
    g.MarginX := 14
    g.MarginY := 12
    g.Add("Picture", "w" tw " h" th " +Border", "HBITMAP:" hb)
    g.Add("Text", "xm w380", (text = "") ? "No text found. Type what to search for, or search by image." : "Text found (you can fix it):")
    ed := g.Add("Edit", "xm w380 r4", text)
    g.Add("Button", "xm w185 h36", "Search Google").OnEvent("Click", CsPSearch)
    g.Add("Button", "x+10 yp w185 h36", "Translate").OnEvent("Click", CsPTranslate)
    g.Add("Button", "xm w185 h36", "Copy text").OnEvent("Click", CsPCopyText)
    g.Add("Button", "x+10 yp w185 h36", "Copy image").OnEvent("Click", CsPCopyImage)
    g.Add("Button", "xm w185 h36", "Image search").OnEvent("Click", CsPLens)
    g.Add("Button", "x+10 yp w185 h36", "Save image").OnEvent("Click", CsPSave)
    g.Add("Button", "xm w380 h36", "Close").OnEvent("Click", CsPClose)
    g.OnEvent("Close", CsPClose)
    g.OnEvent("Escape", CsPClose)
    csPanel := {gui: g, edit: ed, crop: crop, hb: hb}
    x := Max(csL + 10, Min(rx + rw + 20, csL + csW - 430))
    y := Max(csT + 10, Min(ry, csT + csH - (th + 390)))
    g.Show("AutoSize x" x " y" y)
    ed.Focus()
}

CsPClose(*) {
    global csPanel
    if !IsObject(csPanel)
        return
    DllCall("DeleteObject", "Ptr", csPanel.hb)
    DllCall("gdiplus\GdipDisposeImage", "Ptr", csPanel.crop)
    csPanel.gui.Destroy()
    csPanel := 0
}

CsPSearch(*) {
    t := Trim(csPanel.edit.Value)
    if (t = "") {
        Notify("Type something to search for first", 1500)
        return
    }
    Run("https://www.google.com/search?q=" UrlEncode(SubStr(t, 1, 400)))
    CsPClose()
}

CsPTranslate(*) {
    t := Trim(csPanel.edit.Value)
    if (t = "") {
        Notify("Type something to translate first", 1500)
        return
    }
    Run("https://translate.google.com/?sl=auto&op=translate&text=" UrlEncode(SubStr(t, 1, 400)))
    CsPClose()
}

CsPCopyText(*) {
    t := Trim(csPanel.edit.Value)
    if (t = "")
        return
    A_Clipboard := t
    Notify("Text copied", 1200)
}

CsPCopyImage(*) {
    if ClipSetImage(csPanel.crop)
        Notify("Image copied", 1200)
}

CsPSave(*) {                                         ; saves the picture in your Pictures folder
    dir := EnvGet("USERPROFILE") "\Pictures"
    if !DirExist(dir)
        dir := A_Desktop
    path := dir "\CircleSearch_" FormatTime(, "yyyyMMdd_HHmmss") ".png"
    if SavePng(csPanel.crop, path) {
        Notify("Saved to " path, 4000)
        Run('explorer.exe /select,"' path '"')       ; shows the file, ready to upload to Google Lens
    } else {
        Notify("Could not save the image", 2000)
    }
}

CsPLens(*) {                                         ; image search: sends the picture to Google Lens by itself
    png := A_Temp "\mm_search.png"
    if !SavePng(csPanel.crop, png) {
        Notify("Could not prepare the image", 2000)
        return
    }
    iw := 0, ih := 0
    DllCall("gdiplus\GdipGetImageWidth", "Ptr", csPanel.crop, "UInt*", &iw)
    DllCall("gdiplus\GdipGetImageHeight", "Ptr", csPanel.crop, "UInt*", &ih)
    ClipSetImage(csPanel.crop)                       ; backup: Ctrl+V works if the automatic search ever fails
    html := LENS_HTML
    html := StrReplace(html, "__W__", iw)
    html := StrReplace(html, "__H__", ih)
    html := StrReplace(html, "__B64__", Base64Encode(FileRead(png, "RAW")))
    page := A_Temp "\mm_search.html"
    try FileDelete(page)
    FileAppend(html, page, "UTF-8")
    Run(page)
    CsPClose()
    Notify("Sending your picture to Google...", 3000)
}

; ================= CURSOR CUSTOMIZATION =================
HexInt(txt, def) {
    txt := RegExReplace(txt, "[^0-9A-Fa-f]")
    return (txt = "") ? def : Integer("0x" SubStr(txt, 1, 6))
}

IniInt(key, def, lo, hi) {
    try {
        v := Integer(IniRead(iniFile, "Cursor", key, String(def)))
    } catch {
        return def
    }
    return Max(lo, Min(hi, v))
}

GFillPoly(g, argb, pts, n) {
    b := 0
    DllCall("gdiplus\GdipCreateSolidFill", "UInt", argb, "Ptr*", &b)
    DllCall("gdiplus\GdipFillPolygon", "Ptr", g, "Ptr", b, "Ptr", pts, "Int", n, "Int", 0)
    DllCall("gdiplus\GdipDeleteBrush", "Ptr", b)
}

GFillRect(g, argb, x, y, w, h) {
    b := 0
    DllCall("gdiplus\GdipCreateSolidFill", "UInt", argb, "Ptr*", &b)
    DllCall("gdiplus\GdipFillRectangle", "Ptr", g, "Ptr", b, "Float", x, "Float", y, "Float", w, "Float", h)
    DllCall("gdiplus\GdipDeleteBrush", "Ptr", b)
}

; Draws the arrow cursor into a GDI+ bitmap (caller must dispose it)
BuildCursorBitmap(px, rgb1, rgb2, style, outline) {
    k := px / 32
    bmp := 0
    DllCall("gdiplus\GdipCreateBitmapFromScan0", "Int", px, "Int", px, "Int", 0, "Int", 0x26200A, "Ptr", 0, "Ptr*", &bmp)
    g := 0
    DllCall("gdiplus\GdipGetImageGraphicsContext", "Ptr", bmp, "Ptr*", &g)
    DllCall("gdiplus\GdipSetSmoothingMode", "Ptr", g, "Int", 4)

    arrow := [1,1, 1,24, 7,18, 12,29, 16,27, 11,17, 20,17]
    pts := Buffer(8 * 7, 0)
    Loop 7 {
        NumPut("Float", arrow[2 * A_Index - 1] * k, "Float", arrow[2 * A_Index] * k, pts, (A_Index - 1) * 8)
    }

    GFillPoly(g, 0xFF000000 | rgb1, pts, 7)
    if (style != 3) {                                ; second color on one half
        if (style = 1)
            DllCall("gdiplus\GdipSetClipRect", "Ptr", g, "Float", 10.5 * k, "Float", 0, "Float", px, "Float", px, "Int", 0)
        else
            DllCall("gdiplus\GdipSetClipRect", "Ptr", g, "Float", 0, "Float", 15 * k, "Float", px, "Float", px, "Int", 0)
        GFillPoly(g, 0xFF000000 | rgb2, pts, 7)
        DllCall("gdiplus\GdipResetClip", "Ptr", g)
    }
    if (outline != 3) {
        pen := 0
        DllCall("gdiplus\GdipCreatePen1", "UInt", (outline = 1) ? 0xFF000000 : 0xFFFFFFFF, "Float", 1.2 * k, "Int", 2, "Ptr*", &pen)
        DllCall("gdiplus\GdipSetPenLineJoin", "Ptr", pen, "Int", 2)
        DllCall("gdiplus\GdipDrawPolygon", "Ptr", g, "Ptr", pen, "Ptr", pts, "Int", 7)
        DllCall("gdiplus\GdipDeletePen", "Ptr", pen)
    }
    DllCall("gdiplus\GdipDeleteGraphics", "Ptr", g)
    return bmp
}

; Turns the drawing into a real Windows cursor (with the tip as the click point)
MakeCursorHandle(rgb1, rgb2, size, style, outline) {
    px := [32, 48, 64, 96][size]
    bmp := BuildCursorBitmap(px, rgb1, rgb2, style, outline)
    hIcon := 0
    DllCall("gdiplus\GdipCreateHICONFromBitmap", "Ptr", bmp, "Ptr*", &hIcon)
    DllCall("gdiplus\GdipDisposeImage", "Ptr", bmp)
    if !hIcon
        return 0
    ii := Buffer(40, 0)
    DllCall("GetIconInfo", "Ptr", hIcon, "Ptr", ii)
    k := Round(px / 32)
    NumPut("UInt", 0, ii, 0)                         ; fIcon = false -> it is a cursor
    NumPut("UInt", k, ii, 4)                         ; hotspot x (the arrow tip)
    NumPut("UInt", k, ii, 8)                         ; hotspot y
    hCur := DllCall("CreateIconIndirect", "Ptr", ii, "Ptr")
    offMask := (A_PtrSize = 8) ? 16 : 12
    DllCall("DeleteObject", "Ptr", NumGet(ii, offMask, "Ptr"))
    DllCall("DeleteObject", "Ptr", NumGet(ii, offMask + A_PtrSize, "Ptr"))
    DllCall("DestroyIcon", "Ptr", hIcon)
    return hCur
}

; Windows color dialog. Returns 0xRRGGBB, or -1 if cancelled.
PickColor(initRGB) {
    static cust := Buffer(64, 0)
    o := A_PtrSize
    cc := Buffer(9 * o, 0)
    NumPut("UInt", 9 * o, cc, 0)
    NumPut("Ptr", cg.gui.Hwnd, cc, o)
    NumPut("UInt", ((initRGB & 0xFF) << 16) | (initRGB & 0xFF00) | (initRGB >> 16), cc, 3 * o)
    NumPut("Ptr", cust.Ptr, cc, 4 * o)
    NumPut("UInt", 3, cc, 5 * o)                     ; CC_RGBINIT | CC_FULLOPEN
    if !DllCall("comdlg32\ChooseColorW", "Ptr", cc, "Int")
        return -1
    r := NumGet(cc, 3 * o, "UInt")
    return ((r & 0xFF) << 16) | (r & 0xFF00) | (r >> 16)
}

ShowCursorGui(*) {
    global cg
    if IsObject(cg) {
        cg.gui.Show()
        return
    }
    g := Gui("+AlwaysOnTop", "Mouse Mode settings")
    g.SetFont("s11", "Segoe UI")
    g.OnEvent("Close", CgClose)
    g.OnEvent("Escape", CgClose)
    cg := {gui: g, c1: cur1, c2: cur2, size: curSize, style: curStyle, ol: curOutline, hbm: 0}

    names := []
    pick := presets.Length
    for i, p in presets {
        names.Push(p.n)
        if (i < presets.Length && p.a = cur1 && p.b = cur2 && p.st = curStyle && p.ol = curOutline)
            pick := i
    }
    g.Add("Text", "x20 y18 w320", "Preset")
    cg.ddPreset := g.Add("DropDownList", "x20 y44 w320 Choose" pick, names)
    cg.ddPreset.OnEvent("Change", CgPreset)

    g.Add("Text", "x20 y95 w320", "Color 1  (left / top)")
    cg.chip1 := g.Add("Text", "x20 y121 w70 h32 +Border Background" Format("{:06X}", cur1))
    g.Add("Button", "x105 y121 w130 h32", "Pick color...").OnEvent("Click", CgPick1)

    g.Add("Text", "x20 y168 w320", "Color 2  (right / bottom)")
    cg.chip2 := g.Add("Text", "x20 y194 w70 h32 +Border Background" Format("{:06X}", cur2))
    g.Add("Button", "x105 y194 w130 h32", "Pick color...").OnEvent("Click", CgPick2)

    g.Add("Text", "x20 y243 w320", "Style")
    cg.ddStyle := g.Add("DropDownList", "x20 y269 w320 Choose" curStyle, ["Split: left | right", "Split: top | bottom", "One solid color"])
    cg.ddStyle.OnEvent("Change", CgStyle)

    g.Add("Text", "x20 y318 w320", "Size")
    cg.ddSize := g.Add("DropDownList", "x20 y344 w320 Choose" curSize, ["Small", "Medium", "Large", "Extra large"])
    cg.ddSize.OnEvent("Change", CgSize)

    g.Add("Text", "x20 y393 w320", "Outline")
    cg.ddOutline := g.Add("DropDownList", "x20 y419 w320 Choose" curOutline, ["Black", "White", "None"])
    cg.ddOutline.OnEvent("Change", CgOutline)

    g.Add("Text", "x370 y18 w170", "Preview")
    cg.pic := g.Add("Picture", "x370 y44 w160 h160 +Border")
    g.Add("Text", "x370 y212 w170 h40 cGray", "Shown on a light and a dark background")

    cg.chk := g.Add("Checkbox", "x20 y470 w520 h28" (colorCursor ? " Checked" : ""), "Use my custom cursor while Mouse Mode is on")
    g.Add("Button", "x20 y516 w110 h38 Default", "Apply").OnEvent("Click", CgApply)
    g.Add("Button", "x140 y516 w130 h38", "Try it (4 s)").OnEvent("Click", CgTry)
    g.Add("Button", "x280 y516 w110 h38", "Reset").OnEvent("Click", CgReset)
    g.Add("Button", "x400 y516 w110 h38", "Cancel").OnEvent("Click", CgClose)

    CgRefresh()
    g.Show("w560 h580")
}

CgRefresh() {
    cg.chip1.Opt("Background" Format("{:06X}", cg.c1))
    cg.chip1.Redraw()
    cg.chip2.Opt("Background" Format("{:06X}", cg.c2))
    cg.chip2.Redraw()

    px := [32, 48, 64, 96][cg.size]
    cur := BuildCursorBitmap(px, cg.c1, cg.c2, cg.style, cg.ol)
    canvas := 0
    DllCall("gdiplus\GdipCreateBitmapFromScan0", "Int", 160, "Int", 160, "Int", 0, "Int", 0x26200A, "Ptr", 0, "Ptr*", &canvas)
    g := 0
    DllCall("gdiplus\GdipGetImageGraphicsContext", "Ptr", canvas, "Ptr*", &g)
    DllCall("gdiplus\GdipSetSmoothingMode", "Ptr", g, "Int", 4)
    GFillRect(g, 0xFFF4F4F4, 0, 0, 80, 160)          ; light half
    GFillRect(g, 0xFF2B2B2B, 80, 0, 80, 160)         ; dark half
    DllCall("gdiplus\GdipDrawImageI", "Ptr", g, "Ptr", cur, "Int", 80 - px // 2, "Int", 80 - px // 2)
    hbm := 0
    DllCall("gdiplus\GdipCreateHBITMAPFromBitmap", "Ptr", canvas, "Ptr*", &hbm, "UInt", 0xFFFFFFFF)
    cg.pic.Value := "HBITMAP:" hbm
    if cg.hbm
        DllCall("DeleteObject", "Ptr", cg.hbm)
    cg.hbm := hbm
    DllCall("gdiplus\GdipDeleteGraphics", "Ptr", g)
    DllCall("gdiplus\GdipDisposeImage", "Ptr", canvas)
    DllCall("gdiplus\GdipDisposeImage", "Ptr", cur)
}

CgMarkCustom() {
    cg.ddPreset.Choose(presets.Length)
}

CgPreset(ctrl, *) {
    i := ctrl.Value
    if (i >= 1 && i < presets.Length) {
        p := presets[i]
        cg.c1 := p.a
        cg.c2 := p.b
        cg.style := p.st
        cg.ol := p.ol
        cg.ddStyle.Choose(p.st)
        cg.ddOutline.Choose(p.ol)
    }
    CgRefresh()
}

CgStyle(ctrl, *) {
    cg.style := ctrl.Value
    CgMarkCustom()
    CgRefresh()
}

CgSize(ctrl, *) {
    cg.size := ctrl.Value
    CgRefresh()
}

CgOutline(ctrl, *) {
    cg.ol := ctrl.Value
    CgMarkCustom()
    CgRefresh()
}

CgPick1(*) {
    c := PickColor(cg.c1)
    if (c >= 0) {
        cg.c1 := c
        CgMarkCustom()
        CgRefresh()
    }
}

CgPick2(*) {
    c := PickColor(cg.c2)
    if (c >= 0) {
        cg.c2 := c
        CgMarkCustom()
        CgRefresh()
    }
}

CgReset(*) {
    p := presets[1]
    cg.c1 := p.a
    cg.c2 := p.b
    cg.style := p.st
    cg.ol := p.ol
    cg.size := 1
    cg.ddPreset.Choose(1)
    cg.ddStyle.Choose(cg.style)
    cg.ddOutline.Choose(cg.ol)
    cg.ddSize.Choose(1)
    CgRefresh()
}

CgTry(*) {                                           ; shows the cursor for 4 seconds
    h := MakeCursorHandle(cg.c1, cg.c2, cg.size, cg.style, cg.ol)
    if !h
        return
    DllCall("SetSystemCursor", "Ptr", h, "Int", 32512)
    SetTimer(CgTryEnd, -4000)
}

CgTryEnd() {
    RestoreCursor()
    if (modeOn && colorCursor)
        SetCursor()
}

CgApply(*) {
    global cur1, cur2, curSize, curStyle, curOutline, colorCursor
    cur1 := cg.c1
    cur2 := cg.c2
    curSize := cg.size
    curStyle := cg.style
    curOutline := cg.ol
    colorCursor := cg.chk.Value ? true : false
    IniWrite(Format("{:06X}", cur1), iniFile, "Cursor", "color1")
    IniWrite(Format("{:06X}", cur2), iniFile, "Cursor", "color2")
    IniWrite(curSize, iniFile, "Cursor", "size")
    IniWrite(curStyle, iniFile, "Cursor", "style")
    IniWrite(curOutline, iniFile, "Cursor", "outline")
    IniWrite(colorCursor ? "1" : "0", iniFile, "General", "colorCursor")
    if modeOn {                                      ; update the live cursor right away
        RestoreCursor()
        if colorCursor
            SetCursor()
    }
    CgClose()
    Notify("Cursor saved", 1200)
}

CgClose(*) {
    global cg
    if !IsObject(cg)
        return
    if cg.hbm
        DllCall("DeleteObject", "Ptr", cg.hbm)
    cg.gui.Destroy()
    cg := 0
}

; ---------- start with Windows ----------
StartupOn() {
    try {
        RegRead(StartupKey, "MouseMode")
        return true
    } catch {
        return false
    }
}

ToggleStartup(*) {
    if StartupOn() {
        RegDelete(StartupKey, "MouseMode")
        Notify("Will NOT start with Windows", 1500)
    } else {
        cmd := A_IsCompiled ? '"' A_ScriptFullPath '"' : '"' A_AhkPath '" "' A_ScriptFullPath '"'
        RegWrite(cmd, "REG_SZ", StartupKey, "MouseMode")
        Notify("Will start with Windows", 1500)
    }
    RebuildTray()
}

; ---------- your shortcuts ----------
MakeRunner(i) {
    return (*) => RunCustom(i)
}
MakeRemover(i) {
    return (*) => RemoveCustom(i)
}

CustomLabel(c) {
    if (c.name != "")
        return c.name
    if RegExMatch(c.target, "i)^https?://")
        return "Website"
    SplitPath(c.target, &fn, , , &noext)
    return (noext != "") ? noext : fn
}

LoadIcon(c) {
    if c.bmp {
        DllCall("gdiplus\GdipDisposeImage", "Ptr", c.bmp)
        c.bmp := 0
    }
    shfi := Buffer(696, 0)
    DllCall("shell32\SHGetFileInfoW", "WStr", c.target, "UInt", 0, "Ptr", shfi, "UInt", 696, "UInt", 0x100, "Ptr")
    hIcon := NumGet(shfi, 0, "Ptr")
    if hIcon {
        bmp := 0
        DllCall("gdiplus\GdipCreateBitmapFromHICON", "Ptr", hIcon, "Ptr*", &bmp)
        DllCall("DestroyIcon", "Ptr", hIcon)
        c.bmp := bmp
    }
}

; Built-in options first, then your shortcuts, then ONE "Add app" slot while there is room (max 3 shortcuts)
BuildItems() {
    global radAll
    all := [
        {name: "Keyboard",   icon: Chr(0xE765), act: (*) => ToggleKeyboard()},    ; our own swipe keyboard
        {name: "Voice",      icon: Chr(0xE720), act: (*) => Send("#h")},         ; Windows voice typing (press again to stop)
        {name: "Settings",   icon: Chr(0xE713), act: (*) => ShowCursorGui()},    ; opens the customize window
        {name: "OFF",        icon: Chr(0xE7E8), act: (*) => ToggleMode()},
        {name: "Switch",     icon: Chr(0xE7C4), act: (*) => Send("^!{Tab}")},    ; app switcher that stays open: click a window
        {name: "Clipboard",  icon: Chr(0xE77F), act: (*) => ToggleClipboard()},  ; history of things you copied
        {name: "Circle",     icon: Chr(0xE721), act: (*) => CircleStart()}        ; circle to search (first slice of page 2)
    ]
    for i, c in customs {
        all.Push({name: CustomLabel(c), icon: Chr(0xE71D), bmp: c.bmp, ci: i, act: MakeRunner(i)})
    }
    if (customs.Length < MAX_CUSTOM)
        all.Push({name: "Add app", icon: Chr(0xE710), bmp: 0, act: (*) => AddCustom()})
    radAll := all
    ApplyPage()
}

; 6 slices per page. Page 1 = the everyday tools, page 2 = Circle + your own shortcuts.
ApplyPage() {
    global radItems, radPage, radPages
    per := 6
    radPages := Ceil(radAll.Length / per)
    radPage := Max(1, Min(radPage, radPages))
    items := []
    Loop per {
        i := (radPage - 1) * per + A_Index
        if (i <= radAll.Length)
            items.Push(radAll[i])
    }
    radItems := items
}

FlipPage() {
    global radPage, radSel, radX, radLastTick
    radPage := Mod(radPage, radPages) + 1
    radLastTick := A_TickCount
    ApplyPage()
    radSel := 0
    radX := 0
    DrawRadial()
    PresentRadial()
}

SaveCustoms() {
    IniWrite("", iniFile, "Custom", "target")          ; clear the old single-shortcut key
    IniWrite("", iniFile, "Custom", "name")
    Loop MAX_CUSTOM {
        i := A_Index
        IniWrite((i <= customs.Length) ? customs[i].target : "", iniFile, "Custom", "target" i)
        IniWrite((i <= customs.Length) ? customs[i].name : "", iniFile, "Custom", "name" i)
    }
}

AddCustom() {
    if (customs.Length >= MAX_CUSTOM)
        return
    f := FileSelect(3, , "Choose an app or file to add to your menu")
    if (f = "")
        return
    c := {target: f, name: "", bmp: 0}
    LoadIcon(c)
    customs.Push(c)
    SaveCustoms()
    BuildItems()
    RebuildTray()
    Notify("Added: " CustomLabel(c), 1200)
}

RunCustom(i) {
    try Run(customs[i].target)
    catch
        MsgBox("Could not open:`n" customs[i].target "`n`nRemove it from the tray menu and add it again.")
}

ConfirmRemove(i) {
    if (i > customs.Length)
        return
    if (MsgBox('Remove "' CustomLabel(customs[i]) '" from your menu?', "Remove shortcut", 262180) = "Yes")
        RemoveCustom(i)
}

RemoveCustom(i) {
    c := customs[i]
    if c.bmp
        DllCall("gdiplus\GdipDisposeImage", "Ptr", c.bmp)
    customs.RemoveAt(i)
    SaveCustoms()
    BuildItems()
    RebuildTray()
    Notify("Removed", 1000)
}

; ---------- radial menu: open / update / close ----------
OpenRadial() {
    global radOpen, radSel, radX, radCX, radCY, radPage, radLastTick
    radPage := 1
    ApplyPage()
    radLastTick := A_TickCount
    MouseGetPos(&radCX, &radCY)                      ; menu is centered exactly on the cursor
    radSel := 0
    radX := 0
    radGui.Show("NoActivate x" (radCX - radW // 2) " y" (radCY - radW // 2) " w" radW " h" radW)
    DrawRadial()
    PresentRadial()
    radOpen := true
    SetTimer(RadialTick, 20)
}

RadialTick() {
    global radSel, radX
    MouseGetPos(&mx, &my)
    dx := mx - radCX
    dy := my - radCY
    dist := Sqrt(dx * dx + dy * dy)
    n := radItems.Length
    sel := 0
    if (dist > 40 * radS && dist < 150 * radS) {     ; center = cancel, far outside = cancel
        ang := DllCall("msvcrt\atan2", "Double", dx, "Double", -dy, "Cdecl Double") * 180 / 3.141592653589793
        if (ang < 0)
            ang += 360
        sel := Mod(Floor((ang + 180 / n) / (360 / n)), n) + 1
    }
    hx := 0                                          ; is the cursor on a little x badge?
    for i, item in radItems {
        if item.HasOwnProp("ci") {
            BadgeOffset(i, n, &ox, &oy)
            if (Sqrt((dx - ox) * (dx - ox) + (dy - oy) * (dy - oy)) <= 11 * radS) {
                hx := i
                break
            }
        }
    }
    if (sel != radSel || hx != radX) {
        radSel := sel
        radX := hx
        DrawRadial()
        PresentRadial()
    }
}

; where the little x badge sits (offset from the menu center) for slice i
BadgeOffset(i, n, &ox, &oy) {
    a := ((i - 1) * 360 / n + 0.33 * (360 / n)) * 3.141592653589793 / 180
    ox := 116 * radS * Sin(a)
    oy := -116 * radS * Cos(a)
}

CloseRadial() {
    global radOpen, radX
    radX := 0
    SetTimer(RadialTick, 0)
    radGui.Hide()
    radOpen := false
}

RadialSelect() {                                     ; called when right button is released
    chosen := radX ? 0 : radSel                      ; resting on a little x = don't launch anything
    CloseRadial()                                    ; menu always disappears
    if chosen
        SetTimer(radItems[chosen].act, -10)          ; ...and runs the option if one was highlighted
}

; ---------- radial menu: drawing ----------
DrawRadial() {
    S := radS
    c := radW / 2
    n := radItems.Length
    PI := 3.141592653589793
    many := (n >= 5)                                 ; 5-6 slices: slightly tighter text so nothing touches
    labelR := (n >= 9) ? 90 : (n >= 8) ? 88 : (n >= 7) ? 86 : many ? 84 : 80
    fontPx := (n >= 9) ? 10 : (n >= 8) ? 10.5 : (n >= 7) ? 11 : many ? 12 : 13
    glyphPx := (n >= 9) ? 22 : (n >= 8) ? 24 : many ? 26 : 28
    bmpPx := (n >= 9) ? 24 : (n >= 8) ? 26 : many ? 28 : 32
    DllCall("gdiplus\GdipGraphicsClear", "Ptr", radG, "UInt", 0)

    ; dark round backdrop with a soft edge
    GFillEllipse(0xE0101216, c - 140 * S, c - 140 * S, 280 * S, 280 * S)
    GDrawEllipse(0x40FFFFFF, 1.5 * S, c - 140 * S, c - 140 * S, 280 * S, 280 * S)

    ; one wedge per option
    for i, item in radItems {
        aMid := (i - 1) * 360 / n
        start := aMid - 90 - 180 / n + 1.6
        sweep := 360 / n - 3.2
        on := (i = radSel)
        GFillPie(on ? 0xFF2F7DF6 : 0xF02A2E38, c - 132 * S, c - 132 * S, 264 * S, 264 * S, start, sweep)
    }

    ; center cancel circle
    GFillEllipse(0xFF14161B, c - 40 * S, c - 40 * S, 80 * S, 80 * S)
    GDrawEllipse(0x50FFFFFF, 1.5 * S, c - 40 * S, c - 40 * S, 80 * S, 80 * S)
    if (radPages > 1) {                              ; X on top, page number below (scroll to flip)
        GText(Chr(0xE711), "Segoe MDL2 Assets", 16 * S, 0x90FFFFFF, c - 20 * S, c - 30 * S, 40 * S, 36 * S, 0)
        GText(radPage "/" radPages, "Segoe UI", 12 * S, 0xB0FFFFFF, c - 20 * S, c + 6 * S, 40 * S, 22 * S, 0)
    } else {
        GText(Chr(0xE711), "Segoe MDL2 Assets", 18 * S, 0x90FFFFFF, c - 20 * S, c - 20 * S, 40 * S, 40 * S, 0)
    }

    ; icons + labels
    for i, item in radItems {
        aMid := (i - 1) * 360 / n
        rad := aMid * PI / 180
        px := c + labelR * S * Sin(rad)
        py := c - labelR * S * Cos(rad)
        col := (i = radSel) ? 0xFFFFFFFF : 0xFFD5D9E2
        if (item.HasOwnProp("bmp") && item.bmp) {
            b := bmpPx
            DllCall("gdiplus\GdipDrawImageRectI", "Ptr", radG, "Ptr", item.bmp
                , "Int", Round(px - b * S / 2), "Int", Round(py - (16 + b / 2) * S), "Int", Round(b * S), "Int", Round(b * S))
        } else {
            GText(item.icon, "Segoe MDL2 Assets", glyphPx * S, col, px - 40 * S, py - 34 * S, 80 * S, 36 * S, 0)
        }
        label := (StrLen(item.name) > 10) ? SubStr(item.name, 1, 9) ".." : item.name
        GText(label, "Segoe UI", fontPx * S, col, px - 50 * S, py + 6 * S, 100 * S, 22 * S, 1)
        if item.HasOwnProp("ci") {                   ; little x to remove your own shortcut
            BadgeOffset(i, n, &ox, &oy)
            bx := c + ox
            by := c + oy
            GFillEllipse((i = radX) ? 0xFFE5484D : 0xFF3A3F4B, bx - 7 * S, by - 7 * S, 14 * S, 14 * S)
            GText(Chr(0xE711), "Segoe MDL2 Assets", 8 * S, 0xFFFFFFFF, bx - 8 * S, by - 8 * S, 16 * S, 16 * S, 0)
        }
    }
}

PresentRadial() {
    pt := Buffer(8, 0)
    NumPut("Int", radCX - radW // 2, "Int", radCY - radW // 2, pt)
    sz := Buffer(8, 0)
    NumPut("Int", radW, "Int", radW, sz)
    src := Buffer(8, 0)
    bf := Buffer(4, 0)
    NumPut("UChar", 0, "UChar", 0, "UChar", 255, "UChar", 1, bf)   ; per-pixel alpha
    DllCall("UpdateLayeredWindow", "Ptr", radGui.Hwnd, "Ptr", 0, "Ptr", pt, "Ptr", sz
        , "Ptr", radHDC, "Ptr", src, "UInt", 0, "Ptr", bf, "UInt", 2)
}

GFillPie(argb, x, y, w, h, start, sweep) {
    b := 0
    DllCall("gdiplus\GdipCreateSolidFill", "UInt", argb, "Ptr*", &b)
    DllCall("gdiplus\GdipFillPie", "Ptr", radG, "Ptr", b, "Float", x, "Float", y, "Float", w, "Float", h
        , "Float", start, "Float", sweep)
    DllCall("gdiplus\GdipDeleteBrush", "Ptr", b)
}

GFillEllipse(argb, x, y, w, h) {
    b := 0
    DllCall("gdiplus\GdipCreateSolidFill", "UInt", argb, "Ptr*", &b)
    DllCall("gdiplus\GdipFillEllipse", "Ptr", radG, "Ptr", b, "Float", x, "Float", y, "Float", w, "Float", h)
    DllCall("gdiplus\GdipDeleteBrush", "Ptr", b)
}

GDrawEllipse(argb, penW, x, y, w, h) {
    p := 0
    DllCall("gdiplus\GdipCreatePen1", "UInt", argb, "Float", penW, "Int", 2, "Ptr*", &p)
    DllCall("gdiplus\GdipDrawEllipse", "Ptr", radG, "Ptr", p, "Float", x, "Float", y, "Float", w, "Float", h)
    DllCall("gdiplus\GdipDeletePen", "Ptr", p)
}

GText(str, fontName, px, argb, x, y, w, h, bold, g := 0, align := 1) {
    if !g
        g := radG
    fam := 0, font := 0, fmt := 0, br := 0
    DllCall("gdiplus\GdipCreateFontFamilyFromName", "WStr", fontName, "Ptr", 0, "Ptr*", &fam)
    DllCall("gdiplus\GdipCreateFont", "Ptr", fam, "Float", px, "Int", bold, "Int", 2, "Ptr*", &font)
    DllCall("gdiplus\GdipCreateStringFormat", "Int", 0, "Int", 0, "Ptr*", &fmt)
    DllCall("gdiplus\GdipSetStringFormatAlign", "Ptr", fmt, "Int", align)   ; 1 = center, 0 = left
    DllCall("gdiplus\GdipSetStringFormatLineAlign", "Ptr", fmt, "Int", 1)   ; center vertically
    DllCall("gdiplus\GdipCreateSolidFill", "UInt", argb, "Ptr*", &br)
    rc := Buffer(16, 0)
    NumPut("Float", x, "Float", y, "Float", w, "Float", h, rc)
    DllCall("gdiplus\GdipDrawString", "Ptr", g, "WStr", str, "Int", -1, "Ptr", font, "Ptr", rc, "Ptr", fmt, "Ptr", br)
    DllCall("gdiplus\GdipDeleteBrush", "Ptr", br)
    DllCall("gdiplus\GdipDeleteStringFormat", "Ptr", fmt)
    DllCall("gdiplus\GdipDeleteFont", "Ptr", font)
    DllCall("gdiplus\GdipDeleteFontFamily", "Ptr", fam)
}

; ================= GESTURES (only when mode is ON) =================
; ---- while Circle to Search is on screen: right-click only cancels ----
#HotIf csActive
$RButton:: {
    KeyWait("RButton")
    CsCancel()
}
#HotIf

; ---- while the radial menu is open: left-click on a little x removes that shortcut ----
#HotIf radOpen
$LButton:: {
    if !radX
        return
    i := radItems[radX].ci
    KeyWait("LButton")
    CloseRadial()
    SetTimer(() => ConfirmRemove(i), -10)
}
#HotIf

#HotIf modeOn

; RIGHT BUTTON: quick = normal right click | hold = COPY | scroll while held = RADIAL MENU
$RButton:: {
    global scrolled
    scrolled := false
    if !KeyWait("RButton", "T" (holdMs / 1000)) {      ; still held after holdMs
        if !scrolled
            CopySelection()
        KeyWait("RButton")                              ; wait for release
        ToolTip()
    } else if !scrolled {
        Click("Right")                                  ; quick press = normal right click
    }
    if radOpen
        RadialSelect()      ; release over an option = run it | release in the center = just close
}

; LEFT + RIGHT together = SCREENSHOT
~LButton & RButton:: {
    global scrolled
    scrolled := true
    Send("#+s")
}

#HotIf

; wheel over the clipboard list = scroll it
#HotIf clipOpen && ClipMouseOver()
WheelUp:: ClipScrollBy(-1)
WheelDown:: ClipScrollBy(1)
#HotIf

; RIGHT held + scroll = open radial menu (under the cursor)
#HotIf modeOn && GetKeyState("RButton", "P")
WheelUp::
WheelDown:: {
    global scrolled
    scrolled := true
    if !radOpen
        OpenRadial()
    else if (radPages > 1 && A_TickCount - radLastTick > 350)
        FlipPage()                                   ; scroll again = other page of the circle
}
#HotIf
