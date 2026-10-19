package editor

import "core:fmt"
import "core:log"
import "core:os"
import "core:strings"
import "gui:skald"

// Space taken by a split pane divider (Skald's default thickness)
DIVIDER :: 6

MIN_SIDEBAR_WIDTH  :: 180
MIN_CENTER_WIDTH   :: 200
MIN_VIEWPORT_HEIGHT :: 160
MIN_BOTTOM_HEIGHT  :: 90
MIN_SCENE_TREE_HEIGHT :: 120
MIN_INSPECTOR_HEIGHT  :: 160
MIN_BROWSER_TREE_HEIGHT :: 100
MIN_PREVIEW_HEIGHT :: 120

// Editing tool used by the viewport
Tool :: enum {
	Select,
	Move,
	Rotate,
	Scale,
}

PlayState :: enum {
	Stopped,
	// Building the player before the game can start
	Building,
	Playing,
	Paused,
}

BottomTab :: enum {
	Console,
	Output,
	Animation,
	// Mix buses (view_mixer.odin)
	Mixer,
	// Version control (view_git.odin)
	Git,
}

LogLevel :: enum {
	Info,
	Warning,
	Error,
}

// One line in the console panel
LogLine :: struct {
	level: LogLevel,
	text: string,
}

// Folders shown in the project browser
BrowserFolder :: enum {
	Scenes,
	Scripts,
	Images,
	Audio,
	// Music assets (streamed by MusicPlayers)
	Music,
	Fonts,
	// Data resources (project_data.odin)
	Data,
	// Saved node trees (component_edit.odin)
	Components,
	// LDtk projects (ldtk_edit.odin)
	Levels,
}

/*
Sizes of the resizable panels. Sidebars and the bottom panel keep their size when the window
is resized; the viewport takes whatever is left.
*/
Layout :: struct {
	leftWidth: f32,
	rightWidth: f32,
	bottomHeight: f32,
	// Height of the scene tree above the inspector in the right sidebar
	sceneTreeHeight: f32,
	// Preview panel at the bottom of the project browser
	previewOpen: bool,
	previewHeight: f32,
	// Space shared by the browser tree and preview, measured last frame
	browserBodyHeight: f32,
	bottomOpen: bool,
	// Size of the area between the toolbar and the status bar, measured last frame.
	// Needed to turn a dragged divider position into a sidebar or bottom panel size
	workspace: [2]f32,
}

/*
Sidebar widths that fit in the workspace. When the window is too narrow for the stored widths
plus a minimum-size viewport, both sidebars shrink in proportion (down to their minimum).
`view` and `update` both use this, so a dragged divider maps back to the same widths.

Inputs:
- layout: The panel layout, with `workspace` measured

Returns:
- The left and right sidebar widths to use this frame
*/
FittedSidebarWidths :: proc(layout: ^Layout) -> (left, right: f32) {
	left, right = layout.leftWidth, layout.rightWidth
	available := layout.workspace.x - DIVIDER * 2 - MIN_CENTER_WIDTH
	if layout.workspace.x > 0 && left + right > available {
		factor := max(available, 0) / (left + right)
		left = max(left * factor, MIN_SIDEBAR_WIDTH)
		right = max(right * factor, MIN_SIDEBAR_WIDTH)
	}
	return
}

/*
Bottom panel height that fits in the workspace, leaving the viewport its minimum height.

Inputs:
- layout: The panel layout, with `workspace` measured

Returns:
- The bottom panel height to use this frame
*/
FittedBottomHeight :: proc(layout: ^Layout) -> f32 {
	if layout.workspace.y <= 0 do return layout.bottomHeight
	return clamp(layout.bottomHeight, MIN_BOTTOM_HEIGHT, max(layout.workspace.y - DIVIDER - MIN_VIEWPORT_HEIGHT, MIN_BOTTOM_HEIGHT))
}

/*
The whole editor state. Only `update` changes it.
*/
State :: struct {
	project: Project,
	// Files open in the built-in code editor (absolute; owned), and the tab that shows: 1-based,
	// 0 = the scene (code_tabs.odin)
	codeTabs: [dynamic]string,
	codeTab: int,
	codeTickPending: bool,
	// The code editor should take the keyboard (a tab was opened or picked)
	codeFocusPending: bool,
	// The file dialog the code editor asked for, until it answers
	codeDialog: CodeDialog,
	// Settings > Toolchain is installing Odin
	toolchainInstalling: bool,
	// Project archives (project_archive.odin): one being written or unpacked; the archive Open
	// Project Archive picked, until its folder is chosen (owned)
	archive: struct {
		busy: bool,
		openPath: string,
	},
	// The Git tab (vcs.odin)
	git: GitState,
	// Closing a tab with unsaved changes: the prompt
	codeClose: struct {
		open: bool,
		index: int,
	},
	codeNoOLSLogged: bool,
	// Index of the scene open in the viewport
	currentScene: int,
	// Selected node in the current scene, -1 for none
	selectedNode: int,
	browserOpen: [BrowserFolder]bool,
	browserSelection: BrowserItem,
	// Project browser filter (owned; "" shows everything)
	browserSearch: string,
	// The remove-asset confirmation dialog
	removeConfirm: struct {
		open: bool,
		asset: int,
	},
	addNode: AddNodeDialog,
	// The Animation panel (view_animation.odin)
	animEditor: AnimEditor,
	// The Mixer tab: a bus name being typed (its index, the text; owned), kept until it's valid
	busEdit: struct {
		index: int,
		text: string,
	},
	// Inspector X/Y pairs whose axes change together
	inspectorLinks: [LinkedPair]bool,
	// The same for ParticleEmitter [2]f32 settings, by index in e.ParticleSettings_Fields
	particleLinks: bit_set[0 ..< 64],
	// The color ramp editor's selected stop, and whether its marker is being dragged
	rampStop: int,
	rampDragging: bool,
	// Text typed into the focused number field
	numberEdit: NumberEdit,
	// Every selected node of the open scene, sorted; `selectedNode` is the primary one (selection.odin)
	selection: [dynamic]int,
	// Set by code that chose a multi-selection this message (Selection_Set), so `update` keeps it
	selectionSet: bool,
	// The active settings (see settings.odin), and the file they're saved to ("" = don't save)
	settings: Settings,
	settingsPath: string,
	settingsDialog: SettingsDialog,
	history: History,
	// What the last build said about the project's scripts, and its script files (scripts.odin)
	scripts: ScriptCatalog,
	scriptFiles: [dynamic]string,
	// A background build of the scripts was requested once for this project
	scriptsAutoBuilt: bool,
	newScript: struct {
		open: bool,
		// Owned
		name: string,
		kind: ScriptKind,
	},
	// New Data Resource dialog: its name and data type (owned)
	newData: struct {
		open: bool,
		name: string,
		type: string,
	},
	// The data resource the inspector shows (index into project.data), -1 for none: chosen in
	// the browser, cleared when a node is selected
	dataSelection: int,
	session: SessionState,
	// Copied or cut nodes: one subtree, parents relative to the list (see node_edit.odin)
	clipboard: [dynamic]NodeDef,
	// Renaming a node in place in the scene tree (F2, double-click)
	rename: struct {
		active: bool,
		// What's renamed: a node of the open scene, or a scene (in the browser)
		target: RenameTarget,
		// The node's or scene's index
		node: int,
		// The edited name (owned)
		text: string,
		// The text field has been given focus; losing it afterwards commits
		focused: bool,
	},
	// After an inline rename, keyboard focus goes back to the tree it happened in (the view does
	// it, then sends Refocus_Done)
	refocus: RefocusTarget,
	// The project browser has keyboard focus: Delete, Ctrl+D/C/X/V and F2 act on its selected scene
	browserFocused: bool,
	// A copied scene (Copy, Cut), pasted with Paste in the browser
	sceneClipboard: SceneDef,
	hasSceneClipboard: bool,
	projectSettings: ProjectSettingsDialog,
	// A press on an image in the project browser, which becomes a drag into the viewport
	assetDrag: struct {
		pressed: bool,
		active: bool,
		asset: int,
		start: [2]f32,
	},
	// A press on a scene tree row, which becomes a drag once the mouse moves
	treeDrag: struct {
		pressed: bool,
		active: bool,
		node: int,
		start: [2]f32,
	},
	tool: Tool,
	viewport: ViewportState,
	playState: PlayState,
	bottomTab: BottomTab,
	layout: Layout,
	// Console tab: editor messages and the running game's output
	console: [dynamic]LogLine,
	// Output tab: build output
	output: [dynamic]LogLine,
	play: PlaySession,
	exporting: ExportSession,
}

// Project opened when no folder is given on the command line
DEMO_PROJECT :: "examples/demo_project"

init :: proc() -> State {
	state := State{
		currentScene = 0,
		selectedNode = -1,

		browserOpen = {.Scenes = true, .Scripts = true, .Images = true, .Audio = false, .Music = false, .Fonts = false, .Data = true, .Components = true, .Levels = true},
		browserSelection = {kind = .None},
		dataSelection = -1,
		viewport = {animate = true, gridVisible = true, showShapes = true},
		layout = {
			leftWidth = 240,
			rightWidth = 300,
			bottomHeight = 200,
			sceneTreeHeight = 280,
			bottomOpen = true,
			previewOpen = true,
			previewHeight = 220,
		},
	}
	args := parseArgs()
	settings, problems := Settings_Load(args.settings)
	state.settings = settings
	state.settingsPath = args.settings
	for problem in problems do logLine(&state, .Warning, fmt.aprintf("Settings: %s", problem))
	root := args.project
	project, message, warnings := Project_Load(root)
	if message == "" {
		state.project = project
		logLine(&state, .Info, fmt.aprintf("Opened '%s' from %s", project.name, root))
		for warning in warnings do logLine(&state, .Warning, strings.clone(warning))
	} else if root == Editor_DemoProject() {
		// First run: write the demo project so it can be played and edited
		state.project = Project_CreateDemo(root)
		if saveMessage := Project_Save(&state.project); saveMessage != "" {
			logLine(&state, .Error, fmt.aprintf("Couldn't create the demo project: %s", saveMessage))
		} else {
			logLine(&state, .Info, fmt.aprintf("Created the demo project in %s", root))
		}
	} else {
		// Don't write into a folder the user named; show the demo without saving it
		state.project = Project_CreateDemo(DEMO_PROJECT)
		logLine(&state, .Error, fmt.aprintf("%s. Showing the demo project instead", message))
	}
	// After the project is chosen: list its script files for the browser
	Scripts_Refresh(&state)
	return state
}

/*
Frees the editor state: the project and the console.

Inputs:
- state: The state to free
*/
State_Destroy :: proc(state: ^State) {
	CodeTabs_CloseAll(state)
	delete(state.codeTabs)
	Project_Destroy(&state.project)
	delete(state.archive.openPath)
	GitState_Destroy(&state.git)
	LDtkEdit_Destroy()
	for line in state.console do delete(line.text)
	delete(state.console)
	for line in state.output do delete(line.text)
	delete(state.output)
	delete(state.browserSearch)
	delete(state.addNode.search)
	Subtree_Destroy(&state.clipboard)
	delete(state.rename.text)
	if state.hasSceneClipboard do SceneDef_Destroy(&state.sceneClipboard)
	delete(state.projectSettings.name)
	delete(state.projectSettings.startScene)
	Editor_ForgetProcesses()
	delete(state.numberEdit.text)
	delete(state.session.newProject.name)
	delete(state.session.newProject.location)
	History_Destroy(&state.history)
	ScriptCatalog_Clear(&state.scripts)
	for f in state.scriptFiles do delete(f)
	delete(state.scriptFiles)
	delete(state.newScript.name)
	delete(state.newData.name)
	delete(state.newData.type)
	delete(state.selection)
	delete(state.settingsPath)
	delete(state.settingsDialog.search)
	delete(state.play.partial)
	ExportSession_Destroy(state)
}

// Appends a line to the console. text must be heap-allocated; the console owns it.
// echo also writes it to the editor's own log
logLine :: proc(state: ^State, level: LogLevel, text: string, echo := true) {
	append(&state.console, LogLine{level, text})
	if !echo do return
	switch level {
	case .Info:    log.info(text)
	case .Warning: log.warn(text)
	case .Error:   log.error(text)
	}
}

// Command line: odin_sdl_editor [project folder] [--script <file>] [--settings <file.ini>]
@(private="file")
Args :: struct {
	project: string,
	script: string,
	// The settings file: editor.ini next to the executable by default. Test scripts get "" (the
	// defaults, never saved) unless --settings names one, so they don't use or change yours
	settings: string,
}

@(private="file")
parseArgs :: proc() -> Args {
	args := Args{project = Editor_DemoProject()}
	settingsGiven := false
	for i := 1; i < len(os.args); i += 1 {
		if os.args[i] == "--script" && i + 1 < len(os.args) {
			args.script = Editor_ArgumentPath(os.args[i + 1])
			i += 1
		} else if os.args[i] == "--settings" && i + 1 < len(os.args) {
			args.settings = Editor_ArgumentPath(os.args[i + 1])
			settingsGiven = true
			i += 1
		} else if strings.has_prefix(os.args[i], "-psn_") {
			// Old macOS Finder launches add a process serial number: not a project
		} else {
			args.project = Editor_ArgumentPath(os.args[i])
		}
	}
	if !settingsGiven && args.script == "" do args.settings = Settings_DefaultPath()
	return args
}

// Build with -define:EDITOR_FULLSCREEN=true to open fullscreen, e.g. to check the full layout
// on a tiling window manager that would otherwise shrink the window
EDITOR_FULLSCREEN :: #config(EDITOR_FULLSCREEN, false)

main :: proc() {
	context.logger = log.create_console_logger(.Info)
	// From a macOS app bundle: a writable working folder, the bundled Vulkan (bundle.odin)
	Editor_SetupBundle()

	// A UI test script drives the editor through injected input (test_driver.odin)
	if script := parseArgs().script; script != "" {
		if !ScriptDriver_Load(script) do os.exit(1)
	}

	// The theme comes from the settings; init loads them again for the state (and reports problems)
	args := parseArgs()
	settings, _ := Settings_Load(args.settings)
	delete(args.settings)

	skald.run(skald.App(State, Msg){
		title  = "Odin SDL Editor",
		size   = {1440, 900},
		theme  = Settings_Theme(&settings),
		init   = init,
		update = update,
		view   = view,
		// The window's close button asks about unsaved changes, like File > Quit
		on_close_request = proc() -> Msg { return Msg(Action.Quit) },
		window_flags = EDITOR_FULLSCREEN ? {.RESIZABLE, .FULLSCREEN} : {},
	})

	if ScriptDriver_Active() || parseArgs().script != "" {
		os.exit(ScriptDriver_ExitCode())
	}
}
