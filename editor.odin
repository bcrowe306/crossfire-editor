package crossfire_editor

import "core:fmt"
import "core:log"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"
import "gui:skald"
import sdl "vendor:sdl3"

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
	// Move, rotate and scale handles at once
	Transform,
	// A click zooms in where it is (Alt: out), a drag zooms to the box
	Zoom,
	// Left drags pan the view (like Space + drag)
	Pan,
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
	// Painting the selected TileMap (view_tiles.odin)
	Tiles,
	// An Animator's keyframe clips (view_timeline.odin)
	Timeline,
	// The game running from Play, as it plays (view_live.odin)
	Live,
	// A StateMachine's graph (view_states.odin)
	States,
	// The shown ParticleEmitter's settings by category (view_particles.odin)
	Particles,
	// A dialogue's nodes and steps (view_dialogue.odin)
	Dialogue,
	// The project's editor plugins (view_plugins.odin)
	Plugins,
	// The Level mode's LDtk tab (level_mode.odin; not the Scene mode's)
	LDtk,
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
	// Translation tables (the engine's localization.odin)
	Translations,
	// Animation assets (animation_sets_edit.odin)
	Animations,
	// UI themes (theme_edit.odin)
	Themes,
	// Shaders (shader_edit.odin)
	Shaders,
	// Physics materials (material_edit.odin)
	Materials,
	// Texture atlases (atlas_edit.odin)
	Atlases,
	// Dialogues (dialogue_edit.odin)
	Dialogues,
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
Scene tree height that fits in the right sidebar, leaving the inspector its minimum height: in a
short window (900x500) the stored 280 px left the inspector about 100.

Inputs:
- layout: The panel layout, with `workspace` measured

Returns:
- The scene tree's height to use this frame
*/
FittedSceneTreeHeight :: proc(layout: ^Layout) -> f32 {
	if layout.workspace.y <= 0 do return layout.sceneTreeHeight
	return clamp(layout.sceneTreeHeight, MIN_SCENE_TREE_HEIGHT, max(layout.workspace.y - DIVIDER - MIN_INSPECTOR_HEIGHT, MIN_SCENE_TREE_HEIGHT))
}

/*
Browser preview height that fits under the browser's tree: at most half the space they share, so
a short window (900x500) keeps more than four rows of the tree.

Inputs:
- layout: The panel layout
- body: The height the tree and the preview share

Returns:
- The preview's height to use this frame
*/
FittedPreviewHeight :: proc(layout: ^Layout, body: f32) -> f32 {
	fit := max(min(body - MIN_BROWSER_TREE_HEIGHT - DIVIDER, (body - DIVIDER) / 2), MIN_PREVIEW_HEIGHT)
	return clamp(layout.previewHeight, MIN_PREVIEW_HEIGHT, fit)
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
	// Emscripten is being installed (Toolchain_InstallEmscripten); the exports waiting for it
	emscriptenInstalling: bool,
	exportAfterEmscripten: bit_set[ExportTarget],
	// Project archives (project_archive.odin): one being written or unpacked; the archive Open
	// Project Archive picked, until its folder is chosen (owned)
	archive: struct {
		busy: bool,
		openPath: string,
		// The archive being written keeps `.git/` (Export Project Archive with History)
		includeGit: bool,
	},
	// The Git tab (vcs.odin)
	git: GitState,
	// Closing a tab with unsaved changes: the prompt
	// Closing a component's tab with unsaved changes asks (view_project_dialogs.odin): which one
	componentClose: struct {
		open: bool,
		scene: int,
	},
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
	// Help > About (view_about.odin)
	aboutOpen: bool,
	// The docs window (docs_window.odin)
	docs: DocsWindow,
	// The Animation panel (view_animation.odin)
	animEditor: AnimEditor,
	// The sprite sheet slicer's tabs (slicer_edit.odin)
	slicer: SlicerState,
	// The Tiles panel: the brush, tool and layer painted (tile_paint.odin)
	tilePainter: TilePainter,
	// The Timeline tab: the Animator it edits, the playhead (timeline_edit.odin)
	timeline: TimelineEditor,
	// The running game, as the Live tab shows it (live_edit.odin)
	live: LiveView,
	// The States tab: the StateMachine it shows, its selection (state_machine_edit.odin)
	states: StatesEditor,
	// The Particles tab: the ParticleEmitter it shows, its category (particles_edit.odin)
	particles: ParticlesEditor,
	// The Mixer tab: a bus name being typed (its index, the text; owned), kept until it's valid
	busEdit: struct {
		index: int,
		text: string,
	},
	// Inspector X/Y pairs whose axes change together
	inspectorLinks: [LinkedPair]bool,
	// The same for ParticleEmitter [2]f32 settings, by index in e.ParticleSettings_Fields
	particleLinks: bit_set[0 ..< 64],
	// The color ramp editor's selected stop, and the bar whose marker is being dragged (0: none;
	// the inspector's and the Particles tab's bars can both show)
	rampStop: int,
	rampDrag: skald.Widget_ID,
	// Text typed into the focused number field
	numberEdit: NumberEdit,
	// Every selected node of the open scene, sorted; `selectedNode` is the primary one (selection.odin)
	selection: [dynamic]int,
	// Set by code that chose a multi-selection this message (Selection_Set), so `update` keeps it
	selectionSet: bool,
	// The active settings (see settings.odin), and the file they're saved to ("" = don't save)
	settings: Settings,
	settingsPath: string,
	// The projects opened lately, for the File menu (recent_projects.odin)
	recentProjects: RecentProjects,
	settingsDialog: SettingsDialog,
	history: History,
	// What the last build said about the project's scripts, and its script files (scripts.odin)
	scripts: ScriptCatalog,
	// The script index (script_index.odin): the scripts' declarations read from their source,
	// merged into `scripts` where the source is newer than the build
	scriptIndex: ScriptIndex,
	// The newest script source when the last build started (the index compares files with it)
	scriptsBuildSource: time.Time,
	scriptFiles: [dynamic]string,
	// A background build of the scripts was requested once for this project
	scriptsAutoBuilt: bool,
	// The inspector's Listen... dialog (node_listeners.odin) and whether its Events section is open
	listenerDialog: ListenerDialog,
	inspectorEventsOpen: bool,
	// The Color dialog a code tab's swatch opened (code_colors.odin)
	codeColor: CodeColorDialog,
	// The Range dialog a code action opened (code_actions.odin)
	codeRange: CodeRangeDialog,
	// The project's log points and their dialog (log_points.odin)
	logPoints: LogPoints,
	// The last link opened in the browser (Links_Open; owned): the UI tests read it
	lastLink: string,
	// The LDtkLevel inspector's list of the level's entities is shown
	ldtkInstancesOpen: bool,
	// The New Event dialog (new_event.odin)
	newEvent: NewEventDialog,
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
	// The theme the inspector shows (an index into project.themes; -1 none), chosen in the browser
	themeSelection: int,
	// The physics material the inspector shows (an index into project.materials; -1 none)
	materialSelection: int,
	// The atlas the inspector shows (atlas_edit.odin; -1 none): the browser selected it
	atlasSelection: int,
	// The Dialogue tab's dialogue and selection (dialogue_edit.odin)
	dialogue: DialogueEditor,
	// Plugins_Tick is scheduled (plugin_host.odin: while the project has a plugins/ folder)
	pluginsTicking: bool,
	// Collision from sprite's settings (collision_trace_edit.odin; view state)
	trace: TraceSettings,
	// The bus the inspector shows the effects of (an index into project.buses; -1 none), opened
	// from the Mixer (bus_effects_edit.odin)
	busSelection: int,
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
	// The open right-click menu (context_menus.odin)
	contextMenu: ContextMenu,
	// A press on an image in the project browser, which becomes a drag into the viewport
	assetDrag: struct {
		pressed: bool,
		active: bool,
		asset: int,
		start: [2]f32,
	},
	// A drag into a code tab of anything else (code_drag.odin)
	codeDrag: CodeDrag,
	// A press on a scene tree row, which becomes a drag once the mouse moves
	treeDrag: struct {
		pressed: bool,
		active: bool,
		node: int,
		start: [2]f32,
	},
	// The editor mode that shows (editor_modes.odin), and the Level mode's own state (level_mode.odin)
	mode: EditorMode,
	level: LevelMode,
	tool: Tool,
	viewport: ViewportState,
	playState: PlayState,
	// The Scene mode's bottom tab and panel sizes (the Level mode's are in `level`: Mode_Layout)
	bottomTab: BottomTab,
	layout: Layout,
	// Console tab: editor messages and the running game's output, with its filters (console.odin)
	console: LogList,
	// Output tab: build and export output
	output: LogList,
	play: PlaySession,
	// A Play_Tick is on its way (`playPoll`): one chain of ticks however often Play starts, so a
	// Restart (a stop and a start in one message) doesn't leave two
	playTickPending: bool,
	exporting: ExportSession,
}

// Project opened when no folder is given on the command line
DEMO_PROJECT :: "examples/demo_project"

init :: proc() -> State {
	state := State{
		currentScene = 0,
		selectedNode = -1,
		timeline = {node = -1, track = -1, key = -1},
		states = {node = -1, state = -1, transition = -1},

		browserOpen = {.Scenes = true, .Scripts = true, .Images = true, .Audio = false, .Music = false, .Fonts = false, .Data = true, .Components = true, .Levels = true, .Translations = true, .Animations = true, .Themes = true, .Materials = true, .Shaders = true, .Atlases = true, .Dialogues = true},
		browserSelection = {kind = .None},
		dataSelection = -1,
		themeSelection = -1,
		materialSelection = -1,
		atlasSelection = -1,
		trace = DEFAULT_TRACE_SETTINGS,
		busSelection = -1,
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
		level = {layout = LEVEL_LAYOUT_DEFAULT, bottomTab = .LDtk},
	}
	args := parseArgs()
	settings, problems := Settings_Load(args.settings)
	// The previews' sound device (Settings > Editor), opened with the first preview
	AudioPreview_SetDevice(FixedText_String(&settings.audioDevice))
	state.settings = settings
	state.settingsPath = args.settings
	state.recentProjects = Recent_Load(args.settings)
	for problem in problems do logLine(&state, .Warning, fmt.aprintf("Settings: %s", problem))
	root := args.project
	// An archive given instead of a folder: unpacked next to it, then opened
	if ProjectArchive_IsArchivePath(root) {
		if unpacked, problem := ProjectArchive_ExtractArgument(root); problem == "" {
			logLine(&state, .Info, fmt.aprintf("Unpacked %s into %s", root, unpacked))
			root = unpacked
		} else {
			logLine(&state, .Error, fmt.aprintf("Couldn't open the archive %s: %s", root, problem))
		}
	}
	project, message, warnings := Project_Load(root)
	if message == "" {
		state.project = project
		logLine(&state, .Info, fmt.aprintf("Opened '%s' from %s", project.name, root))
		for warning in warnings do logLine(&state, .Warning, strings.clone(warning))
	} else if root == Editor_DemoProject() {
		// First run: the demo shipped with the editor (a bundle's), copied where it can be edited
		copied := false
		if shipped := Editor_ShippedDemo(); shipped != "" {
			if problem := Folder_Copy(shipped, root); problem != "" {
				logLine(&state, .Error, fmt.aprintf("Couldn't copy the demo project: %s", problem))
			} else if demo, demoMessage, demoWarnings := Project_Load(root); demoMessage == "" {
				state.project = demo
				copied = true
				logLine(&state, .Info, fmt.aprintf("Copied the demo project to %s", root))
				for warning in demoWarnings do logLine(&state, .Warning, strings.clone(warning))
			}
		}
		// Without one: write the built-in sample so there's something to play and edit
		if !copied {
			state.project = Project_CreateDemo(root)
			if saveMessage := Project_Save(&state.project); saveMessage != "" {
				logLine(&state, .Error, fmt.aprintf("Couldn't create the demo project: %s", saveMessage))
			} else {
				logLine(&state, .Info, fmt.aprintf("Created the demo project in %s", root))
			}
		}
	} else {
		// Don't write into a folder the user named; show the demo without saving it
		state.project = Project_CreateDemo(DEMO_PROJECT)
		logLine(&state, .Error, fmt.aprintf("%s. Showing the demo project instead", message))
	}
	// After the project is chosen: list its script files for the browser
	Scripts_Refresh(&state)
	if message == "" do Recent_Add(&state.recentProjects, state.project.rootPath)
	// The mode the project was left in (editor_modes.odin)
	Mode_Load(&state)
	return state
}

/*
Frees the editor state: the project and the console.

Inputs:
- state: The state to free
*/
State_Destroy :: proc(state: ^State) {
	CodeDrag_Clear(state)
	CodeColorDialog_Destroy(&state.codeColor)
	CodeRangeDialog_Destroy(&state.codeRange)
	LogPoints_Destroy(&state.logPoints)
	DocsWindow_Destroy(&state.docs)
	LevelMode_Destroy(&state.level)
	delete(state.lastLink)
	CodeTabs_CloseAll(state)
	delete(state.codeTabs)
	Project_Destroy(&state.project)
	delete(state.archive.openPath)
	GitState_Destroy(&state.git)
	LDtkEdit_Destroy()
	LDtkDoc_DestroyAll()
	LevelCanvas_Destroy()
	AsepriteEdit_Destroy()
	TilePainter_Destroy(&state.tilePainter)
	TimelineEditor_Destroy(&state.timeline)
	Live_Reset(&state.live)
	LogList_Destroy(&state.console)
	LogList_Destroy(&state.output)
	delete(state.browserSearch)
	delete(state.addNode.search)
	Subtree_Destroy(&state.clipboard)
	delete(state.rename.text)
	if state.hasSceneClipboard do SceneDef_Destroy(&state.sceneClipboard)
	ProjectSettings_Destroy(&state.projectSettings)
	delete(state.animEditor.nameText)
	delete(state.animEditor.asset)
	SlicerState_Destroy(&state.slicer)
	Editor_ForgetProcesses()
	delete(state.numberEdit.text)
	delete(state.session.newProject.name)
	delete(state.session.newProject.location)
	delete(state.session.recent)
	History_Destroy(&state.history)
	ScriptCatalog_Clear(&state.scripts)
	ScriptIndex_Destroy(&state.scriptIndex)
	for f in state.scriptFiles do delete(f)
	delete(state.scriptFiles)
	delete(state.dialogue.path)
	delete(state.newScript.name)
	delete(state.listenerDialog.event)
	NewEventDialog_Destroy(&state.newEvent)
	delete(state.newData.name)
	delete(state.newData.type)
	delete(state.selection)
	delete(state.settingsPath)
	Recent_Destroy(&state.recentProjects)
	delete(state.settingsDialog.search)
	delete(state.play.partial)
	ExportSession_Destroy(state)
}

// Appends a line to the console, in `category` (the editor's own by default), dropping the oldest
// past Settings' limit. text must be heap-allocated; the console owns it. echo also writes it to
// the editor's own log
logLine :: proc(state: ^State, level: LogLevel, text: string, echo := true, category := LOG_EDITOR_CATEGORY) {
	LogList_Append(&state.console, level, category, text, state.settings.consoleLimit)
	if !echo do return
	switch level {
	case .Debug:   log.debug(text)
	case .Info:    log.info(text)
	case .Warning: log.warn(text)
	case .Error:   log.error(text)
	}
}

// Command line: crossfire-editor [project folder] [--export <target>] [--script <file>] [--settings <file.ini>]
// [--window-size <width>x<height>]
@(private="file")
Args :: struct {
	project: string,
	script: string,
	// The settings file: editor.ini next to the executable by default. Test scripts get "" (the
	// defaults, never saved) unless --settings names one, so they don't use or change yours
	settings: string,
	// --export <target>: export the project to that target without a window, then exit
	// (Export_Headless: CI, scripts)
	export: string,
	// --window-size <w>x<h>: open a window of this size (logical pixels), never fullscreen. The UI
	// tests' headless runs use it (tools/ui_tests.sh: 640x660 like a tiled window, 1280x720 like
	// a fullscreen one), where nothing resizes the window
	windowSize: skald.Size,
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
		} else if os.args[i] == "--window-size" && i + 1 < len(os.args) {
			w, _, h := strings.partition(os.args[i + 1], "x")
			width, _ := strconv.parse_int(w)
			height, _ := strconv.parse_int(h)
			args.windowSize = {i32(width), i32(height)}
			i += 1
		} else if os.args[i] == "--export" && i + 1 < len(os.args) {
			args.export = os.args[i + 1]
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
	// The app's name and ID (Linux desktops match the window to its .desktop entry by it)
	Branding_SetAppMetadata()

	// A headless export: no window (export_run.odin)
	if exportArgs := parseArgs(); exportArgs.export != "" {
		os.exit(Export_Headless(exportArgs.project, exportArgs.export, exportArgs.settings))
	}

	// A UI test script drives the editor through injected input (test_driver.odin)
	if script := parseArgs().script; script != "" {
		if !ScriptDriver_Load(script) do os.exit(1)
	}

	// The theme comes from the settings; init loads them again for the state (and reports problems)
	args := parseArgs()
	settings, _ := Settings_Load(args.settings)
	delete(args.settings)
	// A fixed size (--window-size) replaces fullscreen
	windowFlags: sdl.WindowFlags = EDITOR_FULLSCREEN ? {.RESIZABLE, .FULLSCREEN} : {}
	if args.windowSize.x > 0 && args.windowSize.y > 0 do windowFlags = {.RESIZABLE}

	// A Spall trace with SPALL (profiling.odin); stopped below, before any exit
	Profiling_Start()
	skald.run(skald.App(State, Msg){
		title  = APP_NAME,
		size   = {1440, 900},
		theme  = Settings_Theme(&settings),
		init   = init,
		update = update,
		view   = view,
		// The window's close button asks about unsaved changes, like File > Quit
		on_close_request = proc() -> Msg { return Msg(Action.Quit) },
		// Before Skald destroys its GPU device: what was made on it (gpu_share.odin)
		on_shutdown = proc() {
			// Plugins' libraries and a build in progress (plugin_host.odin)
			Plugins_Unload()
			Preview_Destroy()
			CodeEditor_Shutdown()
			SharedGPU_Shutdown()
		},
		initial_window_state = {size = args.windowSize},
		window_flags = windowFlags,
	})
	Profiling_Stop()

	if ScriptDriver_Active() || parseArgs().script != "" {
		os.exit(ScriptDriver_ExitCode())
	}
}
