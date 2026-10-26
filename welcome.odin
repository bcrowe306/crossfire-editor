package crossfire_editor

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "gui:skald"

/*
The welcome screen (TODO.md's "UI and UX" round "Workflow", 2026-10-25). The user's decision: with
no project argument the editor starts here; the demo no longer opens by itself (a path argument,
the UI tests and the profiler, which all pass one, are unaffected).

- It covers the whole window (`view` draws it instead of the editor; dialogs, the docs window and
  toasts still show over it): the recent projects (name and folder; a click opens one, × takes it
  off the list), New Project..., Open Project..., Open Project Archive..., Open the Demo (copied or
  written where it's kept the first time: `Demo_Prepare`) and the User Manual.
- **No project yet** (`WelcomeScreen.noProject`): the editor holds an empty placeholder project
  with no folder (`rootPath` ""), so nothing is written anywhere until one opens; the screen
  can't be closed and the keymap is off. A path argument that fails to open lands here too, with
  the error in a toast.
- **File > Welcome** (`Welcome_Opened`) shows it over an open project: Back (or Escape) returns.
- Opening a project (`switchProject`) closes it.
- Keys: `welcome-screen`, `welcome-new`, `welcome-open`, `welcome-archive`, `welcome-demo`,
  `welcome-manual`, `welcome-back`, `welcome-recent-<i>` / `welcome-recent-remove-<i>` (`i` the
  index into the recent list). Driver check: `welcome <open|closed>`.
*/

// The welcome screen's state (State.welcome)
WelcomeScreen :: struct {
	open: bool,
	// No project is open: the editor holds a placeholder (the screen can't be closed)
	noProject: bool,
}

// File > Welcome: shows the welcome screen over the open project
Welcome_Opened :: struct {}
// Back to the open project (nothing without one)
Welcome_Closed :: struct {}
// Takes a recent project off the list (an index into `recentProjects.folders`)
Welcome_Recent_Removed :: distinct int
// Opens the demo project (made where it's kept on first use)
Welcome_Demo_Opened :: struct {}

/*
The placeholder the editor holds while no project is open: an empty project without a folder
(`rootPath` ""), which nothing writes to disk.
*/
Project_CreatePlaceholder :: proc() -> Project {
	project := Project_CreateEmpty(".", "No Project")
	delete(project.rootPath)
	project.rootPath = strings.clone("")
	return project
}

/*
Makes sure the demo project is on disk (`Editor_DemoProject`): the one shipped with the editor
copied there on first use (a bundle's), else the built-in reduced one written there.

Returns:
- The demo's folder ("" when it couldn't be made: the reason is logged)
*/
Demo_Prepare :: proc(state: ^State) -> string {
	root := Editor_DemoProject()
	if os.exists(filepath.join({root, "project.xml"}, context.temp_allocator) or_else "") do return root
	if shipped := Editor_ShippedDemo(); shipped != "" {
		if problem := Folder_Copy(shipped, root); problem != "" {
			logLine(state, .Error, fmt.aprintf("Couldn't copy the demo project: %s", problem))
		} else {
			logLine(state, .Info, fmt.aprintf("Copied the demo project to %s", root))
			return root
		}
	}
	demo := Project_CreateDemo(root)
	defer Project_Destroy(&demo)
	if message := Project_Save(&demo); message != "" {
		logLine(state, .Error, fmt.aprintf("Couldn't create the demo project: %s", message))
		Notify(state, .Error, fmt.tprintf("Couldn't create the demo project: %s", message))
		return ""
	}
	logLine(state, .Info, fmt.aprintf("Created the demo project in %s", root))
	return root
}

/*
The welcome screen's messages.

Returns:
- A command to run, and whether `m` was one
*/
Welcome_Update :: proc(state: ^State, m: Msg) -> (skald.Command(Msg), bool) {
	#partial switch v in m {
	case Welcome_Opened:
		state.welcome.open = true
	case Welcome_Closed:
		if !state.welcome.noProject do state.welcome.open = false
	case Welcome_Recent_Removed:
		if int(v) >= 0 && int(v) < len(state.recentProjects.folders) {
			Recent_Remove(&state.recentProjects, strings.clone(state.recentProjects.folders[int(v)], context.temp_allocator))
		}
	case Welcome_Demo_Opened:
		root := Demo_Prepare(state)
		if root == "" do return {}, true
		delete(state.session.recent)
		state.session.recent = strings.clone(root)
		return Session_Request(state, .Open_Recent), true
	case Action:
		// Escape goes back to the open project
		if (v == .Deselect || v == .Level_Cancel) && state.welcome.open && !state.welcome.noProject {
			state.welcome.open = false
			return {}, true
		}
		return {}, false
	case:
		return {}, false
	}
	return {}, true
}

/*
The welcome screen, over the whole window: the editor's name, Start (New, Open, Open Project
Archive, the demo, the manual) and the recent projects.
*/
welcomeView :: proc(s: ^State, ctx: ^skald.Ctx(Msg)) -> skald.View {
	return skald.sized(ctx, s, welcomeSized)
}

@(private="file")
welcomeSized :: proc(ctx: ^skald.Ctx(Msg), s: ^State, size: [2]f32) -> skald.View {
	tk := uiTokens(ctx)
	th := ctx.theme
	button :: proc(ctx: ^skald.Ctx(Msg), key, icon, label: string, msg: Msg, primary := false) -> skald.View {
		th := ctx.theme
		tk := uiTokens(ctx)
		return skald.button(ctx, fmt.tprintf("%s  %s", icon, label), msg, id = skald.hash_id(key),
			bg = primary ? th.color.primary : th.color.surface, fg = primary ? th.color.on_primary : th.color.fg,
			padding = {tk.m, tk.s}, font_size = th.font.size_sm, text_align = .Start, width = tk.fieldXL)
	}
	start := skald.col(
		uiSection(th, tk, "Start"),
		button(ctx, "welcome-new", Action_Icon(.New_Project), "New Project...", Msg(Action.New_Project), primary = true),
		button(ctx, "welcome-open", Action_Icon(.Open_Project), "Open Project...", Msg(Action.Open_Project)),
		button(ctx, "welcome-archive", Action_Icon(.Open_Project), "Open Project Archive...", Msg(Action.Open_Project_Archive)),
		button(ctx, "welcome-demo", ICON_FILM, "Open the Demo", Msg(Welcome_Demo_Opened{})),
		button(ctx, "welcome-manual", ACTION_ICONS[.Manual], "User Manual", Msg(Manual_Opened("getting_started"))),
		spacing = tk.rowGap,
	)

	// The recent projects: name and folder, a click opens it, × takes it off the list
	recent := make([dynamic]skald.View, context.temp_allocator)
	append(&recent, uiSection(th, tk, "Recent Projects"))
	open := absolutePath(s.project.rootPath)
	for folder, i in s.recentProjects.folders {
		if !s.welcome.noProject && folder == open do continue
		row := skald.row(
			skald.flex(1, skald.button(ctx, fmt.tprintf("%s\n%s", filepath.base(folder), Recent_Label(folder)[len(filepath.base(folder)) + 3:]), Msg(Recent_Project_Chosen(i)),
				id = skald.hash_id(fmt.tprintf("welcome-recent-%d", i)), bg = th.color.surface, fg = th.color.fg,
				padding = {tk.m, tk.s}, font_size = th.font.size_sm, text_align = .Start, overflow = .Ellipsis)),
			skald.tooltip(ctx, skald.button(ctx, ACTION_ICONS[.Remove], Msg(Welcome_Recent_Removed(i)),
				id = skald.hash_id(fmt.tprintf("welcome-recent-remove-%d", i)), bg = th.color.surface, fg = th.color.fg_muted,
				width = tk.panelButtonWidth, padding = {0, tk.s}, font_size = tk.iconSmall),
				"Take it off the list (the folder stays)", id = skald.hash_id(fmt.tprintf("welcome-recent-remove-tip-%d", i))),
			spacing = tk.xxs,
			cross_align = .Stretch,
		)
		append(&recent, row)
	}
	if len(recent) == 1 {
		append(&recent, emptyState(ctx, "No recent projects yet: the projects you open show here.",
			{label = "Open the Demo", msg = Msg(Welcome_Demo_Opened{}), key = "welcome-empty-demo"}, width = tk.textNarrow))
	}
	recentList := skald.col(..recent[:], spacing = tk.rowGap, cross_align = .Stretch, width = tk.dialogM)

	title := skald.col(
		uiText(th, .Title, APP_NAME),
		uiText(th, .Muted, fmt.tprintf("Version %s · a 2D game editor for the Crossfire Engine", EDITOR_VERSION)),
		spacing = tk.xxs,
	)
	header: skald.View = title
	if !s.welcome.noProject {
		back := skald.button(ctx, fmt.tprintf("%s  Back to %s", ACTION_ICONS[.Back], s.project.name), Msg(Welcome_Closed{}),
			id = skald.hash_id("welcome-back"), bg = th.color.surface, fg = th.color.fg, padding = tk.buttonPadding, font_size = th.font.size_sm)
		header = skald.row(title, skald.flex(1, skald.spacer(0)), back, cross_align = .Start)
	}
	// Side by side when there's room, else the recent list under Start (a tiled window)
	body: skald.View
	if size.x < tk.fieldXL + tk.dialogM + tk.xl * 4 {
		body = skald.col(start, recentList, spacing = tk.l, cross_align = .Stretch)
	} else {
		body = skald.row(start, recentList, spacing = tk.xl * 2, cross_align = .Start)
	}
	content := skald.col(header, body, spacing = tk.l, padding = tk.xl, cross_align = .Stretch)
	return skald.zone(ctx, skald.col(
		skald.flex(1, skald.scroll(ctx, {0, 0}, content, id = skald.hash_id("welcome-scroll"))),
		cross_align = .Stretch,
		bg = th.color.bg,
	), skald.hash_id("welcome-screen"))
}
