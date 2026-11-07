# Mouse Mode

A Windows accessibility tool that lets you do common tasks with **only the mouse**.
Turn it on with a hotkey, and a few button gestures plus a round pop-up menu replace
the keyboard shortcuts you'd normally need: copy, screenshot, typing by voice, switching apps, launching your own apps.

> **Status:** working prototype (v0.1.0), built with AutoHotkey v2. Windows 10/11 only.

![Mouse Mode demo](demo.gif)



## Why

Keyboard shortcuts are hard or impossible for some people (RSI, tremors, one-handed use,
limited mobility). Existing tools cover pieces of the problem (gesture tools, on-screen
keyboards, dwell clicking), but few combine them into one simple mouse-only setup.
This project is an attempt at that.

## Quick start

1. Go to the [**Releases**](../../releases) page and download `MouseMode-v0.1.0.zip`.
2. Unzip it and run `mousemode.exe`. **No installation and no AutoHotkey needed.**
3. Press `Ctrl+Alt+O` (or click the tray icon) to turn mouse mode on.
4. Right-click the tray icon and choose **Start with Windows** if you want it always available.

Keep the exe in one fixed folder (for example Documents). Your settings and shortcuts are saved next to it.

> **Windows may warn you** ("Windows protected your PC") because the program is unsigned: click **More info**, then **Run anyway**.
> Some antivirus tools flag programs that watch the mouse. It is a false positive, and the full source code is in this repository so you can check it.

**Prefer to run the script?** Install [AutoHotkey v2](https://www.autohotkey.com/), keep `mousemode.ahk`, `mousemode.cur` and `mousemode.ico` in the same folder, and double-click `mousemode.ahk`.

## How to use it

| Action | What happens |
|---|---|
| `Ctrl+Alt+O` or click the tray icon | Turn mouse mode on/off. The cursor turns half blue / half red while it's on. |
| **Hold right-click** | Copies the selection. "Copied" appears while you're still holding (only if something was really copied). |
| **Quick right-click** | Normal context menu (nothing that already works is replaced) |
| **Left + right click together** | Screenshot (Windows Snipping Tool) |
| **Hold right-click and scroll** | Opens the round menu under your cursor. Point at a slice and release to choose it. Release in the center to cancel. |

### The round menu

- **Keyboard**: opens the on-screen keyboard
- **Voice**: starts Windows voice typing (choose it again to stop)
- **Screenshot**
- **OFF**: turns mouse mode off
- **Switch**: opens the Windows app switcher (like Alt+Tab) that stays open so you can click a window
- **Your own shortcuts (up to 3)**: choose the **Add app** slice and pick any app or file. It shows the app's real icon. To remove one, point at the small **x** on its slice and left-click while holding right-click.

## Settings

`settings.ini` is created on first run. You can change the toggle hotkey, the hold time, and turn off the colored cursor.
Use **Reload** from the tray menu after editing. See `settings.example.ini`.

## Notes and limitations

- Windows 10/11 only.
- Voice typing uses Windows' built-in dictation (Win+H). It needs a microphone, an internet connection, and "Online speech recognition" turned on in Windows settings.
- While the mode is on, the system arrow cursor is replaced. It is restored when you turn the mode off or quit.
- The Keyboard slice opens the built-in Windows on-screen keyboard for now.
- Some apps that draw their own cursor (games) ignore the cursor color change.
- Apps running as administrator may ignore the gestures unless this program is also run as administrator.
- With all 3 shortcuts added, the menu has 8 slices and the labels are small.

## Roadmap

- [ ] Own on-screen keyboard with word suggestions
- [ ] Swipe typing (trace letters with the mouse)
- [ ] Paste / Undo slices
- [ ] Dwell click and drag lock
- [ ] Settings window and installer
- [ ] Testing with people who rely on assistive tech

## How it works (short)

AutoHotkey v2 handles the global mouse hooks. The round menu is drawn with GDI+ into a
per-pixel-transparent, click-through window that never takes focus, so shortcuts like copy
still go to the app you were using. Slices are picked by the angle and distance of the
cursor from the menu center.

## Credits

Built with [AutoHotkey](https://www.autohotkey.com/), an open-source project. The released `.exe` is the script compiled with AutoHotkey's own compiler (Ahk2Exe), so it contains the AutoHotkey runtime.

## License

MIT, see `LICENSE`.
