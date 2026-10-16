package editor

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
	Select_All,
	Toggle_Grid,
	Toggle_Snap,
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

// Renaming a node in the scene tree
Rename_Started :: distinct int
Rename_Text_Changed :: distinct string
Rename_Focused :: struct {}
// Enter, or the field lost focus
Rename_Committed :: struct {}
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
	Font_Size,
	Zoom,
	Columns,
	Rows,
	FPS,
}

// Text properties. Play_Mode carries the enum value's name; Color carries #rrggbb
NodeTextField :: enum {
	Text,
	Texture,
	Color,
	Play_Mode,
}

Node_Text_Changed :: struct {
	field: NodeTextField,
	value: string,
}

NodeFlag :: enum {
	Loop,
	Centered,
}

Node_Flag_Changed :: struct {
	flag: NodeFlag,
	value: bool,
}

Node_Field_Changed :: struct {
	field: NodeField,
	value: f64,
}

// Scripts (scripts.odin)
// The view noticed a project with scripts that hasn't been built: build it once in the background
Scripts_Auto_Build :: struct {}
// Attach a script to the selected node by name ("" detaches)
Node_Script_Changed :: distinct string
// A script field's value on the selected node (strings only valid while handling the message)
Script_Prop_Changed :: struct {
	name: string,
	value: string,
	defaultValue: string,
}
Script_Open_File :: struct {
	file: string,
	line: int,
}
New_Script_Opened :: struct {}
New_Script_Name_Changed :: distinct string
New_Script_Created :: struct {}
New_Script_Cancelled :: struct {}

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
Settings_Code_Editor_Changed :: distinct string
Settings_Optimized_Play_Changed :: distinct bool
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
	New_Project_Name_Changed,
	New_Project_Location_Changed,
	New_Project_Browse,
	New_Project_Location_Chosen,
	New_Project_Created,
	New_Project_Cancelled,
	Open_Project_Chosen,
	Quit_Without_Asking,
	Scripts_Auto_Build,
	Node_Script_Changed,
	Script_Prop_Changed,
	Script_Open_File,
	New_Script_Opened,
	New_Script_Name_Changed,
	New_Script_Created,
	New_Script_Cancelled,
	Inspector_Link_Toggled,
	Number_Text_Changed,
	Number_Edit_Ended,
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
	Settings_Code_Editor_Changed,
	Settings_Optimized_Play_Changed,
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
}
