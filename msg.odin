package crossfire_editor

import e "engine:."
import "gui:skald"
import sdl "vendor:sdl3"

/*
Commands triggered from the menu bar, toolbar and keyboard shortcuts. Default keys are in
keymap.odin.
*/
Action :: enum {
	New_Project,
	Open_Project,
	Save_Project,
	// A copy of the project in another folder, then opened (project_session.odin)
	Save_Project_As,
	Export,
	// The whole project in one file, and opening one (project_archive.odin)
	Export_Project_Archive,
	Export_Project_Archive_With_History,
	Open_Project_Archive,
	Quit,
	Undo,
	Redo,
	Add_Node,
	Delete_Node,
	Duplicate_Node,
	Copy_Node,
	Cut_Node,
	Paste_Node,
	Rename_Node,
	// The selected node and its subtree become a component (component_edit.odin)
	Save_As_Component,
	// The selected node's script: New Script for it when it has none, else open it
	Add_Script,
	// Play from the scene open in the viewport instead of the start scene
	Play_Scene,
	Open_Project_Settings,
	Select_All,
	Toggle_Grid,
	Toggle_Snap,
	// Outline collision shapes, rays and joints in the viewport
	Toggle_Collision_Shapes,
	// Shows the viewport unlit (a lit scene's darkness hides what's being edited)
	Toggle_Lighting,
	// The project's development setting: the game draws its physics shapes (never in exports)
	Toggle_Physics_Debug,
	Play,
	Pause,
	Stop,
	// Stop the game and play it again as it was started (Play or Play Scene), rebuilt if needed
	Restart,
	Toggle_Bottom_Panel,
	Clear_Console,
	About,
	// Help > User Manual: the manual's contents in the browser (docs/manual)
	User_Manual,

	// Viewport tools
	Tool_Select,
	Tool_Move,
	Tool_Rotate,
	Tool_Scale,
	Tool_Pan,
	Tool_Transform,
	Tool_Zoom,
	Toggle_Local_Axes,
	Toggle_Guides,
	// Viewport navigation
	Frame_Selected,
	View_Fit,
	Zoom_In,
	Zoom_Out,
	Zoom_100,
	Toggle_Animation,
	// Selection
	Deselect,
	Nudge_Left,
	Nudge_Right,
	Nudge_Up,
	Nudge_Down,
	Nudge_Left_Large,
	Nudge_Right_Large,
	Nudge_Up_Large,
	Nudge_Down_Large,

	// Project browser
	Import_Asset,
	Remove_Asset,
	Toggle_Preview_Panel,
	Play_Audio_Preview,
	Stop_Audio_Preview,

	Open_Settings,
	Build_Scripts,
	// Open the selected node's script in the code editor
	Open_Script,
	// Close the code tab that shows (code_tabs.odin)
	Close_Code_Tab,
}

// Panel resizing. Each carries the new size of a split's first pane
Left_Resized       :: distinct f32
Center_Resized     :: distinct f32
Viewport_Resized   :: distinct f32
Scene_Tree_Resized :: distinct f32
// Sent by the layout when the workspace size changes
Workspace_Measured :: distinct [2]f32

// The Console's (output: the Output tab's) Follow toggle in its header: keep the newest line in view
Log_Follow_Toggled :: struct {
	output: bool,
}
// The view saw the list scrolled up (follow false) or back to its end (true)
Log_Follow_Set :: struct {
	output: bool,
	follow: bool,
}
// A level's toggle in the header: show or hide its lines
Log_Level_Toggled :: struct {
	output: bool,
	level: LogLevel,
}
// A category picked in the header's category menu: show or hide its lines (the menu stays open)
Log_Category_Toggled :: struct {
	output: bool,
	// Index into the list's `categories`
	category: int,
}
// Show every category again
Log_Categories_Shown :: struct {
	output: bool,
}
// The header's search box: only lines containing the text, any case (the string is the frame's)
Log_Search_Changed :: struct {
	output: bool,
	text: string,
}
// Every filter off: all levels, all categories, no search
Log_Filters_Cleared :: struct {
	output: bool,
}
// The test driver's `console_fill`: count lines added to the Console, as a running game's would
// ("<category> line <serial>"; the category string is the frame's)
Log_Test_Lines :: struct {
	count: int,
	level: LogLevel,
	category: string,
}

Bottom_Tab_Changed :: distinct int
Scene_Tab_Changed  :: distinct int
// A scene tab's × (by tab index, as Scene_Tab_Changed): the tab hides, the scene stays
Scene_Tab_Closed :: distinct int
Tool_Selected      :: distinct Tool

// Project browser: row index in the browser tree
Browser_Toggled  :: distinct int
Browser_Selected :: distinct int

// Scene tree: row index in the scene tree
Node_Toggled  :: distinct int
Node_Selected :: distinct int
// Viewport click: node index in the scene, -1 for empty space
Node_Picked   :: distinct int
// Ctrl+click (toggle) or Shift+click (add) on a node in the viewport: node index
Node_Pick_Toggled :: distinct int
Node_Pick_Added   :: distinct int
// A click on a node that's already part of a multi-selection: it becomes the primary one and the
// selection stays (so dragging moves them all)
Node_Primary_Picked :: distinct int
// Scene tree Ctrl+click (toggle) or Shift+click (range from the primary node): row index
Tree_Selection_Clicked :: struct {
	row: int,
	range: bool,
}

// Scene tree right-click (before its context menu opens): row index, -1 below the rows
Node_Right_Clicked :: distinct int
// Scene tree drag: the left button went down on a node's row
Tree_Drag_Pressed :: struct {
	node: int,
	start: [2]f32,
}
// The mouse moved far enough with the button down: it's a drag, not a click
Tree_Drag_Started :: struct {}
// Released over a place the node can go
Tree_Drag_Dropped :: struct {
	target: int,
	position: DropPosition,
}
// Released anywhere else
Tree_Drag_Cancelled :: struct {}
// A browser asset released over the code tab: a field of its handle type goes into the script (asset_fields.odin)
Asset_Dropped_On_Code :: struct {
	// Where it was dropped (window coordinates)
	mouse: [2]f32,
}
// Released over the code tab: a node field for the dragged node goes into its script (node_fields.odin)
Tree_Drag_Dropped_On_Code :: struct {
	// Where it was dropped (window coordinates)
	mouse: [2]f32,
}

// Scene management in the project browser (project_scenes.odin)
SceneOp :: enum {
	New,
	Open,
	Play,
	Rename,
	Duplicate,
	Copy,
	Cut,
	Paste,
	Delete,
	Set_Start,
}
Scene_Action :: struct {
	op: SceneOp,
	// The scene, or -1 (New and Paste then add at the end)
	scene: int,
}
// The browser's scene preview: one of a scene's own settings (scene_settings.odin)
Scene_Screen_Layer_Toggled :: struct {
	scene: int,
	layer: e.RenderLayer,
}
// Its own background color on or off, or the color changed (`fromProject`: start from the project's)
Scene_Background_Changed :: struct {
	scene: int,
	on: bool,
	color: sdl.Color,
	fromProject: bool,
}
Scene_Gravity_Toggled :: struct {
	scene: int,
	on: bool,
}
Scene_Gravity_Changed :: struct {
	scene: int,
	axis: int,
	value: f64,
}
// The inspector's Events section (view_inspector_events.odin): Listen... on a node's event
Listener_Dialog_Opened :: struct {
	node: int,
	// Only valid while handling the message
	event: string,
}
Listener_Dialog_Cancelled :: struct {}
// The dialog's choice: the node (in the open scene) whose script listens
Listener_Target_Chosen :: distinct int
// × on a listener: the node and the listener's index
Listener_Removed :: struct {
	node, index: int,
}
Inspector_Events_Toggled :: struct {}
// The LDtkLevel inspector: its entity list shown or hidden; an entity clicked (centers the viewport
// on its world position)
LDtk_Instances_Toggled :: struct {}
LDtk_Entity_Framed :: distinct [2]f32
// The Events section's Globals: the node's script listens to a global's event (strings only
// valid while handling the message)
Global_Listen_Requested :: struct {
	node: int,
	global: string,
	event: string,
}
// The New Event dialog (new_event.odin): opened for a script; its fields; Create; Cancel
New_Event_Opened :: distinct string
New_Event_Name_Changed :: distinct string
New_Event_Description_Changed :: distinct string
New_Event_Kind_Changed :: distinct EventDataKind
New_Event_Created :: struct {}
New_Event_Cancelled :: struct {}
// The script preview's list of nodes using it: open that scene (or component) and select the node
Script_Usage_Clicked :: struct {
	scene, node: int,
}
// The browser gained or lost keyboard focus
Browser_Focus_Changed :: distinct bool
// A right-click on a browser row (before its context menu opens): row index, -1 below the rows
Browser_Right_Clicked :: distinct int

RefocusTarget :: enum {
	None,
	Browser,
	Scene_Tree,
}
Refocus_Done :: struct {}

// What an inline rename is for
RenameTarget :: enum {
	Node,
	Scene,
	// A component, in the browser (`node` is its asset's index)
	Component,
}

// Project Settings dialog (view_project_settings.odin)
Project_Settings_Name_Changed :: distinct string
Project_Settings_Scale_Changed :: distinct string
// The renderer the game draws with (Project Settings > General)
Project_Settings_Renderer_Changed :: distinct e.RenderBackend
// Project Settings > General > Image filtering (asset_import_edit.odin)
Project_Settings_Texture_Filter_Changed :: distinct e.TextureFilter
Project_Settings_Background_Changed :: distinct skald.Color
Project_Settings_Start_Changed :: distinct string
// The language the game starts in (a translation table's, like "fr"; "" for the player's)
Project_Settings_Locale_Changed :: distinct string
// The game window's icon (an image asset's path; TEXTURE_NONE for the engine's)
Project_Settings_Icon_Changed :: distinct string
Project_Settings_Size_Changed :: struct {
	axis: int,
	value: f64,
}
Project_Settings_Physics_Changed :: struct {
	field: PhysicsTarget,
	value: f64,
}
Project_Settings_Physics_Debug_Changed :: distinct bool
// Project Settings > General: the sound output's sample rate, or (channels) its channel count; 0 = the device's
Project_Settings_Audio_Changed :: struct {
	channels: bool,
	value: int,
}
// Project Settings > Grid: one of the grid's numbers
Project_Settings_Grid_Changed :: struct {
	field: GridTarget,
	value: f64,
}
Project_Settings_Physics_Smoothing_Changed :: distinct bool
// Project Settings > General: one of the window's settings (the engine's WindowSettings)
WindowField :: enum {
	Fullscreen,
	VSync,
	High_DPI,
}
Project_Settings_Window_Changed :: struct {
	field: WindowField,
	value: bool,
}
// Project Settings > Globals: add a script as a global, remove / move / show one (by index)
// New Data Resource dialog (view_project_dialogs.odin)
New_Script_Kind_Changed :: distinct ScriptKind
New_Data_Opened :: struct {}
New_Data_Name_Changed :: distinct string
New_Data_Type_Changed :: distinct string
New_Data_Created :: struct {}
New_Data_Cancelled :: struct {}
Global_Added :: distinct string
Global_Removed :: distinct int
Global_Selected :: distinct int
Global_Moved :: struct {
	index: int,
	delta: int,
}
Project_Settings_Applied :: struct {}
Project_Settings_Cancelled :: struct {}
Project_Settings_Tab_Changed :: distinct ProjectSettingsTab
// Export tab: the target whose settings are shown
Export_Target_Selected :: distinct ExportTarget
Export_Target_Enabled :: struct {
	target: ExportTarget,
	value: bool,
}
Export_Text_Changed :: struct {
	target: ExportTarget,
	field: ExportField,
	text: string,
}
Export_Flag_Changed :: struct {
	target: ExportTarget,
	field: ExportField,
	value: bool,
}
// The Export tab's Export button: apply the dialog, then export this target
Export_Target_Run :: distinct ExportTarget
Export_Cancel_Requested :: struct {}
// Export these targets (sent after Export_Target_Run's undo step, so the save comes after it)
Export_Requested :: distinct bit_set[ExportTarget]

// Renaming a node in the scene tree
Rename_Started :: distinct int
Rename_Text_Changed :: distinct string
Rename_Focused :: struct {}
// Enter, or the field lost focus
Rename_Committed :: struct {
	// Enter (focus goes back to the tree), rather than the field losing focus to a click elsewhere
	byKey: bool,
}
// Escape
Rename_Cancelled :: struct {}
// Keeps frames coming (auto-scrolling while the mouse is held still)
Frame_Requested :: struct {}
// The About dialog closed
About_Closed :: struct {}
// What the open scene draws, as a world rectangle {x, y, w, h}, once its preview is built (the
// view sends it while `viewport.fitContent` is set)
Viewport_Content_Measured :: distinct [4]f32

// Project session (project_session.odin)
ConfirmChoice :: enum {
	Save,
	Discard,
	Cancel,
}
// The "save changes?" prompt's answer
Confirm_Chosen :: distinct ConfirmChoice

// Code tabs (code_tabs.odin): show / close a tab (by index), the unsaved-changes answer
Code_Tab_Selected :: distinct int
Code_Tab_Close_Requested :: distinct int
Code_Close_Chosen :: distinct ConfirmChoice
// The close prompt of a component's tab with unsaved changes: save it, throw them away, cancel
Component_Close_Chosen :: distinct ConfirmChoice
// The open file asks for another (Go to Definition): 0-based line and character (owned by the frame)
Code_Open_Requested :: struct {
	path: string,
	line, character: int,
}
// The language server's rename changed other files (`ce.editor_take_file_edits`): apply them in
// their code tabs (opened hidden), one undo step each. Edits are UTF-16 ranges by path (for the frame)
Code_File_Edits_Requested :: struct {
	paths: []string,
	edits: [][]CodeFileEdit,
}
// One edit of Code_File_Edits_Requested: 0-based lines, UTF-16 columns
CodeFileEdit :: struct {
	startLine, startCharacter, endLine, endCharacter: int,
	text: string,
}
// Save the script that shows
Code_Save_Requested :: struct {}
// Keep frames coming while a language server may answer (and to look at the file on disk)
Code_Tick_Requested :: struct {
	seconds: f32,
}
// The shown file changed on disk and was read again (path: the frame's)
Code_Reloaded :: struct {
	path: string,
}
// The code editor asked for a file dialog (Ctrl+O, Ctrl+Shift+S), and its answer
CodeDialog :: enum {
	None,
	Open,
	Save_As,
}
Code_Dialog_Requested :: distinct CodeDialog
Code_Dialog_Picked :: distinct skald.File_Dialog_Result
// The bar's answer when the file changed on disk under unsaved changes: true reloads it
Code_Disk_Chosen :: distinct bool
Code_Tick :: struct {}
// The code editor took the keyboard focus a tab asked for
Code_Focused :: struct {}
New_Project_Name_Changed :: distinct string
New_Project_Location_Changed :: distinct string
New_Project_Browse :: struct {}
// The folder dialog closed (path is only valid while handling the message)
New_Project_Location_Chosen :: distinct skald.File_Dialog_Result
New_Project_Created :: struct {}
New_Project_Cancelled :: struct {}
// Quit even with unsaved changes (the UI test driver, when a script ends)
Quit_Without_Asking :: struct {}
Open_Project_Chosen :: distinct skald.File_Dialog_Result
// The File menu's recent projects (recent_projects.odin): one chosen (its index in the list), the
// list emptied
Recent_Project_Chosen :: distinct int
Recent_Projects_Cleared :: struct {}
// Project archives (project_archive.odin): where to write one; the archive to open, then the
// folder to unpack it into (paths are only valid while handling the message)
Project_Archive_Path_Chosen :: distinct skald.File_Dialog_Result
Project_Archive_Open_Chosen :: distinct skald.File_Dialog_Result
Project_Archive_Destination_Chosen :: distinct skald.File_Dialog_Result

// Project browser drag of an image asset into the viewport
Asset_Drag_Pressed :: struct {
	asset: int,
	start: [2]f32,
}
Asset_Drag_Started :: struct {}
// Released over the viewport: a Sprite is created there (world coordinates)
Asset_Dropped :: struct {
	world: [2]f32,
}
Asset_Drag_Cancelled :: struct {}

// Inspector edits to the selected node
Node_Renamed            :: distinct string
Node_Visibility_Changed :: distinct bool

// Number properties
NodeField :: enum {
	Position_X,
	Position_Y,
	Rotation,
	Scale_X,
	Scale_Y,
	Layer,
	// Draw order in the layer (format 13)
	Z_Index,
	Font_Size,
	Zoom,
	// Physics
	Friction,
	Restitution,
	Density,
	Gravity_Scale,
	Linear_Damping,
	Angular_Damping,
	Floor_Max_Angle,
	Shape_Width,
	Shape_Height,
	Radius,
	Target_X,
	Target_Y,
	// Joint
	Offset_X,
	Offset_Y,
	Lower,
	Upper,
	Motor_Speed,
	Max_Motor,
	Hertz,
	Damping,
	// A Sprite's 9-patch size (aseprite_edit.odin)
	Nine_Width,
	Nine_Height,
}

// Text properties. Play_Mode carries the enum value's name; Color carries #rrggbb
NodeTextField :: enum {
	Text,
	Texture,
	Color,
	// The AnimatedSprite animation it starts with ("" or ANIMATION_FIRST: the first)
	Autoplay,
	// The animation asset an AnimatedSprite plays (ANIMATION_OWN: its own animations)
	Animation_Set,
	// Aseprite slices: a sprite's pivot slice, a Sprite's 9-patch slice, a CollisionShape's
	// slice (SLICE_NONE for none; aseprite_edit.odin)
	Pivot_Slice,
	Nine_Slice,
	Slice,
	// A Sprite's atlas region (REGION_NONE for none; atlas_edit.odin)
	Region,
	// A Component node's component (its file; TEXTURE_NONE for none)
	Component,
	// A sound node's sound or music asset (TEXTURE_NONE for none), and its bus (a name; Master is "")
	Sound,
	Bus,
	// A CollisionShape's kind, by name
	Shape,
	// A Joint's kind, and its bodies (names; "" for body A's default)
	Joint_Kind,
	Body_A,
	Body_B,
	// Every node (format 13): process mode and blend mode by name, groups comma-separated
	Process_Mode,
	Blend_Mode,
	Groups,
	// A body's physics material (MATERIAL_NONE for none)
	Material,
}

Node_Text_Changed :: struct {
	field: NodeTextField,
	value: string,
}

NodeFlag :: enum {
	Centered,
	Fixed_Rotation,
	Bullet,
	Disabled,
	Enabled,
	Exclude_Parent,
	Limit,
	Motor,
	Spring,
	Collide_Connected,
	// Every node: its children draw by their y (format 13)
	Y_Sort,
	// CollisionShape: a one-way platform (format 13)
	One_Way,
	// ScreenEffect: it covers the screen layers too (shader_edit.odin)
	Effect_Screen_Layers,
}

// Turns one collision layer (1-64) on or off in the selected node's layers (or its mask)
Node_Layer_Toggled :: struct {
	mask: bool,
	layer: int,
}

// Typing a CollisionShape's points ("x,y x,y"); applies when they all parse (see number_field.odin)
Node_Points_Changed :: struct {
	id: skald.Widget_ID,
	text: string,
}

Node_Flag_Changed :: struct {
	flag: NodeFlag,
	value: bool,
}

Node_Field_Changed :: struct {
	field: NodeField,
	value: f64,
}

// ParticleEmitter settings of the selected node (view_inspector_particles.odin). Strings are only
// valid while handling the message
// A setting, as text (`e.ParticleSettings_Set`'s format)
Particle_Field_Changed :: struct {
	name: string,
	value: string,
}
// One axis of an [2]f32 setting; the other follows when the pair is linked
Particle_Axis_Changed :: struct {
	name: string,
	axis: int,
	value: f32,
}
// Links or unlinks an [2]f32 setting's axes (its index in `e.ParticleSettings_Fields`)
Particle_Link_Toggled :: distinct int
// Every setting back to the defaults
Particles_Reset :: struct {}
// The color ramp changed (`text`), and the stop to select after it
Ramp_Edited :: struct {
	text: string,
	selected: int,
}
Ramp_Stop_Selected :: distinct int
// A ramp stop's marker was pressed (true) or released (false)
Ramp_Drag_Changed :: distinct bool

// Scripts (scripts.odin)
// The view noticed a project with scripts that hasn't been built: build it once in the background
Scripts_Auto_Build :: struct {}
// Attach a script to the selected node by name ("" detaches)
Node_Script_Changed :: distinct string
// A field's value: on the selected node's script, a draft global or a data resource (`target`).
// Strings are only valid while handling the message
Script_Prop_Changed :: struct {
	name: string,
	value: string,
	defaultValue: string,
	target: PropTarget,
}
Script_Open_File :: struct {
	file: string,
	line: int,
}
// Checks on code editor processes started by Open (logs one that failed)
Editor_Process_Check :: struct {}
New_Script_Opened :: struct {}
New_Script_Name_Changed :: distinct string
New_Script_Created :: struct {}
New_Script_Cancelled :: struct {}

// Sound nodes and the Mixer tab (mixer.odin, view_mixer.odin)
AudioField :: enum {
	Volume,
	Pitch,
	Pan,
	Max_Distance,
	Attenuation,
	Fade_In,
	Fade_Out,
}
Audio_Field_Changed :: struct {
	field: AudioField,
	value: f32,
}
AudioFlag :: enum {
	Loop,
	Autostart,
}
Audio_Flag_Changed :: struct {
	flag: AudioFlag,
	value: bool,
}
// Plays the selected sound node's sound in the editor (the browser's sound preview); false stops it
Audio_Preview_Requested :: distinct bool
// An audio asset becomes music (streamed by MusicPlayers) or a sound again
Asset_Kind_Changed :: struct {
	index: int,
	kind: AssetKind,
}
Bus_Added :: struct {}
Bus_Removed :: distinct int
// Typing a bus's name (applies once it's valid and unused)
Bus_Renamed :: struct {
	index: int,
	name: string,
}
Bus_Volume_Changed :: struct {
	index: int,
	value: f32,
}
Bus_Pan_Changed :: struct {
	index: int,
	value: f32,
}
Bus_Mute_Toggled :: distinct int

// Components (component_edit.odin)
// Opens a component (its index in project.scenes) in a viewport tab
Component_Opened :: distinct int
// Adds an instance of a component asset (its index in project.assets) to the open scene, under the selection
Component_Instance_Added :: distinct int
// Makes a new component (a Node2D to build on) and opens it
Component_New :: struct {}
// Starts renaming a component in the browser (its asset's index)
Component_Rename_Started :: distinct int
// Make Unique: the selected instance gets a copy of its component, its own from now on
Component_Made_Unique :: struct {}

// Project Settings > Input (input_actions.odin): the draft's actions
Input_New_Name_Changed :: distinct string
Input_Action_Added :: struct {}
// Adds the default ui_* actions it doesn't have
Input_Defaults_Added :: struct {}
Input_Action_Selected :: distinct int
Input_Action_Removed :: distinct int
Input_Action_Moved :: struct {
	index, delta: int,
}
// Typing the shown action's name (applies when it's valid and unused)
Input_Action_Renamed :: distinct string
Input_Deadzone_Changed :: distinct f32
Input_Binding_Added :: struct {
	binding: e.InputBinding,
}
Input_Binding_Removed :: distinct int
// "Press a key or button": the modifiers held when it started
Input_Capture_Started :: distinct skald.Modifiers
Input_Capture_Cancelled :: struct {}
// The gamepad new gamepad bindings are for (-1 any)
Input_Device_Changed :: distinct int

// Help > Keyboard Shortcuts: the Settings dialog on its Keyboard tab
Open_Keyboard_Settings :: struct {}
// View > Grid Settings: the Project Settings dialog on its Grid tab
Open_Grid_Settings :: struct {}

// The Animation panel (view_animation.odin, animation_edit.odin): the selected AnimatedSprite's
// animations. Strings are only valid while handling the message
// Selects an animation by index
Anim_Selected :: distinct int
Anim_Added :: struct {}
Anim_Duplicated :: struct {}
Anim_Removed :: struct {}
// Moves the selected animation up (-1) or down (+1) in the list
Anim_Moved :: distinct int
// Typing the selected animation's name (kept until it's a valid, unused one)
Anim_Name_Typed :: struct {
	id: skald.Widget_ID,
	text: string,
}
// The selected animation's numbers (number fields: see NumberTarget)
AnimField :: enum {
	Start,
	End,
	// How many frames it plays (moves its end)
	Frames,
	FPS,
	// Its sheet's grid: columns x rows, or a cell's size (`Anim_Grid_Mode_Changed`)
	Columns,
	Rows,
	Cell_Width,
	Cell_Height,
	// Pixels around the grid and between cells
	Margin,
	Spacing,
	// Times a non-looping animation plays (0 or 1: once)
	Repeat,
}
// Frame times on (each frame of its range gets its own, starting at 1 / fps) or off (fps for all)
Anim_Durations_Toggled :: distinct bool
// One frame's time, in milliseconds (`frame` from the animation's first: see AnimDurationTarget)
Anim_Duration_Changed :: struct {
	frame: int,
	ms: f64,
}
// The selected animation's sheet image (TEXTURE_NONE for none)
Anim_Sheet_Texture_Changed :: distinct string
// An image dragged from the browser was released over the Animation panel: the selected
// animation's sheet (the dragged asset is State.assetDrag's)
Anim_Sheet_Dropped :: struct {}
// How the selected animation's sheet is cut: an `e.SheetGridMode` by name (Cells, Size)
Anim_Grid_Mode_Changed :: distinct string
// The browser shows an animation asset in the Animation panel (its path; "": the selected sprite's)
Anim_Asset_Shown :: distinct string
// The inspector's Save as Animation Asset: the selected sprite's own animations become an asset it uses
Anim_Set_From_Node :: struct {}
// The browser's New Animations: an empty animation asset, shown in the Animation panel
Anim_Set_New :: struct {}
Anim_Field_Changed :: struct {
	field: AnimField,
	value: f64,
}
Anim_Loop_Changed :: distinct bool
// A play mode, by name
Anim_Mode_Changed :: distinct string
// The selected animation becomes the one the sprite starts with
Anim_Autoplay_Set :: struct {}
// A click on a frame thumbnail: sets the start (or, `end`, the end) of the selected animation
Anim_Frame_Clicked :: struct {
	frame: int,
	end: bool,
}
// The panel's preview: play / pause, and its frame timer
Anim_Playback_Toggled :: struct {}
Anim_Tick :: struct {}
Anim_Tick_Requested :: struct {}

// Inspector X/Y pairs that can be linked
LinkedPair :: enum {
	Position,
	Scale,
}
Inspector_Link_Toggled :: distinct LinkedPair

// Typing in a number field (number_field.odin). `text` is only valid while handling the message
Number_Text_Changed :: struct {
	target: NumberTarget,
	id: skald.Widget_ID,
	text: string,
	lo, hi: f64,
}
// The field lost focus: drop its typed text
Number_Edit_Ended :: distinct skald.Widget_ID

/*
Everything that can happen in the editor. `update` handles each case.
*/
// Viewport: the view area's size changed (logical pixels)
Viewport_Measured :: distinct [2]f32
// Viewport: pan by a mouse movement in pixels
Viewport_Panned :: distinct [2]f32
// Viewport: zoom by a factor around a world point
Viewport_Zoomed :: struct {
	factor: f32,
	anchor: [2]f32,
}
// Viewport: a drag started on a node (or a pan); positions are world coordinates
Viewport_Drag_Begin :: struct {
	mode: DragMode,
	node: int,
	mouse: [2]f32,
	// Box selection: Ctrl or Shift held, add to the selection; the Zoom tool: Alt held (out)
	additive: bool,
	// Alt+drag: duplicate the selection first, and drag the copies
	duplicate: bool,
}
Viewport_Drag_Move :: struct {
	mouse: [2]f32,
	constrain: bool,
}
Viewport_Drag_End :: struct {}
// Sent every frame while viewport animations play, so frames keep coming
Viewport_Tick :: struct {}
// The view wants the next animation frame: starts a timer that sends Viewport_Tick
Viewport_Tick_Requested :: struct {}

// Project browser
Browser_Search_Changed :: distinct string
// The import file dialog closed (path is only valid while handling the message)
Asset_Import_Result :: distinct skald.File_Dialog_Result
// The remove-asset dialog's choice
Asset_Remove_Confirmed :: struct {
	deleteFile: bool,
}
Asset_Remove_Cancelled :: struct {}
// The browser's tree/preview divider moved: the tree's new height
Browser_Tree_Resized :: distinct f32
// Height of the space the browser tree and preview share, measured by layout
Browser_Body_Measured :: distinct f32
// Sent every frame while a sound plays in the preview, so its progress keeps updating
Preview_Tick :: struct {}

// Settings dialog (settings_dialog.odin)
Settings_Tab_Changed :: distinct int
// "Dark" or "Light"
Settings_Theme_Changed :: distinct string
Settings_Value_Changed :: struct {
	field: SettingsField,
	value: f64,
}
Settings_Search_Changed :: distinct string
Settings_Code_Editor_Path_Changed :: distinct string
Settings_Code_Editor_Args_Changed :: distinct string
// Browse... for the code editor program, and the file dialog's answer
Settings_Code_Editor_Browse :: struct {}
Settings_Code_Editor_Picked :: distinct skald.File_Dialog_Result
Settings_Optimized_Play_Changed :: distinct bool
Settings_Hot_Reload_Changed :: distinct bool
// Settings > Editor: the mouse wheel pans the viewport (Ctrl + wheel zooms), for touchpads
Settings_Wheel_Pans_Changed :: distinct bool
// Settings > Editor: the playback device for Play and the editor's previews ("" = the default)
Settings_Audio_Device_Changed :: distinct string
Settings_Builtin_Editor_Changed :: distinct bool
Settings_Auto_Close_Changed :: distinct bool
Settings_OLS_Path_Changed :: distinct string
Settings_LDtk_Path_Changed :: distinct string
// Settings > Editor > Aseprite program typed
Settings_Aseprite_Path_Changed :: distinct string
Settings_Odin_Path_Changed :: distinct string
// Settings > Toolchain's Install Odin
Toolchain_Install_Requested :: struct {}
// Install Emscripten for web exports (Settings > Toolchain, or a web export that needs it)
Toolchain_Emscripten_Requested :: struct {}
// Clicked a shortcut: the next key press binds that slot
Settings_Capture_Started :: struct {
	action: Action,
	slot: int,
}
Settings_Key_Captured :: distinct skald.Shortcut
Settings_Capture_Cancelled :: struct {}
Settings_Key_Cleared :: struct {
	action: Action,
	slot: int,
}
// Back to the action's default chords
Settings_Key_Reset :: distinct Action
// Back to the defaults for the open tab
Settings_Tab_Reset :: struct {}
// Apply (and save) the draft; Save also closes the dialog
Settings_Applied :: struct {
	close: bool,
}
Settings_Cancelled :: struct {}

// Add Node dialog
Add_Node_Search_Changed :: distinct string
// Move the highlight up (-1) or down (+1)
Add_Node_Highlight_Moved :: distinct int
// Add the highlighted kind (Enter)
Add_Node_Confirmed :: struct {}
// Add this kind (a click on its row)
Add_Node_Kind_Chosen :: distinct NodeKind
// Add a node type of the project's code (a click on its row: its name, for the frame)
Add_Node_Type_Chosen :: distinct string
Add_Node_Cancelled :: struct {}

Msg :: union {
	Scene_Screen_Layer_Toggled,
	Scene_Background_Changed,
	Scene_Gravity_Toggled,
	Scene_Gravity_Changed,
	Script_Usage_Clicked,
	Listener_Dialog_Opened,
	Listener_Dialog_Cancelled,
	Listener_Target_Chosen,
	Listener_Removed,
	Inspector_Events_Toggled,
	LDtk_Instances_Toggled,
	LDtk_Entity_Framed,
	Global_Listen_Requested,
	New_Event_Opened,
	New_Event_Name_Changed,
	New_Event_Description_Changed,
	New_Event_Kind_Changed,
	New_Event_Created,
	New_Event_Cancelled,
	Action,
	Play_Tick,
	Script_Tick,
	Viewport_Measured,
	Viewport_Panned,
	Viewport_Zoomed,
	Viewport_Drag_Begin,
	Viewport_Drag_Move,
	Viewport_Drag_End,
	Viewport_Tick,
	Viewport_Tick_Requested,
	Browser_Search_Changed,
	Asset_Import_Result,
	Asset_Remove_Confirmed,
	Asset_Remove_Cancelled,
	Browser_Tree_Resized,
	Node_Pick_Toggled,
	Node_Pick_Added,
	Node_Primary_Picked,
	Tree_Selection_Clicked,
	Node_Right_Clicked,
	Tree_Drag_Pressed,
	Tree_Drag_Started,
	Tree_Drag_Dropped,
	Tree_Drag_Cancelled,
	Tree_Drag_Dropped_On_Code,
	Component_Close_Chosen,
	Asset_Dropped_On_Code,
	Confirm_Chosen,
	Code_Tab_Selected,
	Code_Tab_Close_Requested,
	Code_Close_Chosen,
	Code_Open_Requested,
	Code_File_Edits_Requested,
	Code_Save_Requested,
	Code_Tick_Requested,
	Code_Reloaded,
	Code_Disk_Chosen,
	Code_Dialog_Requested,
	Code_Dialog_Picked,
	Code_Tick,
	Code_Focused,
	New_Project_Name_Changed,
	New_Project_Location_Changed,
	New_Project_Browse,
	New_Project_Location_Chosen,
	New_Project_Created,
	New_Project_Cancelled,
	Open_Project_Chosen,
	Recent_Project_Chosen,
	Recent_Projects_Cleared,
	Project_Archive_Path_Chosen,
	Project_Archive_Open_Chosen,
	Project_Archive_Destination_Chosen,
	Project_Archive_Written,
	Project_Archive_Extracted,
	Quit_Without_Asking,
	Scripts_Auto_Build,
	Node_Script_Changed,
	Script_Prop_Changed,
	Script_Open_File,
	Editor_Process_Check,
	New_Script_Opened,
	New_Script_Name_Changed,
	New_Script_Created,
	New_Script_Cancelled,
	Inspector_Link_Toggled,
	Number_Text_Changed,
	Number_Edit_Ended,
	Refocus_Done,
	Scene_Action,
	Browser_Focus_Changed,
	Browser_Right_Clicked,
	Project_Settings_Name_Changed,
	Project_Settings_Scale_Changed,
	Project_Settings_Renderer_Changed,
	Project_Settings_Texture_Filter_Changed,
	Project_Settings_Background_Changed,
	Project_Settings_Start_Changed,
	Project_Settings_Locale_Changed,
	Project_Settings_Icon_Changed,
	Project_Settings_Size_Changed,
	Project_Settings_Applied,
	Project_Settings_Transition_Changed,
	Project_Settings_Loading_Changed,
	Project_Settings_Cancelled,
	Project_Settings_Physics_Changed,
	Project_Settings_Physics_Debug_Changed,
	Project_Settings_Physics_Smoothing_Changed,
	Project_Settings_Window_Changed,
	Project_Settings_Grid_Changed,
	Project_Settings_Audio_Changed,
	New_Script_Kind_Changed,
	New_Data_Opened,
	New_Data_Name_Changed,
	New_Data_Type_Changed,
	New_Data_Created,
	New_Data_Cancelled,
	Global_Added,
	Global_Removed,
	Global_Selected,
	Global_Moved,
	Project_Settings_Tab_Changed,
	Steam_Setting_Changed,
	Steam_Achievement_Added,
	Steam_Achievement_Removed,
	Players_Setting_Changed,
	Export_Target_Selected,
	Export_Target_Enabled,
	Export_Text_Changed,
	Export_Flag_Changed,
	Export_Target_Run,
	Export_Cancel_Requested,
	Export_Requested,
	Export_Tick,
	Rename_Started,
	Rename_Text_Changed,
	Rename_Focused,
	Rename_Committed,
	Rename_Cancelled,
	Frame_Requested,
	About_Closed,
	Manual_Opened,
	About_Link_Opened,
	Viewport_Content_Measured,
	Asset_Drag_Pressed,
	Asset_Drag_Started,
	Asset_Dropped,
	Asset_Drag_Cancelled,
	Settings_Tab_Changed,
	Settings_Theme_Changed,
	Settings_Value_Changed,
	Settings_Theme_Color_Changed,
	Settings_Theme_Color_Reset,
	Settings_Theme_Preset_Chosen,
	Settings_Search_Changed,
	Settings_Code_Editor_Path_Changed,
	Settings_Code_Editor_Args_Changed,
	Settings_Code_Editor_Browse,
	Settings_Code_Editor_Picked,
	Settings_Optimized_Play_Changed,
	Settings_Hot_Reload_Changed,
	Settings_Wheel_Pans_Changed,
	Settings_Builtin_Editor_Changed,
	Settings_Auto_Close_Changed,
	Settings_OLS_Path_Changed,
	Settings_LDtk_Path_Changed,
	Settings_Aseprite_Path_Changed,
	Settings_Audio_Device_Changed,
	Settings_Odin_Path_Changed,
	Toolchain_Install_Requested,
	Toolchain_Install_Finished,
	Toolchain_Emscripten_Requested,
	Toolchain_Emscripten_Finished,
	Git_Refresh_Requested,
	Git_Snapshot_Read,
	Git_Op_Requested,
	Git_Op_Finished,
	Git_Message_Changed,
	Git_Diff_Requested,
	Git_Diff_Read,
	Git_Discard_Asked,
	Git_New_Branch_Changed,
	Git_Remote_URL_Changed,
	LDtk_Setting_Changed,
	TileMap_Setting_Changed,
	Tile_Brush,
	Tile_Tool_Chosen,
	Tile_Brush_Chosen,
	Tile_Layer_Chosen,
	Tile_Terrain_Chosen,
	Tile_Tileset_Chosen,
	Tile_Brush_Turned,
	Tile_Layer_Added,
	Tile_Layer_Reverted,
	Timeline_Changed,
	UI_Setting_Changed,
	Light_Setting_Changed,
	Touch_Setting_Changed,
	Line_Setting_Changed,
	Node_Shader_Changed,
	Node_Shader_Param_Changed,
	Shader_New_Requested,
	Nav_Setting_Changed,
	SM_Changed,
	Camera_Tool_Changed,
	Camera_Changed,
	SM_View,
	Live_Command,
	Live_Selected,
	Live_Property_Edited,
	Scene_Lighting_Changed,
	Theme_Field_Changed,
	Theme_Font_Changed,
	Theme_Created,
	Theme_Project_Set,
	Material_Field_Changed,
	Material_Created,
	Trace_Setting_Changed,
	Trace_Sprite_Chosen,
	Collision_Traced,
	Timeline_View,
	Timeline_Tick,
	Timeline_Tick_Requested,
	LDtk_Level_Picked,
	LDtk_Open_Requested,
	LDtk_Asset_Open_Requested,
	Aseprite_Asset_Open_Requested,
	Aseprite_Layer_Toggled,
	Settings_Capture_Started,
	Settings_Key_Captured,
	Settings_Capture_Cancelled,
	Settings_Key_Cleared,
	Settings_Key_Reset,
	Settings_Tab_Reset,
	Settings_Applied,
	Settings_Cancelled,
	Add_Node_Search_Changed,
	Add_Node_Highlight_Moved,
	Add_Node_Confirmed,
	Add_Node_Kind_Chosen,
	Add_Node_Type_Chosen,
	Add_Node_Cancelled,
	Node_Script_Added,
	Node_Script_Removed,
	Node_Script_Open,
	Asset_Filter_Changed,
	Asset_MSDF_Changed,
	Font_MSDF_Make_Requested,
	Audio_Convert_Requested,
	Audio_Converted,
	Atlas_Created,
	Atlas_Image_Added,
	Atlas_Image_Removed,
	Atlas_Padding_Changed,
	Atlas_Filter_Changed,
	Atlas_Pack_Requested,
	Skeleton_Setting_Changed,
	Skeleton_Bone_Added,
	Mesh_Made,
	Mesh_Bound,
	Dialogue_Changed,
	Dialogue_View,
	Dialogue_Created,
	DialogueBox_Setting_Changed,
	Plugins_Tick,
	ScriptIndex_Tick,
	ScriptIndex_Parsed,
	Code_Usage_Opened,
	Code_Rename_Requested,
	NameTable_Loaded,
	Plugin_Command_Run,
	Plugin_Row_Changed,
	Plugin_New_Requested,
	Plugins_Rebuild_Requested,
	Browser_Body_Measured,
	Preview_Tick,
	Left_Resized,
	Center_Resized,
	Viewport_Resized,
	Scene_Tree_Resized,
	Workspace_Measured,
	Bottom_Tab_Changed,
	Scene_Tab_Changed,
	Scene_Tab_Closed,
	Tool_Selected,
	Browser_Toggled,
	Browser_Selected,
	Node_Toggled,
	Node_Selected,
	Node_Picked,
	Node_Renamed,
	Node_Visibility_Changed,
	Node_Field_Changed,
	Node_Text_Changed,
	Node_Flag_Changed,
	Node_Layer_Toggled,
	Node_Points_Changed,
	Open_Keyboard_Settings,
	Open_Grid_Settings,
	Component_Opened,
	Audio_Field_Changed,
	Audio_Flag_Changed,
	Audio_Preview_Requested,
	Asset_Kind_Changed,
	Bus_Added,
	Bus_Removed,
	Bus_Renamed,
	Bus_Volume_Changed,
	Bus_Pan_Changed,
	Bus_Mute_Toggled,
	Bus_Effects_Opened,
	Bus_Effect_Added,
	Bus_Effect_Removed,
	Bus_Effect_Moved,
	Bus_Effect_Changed,
	Music_Layer_Added,
	Music_Layer_Removed,
	Music_Layer_Changed,
	Component_Instance_Added,
	Component_New,
	Component_Rename_Started,
	Component_Made_Unique,
	Input_New_Name_Changed,
	Input_Action_Added,
	Input_Defaults_Added,
	Input_Action_Selected,
	Input_Action_Removed,
	Input_Action_Moved,
	Input_Action_Renamed,
	Input_Deadzone_Changed,
	Input_Binding_Added,
	Input_Binding_Removed,
	Input_Capture_Started,
	Input_Capture_Cancelled,
	Input_Device_Changed,
	Anim_Selected,
	Anim_Sheet_Texture_Changed,
	Anim_Sheet_Dropped,
	Anim_Grid_Mode_Changed,
	Anim_Asset_Shown,
	Anim_Set_From_Node,
	Anim_Set_New,
	Anim_Added,
	Anim_Duplicated,
	Anim_Removed,
	Anim_Moved,
	Anim_Name_Typed,
	Anim_Field_Changed,
	Anim_Loop_Changed,
	Anim_Mode_Changed,
	Anim_Autoplay_Set,
	Anim_Frame_Clicked,
	Anim_Durations_Toggled,
	Anim_Duration_Changed,
	Anim_Playback_Toggled,
	Anim_Tick,
	Anim_Tick_Requested,
	Particle_Field_Changed,
	Particle_Axis_Changed,
	Particle_Link_Toggled,
	Particles_Reset,
	Ramp_Edited,
	Ramp_Stop_Selected,
	Ramp_Drag_Changed,
	// Context menus (context_menus.odin)
	Context_Menu_Opened,
	Context_Menu_Closed,
	Node_Command,
	Add_Node_Here,
	Paste_Here,
	Tab_Command,
	File_Command,
	Log_Command,
	// The Console's and Output tab's following and filters (console.odin)
	Log_Follow_Toggled,
	Log_Follow_Set,
	Log_Level_Toggled,
	Log_Category_Toggled,
	Log_Categories_Shown,
	Log_Search_Changed,
	Log_Filters_Cleared,
	Log_Test_Lines,
	Script_Open_External,
	Asset_Add_To_Scene,
	Graph_Command,
	Text_Copied,
	Timeline_Key_Here,
	// Viewport tools (viewport_tools.odin)
	Align_Nodes,
	Guide_Added,
	Guide_Moved,
	Guide_Removed,
	Guides_Cleared,
}
