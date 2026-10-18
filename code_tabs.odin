package editor

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "gui:skald"

/*
Code tabs: scripts open in the built-in code editor (code_editor_host.odin), as tabs after the
scene tabs in the center panel. Opening a script (the inspector's or browser's Open, New Script,
Scripts > Open Script) opens its tab, or shows it if it's open; each script has its own tab. A tab
closes with its × (or a middle click, or Ctrl+W); one with unsaved changes asks first. Picking a
scene tab (or anything that changes the open scene) shows the scene again.

With Settings > Editor > "Use the built-in code editor" off, scripts open in the external program
instead (`Script_OpenInEditor`), as before.

Unsaved scripts count as unsaved changes (the title's `*`, the prompt before quitting): Save
(Ctrl+S), Play and Export save them with the project, and a save starts a script build in the
background so the inspector learns new fields.

Widget keys: the tabs `code-tab-<i>` and their close buttons `code-tab-close-<i>`, the editor
`code-editor`, `code-save`, and the close prompt's `code-close-save`, `code-close-discard`,
`code-close-cancel`.
*/

/*
Opens a script where the settings say: a code tab, or the external program.

Inputs:
- path: The file (absolute, or relative to the project)
- line: 1-based
*/
Script_Open :: proc(state: ^State, path: string, line: int) -> skald.Command(Msg) {
	if !state.settings.builtInCodeEditor do return Script_OpenInEditor(state, path, line)
	CodeTabs_Open(state, path, line)
	return {}
}

// Opens a file in a code tab (or shows its tab) and puts the caret on `line` (1-based; 0 leaves it)
CodeTabs_Open :: proc(state: ^State, path: string, line: int) {
	absolute := path
	if !filepath.is_abs(path) do absolute = joinPath(state.project.rootPath, path, allocator = context.temp_allocator)
	if full, err := os.get_absolute_path(absolute, context.temp_allocator); err == nil do absolute = full
	// The language server reads the scripts folder's ols.json (the engine and project collections)
	if message := Scripts_WriteOLSConfig(&state.project); message != "" do logLine(state, .Warning, fmt.aprintf("ols.json: %s", message))
	scriptsDir := joinPath(state.project.rootPath, SCRIPTS_FOLDER, allocator = context.temp_allocator)
	if full, err := os.get_absolute_path(scriptsDir, context.temp_allocator); err == nil do scriptsDir = full
	known := CodeEditor_Find(absolute) != nil
	ols := ""
	if !known {
		ols = Code_FindOLS(FixedText_String(&state.settings.olsPath))
		if ols == "" && !state.codeNoOLSLogged {
			logLine(state, .Info, strings.clone("No Odin language server (ols) found: the code editor works without completion and diagnostics. Set its path in Settings > Editor"))
			state.codeNoOLSLogged = true
		}
	}
	// The code editor's keymap and theme edits live next to editor.ini (none in test runs without one)
	configDir := ""
	if state.settingsPath != "" do configDir = joinPath(filepath.dir(state.settingsPath), "code_editor", allocator = context.temp_allocator)
	if _, problem := CodeEditor_Open(absolute, scriptsDir, ols, configDir, state.settings.theme == .Light); problem != "" {
		logLine(state, .Warning, strings.clone(problem))
		return
	}
	index := -1
	for tab, i in state.codeTabs do if tab == absolute do index = i
	if index < 0 {
		append(&state.codeTabs, strings.clone(absolute))
		index = len(state.codeTabs) - 1
	}
	state.codeTab = index + 1
	state.codeFocusPending = true
	if line > 0 do CodeEditor_GotoLine(absolute, line)
}

// The file the shown code tab has open ("" when the scene shows)
CodeTabs_Active :: proc(state: ^State) -> string {
	i := state.codeTab - 1
	return i >= 0 && i < len(state.codeTabs) ? state.codeTabs[i] : ""
}

// Closes a tab (its changes are lost: CodeTabs_Update asks first) and shows a neighbour or the scene
CodeTabs_Close :: proc(state: ^State, index: int) {
	if index < 0 || index >= len(state.codeTabs) do return
	CodeEditor_Close(state.codeTabs[index])
	delete(state.codeTabs[index])
	ordered_remove(&state.codeTabs, index)
	active := state.codeTab - 1
	switch {
	case active == index:
		// The tab that took its place, else the one before, else the scene
		state.codeTab = len(state.codeTabs) == 0 ? 0 : min(index, len(state.codeTabs) - 1) + 1
	case active > index:
		state.codeTab -= 1
	}
}

// Closes every tab without asking (switching projects, after the save prompt). Only this state's:
// the editors are package state, which tests running side by side share
CodeTabs_CloseAll :: proc(state: ^State) {
	for tab in state.codeTabs {
		CodeEditor_Close(tab)
		delete(tab)
	}
	clear(&state.codeTabs)
	state.codeTab = 0
	state.codeClose = {}
}

/*
Handles the code tabs' messages.

Returns:
- The command, and whether `m` was one of them
*/
CodeTabs_Update :: proc(state: ^State, m: Msg) -> (skald.Command(Msg), bool) {
	#partial switch v in m {
	case Code_Tab_Selected:
		if int(v) >= 0 && int(v) < len(state.codeTabs) {
			state.codeTab = int(v) + 1
			state.codeFocusPending = true
		}
	case Code_Tab_Close_Requested:
		i := int(v)
		if i < 0 || i >= len(state.codeTabs) do break
		if CodeEditor_IsDirty(state.codeTabs[i]) {
			state.codeClose = {open = true, index = i}
		} else {
			CodeTabs_Close(state, i)
		}
	case Code_Close_Chosen:
		i := state.codeClose.index
		state.codeClose = {}
		if i < 0 || i >= len(state.codeTabs) do break
		switch v {
		case .Save:
			if problem := CodeEditor_Save(state.codeTabs[i]); problem != "" {
				logLine(state, .Error, strings.clone(problem))
				break
			}
			logLine(state, .Info, fmt.aprintf("Saved %s", filepath.base(state.codeTabs[i])))
			CodeTabs_Close(state, i)
			return scriptsBuildQuietly(state), true
		case .Discard:
			CodeTabs_Close(state, i)
		case .Cancel:
		}
	case Code_Open_Requested:
		// Go to Definition in another file: its own tab, at the definition (0-based from the server)
		CodeTabs_Open(state, v.path, 0)
		if c := CodeEditor_Find(CodeTabs_Active(state)); c != nil do CodeEditor_GotoPosition(c.path, v.line, v.character)
	case Code_Save_Requested:
		path := CodeTabs_Active(state)
		if path == "" || !CodeEditor_IsDirty(path) do break
		if problem := CodeEditor_Save(path); problem != "" {
			logLine(state, .Error, strings.clone(problem))
			break
		}
		logLine(state, .Info, fmt.aprintf("Saved %s", filepath.base(path)))
		return scriptsBuildQuietly(state), true
	case Code_Tick_Requested:
		if state.codeTickPending do break
		state.codeTickPending = true
		return skald.cmd_delay(v.seconds > 0 ? v.seconds : CODE_TICK_SECONDS, Msg(Code_Tick{})), true
	case Code_Reloaded:
		logLine(state, .Info, fmt.aprintf("%s changed on disk: reloaded", filepath.base(v.path)))
	case Code_Disk_Chosen:
		path := CodeTabs_Active(state)
		CodeEditor_ResolveDiskChange(path, bool(v))
		if bool(v) do logLine(state, .Info, fmt.aprintf("%s reloaded from disk (your changes are gone)", filepath.base(path)))
	case Code_Tick:
		state.codeTickPending = false
	case Code_Focused:
		state.codeFocusPending = false
	case:
		return {}, false
	}
	return {}, true
}

/*
Saves every code tab with changes, logging each (Save, Play and Export call it before saving the
project).

Returns:
- false if one couldn't be saved (logged)
*/
CodeTabs_SaveAll :: proc(state: ^State) -> bool {
	for path in state.codeTabs {
		if !CodeEditor_IsDirty(path) do continue
		if problem := CodeEditor_Save(path); problem != "" {
			logLine(state, .Error, strings.clone(problem))
			return false
		}
		logLine(state, .Info, fmt.aprintf("Saved %s", filepath.base(path)))
	}
	return true
}

// Whether one of this state's tabs has unsaved changes
CodeTabs_AnyDirty :: proc(state: ^State) -> bool {
	for path in state.codeTabs do if CodeEditor_IsDirty(path) do return true
	return false
}

// How often the code view looks for language server replies while one is attached
CODE_TICK_SECONDS :: f32(0.1)

// A build that describes the scripts again after one was saved, when nothing else is using the player
scriptsBuildQuietly :: proc(state: ^State) -> skald.Command(Msg) {
	if state.play.stage != .None || !Project_HasScripts(&state.project) do return {}
	return scriptsBuild(state)
}

// The tab strip's code tabs: name (● when unsaved) and ×; a middle click closes too
CodeTabs_View :: proc(s: ^State, ctx: ^skald.Ctx(Msg)) -> []skald.View {
	th := ctx.theme
	views := make([dynamic]skald.View, context.temp_allocator)
	for path, i in s.codeTabs {
		active := s.codeTab == i + 1
		dirty := CodeEditor_IsDirty(path)
		tabId := skald.hash_id(fmt.tprintf("code-tab-%d", i))
		// A middle click on the tab closes it, as in browsers and code editors
		if state, drawn := ctx.widgets.states[tabId]; drawn && ctx.input.mouse_pressed[.Middle] {
			r := state.last_rect
			p := ctx.input.mouse_pos
			if p.x >= r.x && p.y >= r.y && p.x < r.x + r.w && p.y < r.y + r.h do skald.send(ctx, Msg(Code_Tab_Close_Requested(i)))
		}
		// Styled as skald.tabs styles the scene tabs (view.odin's _tabs): the same fill, text,
		// padding, font and underline, with the × inside the tile
		bg := active ? skald.color_mix(th.color.primary, th.color.surface, 0.94) : th.color.surface
		fg := active ? th.color.fg : th.color.fg_muted
		label := fmt.tprintf("%s  %s%s", ICON_FILE_CODE, filepath.base(path), dirty ? " ●" : "")
		tab := skald.button(ctx, label, Msg(Code_Tab_Selected(i)), id = tabId,
			bg = bg, fg = fg, radius = th.radius.sm, padding = {th.spacing.md, th.spacing.sm}, font_size = th.font.size_md)
		close := skald.button(ctx, ICON_XMARK, Msg(Code_Tab_Close_Requested(i)), id = skald.hash_id(fmt.tprintf("code-tab-close-%d", i)),
			bg = bg, fg = th.color.fg_muted, radius = th.radius.sm, padding = {th.spacing.sm, th.spacing.sm}, font_size = th.font.size_xs)
		underline := active ? skald.rect({0, 2}, th.color.primary) : skald.rect({0, 1}, th.color.border)
		append(&views, skald.tooltip(ctx, skald.col(
			skald.row(tab, close, spacing = 0, cross_align = .Center, bg = bg, radius = th.radius.sm),
			underline,
			spacing = 2,
			cross_align = .Stretch,
		), path, id = skald.hash_id(fmt.tprintf("code-tab-tip-%d", i))))
	}
	return views[:]
}

// The code view's header button: Save (the tabs get the rest of the header)
CodeTabs_HeaderButtons :: proc(s: ^State, ctx: ^skald.Ctx(Msg), path: string) -> skald.View {
	th := ctx.theme
	save := skald.button(ctx, ICON_SAVE, Msg(Code_Save_Requested{}), id = skald.hash_id("code-save"),
		disabled = !CodeEditor_IsDirty(path), bg = th.color.surface, fg = th.color.fg,
		padding = {th.spacing.sm, 3}, font_size = th.font.size_sm, radius = th.radius.sm)
	return skald.tooltip(ctx, save, actionTip(s, "Save the script (Save also saves the project)", .Save_Project), id = skald.hash_id("code-save-tip"))
}

// The bar over the code when its file changed on disk under unsaved changes ({} when it didn't)
CodeTabs_DiskBar :: proc(s: ^State, ctx: ^skald.Ctx(Msg), path: string) -> skald.View {
	th := ctx.theme
	if !CodeEditor_HasDiskConflict(path) do return skald.spacer(0)
	small :: proc(ctx: ^skald.Ctx(Msg), label: string, msg: Msg, key: string) -> skald.View {
		th := ctx.theme
		return skald.button(ctx, label, msg, id = skald.hash_id(key), bg = th.color.bg, fg = th.color.fg,
			padding = {th.spacing.sm, 2}, font_size = th.font.size_xs, radius = th.radius.sm)
	}
	// The message wraps to the panel and the buttons go under it: in a narrow panel one line
	// pushed the buttons past its edge
	left, right := FittedSidebarWidths(&s.layout)
	width := max(s.layout.workspace.x - left - right - DIVIDER * 2 - th.spacing.xs * 2, 120)
	return skald.col(
		skald.text(fmt.tprintf("%s changed on disk, and you have unsaved changes.", filepath.base(path)), skald.rgb(0x1a1a1a), th.font.size_sm, max_width = width),
		skald.row(
			small(ctx, "Reload (lose mine)", Msg(Code_Disk_Chosen(true)), "code-disk-reload"),
			small(ctx, "Keep mine", Msg(Code_Disk_Chosen(false)), "code-disk-keep"),
			spacing = th.spacing.sm,
		),
		spacing = th.spacing.xs,
		padding = th.spacing.xs,
		bg = th.color.warning,
	)
}

// The line under the code: the file, the caret, the language server
CodeTabs_StatusLine :: proc(s: ^State, ctx: ^skald.Ctx(Msg), path: string) -> skald.View {
	th := ctx.theme
	line, column := CodeEditor_Caret(path)
	server := CodeEditor_LspStatus(path)
	if server == "" do server = "off (no ols)"
	return skald.row(
		skald.text(fmt.tprintf("%s%s", filepath.base(path), CodeEditor_IsDirty(path) ? " (unsaved)" : ""), th.color.fg_muted, th.font.size_xs),
		skald.flex(1, skald.spacer(0)),
		skald.text(fmt.tprintf("Ln %d, Col %d", line, column), th.color.fg_muted, th.font.size_xs),
		skald.text(fmt.tprintf("Language server: %s", server), th.color.fg_muted, th.font.size_xs),
		spacing = th.spacing.md,
		padding = th.spacing.xs,
		cross_align = .Center,
		bg = th.color.surface,
	)
}

// "Save changes to mover.odin?" before closing a tab with unsaved changes
codeCloseDialogView :: proc(s: ^State, ctx: ^skald.Ctx(Msg)) -> skald.View {
	th := ctx.theme
	name := ""
	if s.codeClose.index >= 0 && s.codeClose.index < len(s.codeTabs) do name = filepath.base(s.codeTabs[s.codeClose.index])
	return skald.dialog(ctx,
		open = s.codeClose.open,
		on_dismiss = proc() -> Msg { return Code_Close_Chosen(.Cancel) },
		content = skald.col(
			skald.text(fmt.tprintf("Save changes to %s?", name), th.color.fg, th.font.size_lg),
			skald.text("Closing the tab loses the changes that aren't saved.", th.color.fg_muted, th.font.size_sm),
			skald.spacer(th.spacing.sm),
			skald.row(
				skald.button(ctx, "Cancel", Msg(Code_Close_Chosen(.Cancel)), id = skald.hash_id("code-close-cancel"),
					bg = th.color.surface, fg = th.color.fg, font_size = th.font.size_sm),
				skald.flex(1, skald.spacer(0)),
				skald.button(ctx, "Don't Save", Msg(Code_Close_Chosen(.Discard)), id = skald.hash_id("code-close-discard"),
					bg = th.color.danger, fg = th.color.on_primary, font_size = th.font.size_sm),
				skald.button(ctx, "Save", Msg(Code_Close_Chosen(.Save)), id = skald.hash_id("code-close-save"),
					font_size = th.font.size_sm),
				spacing = th.spacing.sm,
			),
			spacing = th.spacing.xs,
			padding = th.spacing.lg,
			cross_align = .Stretch,
		),
		id = skald.hash_id("code-close-dialog"),
		initial_focus = skald.hash_id("code-close-save"),
	)
}
