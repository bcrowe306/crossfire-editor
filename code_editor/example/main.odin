// Standalone demo/test application for the odin_editor package. Opens an
// SDL3 window, hosts a single Editor, and demonstrates:
//   - normal interactive editing (type, navigate, select, undo/redo, etc.)
//   - file load/save via Ctrl/Cmd+S
//   - an optional scripted "self test" mode that drives the editor purely
//     through the event-injection hook (no real input required), proving
//     requirement #8 (SDL event injection for automated testing/demo).
//
// Usage:
//   example                 launch interactively, loading assets/sample.odin.txt
//   example --script        run the injected-event script, then continue interactively
//   example --script-only   run the injected-event script, print the result, and exit
//   example --e2e           run the full automated end-to-end test suite and exit
//                           (exit code 0 on success, 1 if any check failed)
//   example <file>          open <file> instead of the bundled sample
//   example --control 7777  enable the remote-control hook on 127.0.0.1:7777
//                           (drive the running GUI with tools/edctl; see README)
//   example --control-only  with --control: accept input *only* from the hook —
//                           real keyboard/mouse events are dropped and the window
//                           never takes focus, so scripted runs can't be disturbed
//                           by (or steal) the user's typing
//   example --no-lsp        don't attach the OLS language server even if built
//   example --ols <path>    use a specific `ols` binary
//   example --config-dir <dir>  keep settings (keymap.json) in <dir>
//                           (default ~/.config/odin_editor; none with --control-only)
//   example --zed-keymap <path> / --vscode-keymap <path>
//                           where "Import Keybindings from Zed/VSCode" reads
package main

import "../control"
import ed "../editor"
import km "../keymap"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import sdl "vendor:sdl3"
import ttf "vendor:sdl3/ttf"

WINDOW_W :: 1100
WINDOW_H :: 720
FONT_SIZE :: 16

find_font_path :: proc() -> string {
	candidates := []string{
		"/System/Library/Fonts/SFNSMono.ttf",
		"/System/Library/Fonts/Menlo.ttc",
		"/System/Library/Fonts/Supplemental/Andale Mono.ttf",
		"/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf",
		"/usr/share/fonts/truetype/liberation/LiberationMono-Regular.ttf",
	}
	for c in candidates {
		if os.exists(c) {
			return c
		}
	}
	return ""
}

// run_demo_script exercises the injection hook end-to-end: it types text,
// moves the cursor, selects, and deletes -- entirely via
// editor_inject_key/editor_inject_text, never touching real SDL input.
// This is requirement #8's "hook to inject SDL events to test the editor".
run_demo_script :: proc(e: ^ed.Editor, primary_mod: sdl.Keymod) {
	ed.editor_set_text(e, "")
	ed.editor_inject_text(e, "// injected by demo script\n")
	ed.editor_inject_text(e, "hello := \"world\"")
	ed.editor_pump_injected_events(e)

	ed.editor_inject_key(e, sdl.K_HOME)
	ed.editor_pump_injected_events(e)

	ed.editor_inject_key(e, sdl.K_END, sdl.KMOD_SHIFT)
	ed.editor_pump_injected_events(e)

	ed.editor_inject_key(e, sdl.K_C, primary_mod)
	ed.editor_pump_injected_events(e)

	ed.editor_inject_key(e, sdl.K_RIGHT)
	ed.editor_inject_text(e, "\n")
	ed.editor_inject_key(e, sdl.K_V, primary_mod)
	ed.editor_pump_injected_events(e)

	fmt.println("--- demo script result ---")
	text := ed.editor_to_string(e, context.temp_allocator)
	fmt.println(text)
	fmt.println("--- end demo script result ---")
}

// find_ols_binary looks for the `ols` built by `task ols:build`, relative
// to the working directory (task runs from odin_editor/, the repo root is
// one level up) and to the demo binary itself.
find_ols_binary :: proc() -> string {
	exe_dir := filepath.dir(os.args[0])
	next_to_exe, _ := filepath.join({exe_dir, "..", "third_party", "ols", "ols"}, context.temp_allocator)
	candidates := []string{
		"third_party/ols/ols",
		"odin_editor/third_party/ols/ols",
		next_to_exe,
	}
	for c in candidates {
		if os.exists(c) {
			return c
		}
	}
	return ""
}

main :: proc() {
	run_script := false
	script_only := false
	run_e2e := false
	use_lsp := true
	control_port := 0
	control_only := false
	ols_path := ""
	file_arg := ""
	config_dir := ""
	config_dir_set := false
	import_paths: [ed.Keymap_Source]string
	args := os.args[1:]
	for i := 0; i < len(args); i += 1 {
		switch args[i] {
		case "--script":
			run_script = true
		case "--script-only":
			run_script = true
			script_only = true
		case "--e2e":
			run_e2e = true
		case "--no-lsp":
			use_lsp = false
		case "--control":
			i += 1
			ok := false
			if i < len(args) {
				control_port, ok = strconv.parse_int(args[i])
			}
			if !ok {
				fmt.eprintln("--control needs a port number, e.g. --control 7777")
				os.exit(2)
			}
		case "--control-only":
			control_only = true
		case "--ols":
			i += 1
			if i < len(args) {
				ols_path = args[i]
			}
		case "--config-dir":
			i += 1
			if i < len(args) {
				config_dir, config_dir_set = args[i], true
			}
		case "--zed-keymap", "--vscode-keymap":
			src := ed.Keymap_Source.Zed if args[i] == "--zed-keymap" else ed.Keymap_Source.VSCode
			i += 1
			if i < len(args) {
				import_paths[src] = args[i]
			}
		case:
			if strings.has_prefix(args[i], "--") {
				fmt.eprintln("unknown option:", args[i])
				os.exit(2)
			}
			file_arg = args[i]
		}
	}

	platform := km.Platform.Other
	primary_mod := sdl.KMOD_CTRL
	word_mod := sdl.KMOD_CTRL
	when ODIN_OS == .Darwin {
		platform = km.Platform.MacOS
		primary_mod = sdl.KMOD_GUI
		word_mod = sdl.KMOD_ALT
	}

	editor := ed.editor_init(platform)
	defer ed.editor_destroy(&editor)
	for p, src in import_paths {
		if len(p) > 0 {
			ed.editor_set_import_path(&editor, src, p)
		}
	}
	if !config_dir_set && !control_only {
		if home, err := os.user_home_dir(context.temp_allocator); err == nil {
			config_dir, _ = filepath.join({home, ".config", "odin_editor"}, context.temp_allocator)
		}
	}
	if len(config_dir) > 0 {
		ed.editor_set_config_dir(&editor, config_dir)
	}

	// The e2e suite manages its own LSP session and documents.
	if use_lsp && !run_e2e && !script_only {
		if ols_path == "" {
			ols_path = find_ols_binary()
		}
		if ols_path == "" {
			fmt.println("note: ols not found (run `task ols:build`); completion/signature help disabled")
		} else {
			root := filepath.dir(file_arg) if file_arg != "" else "."
			if ed.editor_attach_lsp(&editor, []string{ols_path}, root) {
				fmt.println("attached language server:", ols_path)
			} else {
				fmt.eprintln("warning: failed to start", ols_path)
			}
		}
	}

	if file_arg != "" {
		if !ed.editor_load_file(&editor, file_arg) {
			fmt.eprintln("cannot open", file_arg)
			os.exit(1)
		}
	} else {
		for sample_path in ([]string{"example/assets/sample.odin.txt", "odin_editor/example/assets/sample.odin.txt", "assets/sample.odin.txt"}) {
			if os.exists(sample_path) {
				_ = ed.editor_load_file(&editor, sample_path)
				break
			}
		}
	}

	// SDL must be initialized before the demo script runs: clipboard
	// copy/paste (exercised by run_demo_script) requires the video
	// subsystem to be up even when no window is shown.
	if !sdl.Init(sdl.INIT_VIDEO) {
		fmt.eprintln("sdl.Init failed:", sdl.GetError())
		os.exit(1)
	}
	defer sdl.Quit()

	if run_script {
		run_demo_script(&editor, primary_mod)
		if script_only {
			return
		}
	}

	if !ttf.Init() {
		fmt.eprintln("ttf.Init failed:", sdl.GetError())
		os.exit(1)
	}
	defer ttf.Quit()

	window: ^sdl.Window
	renderer: ^sdl.Renderer
	window_flags := sdl.WINDOW_RESIZABLE
	if control_only {
		window_flags |= sdl.WINDOW_NOT_FOCUSABLE
	}
	if !sdl.CreateWindowAndRenderer("odin_editor demo", WINDOW_W, WINDOW_H, window_flags, &window, &renderer) {
		fmt.eprintln("CreateWindowAndRenderer failed:", sdl.GetError())
		os.exit(1)
	}
	defer sdl.DestroyWindow(window)
	defer sdl.DestroyRenderer(renderer)
	// Its glyph atlas goes first (deferred calls run last-first)
	defer ed.editor_forget_renderer(renderer)

	font_path := find_font_path()
	font: ^ttf.Font
	if font_path != "" {
		cpath := strings.clone_to_cstring(font_path, context.temp_allocator)
		font = ttf.OpenFont(cpath, FONT_SIZE)
	}
	if font == nil {
		fmt.eprintln("warning: could not open a monospace font; text will not render")
	}
	defer if font != nil {
		ttf.CloseFont(font)
	}
	// Emoji / CJK / symbol glyphs come from system fallback fonts.
	fallbacks := ed.font_add_system_fallbacks(font, FONT_SIZE)
	defer ed.font_fallbacks_destroy(&fallbacks, font)

	char_w, char_h: f32 = 9, 18
	if font != nil {
		w, h: i32
		if ttf.GetStringSize(font, raw_data(string("M")), 1, &w, &h) {
			char_w, char_h = f32(w), f32(h)
		}
	}
	// Cell width + glyph height; the editor applies its line spacing.
	ed.editor_set_font(&editor, char_w, char_h)
	ed.editor_set_font_size(&editor, FONT_SIZE) // enables Ctrl/Cmd +/-/0 zoom
	// The text area is the window minus the line-number gutter.
	ed.editor_set_viewport(&editor, WINDOW_W, WINDOW_H)

	_ = sdl.StartTextInput(window)
	defer _ = sdl.StopTextInput(window)

	theme := ed.default_theme()

	if run_e2e {
		all_pass := run_e2e_suite(&editor, renderer, font, theme, primary_mod, word_mod)
		os.exit(all_pass ? 0 : 1)
	}

	srv: control.Server
	if control_port > 0 {
		if !control.server_start(&srv, control_port, window, platform) {
			os.exit(1)
		}
		fmt.printfln("remote control listening on 127.0.0.1:%d", control_port)
	}
	defer control.server_stop(&srv)

	// The editor reports which pointer shape it wants (I-beam over text,
	// arrow over the gutter/popups); the host owns the SDL cursors.
	cursor_shapes := [ed.Mouse_Cursor]^sdl.Cursor{
		.Default = sdl.CreateSystemCursor(.DEFAULT),
		.Text    = sdl.CreateSystemCursor(.TEXT),
	}
	defer for c in cursor_shapes {
		if c != nil {
			sdl.DestroyCursor(c)
		}
	}
	current_shape := ed.Mouse_Cursor.Default
	last_title := ""
	defer delete(last_title)

	running := true
	for running {
		// Remote-control commands push real SDL events, which the
		// PollEvent loop below then delivers like any other input.
		control.server_poll(&srv, &editor)

		event: sdl.Event
		for sdl.PollEvent(&event) {
			if control_only && control.event_is_user_input(event) && !control.event_is_injected(&srv, event) {
				continue
			}
			#partial switch event.type {
			case .QUIT:
				running = false
			case .WINDOW_RESIZED:
				w, h: i32
				sdl.GetWindowSize(window, &w, &h)
				ed.editor_set_viewport(&editor, f32(w), f32(h))
			}
			handled := ed.editor_handle_event(&editor, event)
			if !handled && event.type == .KEY_DOWN {
				handle_host_level_shortcuts(&editor, event.key)
			}
		}

		ed.editor_update(&editor)

		// Zoom: the editor asks for a new size; resize our fonts and
		// re-measure the cell.
		if size, ok := ed.editor_take_font_size_change(&editor); ok && font != nil {
			_ = ttf.SetFontSize(font, size)
			for fb in fallbacks.fonts {
				_ = ttf.SetFontSize(fb, size)
			}
			w, h: i32
			if ttf.GetStringSize(font, raw_data(string("M")), 1, &w, &h) {
				ed.editor_set_font(&editor, f32(w), f32(h))
			}
		}

		// The problems panel asks the host to open other files.
		if path, line, character, ok := ed.editor_take_open_request(&editor); ok {
			if ed.editor_load_file(&editor, path) {
				ed.editor_goto_lsp_position(&editor, line, character)
			} else {
				fmt.eprintln("cannot open", path)
			}
		}

		// The gutter widens as the line count grows; keep the text area
		// fitted to the window.
		{
			w, h: i32
			sdl.GetWindowSize(window, &w, &h)
			ed.editor_set_viewport(&editor, f32(w), f32(h))
		}

		// Window title: file name (+ unsaved marker) and a problems summary
		// (a real host would show the latter in its status bar).
		{
			counts := ed.editor_diagnostic_counts(&editor)
			name, _ := ed.editor_display_name(&editor)
			title := fmt.tprintf("%s%s — odin_editor demo", name, " ●" if editor.buf.dirty else "")
			if counts[.Error] + counts[.Warning] > 0 {
				title = fmt.tprintf("%s — %d error(s), %d warning(s)", title, counts[.Error], counts[.Warning])
			}
			if title != last_title {
				delete(last_title)
				last_title = strings.clone(title)
				_ = sdl.SetWindowTitle(window, strings.clone_to_cstring(title, context.temp_allocator))
			}
		}

		if shape := ed.editor_mouse_cursor(&editor); shape != current_shape {
			current_shape = shape
			_ = sdl.SetCursor(cursor_shapes[shape])
		}

		sdl.SetRenderDrawColor(renderer, 30, 30, 30, 255)
		sdl.RenderClear(renderer)
		ed.editor_render(&editor, renderer, font, 0, 0)
		control.server_after_render(&srv, &editor, renderer)
		sdl.RenderPresent(renderer)

		free_all(context.temp_allocator)
		sdl.Delay(8)
	}
}

// handle_host_level_shortcuts deals with actions the Editor package
// intentionally reports as "not handled" because they require host/OS
// integration (file dialogs, real clipboard already handled inside the
// editor though). Here we just wire Save to the currently open file.
handle_host_level_shortcuts :: proc(e: ^ed.Editor, key: sdl.KeyboardEvent) {
	ctrl_or_cmd := .LCTRL in key.mod || .RCTRL in key.mod || .LGUI in key.mod || .RGUI in key.mod
	if ctrl_or_cmd && key.key == sdl.K_S {
		if ed.editor_save(e) {
			fmt.println("saved", e.document_uri)
		}
	}
}
