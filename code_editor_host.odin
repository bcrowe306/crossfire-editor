package editor

import "core:fmt"
import "core:hash"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:time"
import "gui:skald"
import sdl "vendor:sdl3"
import ttf "vendor:sdl3/ttf"
import stbi "vendor:stb/image"
import ce "code_editor/editor"
import km "code_editor/keymap"
import lspc "code_editor/lsp"

/*
The built-in code editor: `code_editor/` (an Odin code editor on SDL3, with Odin highlighting and
an OLS client) hosted in the center panel's tabs, one tab per open script (code_tabs.odin).

It draws with an SDL renderer and reads SDL events, while this editor draws with Skald on
Vulkan, so each open file gets:
- a `ce.Editor`, drawn by SDL's software renderer into a surface, uploaded as one Skald image
  (`CODE_IMAGE`) only when its pixels changed (like the viewport, viewport_preview.odin)
- the window's raw SDL events, collected by an event watch (`sdl.AddEventWatch`: it sees every
  event as SDL queues it, before Skald polls them, in order, key repeats included). Each frame
  `CodeEditor_View` passes them on: keys and text while the editor has keyboard focus, the mouse
  over it (in its own pixel coordinates), and the end of a drag that started in it

Keyboard focus is Skald's (`ctx.widgets.focused_id == CODE_EDITOR_ID`): a click in the editor
takes it, a click elsewhere drops it. Skald moves focus on Tab before the view is built, so
`CodeEditor_Frame` (at the top of `view`) gives it back when it was the code editor's: Tab
indents. While it has focus the editor's own shortcuts are off except `CODE_EDITOR_PASSTHROUGH`
(save, play, build, ...), whose chords the code editor doesn't get.

Package state, not `State`: it holds SDL resources and the editors' buffers (like the audio
preview).

**One language server for every tab:** the first OLS found (`Code_FindOLS`), rooted at the
project's scripts folder (its ols.json: the engine and project collections). A `ce.Editor` owns
its LSP client by value, so the client moves to the editor that shows (`takeServer`): the others
have it off (they get no input while hidden, so they have nothing to tell it). The server keeps
every document open (diagnostics are per document in the client); one that moves in sends its
whole text again, and opens its document again if the server restarted since. Closing a tab
closes its document on the server, and the last tab stops the server.

**Files changed on disk** (another program, git) are noticed about once a second while their tab
shows, and when it shows again: an unchanged buffer reloads (the caret stays on its line); one
with unsaved changes asks (`CodeEditor_DiskChange`, the code view's bar: Reload / Keep mine).

The code editor's own settings (its keymap and theme editors, the palette's "Color Theme")
persist in `code_editor/` next to editor.ini (`keymap.json`, `theme.json`); test scripts without
--settings keep none.
*/

// The Skald image the active code tab is drawn into, and the code view's widget id key
CODE_IMAGE :: "code-editor-render"
CODE_EDITOR_KEY :: "code-editor"
// The code font's size at 1x (it follows the display's pixel scale, and Ctrl +/- zooms it)
CODE_FONT_SIZE :: f32(14)
CODE_FONT :: #load("assets/fonts/LiberationMono-Regular.ttf", []byte)

// The editor's own actions that still work while the code editor has the keyboard
CODE_EDITOR_PASSTHROUGH :: bit_set[Action]{.Save_Project, .Play, .Play_Scene, .Pause, .Stop, .Build_Scripts, .Quit, .Toggle_Bottom_Panel, .Open_Settings, .Export}

// One open file
CodeEditor :: struct {
	// Absolute (owned)
	path: string,
	ed: ce.Editor,
	surface: ^sdl.Surface,
	renderer: ^sdl.Renderer,
	size: [2]int,
	// What it last rendered (FNV-64 of the pixels): an unchanged frame isn't uploaded
	pixelsHash: u64,
	// The file's modification time when it was last read or written, and the last look at it
	diskTime: time.Time,
	lastDiskCheck: time.Time,
	// It changed on disk while the buffer had unsaved changes: the bar asks
	diskChanged: bool,
	// The server process its document was opened in (0: none yet)
	openedIn: int,
}

// What a file did on disk since it was read (`CodeEditor_DiskChange`)
CodeDiskChange :: enum {
	None,
	// Reloaded: the buffer had no unsaved changes
	Reloaded,
	// The buffer has unsaved changes: ask
	Conflict,
}

@(private="file")
host: struct {
	editors: [dynamic]^CodeEditor,
	font: ^ttf.Font,
	fallbacks: ce.Fallback_Fonts,
	// The size the font is open at (pixels), and the zoom the code editor asked for (1x points)
	fontPixels: f32,
	zoom: f32,
	failed: bool,
	// The frame's input, collected by the event watch (watching: it's installed)
	watching: bool,
	events: [1024]sdl.Event,
	eventCount: int,
	// Which editor's pixels the image holds
	uploaded: ^CodeEditor,
	uploadedHash: u64,
	uploadedSize: [2]int,
	// The code editor had keyboard focus last frame (Tab gives it back)
	hadFocus: bool,
	// The editor holding the shared language server client (nil: none started)
	server: ^CodeEditor,
	// Language servers started (one per project's first file: tests check they're shared)
	serversStarted: int,
	// The editor shown last frame (a tab showing again looks at its file at once)
	lastShown: ^CodeEditor,
}

/*
Opens a file in a new code editor (or returns the one that has it).

Returns:
- The editor, and "" or why it couldn't be opened (temp allocated)
*/
CodeEditor_Open :: proc(path, scriptsDir: string, olsPath: string, configDir := "", lightTheme := false) -> (^CodeEditor, string) {
	if c := CodeEditor_Find(path); c != nil do return c, ""
	if !ensureHost() do return nil, "The code editor couldn't start (no font)"
	platform := km.Platform.Other
	when ODIN_OS == .Darwin do platform = .MacOS
	c := new(CodeEditor)
	c.path = strings.clone(path)
	c.ed = ce.editor_init(platform)
	// The tab shows the file name
	c.ed.show_header = false
	if !ce.editor_load_file(&c.ed, path) {
		ce.editor_destroy(&c.ed)
		delete(c.path)
		free(c)
		return nil, fmt.tprintf("Couldn't open %s", path)
	}
	applyFont(c)
	c.diskTime = modificationTime(path)
	// Its keymap and theme edits persist; a light editor gets the light preset until one is chosen
	if configDir != "" {
		if lightTheme && !os.exists(filepath.join({configDir, "theme.json"}, context.temp_allocator) or_else "") {
			ce.editor_set_theme(&c.ed, ce.ayu_light_theme())
		}
		ce.editor_set_config_dir(&c.ed, configDir)
	} else if lightTheme {
		ce.editor_set_theme(&c.ed, ce.ayu_light_theme())
	}
	// The first file starts the language server every tab shares
	if host.server == nil && olsPath != "" && scriptsDir != "" {
		if ce.editor_attach_lsp(&c.ed, []string{olsPath}, scriptsDir) {
			host.server = c
			host.serversStarted += 1
		} else {
			fmt.eprintln("code editor: couldn't start", olsPath)
		}
	}
	append(&host.editors, c)
	return c, ""
}

// The open editor of a file, or nil
CodeEditor_Find :: proc(path: string) -> ^CodeEditor {
	for c in host.editors do if c.path == path do return c
	return nil
}

// Closes a file's editor (unsaved changes are lost: ask first)
CodeEditor_Close :: proc(path: string) {
	for c, i in host.editors {
		if c.path != path do continue
		if host.uploaded == c do host.uploaded = nil
		if host.lastShown == c do host.lastShown = nil
		releaseServer(c)
		ce.editor_destroy(&c.ed)
		if c.renderer != nil do sdl.DestroyRenderer(c.renderer)
		if c.surface != nil do sdl.DestroySurface(c.surface)
		delete(c.path)
		free(c)
		ordered_remove(&host.editors, i)
		return
	}
}

// Closes every editor and the font (switching projects, quitting)
CodeEditor_CloseAll :: proc() {
	for len(host.editors) > 0 do CodeEditor_Close(host.editors[0].path)
}

// Whether a file's editor has unsaved changes
CodeEditor_IsDirty :: proc(path: string) -> bool {
	c := CodeEditor_Find(path)
	return c != nil && c.ed.buf.dirty
}

// Whether any open file has unsaved changes
CodeEditor_AnyDirty :: proc() -> bool {
	for c in host.editors do if c.ed.buf.dirty do return true
	return false
}

/*
Saves a file's editor.

Returns:
- "" or why it couldn't (temp allocated)
*/
CodeEditor_Save :: proc(path: string) -> string {
	c := CodeEditor_Find(path)
	if c == nil || !c.ed.buf.dirty do return ""
	if !ce.editor_save(&c.ed) do return fmt.tprintf("Couldn't save %s", filepath.base(path))
	// Our own write isn't a change on disk
	c.diskTime = modificationTime(path)
	c.diskChanged = false
	return ""
}

/*
Looks at a file on disk (throttled to once a second unless `now`): reloads the buffer when the
file changed and it has no unsaved changes, or flags the conflict for the code view's bar.
*/
CodeEditor_DiskChange :: proc(path: string, now := false) -> CodeDiskChange {
	c := CodeEditor_Find(path)
	if c == nil do return .None
	if !now && time.diff(c.lastDiskCheck, time.now()) < time.Second do return c.diskChanged ? .Conflict : .None
	c.lastDiskCheck = time.now()
	if c.diskChanged do return .Conflict
	onDisk := modificationTime(path)
	if onDisk == {} || onDisk == c.diskTime do return .None
	if c.ed.buf.dirty {
		c.diskChanged = true
		return .Conflict
	}
	reload(c)
	return .Reloaded
}

// The bar's answers: read the file again (dropping the changes), or keep the buffer (a save overwrites)
CodeEditor_ResolveDiskChange :: proc(path: string, reloadIt: bool) {
	c := CodeEditor_Find(path)
	if c == nil do return
	if reloadIt do reload(c)
	c.diskTime = modificationTime(path)
	c.diskChanged = false
}

// Whether the shown file changed on disk under unsaved changes (the bar shows)
CodeEditor_HasDiskConflict :: proc(path: string) -> bool {
	c := CodeEditor_Find(path)
	return c != nil && c.diskChanged
}

/*
Saves every open file with changes.

Returns:
- How many were saved, and the problems ("" if none; temp allocated)
*/
CodeEditor_SaveAll :: proc() -> (saved: int, problems: string) {
	b := strings.builder_make(context.temp_allocator)
	for c in host.editors {
		if !c.ed.buf.dirty do continue
		if message := CodeEditor_Save(c.path); message != "" {
			if strings.builder_len(b) > 0 do strings.write_string(&b, "; ")
			strings.write_string(&b, message)
		} else {
			saved += 1
		}
	}
	return saved, strings.to_string(b)
}

// The file's text (temp allocated; "" when it isn't open)
CodeEditor_Text :: proc(path: string) -> string {
	c := CodeEditor_Find(path)
	return c != nil ? ce.editor_to_string(&c.ed, context.temp_allocator) : ""
}

// Puts the caret on a 1-based line, scrolled into view
CodeEditor_GotoLine :: proc(path: string, line: int) {
	if c := CodeEditor_Find(path); c != nil && line > 0 do ce.editor_goto_lsp_position(&c.ed, line - 1, 0)
}

// Puts the caret at a language server position (0-based line and UTF-16 character)
CodeEditor_GotoPosition :: proc(path: string, line, character: int) {
	if c := CodeEditor_Find(path); c != nil do ce.editor_goto_lsp_position(&c.ed, line, character)
}

// The caret's line and column (1-based), for the status line and tests
CodeEditor_Caret :: proc(path: string) -> (line, column: int) {
	c := CodeEditor_Find(path)
	if c == nil do return 0, 0
	cursor := ce.editor_primary_cursor(&c.ed)
	return cursor.pos.line + 1, cursor.pos.col + 1
}

/*
How much of the last render isn't the background (pixels), and whether it's what the shown image
holds: tests check the code editor drew its text without reading the screen.
*/
CodeEditor_RenderStats :: proc(path: string) -> (inked: int, uploaded: bool) {
	c := CodeEditor_Find(path)
	if c == nil || c.surface == nil do return 0, false
	pixels := ([^]u8)(c.surface.pixels)[:c.size.x * c.size.y * 4]
	bg := c.ed.theme.background
	for i := 0; i + 3 < len(pixels); i += 4 {
		if pixels[i] != bg.r || pixels[i + 1] != bg.g || pixels[i + 2] != bg.b do inked += 1
	}
	return inked, host.uploaded == c && host.uploadedHash == c.pixelsHash
}

/*
Writes the file's last render (the code editor's own pixels, not the screen) to a PNG, for
looking at it. Returns "" or what went wrong.
*/
CodeEditor_SaveRender :: proc(path, png: string) -> string {
	c := CodeEditor_Find(path)
	if c == nil || c.surface == nil do return "not rendered"
	cpng := strings.clone_to_cstring(png, context.temp_allocator)
	if stbi.write_png(cpng, i32(c.size.x), i32(c.size.y), 4, c.surface.pixels, i32(c.size.x * 4)) == 0 do return "couldn't write it"
	return ""
}

// Whether the completion list shows, and how many items the server last sent (tests)
CodeEditor_CompletionVisible :: proc(path: string) -> (visible: bool, items: int) {
	c := CodeEditor_Find(path)
	if c == nil do return false, 0
	return ce.editor_completion_visible(&c.ed), len(c.ed.lsp.last_completion)
}

// How many language servers run now (0 or 1: every tab shares one), and how many were started
CodeEditor_Servers :: proc() -> (running, started: int) {
	for c in host.editors do if c.ed.lsp_enabled do running += 1
	return running, host.serversStarted
}

// The language server's status for the status line ("" when there's none)
CodeEditor_LspStatus :: proc(path: string) -> string {
	c := CodeEditor_Find(path)
	if c == nil || !c.ed.lsp_enabled do return ""
	return fmt.tprint(ce.editor_lsp_status(&c.ed))
}

/*
Called at the top of `view`, before anything registers shortcuts: gives keyboard focus back to the
code editor when Skald's Tab handling took it, and says whether it has the keyboard.
*/
CodeEditor_Frame :: proc(ctx: ^skald.Ctx(Msg), visible: bool) -> (focused: bool) {
	id := skald.hash_id(CODE_EDITOR_KEY)
	if !visible {
		host.hadFocus = false
		return false
	}
	if host.hadFocus && ctx.widgets.focused_id != id && .Tab in ctx.input.keys_pressed && !ctx.input.mouse_pressed[.Left] {
		skald.widget_focus(ctx, id)
	}
	focused = ctx.widgets.focused_id == id
	host.hadFocus = focused
	return
}

// Whether the code editor has the keyboard (since CodeEditor_Frame this frame)
CodeEditor_Focused :: proc(ctx: ^skald.Ctx(Msg)) -> bool {
	return ctx.widgets.focused_id == skald.hash_id(CODE_EDITOR_KEY)
}

/*
The code view for an open file: hands it this frame's input, renders it when something changed,
and returns the canvas showing it. Sends `Code_Open_Requested` when the file asks for another one
(Go to Definition), and keeps `Code_Tick` coming while a language server is attached.
*/
CodeEditor_View :: proc(s: ^State, ctx: ^skald.Ctx(Msg), path: string) -> skald.View {
	id := skald.hash_id(CODE_EDITOR_KEY)
	c := CodeEditor_Find(path)
	if c == nil {
		drainEvents()
		return skald.text(fmt.tprintf("%s isn't open", filepath.base(path)), ctx.theme.color.fg_muted, ctx.theme.font.size_sm)
	}
	rect := ctx.widgets.states[id].last_rect
	scale := ctx.renderer != nil ? max(ctx.renderer.scale, 1) : 1
	focused := ctx.widgets.focused_id == id
	popupOpen := len(ctx.widgets.overlay_rects_prev) > 0 || ctx.widgets.modal_rect_prev.w > 0
	mouse := ctx.input.mouse_pos
	over := rect.w > 0 && mouse.x >= rect.x && mouse.y >= rect.y && mouse.x < rect.x + rect.w && mouse.y < rect.y + rect.h && !popupOpen
	if ctx.input.mouse_pressed[.Left] && over && !focused {
		skald.widget_focus(ctx, id)
		focused = true
	}
	if focused do ctx.widgets.wants_text_input = true

	// The font follows the display's scale and the editor's zoom
	if size, ok := ce.editor_take_font_size_change(&c.ed); ok do host.zoom = size
	applyFont(c, scale)

	// This frame's input
	passthrough := passthroughChords(&s.settings.keymap)
	dragging := c.ed.mouse.drag != .None
	for i in 0 ..< host.eventCount {
		e := host.events[i]
		#partial switch e.type {
		case .KEY_DOWN, .KEY_UP:
			if !focused || isPassthrough(e.key, passthrough) do continue
			_ = ce.editor_handle_event(&c.ed, e)
		case .TEXT_INPUT, .TEXT_EDITING:
			if focused do _ = ce.editor_handle_event(&c.ed, e)
		case .MOUSE_MOTION:
			if !over && !dragging do continue
			e.motion.x = (e.motion.x - rect.x) * scale
			e.motion.y = (e.motion.y - rect.y) * scale
			_ = ce.editor_handle_event(&c.ed, e)
		case .MOUSE_BUTTON_DOWN, .MOUSE_BUTTON_UP:
			if e.type == .MOUSE_BUTTON_DOWN && !over do continue
			if e.type == .MOUSE_BUTTON_UP && !over && !dragging do continue
			e.button.x = (e.button.x - rect.x) * scale
			e.button.y = (e.button.y - rect.y) * scale
			_ = ce.editor_handle_event(&c.ed, e)
		case .MOUSE_WHEEL:
			if !over do continue
			e.wheel.mouse_x = (e.wheel.mouse_x - rect.x) * scale
			e.wheel.mouse_y = (e.wheel.mouse_y - rect.y) * scale
			_ = ce.editor_handle_event(&c.ed, e)
		}
	}
	drainEvents()
	// The shared language server follows the file that shows
	takeServer(c)
	ce.editor_update(&c.ed)
	if c.ed.lsp_enabled && c.ed.lsp_doc_open do c.openedIn = serverProcess(c)
	if other, line, character, ok := ce.editor_take_open_request(&c.ed); ok {
		skald.send(ctx, Msg(Code_Open_Requested{strings.clone(other, context.temp_allocator), line, character}))
	}
	// Language server replies arrive between inputs, and the file may change on disk
	if !s.codeTickPending && EditorFocused() do skald.send(ctx, Msg(Code_Tick_Requested{c.ed.lsp_enabled ? CODE_TICK_SECONDS : 1}))
	#partial switch CodeEditor_DiskChange(path, now = host.lastShown != c) {
	case .Reloaded: skald.send(ctx, Msg(Code_Reloaded{strings.clone(path, context.temp_allocator)}))
	}
	host.lastShown = c

	// Render when the size or anything shown changed; upload only changed pixels
	size := [2]int{int(rect.w * scale), int(rect.h * scale)}
	imageReady := false
	if ctx.renderer != nil && size.x > 0 && size.y > 0 && ensureSurface(c, size) {
		ce.editor_set_viewport(&c.ed, f32(size.x), f32(size.y))
		sdl.SetRenderDrawColor(c.renderer, 0, 0, 0, 255)
		sdl.RenderClear(c.renderer)
		ce.editor_render(&c.ed, c.renderer, host.font, 0, 0)
		sdl.FlushRenderer(c.renderer)
		pixels := ([^]u8)(c.surface.pixels)[:size.x * size.y * 4]
		c.pixelsHash = hash.fnv64a(pixels)
		if host.uploaded == c && host.uploadedHash == c.pixelsHash && host.uploadedSize == size {
			imageReady = true
		} else {
			if host.uploadedSize == size do imageReady = skald.image_update_pixels(ctx.renderer, CODE_IMAGE, u32(size.x), u32(size.y), pixels)
			if !imageReady {
				imageReady = skald.image_load_pixels(ctx.renderer, CODE_IMAGE, u32(size.x), u32(size.y), pixels)
				host.uploadedSize = size
			}
			host.uploaded = imageReady ? c : nil
			host.uploadedHash = c.pixelsHash
		}
	}

	Data :: struct { ready: bool, bg: skald.Color }
	theme := c.ed.theme.background
	data := new_clone(Data{imageReady, skald.rgba(u32(theme.r) << 24 | u32(theme.g) << 16 | u32(theme.b) << 8 | 0xff)}, context.temp_allocator)
	cursor := ce.editor_mouse_cursor(&c.ed) == .Text ? skald.Cursor_Shape.Text : skald.Cursor_Shape.Default
	return skald.canvas(ctx, data, proc(d: ^Data, p: skald.Canvas_Painter) {
		skald.draw_rect(p.r, p.bounds, d.bg)
		if d.ready do skald.draw_image(p.r, CODE_IMAGE, p.bounds, .Fill)
	}, id = id, cursor = cursor)
}

/*
The first OLS (Odin language server) found: the setting, then `ols` in PATH, then one built in
code_editor/third_party/ols (`task ols`), then Zed's Odin extension's. "" if there's none (the
editor works without completion and diagnostics).
*/
Code_FindOLS :: proc(setting: string) -> string {
	if setting != "" {
		found, ok := Script_FindEditorProgram(setting)
		return ok ? found : ""
	}
	if found, ok := Script_FindEditorProgram("ols"); ok do return found
	exeDir := filepath.dir(os.args[0])
	for candidate in ([]string{"code_editor/third_party/ols/ols", "../code_editor/third_party/ols/ols", "../../code_editor/third_party/ols/ols"}) {
		path := filepath.join({exeDir, candidate}, context.temp_allocator) or_continue
		if os.exists(path) do return path
	}
	if home, err := os.user_home_dir(context.temp_allocator); err == nil {
		zed := filepath.join({home, ".local/share/zed/extensions/work/odin"}, context.temp_allocator) or_else ""
		if handle, openErr := os.open(zed); openErr == nil {
			defer os.close(handle)
			entries, _ := os.read_dir(handle, -1, context.temp_allocator)
			for entry in entries {
				if !strings.has_prefix(entry.name, "ols") do continue
				binary := filepath.join({entry.fullpath, "ols-x86_64-unknown-linux-gnu"}, context.temp_allocator) or_continue
				if os.exists(binary) do return binary
			}
		}
	}
	return ""
}

// INTERNAL

// Moves the shared language server client into `c` (the editor that shows)
@(private="file")
takeServer :: proc(c: ^CodeEditor) {
	from := host.server
	if from == nil || from == c do return
	c.ed.lsp, from.ed.lsp = from.ed.lsp, {}
	c.ed.lsp_supervisor, from.ed.lsp_supervisor = from.ed.lsp_supervisor, {}
	c.ed.lsp_enabled, from.ed.lsp_enabled = from.ed.lsp_enabled, false
	host.server = c
	// Its document as it is now; opened again if the server isn't the one it was opened in
	c.ed.lsp_need_full = true
	if c.openedIn != serverProcess(c) do c.ed.lsp_doc_open = false
}

// Before an editor goes: its document closes on the server, and the client moves to another
// editor (the last one stops it, with the editor)
@(private="file")
releaseServer :: proc(c: ^CodeEditor) {
	if host.server == nil do return
	if host.server != c {
		if c.openedIn != 0 && c.openedIn == serverProcess(host.server) && len(c.ed.document_uri) > 0 && host.server.ed.lsp_enabled {
			lspc.client_did_close(&host.server.ed.lsp, c.ed.document_uri)
		}
		return
	}
	for other in host.editors {
		if other == c do continue
		if c.ed.lsp_enabled && c.ed.lsp_doc_open && len(c.ed.document_uri) > 0 do lspc.client_did_close(&c.ed.lsp, c.ed.document_uri)
		takeServer(other)
		return
	}
	host.server = nil
}

// The language server's process id as `c` sees it (0 when it has none)
@(private="file")
serverProcess :: proc(c: ^CodeEditor) -> int {
	return c.ed.lsp_enabled && c.ed.lsp.has_process ? c.ed.lsp.process.pid : 0
}

@(private="file")
modificationTime :: proc(path: string) -> time.Time {
	t, err := os.modification_time_by_path(path)
	return err == nil ? t : {}
}

// Reads the file again, keeping the caret's line and column (as near as the new text allows)
@(private="file")
reload :: proc(c: ^CodeEditor) {
	cursor := ce.editor_primary_cursor(&c.ed).pos
	// A hidden tab's document stays open on the server: it sends the new text when it shows
	wasOpen := c.ed.lsp_doc_open
	if !ce.editor_load_file(&c.ed, c.path) do return
	if !c.ed.lsp_enabled {
		c.ed.lsp_doc_open = wasOpen
		c.ed.lsp_need_full = true
	}
	ce.editor_goto_lsp_position(&c.ed, cursor.line, cursor.col)
	c.diskTime = modificationTime(c.path)
	c.diskChanged = false
}

@(private="file")
ensureHost :: proc() -> bool {
	if host.font != nil do return true
	if host.failed do return false
	if ttf.WasInit() == 0 && !ttf.Init() {
		host.failed = true
		return false
	}
	host.zoom = CODE_FONT_SIZE
	host.fontPixels = CODE_FONT_SIZE
	host.font = ttf.OpenFontIO(sdl.IOFromConstMem(raw_data(CODE_FONT), uint(len(CODE_FONT))), true, CODE_FONT_SIZE)
	if host.font == nil {
		host.failed = true
		return false
	}
	host.fallbacks = ce.font_add_system_fallbacks(host.font, CODE_FONT_SIZE)
	if !host.watching {
		host.watching = sdl.AddEventWatch(eventWatch, nil)
	}
	return true
}

// Sizes the font for the display scale and zoom, and tells the editor its cell size
@(private="file")
applyFont :: proc(c: ^CodeEditor, scale: f32 = 0) {
	if host.font == nil do return
	scale := scale > 0 ? scale : 1
	pixels := host.zoom * scale
	if pixels != host.fontPixels {
		host.fontPixels = pixels
		_ = ttf.SetFontSize(host.font, pixels)
		for fb in host.fallbacks.fonts do _ = ttf.SetFontSize(fb, pixels)
	}
	w, h: i32
	if ttf.GetStringSize(host.font, raw_data(string("M")), 1, &w, &h) {
		if c.ed.char_w != f32(w) || c.ed.char_h == 0 do ce.editor_set_font(&c.ed, f32(w), f32(h))
	}
	ce.editor_set_font_size(&c.ed, host.zoom)
}

@(private="file")
ensureSurface :: proc(c: ^CodeEditor, size: [2]int) -> bool {
	if c.surface != nil && c.size == size do return true
	if c.renderer != nil do sdl.DestroyRenderer(c.renderer)
	if c.surface != nil do sdl.DestroySurface(c.surface)
	c.renderer = nil
	c.surface = sdl.CreateSurface(i32(size.x), i32(size.y), .RGBA32)
	if c.surface != nil do c.renderer = sdl.CreateSoftwareRenderer(c.surface)
	if c.renderer == nil do return false
	// Packed rows: the upload takes the pixels as they are
	if int(c.surface.pitch) != size.x * 4 do return false
	c.size = size
	return true
}

// The SDL event watch: keeps the frame's keyboard, text and mouse events (the main thread pumps them)
@(private="file")
eventWatch :: proc "c" (userdata: rawptr, event: ^sdl.Event) -> bool {
	#partial switch event.type {
	case .KEY_DOWN, .KEY_UP, .TEXT_INPUT, .TEXT_EDITING, .MOUSE_MOTION, .MOUSE_BUTTON_DOWN, .MOUSE_BUTTON_UP, .MOUSE_WHEEL:
		if host.eventCount < len(host.events) {
			host.events[host.eventCount] = event^
			host.eventCount += 1
		}
	}
	return true
}

// Forgets the frame's events (after the code view took them, or when no code tab shows)
CodeEditor_DrainEvents :: proc() {
	drainEvents()
}

@(private="file")
drainEvents :: proc() {
	host.eventCount = 0
}

// The chords of the actions that pass through while the code editor has the keyboard
@(private="file")
passthroughChords :: proc(keymap: ^Keymap) -> []skald.Shortcut {
	list := make([dynamic]skald.Shortcut, context.temp_allocator)
	for chords, action in keymap {
		if action not_in CODE_EDITOR_PASSTHROUGH do continue
		for chord in chords do if chord != {} do append(&list, chord)
	}
	return list[:]
}

// Whether a key event is one of those chords (the editor handles it, not the code editor)
@(private="file")
isPassthrough :: proc(key: sdl.KeyboardEvent, chords: []skald.Shortcut) -> bool {
	for chord in chords {
		if k, ok := scancodeKey(key.scancode); !ok || k != chord.key do continue
		mods: skald.Modifiers
		if key.mod & sdl.KMOD_CTRL != {} do mods += {.Ctrl}
		if key.mod & sdl.KMOD_SHIFT != {} do mods += {.Shift}
		if key.mod & sdl.KMOD_ALT != {} do mods += {.Alt}
		if key.mod & sdl.KMOD_GUI != {} do mods += {.Super}
		if mods == chord.mods do return true
	}
	return false
}

// The Skald key of a scancode, for the keys editor shortcuts use (letters, digits, F-keys, punctuation)
@(private="file")
scancodeKey :: proc(code: sdl.Scancode) -> (skald.Key, bool) {
	c := int(code)
	switch {
	case c >= int(sdl.Scancode.A) && c <= int(sdl.Scancode.Z):
		return skald.Key(int(skald.Key.A) + c - int(sdl.Scancode.A)), true
	case c >= int(sdl.Scancode._1) && c <= int(sdl.Scancode._9):
		return skald.Key(int(skald.Key.N1) + c - int(sdl.Scancode._1)), true
	case code == ._0:
		return .N0, true
	case c >= int(sdl.Scancode.F1) && c <= int(sdl.Scancode.F12):
		return skald.Key(int(skald.Key.F1) + c - int(sdl.Scancode.F1)), true
	}
	#partial switch code {
	case .COMMA:     return .Comma, true
	case .PERIOD:    return .Period, true
	case .SLASH:     return .Slash, true
	case .MINUS:     return .Minus, true
	case .EQUALS:    return .Equals, true
	case .RETURN:    return .Enter, true
	case .ESCAPE:    return .Escape, true
	case .TAB:       return .Tab, true
	case .SPACE:     return .Space, true
	case .DELETE:    return .Delete, true
	}
	return .Escape, false
}
