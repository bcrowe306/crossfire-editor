package crossfire_editor

import "core:fmt"
import "core:hash"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:time"
import "gui:skald"
import sdl "vendor:sdl3"
import ttf "vendor:sdl3/ttf"
import stbi "vendor:stb/image"
import ce "code_editor/editor"
import cebuf "code_editor/buffer"
import km "code_editor/keymap"
import lspc "code_editor/lsp"
import "code_editor/control"

/*
The built-in code editor: `code_editor/` (an Odin code editor on SDL3, with Odin highlighting and
an OLS client) hosted in the center panel's tabs, one tab per open script (code_tabs.odin).

It draws with an SDL renderer and reads SDL events, while this editor draws with Skald on
Vulkan, so each open file gets:
- a `ce.Editor`, drawn by the shared GPU renderer (gpu_share.odin: SDL's Vulkan renderer on
  Skald's device) straight into the Skald image the tab shows (`CODE_IMAGE`, `host.target`, one
  for whichever file shows); without it (unit tests, or a machine where it can't be made) by
  SDL's software renderer into a surface of its own, uploaded only when its pixels changed. Text
  goes through the code editor's glyph atlas (`ce.editor_forget_renderer` frees it with its
  renderer)
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
CODE_EDITOR_PASSTHROUGH :: bit_set[Action]{.Save_Project, .Play, .Play_Scene, .Pause, .Stop, .Restart, .Build_Scripts, .Quit, .Toggle_Bottom_Panel, .Open_Settings, .Export, .Close_Code_Tab}

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
	// The font size (pixels) its cell size was measured at
	cellsFor: f32,
	// What its last render showed (renderKey) and when: it's drawn again only when something
	// it shows may have changed (codeRenderKey, input, a server reply)
	renderKey: u64,
	renderedAt: time.Tick,
}

// The longest a shown code editor goes without being drawn again (anything the change checks miss)
CODE_RENDER_REFRESH :: 500 * time.Millisecond

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
	// The shared GPU renderer's target the shown file is drawn into (`CODE_IMAGE`), and whether
	// the image is it (else the software path's upload)
	target: GPUTarget,
	onGPU: bool,
	// Which editor's pixels the image holds
	uploaded: ^CodeEditor,
	uploadedHash: u64,
	uploadedSize: [2]int,
	// The code editor had keyboard focus last frame (Tab gives it back)
	hadFocus: bool,
	// Something was dropped on it: it takes the keyboard next frame (its menu's keys)
	focusNext: bool,
	// The editor holding the shared language server client (nil: none started)
	server: ^CodeEditor,
	// Language servers started (one per project's first file: tests check they're shared)
	serversStarted: int,
	// The editor shown last frame (a tab showing again looks at its file at once)
	lastShown: ^CodeEditor,
	// The scripts folder's .odin files and their modification times, as the language server was
	// last told (CodeEditor_WatchScripts; paths owned), the folder, and when it was last looked at
	watched: map[string]time.Time,
	watchedDir: string,
	lastWatch: time.Time,
	// Where the shown code view was last drawn (window coordinates) and the display's scale:
	// drops and the test driver turn window points into the editor's pixels with them
	shownRect: skald.Rect,
	shownScale: f32,
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
	// Odin is indented with tabs (odinfmt's style, and the engine's)
	c.ed.indent_with_tabs = strings.has_suffix(path, ".odin")
	// Its zoom (Ctrl +/-) starts from, and Ctrl+0 goes back to, the code font's size
	ce.editor_set_font_size(&c.ed, CODE_FONT_SIZE)
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
	// The project's completions, hovers, problems, markers, hints and drops (code_providers.odin)
	ce.editor_set_providers(&c.ed, CodeProviders_Registry())
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
		if c.renderer != nil {
			ce.editor_forget_renderer(c.renderer)
			sdl.DestroyRenderer(c.renderer)
		}
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

/*
Frees everything the code editor holds: the editors, their list and the font (the event watch
stays). Tests call it when they finish: each test has its own allocator, freed after it, so the
next one must not find this one's memory here.
*/
CodeEditor_Shutdown :: proc() {
	CodeEditor_CloseAll()
	delete(host.editors)
	host.editors = nil
	for path in host.watched do delete(path)
	delete(host.watched)
	host.watched = nil
	delete(host.watchedDir)
	host.watchedDir = ""
	if host.font != nil {
		ce.font_fallbacks_destroy(&host.fallbacks, host.font)
		ttf.CloseFont(host.font)
	}
	host.font = nil
	host.fallbacks = {}
	host.failed = false
	host.server = nil
	host.lastShown = nil
	host.uploaded = nil
	GPUTarget_Destroy(&host.target)
	host.onGPU = false
	host.serversStarted = 0
	CodeProviders_Shutdown()
	CodePreviews_Shutdown()
	CodeColors_Shutdown()
	CodeLive_Shutdown()
	LogPoints_Shutdown()
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

/*
Inserts text at the start of a 0-based line of an open file's buffer, as one undoable edit (not
typed: no auto-indent or bracket pairing), and tells its language server.

Returns:
- false when the file isn't open or the line is past its end
*/
CodeEditor_InsertAtLine :: proc(path: string, line: int, text: string) -> bool {
	return CodeEditor_InsertAt(path, line, 0, text)
}

// Inserts text at a 0-based line and byte column of an open file's buffer, like CodeEditor_InsertAtLine
CodeEditor_InsertAt :: proc(path: string, line, column: int, text: string) -> bool {
	c := CodeEditor_Find(path)
	if c == nil || line < 0 || line > cebuf.buffer_line_count(&c.ed.buf) do return false
	cebuf.buffer_insert_text(&c.ed.buf, {line = line, col = column}, text)
	ce.editor_notify_lsp_changed(&c.ed)
	return true
}

/*
Applies edits to an open file's buffer (positions in its text now; they mustn't overlap) as one
undo step, the caret kept where it was (moved with the edits), and tells its language server.

Returns:
- false when the file isn't open
*/
CodeEditor_ApplyEdits :: proc(path: string, edits: []ce.Text_Edit) -> bool {
	c := CodeEditor_Find(path)
	if c == nil do return false
	if len(edits) == 0 do return true
	ce.editor_apply_edits(&c.ed, edits, ce.editor_position_after_edits(c.ed.buf.cursors[0].pos, edits))
	return true
}

/*
Tells the language server about the scripts folder's .odin files that were created, changed or
deleted on disk since it was last told: OLS doesn't see a new file of the package (a New Script,
the regenerated assets.odin, a git pull, another editor's save) or a changed one's new symbols
until it is, so completion missed them. Files open in a code tab are left out: the server has
their text. Looks at most once a second; the first look (or a new folder) only records.

Inputs:
- dir: The project's scripts folder
*/
CodeEditor_WatchScripts :: proc(dir: string) {
	c := host.server
	if c == nil || !c.ed.lsp.initialized do return
	now := time.now()
	if time.diff(host.lastWatch, now) < time.Second do return
	host.lastWatch = now
	first := host.watchedDir != dir
	if first {
		delete(host.watchedDir)
		host.watchedDir = strings.clone(dir)
		for path in host.watched do delete(path)
		clear(&host.watched)
	}
	entries, err := os.read_all_directory_by_path(dir, context.temp_allocator)
	if err != nil do return
	changes := make([dynamic]lspc.FileEvent, context.temp_allocator)
	seen := make(map[string]bool, context.temp_allocator)
	uri :: proc(path: string) -> string { return lspc.file_uri(lspc.resolve_path(path, context.temp_allocator), context.temp_allocator) }
	for entry in entries {
		if entry.type == .Directory || !strings.has_suffix(entry.name, ".odin") do continue
		path := absolutePath(entry.fullpath)
		seen[path] = true
		known, had := host.watched[path]
		if had && known == entry.modification_time do continue
		if had {
			host.watched[path] = entry.modification_time
		} else {
			host.watched[strings.clone(path)] = entry.modification_time
		}
		if !first && CodeEditor_Find(path) == nil do append(&changes, lspc.FileEvent{uri(path), had ? 2 : 1})
	}
	gone := make([dynamic]string, context.temp_allocator)
	for path in host.watched do if path not_in seen do append(&gone, path)
	for path in gone {
		append(&changes, lspc.FileEvent{uri(path), 3})
		delete_key(&host.watched, path)
		delete(path)
	}
	lspc.client_did_change_watched_files(&c.ed.lsp, changes[:])
}

// Puts the caret on a 1-based line, scrolled into view
CodeEditor_GotoLine :: proc(path: string, line: int) {
	if c := CodeEditor_Find(path); c != nil && line > 0 do ce.editor_goto_lsp_position(&c.ed, line - 1, 0)
}

// Puts the caret at a language server position (0-based line and UTF-16 character)
CodeEditor_GotoPosition :: proc(path: string, line, character: int) {
	if c := CodeEditor_Find(path); c != nil do ce.editor_goto_lsp_position(&c.ed, line, character)
}

/*
Makes a file's editor read-only, or editable again: a read-only one takes no edits (typing,
pasting, the host's inserts), so it never has changes to save. Files outside the project opened
from an error or a definition (an engine source, Odin's core library) are.

Inputs:
- path: The open file
- readOnly: Refuse edits
*/
CodeEditor_SetReadOnly :: proc(path: string, readOnly: bool) {
	if c := CodeEditor_Find(path); c != nil do c.ed.buf.read_only = readOnly
}

// Whether a file's editor refuses edits (`CodeEditor_SetReadOnly`)
CodeEditor_IsReadOnly :: proc(path: string) -> bool {
	c := CodeEditor_Find(path)
	return c != nil && c.ed.buf.read_only
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
	if c == nil do return 0, false
	pixels := lastPixels(c)
	if pixels == nil do return 0, false
	bg := c.ed.theme.background
	for i := 0; i + 3 < len(pixels); i += 4 {
		if pixels[i] != bg.r || pixels[i + 1] != bg.g || pixels[i + 2] != bg.b do inked += 1
	}
	return inked, host.uploaded == c && (host.onGPU || host.uploadedHash == c.pixelsHash)
}

// Whether the shown code tab is drawn by the shared GPU renderer (tests)
CodeEditor_OnGPU :: proc() -> bool {
	return host.onGPU
}

// A file's last render (RGBA8, `c.size`): read back from the shared target when it's the one
// shown there, else its software surface; nil when there's none
@(private="file")
lastPixels :: proc(c: ^CodeEditor) -> []u8 {
	if host.onGPU {
		if host.uploaded != c do return nil
		return GPUTarget_ReadPixels(&host.target, c.size)
	}
	if c.surface == nil do return nil
	return ([^]u8)(c.surface.pixels)[:c.size.x * c.size.y * 4]
}

/*
Writes the file's last render (the code editor's own pixels, not the screen) to a PNG, for
looking at it. Returns "" or what went wrong.
*/
CodeEditor_SaveRender :: proc(path, png: string) -> string {
	c := CodeEditor_Find(path)
	if c == nil do return "not rendered"
	pixels := lastPixels(c)
	if pixels == nil do return "not rendered"
	cpng := strings.clone_to_cstring(png, context.temp_allocator)
	if stbi.write_png(cpng, i32(c.size.x), i32(c.size.y), 4, raw_data(pixels), i32(c.size.x * 4)) == 0 do return "couldn't write it"
	return ""
}

// Whether the completion list shows, and how many items the server last sent (tests)
CodeEditor_CompletionVisible :: proc(path: string) -> (visible: bool, items: int) {
	c := CodeEditor_Find(path)
	if c == nil do return false, 0
	return ce.editor_completion_visible(&c.ed), len(c.ed.lsp.last_completion)
}

// Whether the last completion list (the server's, or the shown one merged with the providers')
// has an item with that label (tests)
CodeEditor_CompletionHas :: proc(path, label: string) -> bool {
	c := CodeEditor_Find(path)
	if c == nil do return false
	for item in c.ed.lsp.last_completion do if item.label == label do return true
	for en in c.ed.completion.items do if en.item.label == label do return true
	return false
}

// Whether the shown completion list lists that item, from a provider (or folded into by one;
// tests): the project's items reach the code tab
CodeEditor_CompletionProvided :: proc(path, label: string) -> bool {
	c := CodeEditor_Find(path)
	if c == nil || !ce.editor_completion_visible(&c.ed) do return false
	for i in c.ed.completion.filtered do if c.ed.completion.items[i].item.label == label do return c.ed.completion.items[i].provided
	return false
}

// The hover the code tab shows, its lines joined ("" when none; temp allocated)
CodeEditor_HoverText :: proc(path: string) -> string {
	c := CodeEditor_Find(path)
	if c == nil do return ""
	_, lines, ok := ce.editor_hover_layout(&c.ed)
	if !ok do return ""
	b := strings.builder_make(context.temp_allocator)
	for l, i in lines {
		if i > 0 do strings.write_byte(&b, '\n')
		strings.write_string(&b, l.text)
	}
	return strings.to_string(b)
}

// How many pictures and widgets (a play button) the code tab's hover shows (tests)
CodeEditor_HoverBlocks :: proc(path: string) -> (images, widgets: int) {
	c := CodeEditor_Find(path)
	if c == nil do return
	if _, _, ok := ce.editor_hover_layout(&c.ed); !ok do return
	for b in ce.editor_hover_blocks(&c.ed) {
		#partial switch _ in b {
		case ce.Hover_Image:  images += 1
		case ce.Hover_Widget: widgets += 1
		}
	}
	return
}

/*
Where the hover's first widget is in the window (its middle, for the test driver's click), when
the code tab shows a hover with one that's in view.
*/
CodeEditor_HoverWidgetPoint :: proc(path: string) -> ([2]f32, bool) {
	c := CodeEditor_Find(path)
	if c == nil || host.lastShown != c || host.shownScale <= 0 do return {}, false
	rect, lines, ok := ce.editor_hover_layout(&c.ed)
	if !ok do return {}, false
	blocks := ce.editor_hover_blocks(&c.ed)
	// The hover's lines from its top (a widget fits a hover's height: it isn't scrolled into)
	for l, i in lines {
		if l.block <= 0 || l.block > len(blocks) || l.block_row != 0 do continue
		widget, is := blocks[l.block - 1].(ce.Hover_Widget)
		if !is do continue
		x := rect.x + ce.POPUP_PAD + widget.width * 0.5
		y := rect.y + ce.POPUP_PAD + f32(i) * c.ed.char_h + widget.height * 0.5
		if y > rect.y + rect.h do return {}, false
		return {host.shownRect.x + x / host.shownScale, host.shownRect.y + y / host.shownScale}, true
	}
	return {}, false
}

// Where a line's n-th color swatch is in the window (0-based line and n; the shown file only)
CodeEditor_SwatchPoint :: proc(path: string, line, n: int) -> ([2]f32, bool) {
	c := CodeEditor_Find(path)
	if c == nil || host.lastShown != c || host.shownScale <= 0 do return {}, false
	x, y, ok := ce.editor_inlay_swatch_point(&c.ed, line, n)
	if !ok do return {}, false
	return {host.shownRect.x + x / host.shownScale, host.shownRect.y + y / host.shownScale}, true
}

// Where a line's n-th clickable inlay hint's label is in the window (0-based line and n; the shown
// file only): a live hint's node menu
CodeEditor_InlayLabelPoint :: proc(path: string, line, n: int) -> ([2]f32, bool) {
	c := CodeEditor_Find(path)
	if c == nil || host.lastShown != c || host.shownScale <= 0 do return {}, false
	x, y, ok := ce.editor_inlay_label_point(&c.ed, line, n)
	if !ok do return {}, false
	return {host.shownRect.x + x / host.shownScale, host.shownRect.y + y / host.shownScale}, true
}

/*
The lines a code tab shows: its first (0-based) and how many (code_live.odin asks the game for the
fields there).

Returns:
- The first line and the count, and false when the file isn't open
*/
CodeEditor_VisibleLines :: proc(path: string) -> (first, count: int, ok: bool) {
	c := CodeEditor_Find(path)
	if c == nil do return 0, 0, false
	return c.ed.scroll_line, ce.editor_text_rows(&c.ed), true
}

/*
Where a position's character is in the window (0-based line and byte column; the shown file
only), and how far the pointer moves for one scrub step there, for the test driver's scrubs.
*/
CodeEditor_ScrubPoint :: proc(path: string, line, column: int) -> (at: [2]f32, perStep: f32, ok: bool) {
	c := CodeEditor_Find(path)
	if c == nil || host.lastShown != c || host.shownScale <= 0 do return
	x, y, inView := ce.editor_text_point(&c.ed, {line, column})
	if !inView do return
	return {host.shownRect.x + x / host.shownScale, host.shownRect.y + y / host.shownScale}, f32(ce.SCRUB_PIXELS_PER_STEP) * max(c.ed.char_w, 1) / 8 / host.shownScale, true
}

// The value a scrub of the code tab is at ("" when none is being dragged; temp allocated)
CodeEditor_ScrubText :: proc(path: string) -> string {
	c := CodeEditor_Find(path)
	if c == nil do return ""
	return ce.editor_scrub_text(&c.ed)
}

// Whether a line has a color swatch (0-based)
CodeEditor_HasSwatch :: proc(path: string, line: int) -> bool {
	c := CodeEditor_Find(path)
	if c == nil do return false
	for h in ce.editor_inlays_on(&c.ed, line) do if _, has := h.swatch.?; has do return true
	return false
}

// A line's inlay hints, joined (0-based line; temp allocated), and whether it has a gutter marker
CodeEditor_LineNotes :: proc(path: string, line: int) -> (inlays: string, marker: bool) {
	c := CodeEditor_Find(path)
	if c == nil do return "", false
	labels := make([dynamic]string, context.temp_allocator)
	for h in ce.editor_inlays_on(&c.ed, line) do append(&labels, h.label)
	return strings.join(labels[:], " ", context.temp_allocator), len(ce.editor_gutter_markers_on(&c.ed, line)) > 0
}

// Whether the code tab shows a problem whose message contains the text (tests)
CodeEditor_DiagnosticHas :: proc(path, text: string) -> bool {
	c := CodeEditor_Find(path)
	if c == nil do return false
	for d in ce.editor_diagnostics(&c.ed) do if strings.contains(d.message, text) do return true
	return false
}

/*
Where a code position is in the window (0-based line and byte column; the shown file only), or
the middle of its line's gutter marker column (`marker`), for the test driver's pointer.
*/
CodeEditor_WindowPoint :: proc(path: string, line, column: int, marker := false) -> ([2]f32, bool) {
	c := CodeEditor_Find(path)
	if c == nil || host.lastShown != c || host.shownScale <= 0 do return {}, false
	x, y := ce.editor_position_to_screen(&c.ed, {line, column})
	if marker do x = c.ed.origin_x + ce.editor_gutter_width(&c.ed) - ce.GUTTER_MARKER_SPACE / 2 - 2
	// A quarter into the cell (the position before it, whether the code editor rounds or cuts),
	// the middle of the row
	x += marker ? 0 : c.ed.char_w / 4
	y += c.ed.char_h / 2
	return {host.shownRect.x + x / host.shownScale, host.shownRect.y + y / host.shownScale}, true
}

/*
Scrolls the shown code tab so a position (0-based line, byte column) is in view: the line in the
middle when it wasn't, the column too when it's past the view's width (a narrow tab), the caret
staying where it is. For the test driver's drops.

Returns:
- Whether it scrolled (the next frames show it), and whether the file is open
*/
CodeEditor_RevealLine :: proc(path: string, line: int, column := 0) -> (scrolled, ok: bool) {
	c := CodeEditor_Find(path)
	if c == nil do return false, false
	rows := max(1, ce.editor_text_rows(&c.ed))
	cols := max(1, c.ed.visible_cols)
	vcol := ce.editor_visual_col(&c.ed, {line, column})
	// The column with a few cells after it, from the line's start when that fits
	wantCol := vcol + 4 < cols ? 0 : vcol - cols / 2
	// Not the last row: it may be under the horizontal scrollbar
	if line >= c.ed.scroll_line && line < c.ed.scroll_line + max(rows - 1, 1) && c.ed.scroll_col == wantCol do return false, true
	c.ed.scroll_line = max(0, line - rows / 2)
	c.ed.scroll_col = wantCol
	ce.editor_clamp_scroll(&c.ed)
	return true, true
}

// Where a text first is in an open file (0-based line and byte column; -1 when it isn't there)
CodeEditor_FindText :: proc(path, text: string) -> (line, column: int) {
	c := CodeEditor_Find(path)
	if c == nil || text == "" do return -1, -1
	for i in 0 ..< cebuf.buffer_line_count(&c.ed.buf) {
		if at := strings.index(cebuf.buffer_line_str(&c.ed.buf, i), text); at >= 0 do return i, at
	}
	return -1, -1
}

/*
An open file's buffer for the script index: its version, whether it has unsaved changes, and
its text when `wantText` (a temp copy). ("", -1, false when it isn't open.)
*/
CodeEditor_Buffer :: proc(path: string, wantText := false) -> (text: string, version: int, dirty: bool) {
	c := CodeEditor_Find(path)
	if c == nil do return "", -1, false
	if wantText do text = ce.editor_to_string(&c.ed, context.temp_allocator)
	return text, c.ed.buf.version, c.ed.buf.dirty
}

/*
Something dropped on the shown code tab at a window point: the code editor works out where it
landed (a struct, a procedure, a call's argument) and the providers decide what goes there
(code_drops.odin). The code editor takes the keyboard, so a menu's keys reach it.

Inputs:
- source: What was dropped (its panel's description)
- menu: List the choices with a preview instead of doing the plain drop (Shift held)

Returns:
- What happened, for the Console ("" when a menu opened), and whether a provider took it
*/
CodeEditor_Drop :: proc(state: ^State, path: string, mouse: [2]f32, source: DropSource, menu := false) -> (message: string, handled: bool) {
	c := CodeEditor_Find(path)
	if c == nil do return "No script is shown", false
	scale := host.shownScale > 0 ? host.shownScale : 1
	x := (mouse.x - host.shownRect.x) * scale
	y := (mouse.y - host.shownRect.y) * scale
	CodeProviders_Begin(state)
	defer CodeProviders_End()
	src := source
	message, handled = ce.editor_drop(&c.ed, x, y, ce.Drop_Request{kind = CODE_DROP_SOURCE, data = &src, menu = menu})
	if !handled {
		if problem := CodeProviders_TakeDropProblem(); problem != "" do message = problem
	}
	host.focusNext = true
	c.renderKey = 0
	return
}

// Asks the language server for completions at the caret again (the popup shows the answer)
CodeEditor_RequestCompletion :: proc(path: string) {
	if c := CodeEditor_Find(path); c != nil do ce.editor_request_completion(&c.ed)
}

// How many language servers run now (0 or 1: every tab shares one), and how many were started
CodeEditor_Servers :: proc() -> (running, started: int) {
	for c in host.editors do if c.ed.lsp_enabled do running += 1
	return running, host.serversStarted
}

// Where a file's editor imports Zed or VS Code key bindings from (tests: a fixture, never yours)
CodeEditor_SetImportPath :: proc(path: string, zed: bool, file: string) {
	if c := CodeEditor_Find(path); c != nil do ce.editor_set_import_path(&c.ed, zed ? .Zed : .VSCode, file)
}

// The code editor's own transient message (a theme chosen, a keymap imported, ...; "" when none)
CodeEditor_StatusText :: proc(path: string) -> string {
	c := CodeEditor_Find(path)
	return c != nil ? ce.editor_status_text(&c.ed) : ""
}

// What its navigation panels show (tests): the peek window, the references panel and its rows
CodeEditor_Navigation :: proc(path: string) -> (peekOpen, refsOpen: bool, refs: int) {
	c := CodeEditor_Find(path)
	if c == nil do return
	return c.ed.nav.peek.open, c.ed.nav.refs.open, len(c.ed.nav.refs.items)
}

// The code editor's state as JSON (its control package's snapshot: tests read fields from it)
CodeEditor_StateJSON :: proc(path: string) -> string {
	c := CodeEditor_Find(path)
	return c != nil ? control.state_json(&c.ed, 0) : ""
}

/*
Saves a file's buffer under another name and makes the editor that file's (its document moves
with it on the language server).

Returns:
- "" or why it couldn't (temp allocated)
*/
CodeEditor_SaveAs :: proc(path, newPath: string) -> string {
	c := CodeEditor_Find(path)
	if c == nil do return "not open"
	if CodeEditor_Find(newPath) != nil do return fmt.tprintf("%s is open in another tab", filepath.base(newPath))
	if !ce.editor_save_file_as(&c.ed, newPath) do return fmt.tprintf("Couldn't save %s", newPath)
	cursor := ce.editor_primary_cursor(&c.ed).pos
	delete(c.path)
	c.path = strings.clone(newPath)
	_ = ce.editor_load_file(&c.ed, newPath)
	ce.editor_goto_lsp_position(&c.ed, cursor.line, cursor.col)
	c.diskTime = modificationTime(newPath)
	c.diskChanged = false
	return ""
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
	// The input comes from an SDL event watch, installed when a code view first shows (only the
	// running editor gets here: unit tests open files without SDL running)
	if !host.watching do host.watching = sdl.AddEventWatch(eventWatch, nil)
	rect := ctx.widgets.states[id].last_rect
	scale := ctx.renderer != nil ? max(ctx.renderer.scale, 1) : 1
	host.shownRect, host.shownScale = rect, scale
	// The providers read the project while the code editor runs (code_providers.odin)
	CodeProviders_Begin(s)
	defer CodeProviders_End()
	focused := ctx.widgets.focused_id == id
	popupOpen := len(ctx.widgets.overlay_rects_prev) > 0 || ctx.widgets.modal_rect_prev.w > 0
	mouse := ctx.input.mouse_pos
	over := rect.w > 0 && mouse.x >= rect.x && mouse.y >= rect.y && mouse.x < rect.x + rect.w && mouse.y < rect.y + rect.h && !popupOpen
	if ctx.input.mouse_pressed[.Left] && over && !focused || host.focusNext {
		skald.widget_focus(ctx, id)
		focused = true
		host.focusNext = false
	}
	if focused do ctx.widgets.wants_text_input = true

	// The font follows the display's scale and the editor's zoom
	if size, ok := ce.editor_take_font_size_change(&c.ed); ok do host.zoom = size
	applyFont(c, scale)

	// This frame's input
	passthrough := passthroughChords(&s.settings.keymap)
	// Help (F1): an engine declaration's API page, else the manual (the code editor's own F1, its
	// palette, keeps Ctrl+Shift+P)
	help := actionChords(&s.settings.keymap, .User_Manual)
	dragging := c.ed.mouse.drag != .None || ce.editor_scrub_held(&c.ed)
	// Input reaching the editor this frame: it's drawn again
	handled := 0
	for i in 0 ..< host.eventCount {
		e := host.events[i]
		#partial switch e.type {
		case .KEY_DOWN, .KEY_UP:
			if !focused || isPassthrough(e.key, passthrough) do continue
			if isPassthrough(e.key, help) {
				if e.type == .KEY_DOWN && !e.key.repeat {
					url := CodeProviders_HelpAt(s, ce.editor_provider_document(&c.ed), ce.editor_primary_cursor(&c.ed).pos)
					skald.send(ctx, Msg(Code_Help_Requested(url != "" ? url : Manual_URL(""))))
				}
				continue
			}
			handled += 1
			if ce.editor_handle_event(&c.ed, e) || e.type != .KEY_DOWN do continue
			// What the code editor leaves to its host: Open and Save As need file dialogs
			if action, bound := km.keymap_resolve(&c.ed.keymap, ce.sdl_event_to_chord(e.key)); bound {
				#partial switch action {
				case .Open:   skald.send(ctx, Msg(Code_Dialog_Requested(.Open)))
				case .SaveAs: skald.send(ctx, Msg(Code_Dialog_Requested(.Save_As)))
				}
			}
		case .TEXT_INPUT, .TEXT_EDITING:
			if !focused do continue
			handled += 1
			_ = ce.editor_handle_event(&c.ed, e)
		case .MOUSE_MOTION:
			if !over && !dragging do continue
			handled += 1
			e.motion.x = (e.motion.x - rect.x) * scale
			e.motion.y = (e.motion.y - rect.y) * scale
			_ = ce.editor_handle_event(&c.ed, e)
		case .MOUSE_BUTTON_DOWN, .MOUSE_BUTTON_UP:
			if e.type == .MOUSE_BUTTON_DOWN && !over do continue
			if e.type == .MOUSE_BUTTON_UP && !over && !dragging do continue
			handled += 1
			e.button.x = (e.button.x - rect.x) * scale
			e.button.y = (e.button.y - rect.y) * scale
			_ = ce.editor_handle_event(&c.ed, e)
		case .MOUSE_WHEEL:
			if !over do continue
			handled += 1
			e.wheel.mouse_x = (e.wheel.mouse_x - rect.x) * scale
			e.wheel.mouse_y = (e.wheel.mouse_y - rect.y) * scale
			_ = ce.editor_handle_event(&c.ed, e)
		}
	}
	drainEvents()
	// Settings > Editor > Auto-close
	c.ed.auto_close_pairs = s.settings.autoClosePairs
	// The shared language server follows the file that shows
	takeServer(c)
	// It learns of script files changed on disk whenever the code shows, not only on Code_Tick:
	// ticks come only while the window has the keyboard, so a file written meanwhile (git, another
	// editor, a test) was never announced (WatchScripts looks at most once a second)
	CodeEditor_WatchScripts(absolutePath(joinPath(s.project.rootPath, SCRIPTS_FOLDER, allocator = context.temp_allocator)))
	// A reply from the language server (completions, diagnostics, hover...) may change what shows
	if c.ed.lsp_enabled && c.ed.lsp.has_process && c.ed.lsp.stdout != nil {
		if pending, err := os.pipe_has_data(c.ed.lsp.stdout); err == nil && pending do handled += 1
	}
	ce.editor_update(&c.ed)
	if c.ed.lsp_enabled && c.ed.lsp_doc_open do c.openedIn = serverProcess(c)
	// What the providers left: a usage to open (a marker, Find Usages), a rename's project side
	linksSend(ctx)
	// A scrub's value for the game, a running node picked, a write-back; a log point's change
	CodeLive_Take(ctx)
	LogPoints_Take(ctx)
	// A swatch's Color dialog, a hover's play button
	if request, ok := CodeColors_TakeRequest(); ok do skald.send(ctx, Msg(request))
	if audio, ok := CodePreviews_TakeAudio(); ok do skald.send(ctx, Msg(audio))
	// A drop's menu picked from: what it wrote, for the Console
	if message := ce.editor_take_drop_message(&c.ed); message != "" do skald.send(ctx, Msg(Code_Drop_Chosen{message}))
	// The language server's rename changed other files: their tabs apply them
	if others := ce.editor_take_file_edits(&c.ed); len(others) > 0 {
		paths := make([dynamic]string, context.temp_allocator)
		groups := make([dynamic][dynamic]CodeFileEdit, context.temp_allocator)
		for e in others {
			at := -1
			for p, i in paths do if p == e.key do at = i
			if at < 0 {
				append(&paths, e.key)
				append(&groups, make([dynamic]CodeFileEdit, context.temp_allocator))
				at = len(paths) - 1
			}
			append(&groups[at], CodeFileEdit{e.range.start.line, e.range.start.character, e.range.end.line, e.range.end.character, e.new_text})
		}
		edits := make([][]CodeFileEdit, len(groups), context.temp_allocator)
		for g, i in groups do edits[i] = g[:]
		skald.send(ctx, Msg(Code_File_Edits_Requested{paths[:], edits}))
	}
	if other, line, character, ok := ce.editor_take_open_request(&c.ed); ok {
		skald.send(ctx, Msg(Code_Open_Requested{strings.clone(other, context.temp_allocator), line, character}))
	}
	// Language server replies arrive between inputs, and the file may change on disk
	if !s.codeTickPending && EditorFocused() do skald.send(ctx, Msg(Code_Tick_Requested{c.ed.lsp_enabled ? CODE_TICK_SECONDS : 1}))
	// A tab coming to the front takes the key bindings and theme another tab may have changed
	// (Keymap Editor, an import, Theme Editor: they're saved in the config folder)
	if host.lastShown != c && host.lastShown != nil && c.ed.config.dir != "" {
		_ = ce.editor_load_keymap(&c.ed)
		ce.editor_load_theme(&c.ed)
	}
	#partial switch CodeEditor_DiskChange(path, now = host.lastShown != c) {
	case .Reloaded:
		handled += 1
		skald.send(ctx, Msg(Code_Reloaded{strings.clone(path, context.temp_allocator)}))
	}
	if host.lastShown != c do handled += 1
	host.lastShown = c

	// Render only when what it shows may have changed (input, a server reply, a reload, the
	// size, its text or carets, the scroll, the server's answers), and at least every
	// CODE_RENDER_REFRESH; upload only changed pixels. Rendering is a full software redraw
	// (about 11 ms fullscreen): every frame, it took most of a 60 fps frame
	size := [2]int{int(rect.w * scale), int(rect.h * scale)}
	imageReady := false
	stillShown := host.uploaded == c && host.uploadedSize == size
	key := codeRenderKey(c, size, scale)
	if stillShown && handled == 0 && key == c.renderKey && time.tick_since(c.renderedAt) < CODE_RENDER_REFRESH {
		imageReady = true
	} else if ctx.renderer != nil && size.x > 0 && size.y > 0 && SharedGPU_Renderer() != nil && GPUTarget_Ensure(&host.target, CODE_IMAGE, size) {
		// Drawn straight into the image the tab shows
		c.renderKey = key
		c.renderedAt = time.tick_now()
		c.size = size
		r := SharedGPU_Renderer()
		ce.editor_set_viewport(&c.ed, f32(size.x), f32(size.y))
		GPUTarget_Begin(&host.target, size)
		sdl.SetRenderDrawColor(r, 0, 0, 0, 255)
		sdl.RenderClear(r)
		ce.editor_render(&c.ed, r, host.font, 0, 0)
		GPUTarget_End()
		host.onGPU = true
		host.uploaded = c
		host.uploadedSize = size
		imageReady = true
	} else if ctx.renderer != nil && size.x > 0 && size.y > 0 && ensureSurface(c, size) {
		host.onGPU = false
		c.renderKey = key
		c.renderedAt = time.tick_now()
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
				imageReady = skald.image_load_pixels(ctx.renderer, CODE_IMAGE, u32(size.x), u32(size.y), pixels, mipmaps = false)
				host.uploadedSize = size
			}
			host.uploaded = imageReady ? c : nil
			host.uploadedHash = c.pixelsHash
		}
	}

	Data :: struct { ready: bool, bg: skald.Color, onGPU: bool, size: [2]int }
	theme := c.ed.theme.background
	data := new_clone(Data{imageReady, skald.rgba(u32(theme.r) << 24 | u32(theme.g) << 16 | u32(theme.b) << 8 | 0xff), host.onGPU, host.uploadedSize}, context.temp_allocator)
	cursor := skald.Cursor_Shape.Default
	switch ce.editor_mouse_cursor(&c.ed) {
	case .Text:    cursor = .Text
	case .Scrub:   cursor = .EW_Resize
	case .Default:
	}
	return skald.canvas(ctx, data, proc(d: ^Data, p: skald.Canvas_Painter) {
		skald.draw_rect(p.r, p.bounds, d.bg)
		if d.ready && d.onGPU {
			GPUTarget_Draw(p.r, CODE_IMAGE, p.bounds, d.size)
		} else if d.ready {
			skald.draw_image(p.r, CODE_IMAGE, p.bounds, .Fill)
		}
	}, id = id, cursor = cursor)
}

// What a code editor's picture depends on, cheaply: its size, text version, carets and
// selections, scroll, and the server's latest answers
@(private="file")
codeRenderKey :: proc(c: ^CodeEditor, size: [2]int, scale: f32) -> u64 {
	Key :: struct {
		size: [2]int,
		scale: f32,
		version, cursors, scrollLine, scrollCol: int,
		diagnostics, completions, signatures: int,
		// What the providers said (markers, hints, problems), the hover and the merged list
		provided, hover, items: int,
		hoverShown: bool,
		// A hover's play button shows whether its sound plays
		playing: bool,
	}
	key := Key{size, scale, c.ed.buf.version, len(c.ed.buf.cursors), c.ed.scroll_line, c.ed.scroll_col,
		c.ed.lsp.diagnostics_seq, c.ed.lsp.completion_seq, c.ed.lsp.signature_seq,
		c.ed.provided.seq, c.ed.hover.shown_seq, c.ed.completion.items_seq, c.ed.hover.visible,
		c.ed.hover.visible && CodePreviews_AudioPlaying()}
	h := hash.fnv64a(([^]u8)(&key)[:size_of(key)])
	if len(c.ed.buf.cursors) > 0 do h = hash.fnv64a(slice.to_bytes(c.ed.buf.cursors[:]), h)
	return h
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
	// Next to the editor: a release archive's, or a macOS bundle's Contents/MacOS
	if dir, err := os.get_executable_directory(context.temp_allocator); err == nil {
		beside := filepath.join({dir, ODIN_OS == .Windows ? "ols.exe" : "ols"}, context.temp_allocator) or_else ""
		if os.exists(beside) && !os.is_dir(beside) do return beside
	}
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
		// Measured again when the font's size changed since this editor's cells were
		if c.cellsFor != host.fontPixels {
			ce.editor_set_font(&c.ed, f32(w), f32(h))
			c.cellsFor = host.fontPixels
		}
	}
	// The zoom is the same in every tab (setting the size, not the base Ctrl+0 returns to)
	c.ed.font_size = host.zoom
}

@(private="file")
ensureSurface :: proc(c: ^CodeEditor, size: [2]int) -> bool {
	if c.surface != nil && c.size == size do return true
	if c.renderer != nil {
		ce.editor_forget_renderer(c.renderer)
		sdl.DestroyRenderer(c.renderer)
	}
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
		for chord in chords do if chord != {} do append(&list, Chord_OnPlatform(chord))
	}
	return list[:]
}

// An action's chords, on this platform (temp allocated)
@(private="file")
actionChords :: proc(keymap: ^Keymap, action: Action) -> []skald.Shortcut {
	list := make([dynamic]skald.Shortcut, context.temp_allocator)
	for chord in keymap[action] do if chord != {} do append(&list, Chord_OnPlatform(chord))
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
