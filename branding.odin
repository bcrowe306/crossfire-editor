package editor

import sdl "vendor:sdl3"
import img "vendor:sdl3/image"

/*
The editor's name and icon (assets/icons/, made by tools/icons/make_icons.sh).

- `Branding_SetAppMetadata`, before SDL starts: the app's name and identifier. The identifier is
  the window's app ID on Wayland and its class on X11, so Linux desktops match the window to the
  installed `.desktop` entry (and its icon).
- `Branding_SetWindowIcon`, from the view once the window exists: the window's icon (the taskbar
  on Linux and Windows; the Dock while running outside an app bundle on macOS), from the 256 px
  logo built into the executable.

Packages carry the icon too: compiled into the Windows executable (assets/icons/crossfire.rc),
the macOS bundle's .icns (tools/macos/bundle.sh), and the Linux archive's `.desktop` entry
(tools/linux/install-desktop-entry.sh).
*/

// The product's name
APP_NAME :: "Crossfire Editor"
// Its identifier: the macOS bundle ID, the Wayland app ID, the Linux .desktop file's name
APP_IDENTIFIER :: "io.github.bcrowe306.crossfire-editor"

// The window icon: the logo at 256 px
WINDOW_ICON :: #load("assets/icons/crossfire_256.png", []byte)

// Names the app to SDL (call before SDL starts)
Branding_SetAppMetadata :: proc() {
	_ = sdl.SetAppMetadata(APP_NAME, nil, APP_IDENTIFIER)
}

// Whether the window has its icon (set once)
@(private="file")
windowIconSet: bool

// Gives the editor's window its icon, once it has a window
Branding_SetWindowIcon :: proc() {
	if windowIconSet do return
	count: i32
	windows := sdl.GetWindows(&count)
	if windows == nil do return
	defer sdl.free(windows)
	if count == 0 do return
	windowIconSet = true
	surface := img.Load_IO(sdl.IOFromConstMem(raw_data(WINDOW_ICON), uint(len(WINDOW_ICON))), true)
	if surface == nil do return
	defer sdl.DestroySurface(surface)
	_ = sdl.SetWindowIcon(windows[0], surface)
}
