package editor

import "core:fmt"
import "core:log"
import "core:os"
import "gui:skald"

// Space taken by a split pane divider (Skald's default thickness)
DIVIDER :: 6

// Row height of the browser and scene trees. Explicit so test scripts can click rows
TREE_ROW_HEIGHT :: 30

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
	Keys,
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
	Images,
	Audio,
	Fonts,
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
}

// Project opened when no folder is given on the command line
DEMO_PROJECT :: "examples/demo_project"

init :: proc() -> State {
	state := State{
		currentScene = 0,
		selectedNode = -1,

		browserOpen = {.Scenes = true, .Images = true, .Audio = false, .Fonts = false},
		browserSelection = {kind = .None},
		viewport = {animate = true},
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
	root := args.project
	project, message := Project_Load(root)
	if message == "" {
		state.project = project
		logLine(&state, .Info, fmt.aprintf("Opened '%s' from %s", project.name, root))
	} else if root == DEMO_PROJECT {
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
	return state
}

/*
Frees the editor state: the project and the console.

Inputs:
- state: The state to free
*/
State_Destroy :: proc(state: ^State) {
	Project_Destroy(&state.project)
	for line in state.console do delete(line.text)
	delete(state.console)
	for line in state.output do delete(line.text)
	delete(state.output)
	delete(state.browserSearch)
	delete(state.addNode.search)
	delete(state.play.partial)
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

// Command line: odin_sdl_editor [project folder] [--script <file>]
@(private="file")
Args :: struct {
	project: string,
	script: string,
}

@(private="file")
parseArgs :: proc() -> Args {
	args := Args{project = DEMO_PROJECT}
	for i := 1; i < len(os.args); i += 1 {
		if os.args[i] == "--script" && i + 1 < len(os.args) {
			args.script = os.args[i + 1]
			i += 1
		} else {
			args.project = os.args[i]
		}
	}
	return args
}

// Build with -define:EDITOR_FULLSCREEN=true to open fullscreen, e.g. to check the full layout
// on a tiling window manager that would otherwise shrink the window
EDITOR_FULLSCREEN :: #config(EDITOR_FULLSCREEN, false)

main :: proc() {
	context.logger = log.create_console_logger(.Info)

	// A UI test script drives the editor through injected input (test_driver.odin)
	if script := parseArgs().script; script != "" {
		if !ScriptDriver_Load(script) do os.exit(1)
	}

	skald.run(skald.App(State, Msg){
		title  = "Odin SDL Editor",
		size   = {1440, 900},
		theme  = skald.theme_dark(),
		init   = init,
		update = update,
		view   = view,
		window_flags = EDITOR_FULLSCREEN ? {.RESIZABLE, .FULLSCREEN} : {},
	})

	if ScriptDriver_Active() || parseArgs().script != "" {
		os.exit(ScriptDriver_ExitCode())
	}
}
