package editor

import e "engine:."
import "gui:skald"

/*
Commands triggered from the menu bar, toolbar and keyboard shortcuts. Default keys are in
keymap.odin.
*/
Action :: enum {
	New_Project,
	Open_Project,
	Save_Project,
	Export,
	// The whole project in one file, and opening one (project_archive.odin)
	Export_Project_Archive,
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
	// Play from the scene open in the viewport instead of the start scene
	Play_Scene,
	Open_Project_Settings,
	Select_All,
	Toggle_Grid,
	Toggle_Snap,
	// Outline collision shapes, rays and joints in the viewport
	Toggle_Collision_Shapes,
	// The project's development setting: the game draws its physics shapes (never in exports)
	Toggle_Physics_Debug,
	Play,
	Pause,
	Stop,
	Toggle_Bottom_Panel,
	Clear_Console,
	About,

	// Viewport tools
	Tool_Select,
	Tool_Move,
	Tool_Rotate,
	Tool_Scale,
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
Project_Settings_Background_Changed :: distinct skald.Color
Project_Settings_Start_Changed :: distinct string
Project_Settings_Size_Changed :: struct {
	axis: int,
	value: f64,
}
Project_Settings_Physics_Changed :: struct {
	field: PhysicsTarget,
	value: f64,
}
Project_Settings_Physics_Debug_Changed :: distinct bool
Project_Settings_Physics_Smoothing_Changed :: distinct bool
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
// The open file asks for another (Go to Definition): 0-based line and character (owned by the frame)
Code_Open_Requested :: struct {
	path: string,
	line, character: int,
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
	Columns,
	Rows,
	// AnimatedSprite sheet: pixels around the grid and between cells
	Margin,
	Spacing,
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
}

// Text properties. Play_Mode carries the enum value's name; Color carries #rrggbb
NodeTextField :: enum {
	Text,
	Texture,
	Color,
	// The AnimatedSprite animation it starts with ("" or ANIMATION_FIRST: the first)
	Autoplay,
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
	FPS,
}
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
	// Box selection: Ctrl or Shift held, add to the selection
	additive: bool,
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
Settings_Builtin_Editor_Changed :: distinct bool
Settings_OLS_Path_Changed :: distinct string
Settings_LDtk_Path_Changed :: distinct string
Settings_Odin_Path_Changed :: distinct string
// Settings > Toolchain's Install Odin
Toolchain_Install_Requested :: struct {}
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
Add_Node_Cancelled :: struct {}

Msg :: union {
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
	Confirm_Chosen,
	Code_Tab_Selected,
	Code_Tab_Close_Requested,
	Code_Close_Chosen,
	Code_Open_Requested,
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
	Project_Settings_Background_Changed,
	Project_Settings_Start_Changed,
	Project_Settings_Size_Changed,
	Project_Settings_Applied,
	Project_Settings_Cancelled,
	Project_Settings_Physics_Changed,
	Project_Settings_Physics_Debug_Changed,
	Project_Settings_Physics_Smoothing_Changed,
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
	Asset_Drag_Pressed,
	Asset_Drag_Started,
	Asset_Dropped,
	Asset_Drag_Cancelled,
	Settings_Tab_Changed,
	Settings_Theme_Changed,
	Settings_Value_Changed,
	Settings_Search_Changed,
	Settings_Code_Editor_Path_Changed,
	Settings_Code_Editor_Args_Changed,
	Settings_Code_Editor_Browse,
	Settings_Code_Editor_Picked,
	Settings_Optimized_Play_Changed,
	Settings_Builtin_Editor_Changed,
	Settings_OLS_Path_Changed,
	Settings_LDtk_Path_Changed,
	Settings_Odin_Path_Changed,
	Toolchain_Install_Requested,
	Toolchain_Install_Finished,
	Git_Refresh_Requested,
	Git_Snapshot_Read,
	Git_Op_Requested,
	Git_Op_Finished,
	Git_Message_Changed,
	Git_New_Branch_Changed,
	Git_Remote_URL_Changed,
	LDtk_Setting_Changed,
	LDtk_Open_Requested,
	LDtk_Asset_Open_Requested,
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
	Add_Node_Cancelled,
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
}
