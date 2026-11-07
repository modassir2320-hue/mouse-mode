#Requires AutoHotkey v2.0
#SingleInstance Force
;@Ahk2Exe-SetName Mouse Mode
;@Ahk2Exe-SetDescription Mouse-only accessibility tool
;@Ahk2Exe-SetVersion 0.1.0
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
if (!A_IsCompiled && FileExist(A_ScriptDir "\mousemode.ico"))
    TraySetIcon(A_ScriptDir "\mousemode.ico")
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
    saved := ClipboardAll()          ; remember what was on the clipboard
    A_Clipboard := ""                ; empty it so we can tell if the copy worked
    Send("^c")
    if ClipWait(0.3)
        ToolTip("Copied")
    else
        A_Clipboard := saved         ; nothing selected: put the old clipboard back
}

; ---------- tray menu ----------
RebuildTray() {
    A_TrayMenu.Delete()
    A_TrayMenu.Add("Turn mouse mode ON / OFF", ToggleMode)
    A_TrayMenu.Add()
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
    global radItems
    items := [
        {name: "Keyboard",   icon: Chr(0xE765), act: (*) => Run("osk.exe")},   ; placeholder until our own keyboard (Phase 3)
        {name: "Voice",      icon: Chr(0xE720), act: (*) => Send("#h")},        ; Windows voice typing (press again to stop)
        {name: "Screenshot", icon: Chr(0xE722), act: (*) => Send("#+s")},
        {name: "OFF",        icon: Chr(0xE7E8), act: (*) => ToggleMode()},
        {name: "Switch",     icon: Chr(0xE7C4), act: (*) => Send("^!{Tab}")}   ; app switcher that stays open: click a window
    ]
    for i, c in customs {
        items.Push({name: CustomLabel(c), icon: Chr(0xE71D), bmp: c.bmp, ci: i, act: MakeRunner(i)})
    }
    if (customs.Length < MAX_CUSTOM)
        items.Push({name: "Add app", icon: Chr(0xE710), bmp: 0, act: (*) => AddCustom()})
    radItems := items
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
    global radOpen, radSel, radX, radCX, radCY
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
    labelR := (n >= 8) ? 88 : (n >= 7) ? 86 : many ? 84 : 80
    fontPx := (n >= 8) ? 10.5 : (n >= 7) ? 11 : many ? 12 : 13
    glyphPx := (n >= 8) ? 24 : many ? 26 : 28
    bmpPx := (n >= 8) ? 26 : many ? 28 : 32
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
    GText(Chr(0xE711), "Segoe MDL2 Assets", 18 * S, 0x90FFFFFF, c - 20 * S, c - 20 * S, 40 * S, 40 * S, 0)

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

GText(str, fontName, px, argb, x, y, w, h, bold) {
    fam := 0, font := 0, fmt := 0, br := 0
    DllCall("gdiplus\GdipCreateFontFamilyFromName", "WStr", fontName, "Ptr", 0, "Ptr*", &fam)
    DllCall("gdiplus\GdipCreateFont", "Ptr", fam, "Float", px, "Int", bold, "Int", 2, "Ptr*", &font)
    DllCall("gdiplus\GdipCreateStringFormat", "Int", 0, "Int", 0, "Ptr*", &fmt)
    DllCall("gdiplus\GdipSetStringFormatAlign", "Ptr", fmt, "Int", 1)       ; center horizontally
    DllCall("gdiplus\GdipSetStringFormatLineAlign", "Ptr", fmt, "Int", 1)   ; center vertically
    DllCall("gdiplus\GdipCreateSolidFill", "UInt", argb, "Ptr*", &br)
    rc := Buffer(16, 0)
    NumPut("Float", x, "Float", y, "Float", w, "Float", h, rc)
    DllCall("gdiplus\GdipDrawString", "Ptr", radG, "WStr", str, "Int", -1, "Ptr", font, "Ptr", rc, "Ptr", fmt, "Ptr", br)
    DllCall("gdiplus\GdipDeleteBrush", "Ptr", br)
    DllCall("gdiplus\GdipDeleteStringFormat", "Ptr", fmt)
    DllCall("gdiplus\GdipDeleteFont", "Ptr", font)
    DllCall("gdiplus\GdipDeleteFontFamily", "Ptr", fam)
}

; ================= GESTURES (only when mode is ON) =================
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

; RIGHT held + scroll = open radial menu (under the cursor)
#HotIf modeOn && GetKeyState("RButton", "P")
WheelUp::
WheelDown:: {
    global scrolled
    scrolled := true
    if !radOpen
        OpenRadial()
}
#HotIf
