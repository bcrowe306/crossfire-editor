package crossfire_editor

import "core:encoding/json"
import "core:fmt"
import "core:log"
import "core:math"
import "core:path/filepath"
import "core:os"
import "core:reflect"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:time"
import e "engine:."
import "gui:skald"
import sdl "vendor:sdl3"
import stbi "vendor:stb/image"

/*
UI test driver: runs a script that drives the editor through real input.

	crossfire-editor [project folder] --script tests/ui/smoke.script

The script pushes SDL mouse and keyboard events, which reach Skald exactly like a user's input,
and checks the editor's state. Everything happens inside the editor process: the driver never
reads the screen, so it's safe to run while using the machine (the editor window does open). Widgets are found by the key their id was made from
(`skald.hash_id(key)` in the view code), so scripts don't depend on window size or layout.
The editor exits when the script ends: code 0 if every check passed, 1 otherwise.

Script format: one command per line; blank lines and `#` comments are ignored. `{selected}` in a
command is the selected node's index (inspector keys: `click_widget inspector-name-{selected}`).

	wait <frames>                    Let frames pass
	wait_until <check> [timeout=<s>] Wait (default 10 s) until a check passes; fails on timeout
	console_fill <n> [<Level> [<category>]]   Add n lines to the Console, as a game would
	                                 (Log_Test_Lines; Info and "game" by default)
	frame_times <frames> [<lines>]   Time that many frames, adding lines to the Console on each;
	                                 reports the median, p95 and max. With SKALD_BENCH_UNCAP=1
	                                 SKALD_BENCH_FRAMES=1000000000 every frame draws, uncapped
	expect <check>                   Fail unless the check passes now
	click_widget <key>               Click the center of a widget's visible part, e.g. toolbar-play
	click_at <key> <fx> <fy>         Click a point of a widget's visible part, as fractions of its
	                                 width and height (0 0 = top left), e.g. a slider's or ramp's spot
	scroll_by <scroll key> <dy>      Scroll a scroll container by dy pixels (0 or less: to the top)
	if_drawn <key> <command>         Run the command only if the widget was drawn last frame (layouts
	                                 that depend on the window: the toolbar's overflow, toolbar-more)
	note_game                        Remember the running game's process (the `game pid` check)
	click_log_location <console | output> [<n>] [right]
	                                 Click the n-th shown line (1st by default) of the Console or
	                                 Output tab naming a source location (its text: the link),
	                                 scrolled into view first; right: open its menu
	click_offset <key> <dx> <dy> [shift]
	                                 Click dx, dy pixels from a widget's top left (e.g. a thumbnail
	                                 of animation-frames), optionally holding Shift
	click_tile <n>                   Click tile n (1 is the first) of the Tiles panel's palette
	drag_world x1 y1 x2 y2 [right]   Press at a world point in the viewport, move to another, release
	paint_cells c1 r1 c2 r2 [right]  A stroke between two cells of the selected TileMap (the Tiles panel's layer)
	click_state <i>                  Click state i's box in the States tab's graph
	drag_state <i> <dx> <dy>         Drag state i's box by (dx, dy) pixels
	click_timeline <seconds> [track] [double]
	                                 Click the Timeline's tracks at a time: on the ruler, or on a track's row
	drag_timeline_key <track> <key> <seconds>
	                                 Drag a key of the Timeline's clip to a time
	click_frame <n> [shift | right]  Click thumbnail n of the Animation panel's frames (right: its menu)
	click_overlay_item <i>           Click button i (top to bottom) of the open popup, e.g. a
	                                 dropdown's choices after click_widget opened it
	drag_widget <key> <fx0> <fy0> <fx1> <fy1> [shift] [middle | right]
	                                 Press at one point of a widget (fractions), move to another,
	                                 release; optionally holding Shift, with the middle or right
	                                 button instead of the left
	click_row <tree key> <row> [ctrl | shift]
	                                 Click a row of a tree: browser-tree, scene-tree; optionally
	                                 holding Ctrl or Shift
	double_click_row <tree key> <row>   Double-click a row
	click_tab <tabs key> <index>     Click a tab of a skald.tabs strip (the center panel's tabs are
	                                 widgets: scene-tab-<i>, scene-tab-close-<i>, code-tab-<i>, ...)
	close_current_tab                Click the × of the open scene's or component's tab
	touch_project_file <path> <text> Append a line to a project file (made if missing), as another
	                                 program would
	save_code_render <file.png>      Save the shown code tab's render (its own pixels, not the screen)
	write_project_file <path> <text> Write a project file ("\n", "\t"), as another program would
	copy_into_project <file> <project path>
	                                 Copy a file into the project (its folders made)
	live_select <node name>          Choose a node of the running game in the Live tab
	code_dialog_pick <path>          Answer the code editor's Open / Save As dialog with a project path
	save_viewport_render <png>       Write the viewport's last render (the engine's pixels, never the
	                                 screen) to a file, to look at
	code_import_path <zed | vscode> <file>   Where the shown code tab imports key bindings from
	double_click_widget <key>        Double-click the center of a widget's visible part
	wheel_widget <key> <steps>       Turn the wheel over a widget (positive: up / back)
	scroll_into_view <scroll key> <widget key>
	                                 Scroll so the widget is in view, e.g.
	                                 scroll_into_view inspector-scroll inspector-new-script
	right_click_row <tree key> <row> Right-click a row (opens the scene tree's context menu)
	click_context_item <label>[/<label>]  Choose an item of the open context menu (context_menus.odin)
	                                 by its label, or the start of it ("Open Script" for "Open
	                                 Script (Mover)"); "Transform/Reset Scale" goes through a submenu
	right_click_node <name>          Right-click a node in the viewport (its context menu)
	right_click_world <x> <y>        Right-click a world point in the viewport
	right_click_widget <key>         Right-click the middle of a widget (a tab, a log line...)
	drag_guide <top | left> <world>  Pull a guide out of a ruler to a world y (top) or x (left)
	drag_guide_back <i>              Drag guide i back onto its ruler (it's removed)
	drag_row_to <tree key> <row> <widget key>
	                                 Drag a row onto a widget (a scene tree node onto the code tab:
	                                 code-editor)
	drag_row <tree key> <from> <to> <before | inside | after>
	                                 Drag a row onto another row (top quarter, middle, bottom
	                                 quarter); a `to` past the last row drops below the rows
	click_node <name> [ctrl | shift] Click a node in the viewport (current scene)
	select_node <name>               Select a node of the current scene by name (as a click on its row)
	box_select <x0> <y0> <x1> <y1>   Drag a selection box in the viewport, in world coordinates
	drag_to_viewport <browser row> <dx> <dy>
	                                 Drag a browser row into the viewport, to (dx, dy) window
	                                 pixels from its center
	action <Action>                  Send an action, as its menu item would (e.g. Open_Project_Settings)
	send <Message> <value>           Send what a dropdown choice would (dropdowns can't be clicked
	                                 open): New_Script_Kind_Changed <Node | Global | Data>,
	                                 Global_Added <script>, New_Data_Type_Changed <type>,
	                                 Project_Settings_Tab_Changed <tab>, Git_Switch_Branch <name>,
	                                 Recent_Project_Chosen <i> (the File menu's i-th recent project)
	                                 (the Git tab's branch list), New_Script_Opened,
	                                 New_Data_Opened (no value), Scene_Tab_Changed <tab index>,
	                                 Code_Open_Requested <file> (opens it in a code tab),
	                                 Open_Grid_Settings (View > Grid Settings: Project Settings > Grid)
	                                 Right_Sidebar_Width <px> (the inspector's sidebar, as its
	                                 divider dragged; at least MIN_SIDEBAR_WIDTH)
	archive_project <path>           Export Project Archive to a file, as if picked in its dialog
	open_archive <archive> | <folder>
	                                 Open Project Archive: unpack the archive into the folder (as
	                                 if picked in its two dialogs; no unsaved-changes prompt)
	open_project <folder>            Open a project, as if picked in the folder dialog (no
	                                 unsaved-changes prompt)
	drag_node <name> <dx> <dy> [alt] Press on a node, move by (dx, dy) window pixels, release (alt: held)
	scroll <notches> [<fx> <fy>] [shift|ctrl|sideways]
	                                 Mouse wheel over the viewport (positive zooms in): its center,
	                                 or a point as fractions of its view (0 0 top-left, 1 1 bottom-right);
	                                 holding Shift or Ctrl, or turned sideways
	click <x> <y>                    Click a window position (logical pixels)
	move <x> <y>                     Move the mouse
	key <combo>                      Press a key: F5, DELETE, ctrl+s, shift+F5 (SDL scancode names;
	                                 ctrl is Cmd on macOS, as the keymap's is; control is Control)
	type <text>                      Type text into the focused field
	select_asset <path>              Select an asset in the browser (its folder opened), e.g. a component
	right_click_asset <path>         Right-click an asset's browser row (its context menu: browser-menu)
	double_click_asset <path>        Double-click an asset's browser row
	drag_asset_to <path start> <widget>
	                                 Drag the first asset whose path starts so onto a widget (a
	                                 component onto the code tab: code-editor)
	import <path>                    Import a file as an asset, as if picked in the Import dialog
	import_many <path> <path>...     Import several files at once, as the dialog sends them
	                                 (native file dialogs can't be scripted)
	quit                             End the script

Checks:

	scene <name>                 Scene open in the viewport
	scene_dirty <true | false>   The open scene or component has unsaved changes (its tab's dot)
	selected <name | none>       Selected node
	parent <name | none>         The selected node's parent
	nodes <count>                Nodes in the open scene
	play <Stopped | Building | Playing | Paused>
	tab <Console | Output | Animation>
	bottom <open | closed>       Bottom panel
	field <x | y | rotation | scale_x | scale_y | visible | name | z> <value>
	                             Property of the selected node (numbers are rounded to whole units)
	tool <Select | Move | Rotate | Scale>
	zoom <percent>               Viewport zoom, rounded to a whole percent
	viewport_center <x> <y>      The world point at the viewport's center, rounded
	viewport_center_not <x> <y>  ... isn't that point (the view moved)
	typing <true | false>        Whether a text or number field has keyboard focus
	assets <count>               Assets in the project
	browser_rows <count>         Rows the project browser shows (after search filtering)
	preview <image | audio | font | data | component | none>   What the browser's preview panel shows
	components <count>           Components in the project
	anim_source <None | Node | Set path | Aseprite path>
	                             What the Animation panel shows
	animation_set <path | none>  The selected AnimatedSprite's animation asset
	animation_sets <n>           The project's animation assets (.anim.xml)
	kind <NodeKind | none>       The selected node's kind
	texture <path | none>        The selected node's texture
	preview_visible <true | false>   The image preview got usable space (at least 32 x 32)
	audio <playing | stopped>    Sound preview playback
	dialog <open | closed>       The remove-asset dialog
	add_dialog <open | closed>   The Add Node dialog
	context_menu <open | closed>  The right-click menu (context_menus.odin)
	scene_clipboard <true | false>  A scene was copied (the browser's Copy)
	import_folder <path end>     Where the Import dialog opens next (the last import's folder)
	local_axes <on | off>        The move arrows follow the node's own axes
	live_theme <applied | draft> The look the editor shows is the applied settings' (or the dialog's draft)
	theme_color <key> <#RRGGBB>  A theme color the editor shows now (bg, primary...: editor.ini's keys)
	guides <n>                   The open scene's guides
	guide <i> <x | y> <at>       Guide i: vertical (x) or horizontal (y), where (rounded)
	context_item <label> <enabled | disabled | checked | missing>  An item of the open menu
	                             ("Show/Grid" in a submenu)
	row <n> <name>               Node shown in row n of the scene tree
	clipboard <count>            Nodes copied (a subtree)
	selection <count>            Selected nodes
	scenes <A,B,C>               The project's scenes, in order
	start_scene <name>           The scene the game starts in
	project_settings <open | closed>   The Project Settings dialog
	script <name | none>         The selected node's script
	scripts <Unknown | Building | Ready | Failed>   The script catalog (the last build)
	prop <name> <value>          A script value stored on the selected node ("(default)" if none)
	new_script_dialog <open | closed>
	linked <Position | Scale> <true | false>   An inspector X/Y pair is linked
	renaming <true | false>      A node is being renamed in the scene tree
	grid <on | off>, snap <on | off>   Viewport grid and snapping
	modified <true | false>      The project has unsaved changes
	project <name>               The open project's name
	ldtk_level <identifier|first>    The selected LDtkLevel node's level
	about_dialog <open | closed>, confirm_dialog <open | closed>, new_project_dialog <open | closed>
	settings_dialog <open | closed>
	setting <font_size | spacing | row_height | theme | undo_merge_ms | undo_limit | console_limit> <value>
	project_grid <width> <height> <majorEvery> <opacity> <majorOpacity>   The project's viewport grid
	                             An active (applied) setting
	chord <Action> <text>        An action's shortcuts as the settings file writes them, e.g.
	                             chord Redo Ctrl+Shift+Z | Ctrl+Y ("-" for none)
	capture <on | off>           The Settings dialog is waiting for a key to bind
	settings_file_contains <text>   The saved settings file contains the text
	undo <count>                 Steps on the undo stack
	redo <count>                 Steps on the redo stack
	console_contains <text>      A console line contains the text
	console_lines <n>, output_lines <n>   Lines the Console (Output tab) keeps
	console_shown <n>, output_shown <n>   ... of them its filters let through
	console_following <true | false>, output_following   The list follows its newest line
	console_first <text>         The oldest line the Console keeps contains the text
	console_category <name> <shown | hidden | missing>, output_category   A category's filter
	console_line_category <category> <Level> <text>   The first Console line containing the text
	                             has that category and level
	output_contains <text>       An Output line contains the text
	export <idle | running>      Whether exports are running
	archive <idle | busy>        Whether a project archive is being written or unpacked
	console_lacks <text>         No Console line contains the text
	ldtk_preview <levels> <entities> <shapes>
	                             What the viewport built for the selected LDtkLevel node
	aseprite <layers|pivot|nine|slice> <value | none>
	                             The selected node's Aseprite settings
	timeline <clip|clips|tracks|keys|playhead|playing|autoplay> <value>
	                             The Timeline: its clip's name, clip count, track count, the selected track's key count,
	                             playhead (2 decimals), playing, the clip the Animator starts with
	timeline_key <track> <key> <seconds> [value]
	                             A key of the Timeline's clip (seconds with 2 decimals)
	ui <layout|anchor|text|action|width|height|theme|value|min|max|step|checked> <value>
	                             The selected UI control's settings ("none" for empty text)
	nav <cellSize|agentRadius|diagonal|speed|autoMove|width> <value>
	                             The selected NavRegion's or NavAgent's settings
	camtool <factorX|repeatX|transition|zoom|camera> <value>
	                             The selected ParallaxLayer's, CameraZone's or CameraView's settings ("none": no camera)
	cam <target|mode|smoothTime|maxSpeed|deadzoneX|offsetY|lookAheadX|limits|limitLeft|limitRight|shakeStrength|zoom> <value>
	                             The selected Camera's follow target and settings ("none": no target; limits as Left,Top or none)
	states <states|transitions|params|start|selected|position> <value>
	                             The States tab's machine: counts, its start, the selected state's name
	                             ("none") and position ("x, y")
	live <connected|paused|shapes|nodes|properties|selected|scene> <value>
	game pid <new | same | none>  The running game's process against note_game's
	game restartable <true | false>   Restart has a game (or Play's build) to restart
	                             The Live tab's view of the running game (counts for nodes and
	                             properties; selected: true when a node is chosen)
	live prop <name> <value>     The chosen node's property as the running game sent it
	asset <path> <exists | missing | filter <Default|Smooth|Pixel> | msdf <bool>>
	                             A project asset and its import settings
	file_exists <path>           A file in the project folder
	atlas <regions|padding|filter> <value>
	                             The atlas the inspector shows
	region <name | none>         The selected Sprite's atlas region
	plugin <folder> <Waiting|Building|Loaded|Failed>
	                             A project plugin's state (plugin_host.odin)
	dialogue <shown | nodes | start | node | steps | step <i> <text|speaker|kind|options|target>> <value>
	                             The Dialogue tab's dialogue and its selected node
	node_type <name | none>      The selected node's node type of the project's code
	more_scripts <a,b | none>    The selected node's more scripts (after its first)
	script_prop <script> <field> <value>
	                             A value stored for one of the selected node's scripts or its node
	                             type ("(default)" when not set)
	scene_lit <true | false>     The open scene's lighting is on
	light <kind|energy|radius|angle|shadows> <value>
	traced <node> <n | > n>       The traced CollisionShapes (named Traced...) under a node
	material <friction|restitution|density> <value>   The material the inspector shows (2 decimals)
	node_material <path | none>   The selected node's physics material
	                             The selected Light2D's settings
	viewport_unlit <true | false>   The viewport shows lit scenes unlit
	themes <count>               The project's UI themes
	theme <field> <value>        A field of the theme the inspector shows (an e.UITheme field's name)
	ui_theme <path | none>       The project's UI theme
	tile_tool <Tool>             The Tiles panel's tool (Paint, Erase, Rectangle, Fill, Pick, Terrain)
	tile_brush <n>               The Tiles panel's brush tile (flips left out)
	tile <layer> <column> <row> <tile>
	                             A cell of the selected TileMap (painted, else the file's; flips left out)
	tilemap <file|frame|layers|collision> <value>
	                             The selected TileMap's settings (layers "all": every visible one)
	tilemap_built <layers> <shapes> <areas>
	                             What the viewport built for it: layers, solid and one-way shapes, Areas
	ldtk_areas <name> <shapes>[, ...] | none
	                             The Areas its collision values made (name, shapes)
	git <idle | busy>            Whether the Git tab runs a command or reads the repository
	git_state <Unknown | Missing | Not_Repo | Repo>
	git_branch <name>            The project's branch
	git_changes <n>              Changed files in the project folder; git_staged <n>: staged
	git_commits <n>              Commits in the history; git_last_commit <subject>: the newest
	git_diff <path|none>         The change whose diff shows; git_diff_contains <text>: in it
	git_discard_dialog <open|closed>  Asking before discarding a change
	export_enabled <Target> <true | false>   An export target is checked (the project's settings)
	project_file <path>          A file exists, relative to the project folder (an export's output)
	project_file_missing <path>  No such file or folder, relative to the project folder
	project_file_contains <path> <text>   A project file contains the text (after saving)
	project_file_lacks <path> <text>      A project file doesn't contain the text
	shapes <on | off>            The viewport outlines collision shapes, rays and joints
	generated_shapes <solid> <one-way> <area>
	                             The collision shapes the open scene's LDtkLevels and TileMaps
	                             built in the viewport (drawn while `shapes` is on)
	physics_debug_shown <on | off>   What the toolbar's collision shapes button shows (a running
	                             game's, else the project's)
	particle <setting> <value>   A ParticleEmitter setting of the selected node, as scene files
	                             store it (e.g. particle amount 50, particle size 5,5)
	particle_near <setting> <value> <tolerance>   A numeric particle setting is within tolerance
	particle_linked <setting> <true | false>   A particle [2]f32 setting's axes are linked
	ramp_stops <count>           Stops in the selected emitter's color ramp
	ramp_stop <index>            The color ramp editor's selected stop
	input_actions <count>        The project's input actions; draft_input_actions: Project Settings' draft
	input_bindings <action> <a, b, ...>   An action's bindings, described (e.Input_BindingDescribe)
	draft_input_bindings <a, b, ...>      The bindings of the action Project Settings > Input shows
	buses <count>                The project's mix buses (Master counts)
	bus <i> <name|volume|pan|mute|nodes|effects> <value>   A bus (0 is Master)
	bus_effect <bus> <i> <kind|bypass|cutoff|resonance|delay|feedback|roomSize|damping|mix> <value>
	                             One of a bus's effects (bus_effects_edit.odin)
	bus_selection <i | -1>       The bus whose effects the inspector shows
	preview_effects <bus> <master>   How many effects the editor's audio preview plays through
	touch <actions|radius|deadzone|zone|floating|visibility|mouse|opacity|label> <value>
	                             The selected VirtualJoystick or TouchButton (touch_edit.odin)
	players <max|keyboard|join> <value>   The project's local players settings (players_edit.odin)
	steam <app_id|cloud|achievements|draft_achievements> <value>, steam achievement <i> <field> <value>
	                             The project's Steam settings (steam_edit.odin)
	viewport_has_color <#rrggbb> <distance> <true|false>   A pixel of the viewport's last render near the color
	shader <path|param <name>> <value>   The selected node's shader, or one of its parameters' stored text ("default")
	music_layer <i> <name|sound|volume> <value>, music_layer count <n>
	                             The selected MusicPlayer's layers (music_layers_edit.odin)
	scene_tabs <a,b,...>         The scene and component tabs, by name, in order
	toolchain <tool name>: <found | missing>   A Settings > Toolchain row (toolchain Odin compiler: found)
	code_tabs <count>            Open code tabs
	code_close_dialog <open | closed>   The "save changes?" prompt for closing a code tab
	code_disk_conflict <true | false>   The shown file changed on disk under unsaved changes (the bar)
	code_state <field> <value>   The code editor's state: a dotted path in its control JSON
	                             (cursors, selected_text, current_line, find.open, palette.open,
	                             problems.open, window, font_size, ...; arrays compare by length),
	                             or peek_open, refs_open, refs, status (contains), dialog
	code_servers <n> running, <m> started   Language servers (every tab shares one)
	code_tab <file name | none>  The code tab that shows (none: the scene)
	code_focused <true | false>  The code editor has the keyboard
	code_contains <true | false> <text>   The shown code tab's text contains the text (\t, \n)
	code_dirty <true | false>    The shown code tab has unsaved changes
	code_caret <line> <column>   The shown code tab's caret (1-based)
	code_read_only <true | false> The shown code tab refuses edits (a file outside the project)
	render_path <shared | readback | software>   How the viewport draws: straight into Skald's image
	                                 on its GPU device, read back from a GPU renderer, or in software
	code_render_path <shared | software>         How the shown code tab draws
	code_rendered <true | false> The shown code tab drew text (pixels unlike its background) and
	                             that render is the image on screen
	code_lsp <Off | Starting | Running | Failed>   The shown code tab's language server
	code_completion <true | false>   The completion list shows
	code_completion_has <label>      The server's last completion list has that item
	widget_visible <key> <true | false>   Some of the widget was drawn last frame, not clipped away
	recent_menu <i> <folder name | none>   The File menu's i-th recent project (its folder's name)
	in_window <key>              The widget's whole rect is inside the window (not pushed off its edge)
	widget_inside <key> <container key>  All of the widget's rect is inside the container's (content
	                                 that overflows a dialog is drawn, but outside it)
	clear_of_scrollbar <key> <scroll key>   The widget ends left of the scroll's scrollbar strip
	                                 (INSPECTOR_SCROLLBAR_WIDTH): an inspector row fits controlWidth
	scrolled <scroll key> <true | false>  A scroll container is scrolled down from its top
	widget_bottom_near <key> <other key> <px>   The two widgets' bottoms are within px (one fills the other)
	row_visible <tree key> <row> <true | false>   A tree row is wholly inside its scroll's view
	meter <key> <sounding | silent>   A level meter shows more than -50 dB, or nothing
	bus <index> <name | volume | pan | mute | nodes> <value>   A bus (numbers with two decimals)
	sound <sound | bus | volume | pitch | pan | loop | autostart | range> <value>
	                             The selected sound node's settings ("none" for no sound; bus "Master")
	animations <count>           Animations of the selected AnimatedSprite
	animation <name | start | end | count | fps | loop | mode | sheet | grid | columns | rows | cell | margin | gap | cells | repeat | durations> <value> (durations: ms, space separated, or none)
	                             The Animation panel's selected animation (start and end resolved;
	                             sheet "none" for none; grid Cells or Size; cell <w>x<h>; cells:
	                             how many its sheet has)
	animation_note <text | none>  What the selected animation's grid leaves unused (`AnimEdit_SheetNote`: "Left over
	                             (not part of any frame): 28 px on the right", or cells not whole pixels)
	autoplay <name | none>       The animation the selected sprite starts with
	sheet_loaded <true | false>  The Animation panel uploaded the selected animation's sheet (thumbnails)
	globals <A,B | none>         The project's global scripts, in order
	draft_globals <A,B | none>   The Project Settings dialog's globals
	data_count <n>               The project's data resources
	inspector_data <name | none> The data resource the inspector shows
	data_value <name> <field> <value>   A data resource's value ("(default)" if it has none)
	physics_debug <on | off>     The project's Show collision shapes (development) setting

Every input command waits INPUT_SETTLE_FRAMES afterwards, so its effects are visible to the
next check.
*/

INPUT_SETTLE_FRAMES :: 3
DEFAULT_WAIT_TIMEOUT :: 10 * time.Second
// How often a `wait_until code_completion_has` asks the language server again
COMPLETION_RETRY :: 3 * time.Second
// A script that hasn't finished after this long fails
SCRIPT_TIMEOUT :: 300 * time.Second

// Sent every frame while a script runs, so the editor keeps drawing frames
Script_Tick :: struct {}

@(private="file")
Driver :: struct {
	active: bool,
	path: string,
	lines: []string,
	line: int,
	// Frames to let pass before the next command
	waitFrames: int,
	// Events to push on later frames, one batch per frame (a release after a press, drag steps)
	pending: [dynamic][dynamic]sdl.Event,
	// Active wait_until: the check and its deadline
	waitCheck: string,
	waitDeadline: time.Tick,
	waitTimeout: time.Duration,
	// When a `code_completion_has` wait last asked the language server again
	waitAsked: time.Tick,
	started: time.Tick,
	failures: int,
	finished: bool,
	// Window size, and since when it hasn't changed (the first command waits for it to settle)
	windowSize: [2]f32,
	// scroll_into_view: pages scrolled so far looking for the widget
	scrollAttempts: int,
	// The scroll offset scroll_into_view saw last time (to notice the end of the content)
	lastScrollY: f32,
	windowSettled: time.Tick,
	ready: bool,
	// frame_times: frames left to time, lines added each of them, the last frame's start, the
	// frame times so far (milliseconds)
	timing: int,
	timingLines: int,
	timingLast: time.Tick,
	times: [dynamic]f64,
	// note_game: the running game's process id then (the `game pid` check compares)
	notedPid: int,
}

// A new window may still be resized (tiled) right after it opens; the script starts once its
// size has stayed the same this long, so clicks aren't aimed at a layout that then moves
WINDOW_SETTLE_TIME :: 1500 * time.Millisecond

@(private="file")
driver: Driver

/*
Loads a script. Call before the app starts.

Inputs:
- path: Script file

Returns:
- false if the file can't be read
*/
ScriptDriver_Load :: proc(path: string) -> bool {
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil {
		fmt.eprintfln("[script] can't read %s: %v", path, err)
		return false
	}
	driver = {
		active = true,
		path = path,
		lines = strings.split_lines(string(data)),
		started = time.tick_now(),
	}
	return true
}

// The user's clipboard, kept while a script runs (the code editor's Copy and Cut use it) and put back
@(private="file")
savedClipboard: struct {
	saved: bool,
	text: string,
}

@(private="file")
saveClipboard :: proc() {
	if savedClipboard.saved do return
	savedClipboard.saved = true
	if sdl.HasClipboardText() {
		text := sdl.GetClipboardText()
		savedClipboard.text = strings.clone(string(cstring(text)))
		sdl.free(text)
	}
}

@(private="file")
restoreClipboard :: proc() {
	if !savedClipboard.saved do return
	_ = sdl.SetClipboardText(strings.clone_to_cstring(savedClipboard.text, context.temp_allocator))
	delete(savedClipboard.text)
	savedClipboard = {}
}

// Whether a script is driving the editor
ScriptDriver_Active :: proc() -> bool {
	return driver.active
}

// Exit code for a finished script: 0 when every check passed
ScriptDriver_ExitCode :: proc() -> int {
	return driver.failures == 0 && driver.finished ? 0 : 1
}

/*
Runs script commands for this frame. Called from `view`, which has what the driver needs: the
widget rectangles from the last frame and the current state.
*/
ScriptDriver_Frame :: proc(s: ^State, ctx: ^skald.Ctx(Msg)) {
	if !driver.active do return
	saveClipboard()
	// Keep frames coming while the script runs
	skald.send(ctx, Msg(Script_Tick{}))

	if time.tick_since(driver.started) > SCRIPT_TIMEOUT {
		fail("script timed out")
		finish(ctx)
		return
	}

	// frame_times: one frame timed per frame
	if driver.timing > 0 {
		now := time.tick_now()
		if driver.timingLast != {} do append(&driver.times, time.duration_milliseconds(time.tick_diff(driver.timingLast, now)))
		driver.timingLast = now
		driver.timing -= 1
		if driver.timingLines > 0 do skald.send(ctx, Msg(Log_Test_Lines{count = driver.timingLines, level = .Info, category = "spam"}))
		if driver.timing == 0 {
			slice.sort(driver.times[:])
			n := len(driver.times)
			if n > 0 {
				report(true, fmt.tprintf("frame_times: %d frames, median %.2f ms, p95 %.2f ms, max %.2f ms (%d console lines)",
					n, driver.times[n / 2], driver.times[min(n * 95 / 100, n - 1)], driver.times[n - 1], len(LogList_Lines(&s.console))))
			}
			clear(&driver.times)
		}
		return
	}
	// Events queued by the previous command go out one batch per frame
	if len(driver.pending) > 0 {
		batch := driver.pending[0]
		for &event in batch do _ = sdl.PushEvent(&event)
		delete(batch)
		ordered_remove(&driver.pending, 0)
		return
	}
	if driver.waitFrames > 0 {
		driver.waitFrames -= 1
		return
	}
	if !driver.ready {
		size := ctx.renderer != nil ? [2]f32{f32(ctx.renderer.fb_size.x), f32(ctx.renderer.fb_size.y)} : {}
		if size != driver.windowSize || driver.windowSettled == {} {
			driver.windowSize = size
			driver.windowSettled = time.tick_now()
			return
		}
		if time.tick_since(driver.windowSettled) < WINDOW_SETTLE_TIME do return
		driver.ready = true
	}
	if driver.waitCheck != "" {
		ok, message := runCheck(s, ctx, driver.waitCheck)
		if ok {
			report(true, fmt.tprintf("wait_until %s", driver.waitCheck))
			driver.waitCheck = ""
			// Let the views catch up: the next command may click something that only appears now
			driver.waitFrames = INPUT_SETTLE_FRAMES
			return
		} else if time.tick_since(driver.waitDeadline) > 0 {
			fail(fmt.tprintf("wait_until %s: timed out after %v (%s)", driver.waitCheck, driver.waitTimeout, message))
			driver.waitCheck = ""
		} else {
			// The server may answer before it has read a file just written (busy machine):
			// ask again every few seconds, as a person would with Ctrl+Space
			if strings.has_prefix(driver.waitCheck, "code_completion_has") && time.tick_since(driver.waitAsked) > COMPLETION_RETRY {
				driver.waitAsked = time.tick_now()
				CodeEditor_RequestCompletion(CodeTabs_Active(s))
			}
			return
		}
	}

	// Run commands until one needs to wait for later frames
	for driver.line < len(driver.lines) {
		line := strings.trim_space(driver.lines[driver.line])
		driver.line += 1
		if line == "" || strings.has_prefix(line, "#") do continue
		if !runCommand(s, ctx, line) do return
	}
	finish(ctx)
}

// Runs one command. Returns false when the script must wait before the next one
@(private="file")
runCommand :: proc(s: ^State, ctx: ^skald.Ctx(Msg), line: string) -> bool {
	// {selected} stands for the selected node's index (widget keys like inspector-name-{selected})
	line, _ := strings.replace_all(line, "{selected}", fmt.tprint(s.selectedNode), context.temp_allocator)
	command, _, rest := strings.partition(line, " ")
	rest = strings.trim_space(rest)
	args := strings.fields(rest, context.temp_allocator)

	switch command {
	case "wait":
		driver.waitFrames = max(atoi(args, 0, 1), 1)
		return false

	case "wait_until":
		check := rest
		driver.waitTimeout = DEFAULT_WAIT_TIMEOUT
		if index := strings.index(rest, "timeout="); index >= 0 {
			if seconds, ok := strconv.parse_f64(rest[index + len("timeout="):]); ok {
				driver.waitTimeout = time.Duration(seconds * f64(time.Second))
			}
			check = strings.trim_space(rest[:index])
		}
		driver.waitCheck = strings.clone(check)
		driver.waitDeadline = time.tick_add(time.tick_now(), driver.waitTimeout)
		driver.waitAsked = time.tick_now()
		return false

	case "if_drawn":
		// Runs the command only when the widget was drawn last frame (a layout that depends on
		// the window's size: the toolbar's overflow); otherwise it's skipped
		key, _, command := strings.partition(rest, " ")
		st, drawn := ctx.widgets.states[skald.hash_id(key)]
		if drawn && st.last_frame + 1 >= ctx.widgets.frame && st.last_rect.w > 0 do return runCommand(s, ctx, strings.trim_space(command))
		report(true, fmt.tprintf("%s (skipped: not drawn)", line))
		return true

	case "note_game":
		driver.notedPid = s.play.stage == .Running ? s.play.process.pid : 0
		report(true, line)
		return true

	case "expect":
		ok, message := runCheck(s, ctx, rest)
		if ok do report(true, line)
		else do fail(fmt.tprintf("%s (%s)", line, message))
		return true

	case "click_widget":
		rect, ok := widgetRect(ctx, rest)
		if !ok {
			fail(fmt.tprintf("%s: no widget with key '%s' was drawn last frame", line, rest))
			return true
		}
		click({rect.x + rect.w * 0.5, rect.y + rect.h * 0.5})
		report(true, line)
		return false

	case "click_log_location":
		// The n-th shown line (1 by default) of the Console or Output tab naming a source location
		// (error_locations.odin): scrolled into view, then clicked (right: its menu)
		output := len(args) > 0 && args[0] == "output"
		key := output ? "output-scroll" : "console-scroll"
		n, right := 1, false
		for a in args[1:] {
			if a == "right" do right = true
			else if v, isNumber := strconv.parse_int(a); isNumber do n = v
		}
		list := logListOf(s, output)
		lines := LogList_Lines(list)
		shown := LogList_Shown(list)
		row, index, count := -1, -1, 0
		for i, r in shown {
			if _, located := ErrorLocation_Parse(lines[i].text); located {
				count += 1
				if count == n {
					row, index = r, i
					break
				}
			}
		}
		if index < 0 {
			fail(fmt.tprintf("%s: %d shown lines name a source location", line, count))
			return true
		}
		scroll, drawn := &ctx.widgets.states[skald.hash_id(key)]
		if !drawn {
			fail(fmt.tprintf("%s: the %s tab isn't showing", line, output ? "Output" : "Console"))
			return true
		}
		area := scroll.last_rect
		rect, visible := widgetRect(ctx, fmt.tprintf("%s-link-%d", key, index))
		if !visible || rect.y < area.y || rect.y + rect.h > area.y + area.h {
			driver.scrollAttempts += 1
			if driver.scrollAttempts > 10 {
				driver.scrollAttempts = 0
				fail(fmt.tprintf("%s: line %d didn't come into view", line, index))
				return true
			}
			// Its row at the top (rows have one height: the list's content over its rows)
			if len(shown) > 0 && scroll.content_h > 0 do scroll.scroll_y = f32(row) * scroll.content_h / f32(len(shown))
			driver.line -= 1
			driver.waitFrames = INPUT_SETTLE_FRAMES
			return false
		}
		driver.scrollAttempts = 0
		at := [2]f32{rect.x + min(rect.w * 0.5, 40), rect.y + rect.h * 0.5}
		if right {
			pushMouse(.MOUSE_MOTION, at)
			queueBatch(mouseEvent(.MOUSE_BUTTON_DOWN, at, sdl.BUTTON_RIGHT))
			queueBatch(mouseEvent(.MOUSE_BUTTON_UP, at, sdl.BUTTON_RIGHT))
			driver.waitFrames = INPUT_SETTLE_FRAMES
		} else {
			click(at)
		}
		report(true, line)
		return false

	case "scroll_by":
		if len(args) < 2 || skald.hash_id(args[0]) not_in ctx.widgets.states {
			fail(fmt.tprintf("%s: expected a scroll that was drawn and a distance", line))
			return true
		}
		scroll := &ctx.widgets.states[skald.hash_id(args[0])]
		dy := f32(atoi(args, 1, 0))
		scroll.scroll_y = dy <= 0 ? 0 : scroll.scroll_y + dy
		driver.waitFrames = INPUT_SETTLE_FRAMES
		report(true, line)
		return false

	case "click_offset":
		if len(args) < 3 {
			fail(fmt.tprintf("%s: expected a widget key and dx dy", line))
			return true
		}
		state, ok := ctx.widgets.states[skald.hash_id(args[0])]
		if !ok || state.last_rect.w <= 0 {
			fail(fmt.tprintf("%s: no widget with key '%s' was drawn last frame", line, args[0]))
			return true
		}
		point := [2]f32{state.last_rect.x + f32(atoi(args, 1, 0)), state.last_rect.y + f32(atoi(args, 2, 0))}
		click(point, len(args) > 3 && args[3] == "shift" ? {.LSHIFT} : {})
		report(true, line)
		return false

	case "click_tile":
		// A tile of the Tiles panel's palette (view_tiles.odin)
		state, ok := ctx.widgets.states[skald.hash_id("tiles-palette")]
		if !ok || state.last_rect.w <= 0 {
			fail(fmt.tprintf("%s: the tile palette wasn't drawn last frame", line))
			return true
		}
		offset := TilesPanel_TileCenter(atoi(args, 0, 1))
		click({state.last_rect.x + offset.x, state.last_rect.y + offset.y}, {})
		report(true, line)
		return false

	case "drag_guide", "drag_guide_back":
		// drag_guide <top | left> <world>: out of a ruler to a world y (top) or x (left);
		// drag_guide_back <i>: guide i back onto its ruler (removed)
		rect, ok := widgetRect(ctx, "viewport-canvas")
		if !ok || s.viewport.zoom <= 0 {
			fail(fmt.tprintf("%s: the viewport hasn't been drawn", line))
			return true
		}
		middle := [2]f32{rect.x + RULER_SIZE + (rect.w - RULER_SIZE) * 0.5, rect.y + RULER_SIZE + (rect.h - RULER_SIZE) * 0.5}
		center := s.viewport.center
		from, to: [2]f32
		if command == "drag_guide" {
			at, _ := strconv.parse_f32(len(args) > 1 ? args[1] : "")
			top := len(args) > 0 && args[0] == "top"
			from = top ? [2]f32{middle.x, rect.y + RULER_SIZE * 0.5} : [2]f32{rect.x + RULER_SIZE * 0.5, middle.y}
			to, _ = ViewportWorldToWindow(s, ctx, top ? [2]f32{center.x, at} : [2]f32{at, center.y})
		} else {
			guides := s.project.scenes[s.currentScene].guides[:]
			i := atoi(args, 0, 0)
			if i < 0 || i >= len(guides) {
				fail(fmt.tprintf("%s: the scene has %d guides", line, len(guides)))
				return true
			}
			g := guides[i]
			from, _ = ViewportWorldToWindow(s, ctx, g.vertical ? [2]f32{g.at, center.y} : [2]f32{center.x, g.at})
			to = g.vertical ? [2]f32{rect.x + RULER_SIZE * 0.5, from.y} : [2]f32{from.x, rect.y + RULER_SIZE * 0.5}
		}
		pushMouse(.MOUSE_MOTION, from)
		queueBatch(mouseEvent(.MOUSE_BUTTON_DOWN, from))
		STEPS :: 4
		for i in 1..=STEPS do queueBatch(mouseEvent(.MOUSE_MOTION, from + (to - from) * f32(i) / STEPS))
		queueBatch(mouseEvent(.MOUSE_BUTTON_UP, to))
		driver.waitFrames = INPUT_SETTLE_FRAMES
		report(true, line)
		return false

	case "drag_world":
		// drag_world x1 y1 x2 y2 [right]: press at a world point, move to another, release
		if len(args) < 4 {
			fail(fmt.tprintf("%s: expected x1 y1 x2 y2", line))
			return true
		}
		a, okA := ViewportWorldToWindow(s, ctx, {f32(atoi(args, 0, 0)), f32(atoi(args, 1, 0))})
		b, okB := ViewportWorldToWindow(s, ctx, {f32(atoi(args, 2, 0)), f32(atoi(args, 3, 0))})
		if !okA || !okB {
			fail(fmt.tprintf("%s: the viewport hasn't been drawn", line))
			return true
		}
		button := len(args) > 4 && args[4] == "right" ? sdl.BUTTON_RIGHT : sdl.BUTTON_LEFT
		pushMouse(.MOUSE_MOTION, a)
		queueBatch(mouseEvent(.MOUSE_BUTTON_DOWN, a, button))
		STEPS :: 4
		for i in 1..=STEPS do queueBatch(mouseEvent(.MOUSE_MOTION, a + (b - a) * f32(i) / STEPS))
		queueBatch(mouseEvent(.MOUSE_BUTTON_UP, b, button))
		driver.waitFrames = INPUT_SETTLE_FRAMES
		report(true, line)
		return false

	case "click_state", "drag_state":
		node, _ := States_Machine(s)
		i := atoi(args, 0, 0)
		if node == nil || i < 0 || i >= len(node.stateMachine.states) {
			fail(fmt.tprintf("%s: no state %d in the States tab", line, i))
			return true
		}
		r := States_BoxRect(node.stateMachine.states[i])
		at := statesGraphOrigin + [2]f32{r[0] + r[2] * 0.5, r[1] + r[3] * 0.5}
		if command == "click_state" {
			click(at)
		} else {
			to := at + [2]f32{f32(atoi(args, 1, 0)), f32(atoi(args, 2, 0))}
			pushMouse(.MOUSE_MOTION, at)
			queueBatch(mouseEvent(.MOUSE_BUTTON_DOWN, at))
			STEPS :: 4
			for k in 1..=STEPS do queueBatch(mouseEvent(.MOUSE_MOTION, at + (to - at) * f32(k) / STEPS))
			queueBatch(mouseEvent(.MOUSE_BUTTON_UP, to))
			driver.waitFrames = INPUT_SETTLE_FRAMES
		}
		report(true, line)
		return false

	case "click_timeline", "drag_timeline_key":
		// Points in the Timeline's tracks canvas (view_timeline.odin's measures)
		state, ok := ctx.widgets.states[skald.hash_id("timeline-canvas")]
		clip := Timeline_Clip(s)
		if !ok || state.last_rect.w <= 0 || clip == nil {
			fail(fmt.tprintf("%s: the Timeline's tracks weren't drawn last frame", line))
			return true
		}
		r := state.last_rect
		at :: proc(r: skald.Rect, length, seconds: f32, row: int) -> [2]f32 {
			y := row < 0 ? f32(TIMELINE_RULER_HEIGHT) * 0.5 : f32(TIMELINE_RULER_HEIGHT) + (f32(row) + 0.5) * TIMELINE_ROW_HEIGHT
			return {r.x + Timeline_TimeX(timelineCanvasWidth, length, seconds), r.y + y}
		}
		if command == "click_timeline" {
			seconds, _ := strconv.parse_f32(len(args) > 0 ? args[0] : "0")
			row := len(args) > 1 ? atoi(args, 1, -1) : -1
			p := at(r, clip.length, seconds, row)
			if len(args) > 2 && args[2] == "double" {
				pushMouse(.MOUSE_MOTION, p)
				queueBatch(mouseEvent(.MOUSE_BUTTON_DOWN, p))
				queueBatch(mouseEvent(.MOUSE_BUTTON_UP, p))
				second := mouseEvent(.MOUSE_BUTTON_DOWN, p)
				second.button.clicks = 2
				queueBatch(second)
				queueBatch(mouseEvent(.MOUSE_BUTTON_UP, p))
				driver.waitFrames = INPUT_SETTLE_FRAMES
			} else {
				click(p)
			}
			report(true, line)
			return false
		}
		track, key := atoi(args, 0, 0), atoi(args, 1, 0)
		seconds, _ := strconv.parse_f32(len(args) > 2 ? args[2] : "0")
		if track < 0 || track >= len(clip.tracks) || key < 0 || key >= len(clip.tracks[track].keys) {
			fail(fmt.tprintf("%s: no key %d on track %d", line, key, track))
			return true
		}
		a := at(r, clip.length, clip.tracks[track].keys[key].time, track)
		b := at(r, clip.length, seconds, track)
		pushMouse(.MOUSE_MOTION, a)
		queueBatch(mouseEvent(.MOUSE_BUTTON_DOWN, a))
		STEPS :: 4
		for i in 1..=STEPS do queueBatch(mouseEvent(.MOUSE_MOTION, a + (b - a) * f32(i) / STEPS))
		queueBatch(mouseEvent(.MOUSE_BUTTON_UP, b))
		driver.waitFrames = INPUT_SETTLE_FRAMES
		report(true, line)
		return false

	case "paint_cells":
		// paint_cells c1 r1 c2 r2 [right]: a stroke from one cell's center to another's, in the
		// selected TileMap's layer the Tiles panel paints
		node, ase := TilePaint_Node(s)
		if node == nil || len(args) < 4 {
			fail(fmt.tprintf("%s: expected the Tiles tab showing a TileMap, and c1 r1 c2 r2", line))
			return true
		}
		layer := TilePaint_Layer(s, node, ase)
		center :: proc(s: ^State, node: ^NodeDef, ase: ^e.Aseprite, layer: string, c: [2]int) -> [2]f32 {
			lo, hi, _ := TilePaint_CellsRect(s, node, ase, layer, c, c)
			return (lo + hi) * 0.5
		}
		a, okA := ViewportWorldToWindow(s, ctx, center(s, node, ase, layer, {atoi(args, 0, 0), atoi(args, 1, 0)}))
		b, okB := ViewportWorldToWindow(s, ctx, center(s, node, ase, layer, {atoi(args, 2, 0), atoi(args, 3, 0)}))
		if !okA || !okB {
			fail(fmt.tprintf("%s: the viewport hasn't been drawn", line))
			return true
		}
		button := len(args) > 4 && args[4] == "right" ? sdl.BUTTON_RIGHT : sdl.BUTTON_LEFT
		pushMouse(.MOUSE_MOTION, a)
		queueBatch(mouseEvent(.MOUSE_BUTTON_DOWN, a, button))
		for i in 1..=4 do queueBatch(mouseEvent(.MOUSE_MOTION, a + (b - a) * f32(i) / 4))
		queueBatch(mouseEvent(.MOUSE_BUTTON_UP, b, button))
		driver.waitFrames = INPUT_SETTLE_FRAMES
		report(true, line)
		return false

	case "click_frame":
		state, ok := ctx.widgets.states[skald.hash_id("animation-frames")]
		if !ok || state.last_rect.w <= 0 {
			fail(fmt.tprintf("%s: the frames weren't drawn last frame", line))
			return true
		}
		offset := AnimationPanel_FrameCenter(atoi(args, 0, 0))
		at := [2]f32{state.last_rect.x + offset.x, state.last_rect.y + offset.y}
		if len(args) > 1 && args[1] == "right" {
			pushMouse(.MOUSE_MOTION, at)
			queueBatch(mouseEvent(.MOUSE_BUTTON_DOWN, at, sdl.BUTTON_RIGHT))
			queueBatch(mouseEvent(.MOUSE_BUTTON_UP, at, sdl.BUTTON_RIGHT))
			driver.waitFrames = INPUT_SETTLE_FRAMES
		} else {
			click(at, len(args) > 1 && args[1] == "shift" ? {.LSHIFT} : {})
		}
		report(true, line)
		return false

	case "click_overlay_item":
		// The buttons drawn on an overlay layer last frame, top to bottom
		items := make([dynamic]skald.Rect, context.temp_allocator)
		newest: u64
		for _, st in ctx.widgets.states do if st.kind == .Button do newest = max(newest, st.last_overlay_frame)
		// Inside the popup: the last overlay drawn (a dialog's own buttons are on an overlay too)
		popup: skald.Rect
		if n := len(ctx.widgets.overlay_rects_prev); n > 0 do popup = ctx.widgets.overlay_rects_prev[n - 1]
		inside :: proc(r, area: skald.Rect) -> bool {
			return area.w <= 0 || (r.x >= area.x - 1 && r.y >= area.y - 1 && r.x + r.w <= area.x + area.w + 1 && r.y + r.h <= area.y + area.h + 1)
		}
		for _, st in ctx.widgets.states {
			if st.kind == .Button && newest > 0 && st.last_overlay_frame == newest && st.last_rect.w > 0 && inside(st.last_rect, popup) do append(&items, st.last_rect)
		}
		slice.sort_by(items[:], proc(a, b: skald.Rect) -> bool { return a.y < b.y })
		index := atoi(args, 0, 0)
		if index < 0 || index >= len(items) {
			fail(fmt.tprintf("%s: the popup has %d buttons", line, len(items)))
			return true
		}
		r := items[index]
		click({r.x + r.w * 0.5, r.y + r.h * 0.5})
		report(true, line)
		return false

	case "click_at", "drag_widget":
		count := command == "click_at" ? 3 : 5
		if len(args) < count {
			fail(fmt.tprintf("%s: expected a widget key and %d fractions", line, count - 1))
			return true
		}
		rect, ok := widgetRect(ctx, args[0])
		if !ok {
			fail(fmt.tprintf("%s: no widget with key '%s' was drawn last frame", line, args[0]))
			return true
		}
		at :: proc(rect: skald.Rect, args: []string, i: int) -> [2]f32 {
			fx, _ := strconv.parse_f32(args[i])
			fy, _ := strconv.parse_f32(args[i + 1])
			return {rect.x + rect.w * fx, rect.y + rect.h * fy}
		}
		start := at(rect, args, 1)
		if command == "click_at" {
			click(start)
		} else {
			end := at(rect, args, 3)
			shift := false
			button := sdl.BUTTON_LEFT
			for option in args[5:] {
				switch option {
				case "shift":  shift = true
				case "middle": button = sdl.BUTTON_MIDDLE
				case "right":  button = sdl.BUTTON_RIGHT
				}
			}
			pushMouse(.MOUSE_MOTION, start)
			if shift do pushKey(.KEY_DOWN, {.LSHIFT})
			queueBatch(mouseEvent(.MOUSE_BUTTON_DOWN, start, button))
			STEPS :: 4
			for i in 1..=STEPS do queueBatch(mouseEvent(.MOUSE_MOTION, start + (end - start) * f32(i) / STEPS, button))
			queueBatch(mouseEvent(.MOUSE_BUTTON_UP, end, button))
			if shift {
				release: sdl.Event
				release.type = .KEY_UP
				release.key.scancode = .LSHIFT
				queueBatch(release)
			}
			driver.waitFrames = INPUT_SETTLE_FRAMES
		}
		report(true, line)
		return false

	case "click_row":
		if len(args) < 2 {
			fail(fmt.tprintf("%s: expected a tree key and a row", line))
			return true
		}
		rect, ok := widgetRect(ctx, args[0])
		if !ok {
			fail(fmt.tprintf("%s: no tree with key '%s' was drawn last frame", line, args[0]))
			return true
		}
		// Rows are laid out from the tree's real top edge, which may be scrolled out of view
		top := ctx.widgets.states[skald.hash_id(args[0])].last_rect.y
		row := atoi(args, 1, 0)
		y := top + (f32(row) + 0.5) * s.settings.rowHeight
		if !rowVisible(ctx, args[0], y) {
			fail(fmt.tprintf("%s: row %d is scrolled out of view", line, row))
			return true
		}
		mods, modsOk := clickModifiers(args, 2)
		if !modsOk {
			fail(fmt.tprintf("%s: expected ctrl or shift", line))
			return true
		}
		click({rect.x + rect.w * 0.5, y}, mods)
		report(true, line)
		return false

	case "drag_row_to":
		if len(args) < 3 {
			fail(fmt.tprintf("%s: expected a tree key, a row and a widget key", line))
			return true
		}
		rect, ok := widgetRect(ctx, args[0])
		target, targetOk := widgetRect(ctx, args[2])
		if !ok || !targetOk {
			fail(fmt.tprintf("%s: no widget '%s' or '%s' was drawn last frame", line, args[0], args[2]))
			return true
		}
		top := ctx.widgets.states[skald.hash_id(args[0])].last_rect.y
		from := [2]f32{rect.x + rect.w * 0.5, top + (f32(atoi(args, 1, 0)) + 0.5) * s.settings.rowHeight}
		if !rowVisible(ctx, args[0], from.y) {
			fail(fmt.tprintf("%s: row %s is scrolled out of view", line, args[1]))
			return true
		}
		to := [2]f32{target.x + target.w * 0.5, target.y + target.h * 0.5}
		pushMouse(.MOUSE_MOTION, from)
		queueBatch(mouseEvent(.MOUSE_BUTTON_DOWN, from))
		STEPS :: 6
		for i in 1..=STEPS do queueBatch(mouseEvent(.MOUSE_MOTION, from + (to - from) * f32(i) / STEPS))
		queueBatch(mouseEvent(.MOUSE_BUTTON_UP, to))
		driver.waitFrames = INPUT_SETTLE_FRAMES
		report(true, line)
		return false

	case "right_click_row", "drag_row":
		if len(args) < (command == "drag_row" ? 4 : 2) {
			fail(fmt.tprintf("%s: expected a tree key and rows", line))
			return true
		}
		rect, ok := widgetRect(ctx, args[0])
		if !ok {
			fail(fmt.tprintf("%s: no tree with key '%s' was drawn last frame", line, args[0]))
			return true
		}
		top := ctx.widgets.states[skald.hash_id(args[0])].last_rect.y
		x := rect.x + rect.w * 0.5
		from := [2]f32{x, top + (f32(atoi(args, 1, 0)) + 0.5) * s.settings.rowHeight}
		if !rowVisible(ctx, args[0], from.y) {
			fail(fmt.tprintf("%s: row %s is scrolled out of view", line, args[1]))
			return true
		}
		if command == "right_click_row" {
			pushMouse(.MOUSE_MOTION, from)
			queueBatch(mouseEvent(.MOUSE_BUTTON_DOWN, from, sdl.BUTTON_RIGHT))
			queueBatch(mouseEvent(.MOUSE_BUTTON_UP, from, sdl.BUTTON_RIGHT))
			driver.waitFrames = INPUT_SETTLE_FRAMES
			report(true, line)
			return false
		}
		fraction: f32
		switch args[3] {
		case "before": fraction = 0.1
		case "inside": fraction = 0.5
		case "after":  fraction = 0.9
		case:
			fail(fmt.tprintf("%s: expected before, inside or after", line))
			return true
		}
		to := [2]f32{x, top + (f32(atoi(args, 2, 0)) + fraction) * s.settings.rowHeight}
		if !rowVisible(ctx, args[0], to.y) {
			fail(fmt.tprintf("%s: row %s is scrolled out of view", line, args[2]))
			return true
		}
		pushMouse(.MOUSE_MOTION, from)
		queueBatch(mouseEvent(.MOUSE_BUTTON_DOWN, from))
		STEPS :: 4
		for i in 1..=STEPS do queueBatch(mouseEvent(.MOUSE_MOTION, from + (to - from) * f32(i) / STEPS))
		queueBatch(mouseEvent(.MOUSE_BUTTON_UP, to))
		driver.waitFrames = INPUT_SETTLE_FRAMES
		report(true, line)
		return false

	case "click_context_item":
		if !s.contextMenu.open {
			fail(fmt.tprintf("%s: no context menu is open", line))
			return true
		}
		label := strings.join(args, " ", context.temp_allocator)
		items := ContextMenu_Items(s)
		parent, index, ok := contextItemFind(items, label)
		if !ok {
			fail(fmt.tprintf("%s: the menu has no such item (%s)", line, contextItemLabels(items)))
			return true
		}
		center :: proc(r: skald.Rect) -> [2]f32 { return {r.x + r.w * 0.5, r.y + r.h * 0.5} }
		if parent >= 0 {
			// Hover the submenu's row first (it opens), then click its item
			pushMouse(.MOUSE_MOTION, center(skald.popup_menu_row_rect(ctx, items, s.contextMenu.at, parent)))
			to := center(skald.popup_menu_row_rect(ctx, items, s.contextMenu.at, index, parent))
			queueBatch(mouseEvent(.MOUSE_MOTION, to))
			queueBatch(mouseEvent(.MOUSE_BUTTON_DOWN, to))
			queueBatch(mouseEvent(.MOUSE_BUTTON_UP, to))
			driver.waitFrames = INPUT_SETTLE_FRAMES
		} else {
			click(center(skald.popup_menu_row_rect(ctx, items, s.contextMenu.at, index)))
		}
		report(true, line)
		return false

	case "right_click_node", "right_click_world", "right_click_widget":
		at: [2]f32
		ok: bool
		switch command {
		case "right_click_node":
			scene := &s.project.scenes[s.currentScene]
			index := -1
			name := strings.join(args, " ", context.temp_allocator)
			for node, i in scene.nodes do if node.name == name do index = i
			at, ok = ViewportNodePosition(s, ctx, index)
		case "right_click_world":
			x, _ := strconv.parse_f32(args[0] if len(args) > 0 else "")
			y, _ := strconv.parse_f32(args[1] if len(args) > 1 else "")
			at, ok = ViewportWorldToWindow(s, ctx, {x, y})
		case "right_click_widget":
			rect: skald.Rect
			rect, ok = widgetRect(ctx, args[0] if len(args) > 0 else "")
			at = {rect.x + rect.w * 0.5, rect.y + rect.h * 0.5}
		}
		if !ok {
			fail(fmt.tprintf("%s: not on screen", line))
			return true
		}
		pushMouse(.MOUSE_MOTION, at)
		queueBatch(mouseEvent(.MOUSE_BUTTON_DOWN, at, sdl.BUTTON_RIGHT))
		queueBatch(mouseEvent(.MOUSE_BUTTON_UP, at, sdl.BUTTON_RIGHT))
		driver.waitFrames = INPUT_SETTLE_FRAMES
		report(true, line)
		return false

	case "click_node":
		scene := &s.project.scenes[s.currentScene]
		index := -1
		name := len(args) > 0 ? args[0] : ""
		for node, i in scene.nodes do if node.name == name do index = i
		position, ok := ViewportNodePosition(s, ctx, index)
		if !ok {
			fail(fmt.tprintf("%s: no visible node '%s' in the viewport", line, name))
			return true
		}
		mods, modsOk := clickModifiers(args, 1)
		if !modsOk {
			fail(fmt.tprintf("%s: expected ctrl or shift", line))
			return true
		}
		click(position, mods)
		report(true, line)
		return false

	case "scroll_into_view":
		// Scroll a scroll container so a widget inside it is in view, e.g. the inspector's fields
		if len(args) < 2 {
			fail(fmt.tprintf("%s: expected a scroll key and a widget key", line))
			return true
		}
		if skald.hash_id(args[0]) not_in ctx.widgets.states {
			// A layout that changes with the window (the Animation panel) may not use the scroll
			if _, visible := widgetRect(ctx, args[1]); visible {
				report(true, line)
				return true
			}
			fail(fmt.tprintf("%s: no scroll '%s' was drawn last frame", line, args[0]))
			return true
		}
		scroll := &ctx.widgets.states[skald.hash_id(args[0])]
		area := scroll.last_rect
		// A widget out of view keeps the rect from when it was last laid out, so only trust what's
		// visible now: start from the top and page down until it is, clear of the edges. A widget
		// at an edge scrolls when clicked (the scroll reveals the newly focused widget), so the
		// release lands somewhere else and a checkbox doesn't toggle
		// At the end of the content (paging no longer moves it), visible is as good as it gets
		atEnd := driver.scrollAttempts > 1 && scroll.scroll_y == driver.lastScrollY
		driver.lastScrollY = scroll.scroll_y
		if _, visible := widgetRect(ctx, args[1]); visible && (atEnd || clearOfEdges(ctx.widgets.states[skald.hash_id(args[1])].last_rect, area, scroll.scroll_y <= 0)) {
			driver.scrollAttempts = 0
			report(true, line)
			return true
		}
		widget := ctx.widgets.states[skald.hash_id(args[1])]
		if driver.scrollAttempts == 0 {
			scroll.scroll_y = 0
		} else if widget.last_frame + 2 >= ctx.widgets.frame && widget.last_rect.h > 0 {
			// Laid out (so its rect is current): center it
			scroll.scroll_y = max(scroll.scroll_y + (widget.last_rect.y + widget.last_rect.h * 0.5) - (area.y + area.h * 0.5), 0)
		} else {
			scroll.scroll_y += max(area.h * 0.6, 40)
		}
		driver.scrollAttempts += 1
		if driver.scrollAttempts > 30 {
			driver.scrollAttempts = 0
			fail(fmt.tprintf("%s: no widget '%s' after scrolling", line, args[1]))
			return true
		}
		// Look again once the scroll has been laid out
		driver.line -= 1
		driver.waitFrames = INPUT_SETTLE_FRAMES
		return false

	case "click_tab":
		// A tab of a skald.tabs strip: its buttons' ids derive from the strip's
		if len(args) < 2 {
			fail(fmt.tprintf("%s: expected a tabs key and a tab index", line))
			return true
		}
		id := skald.widget_make_sub_id(skald.hash_id(args[0]), u64(atoi(args, 1, 0) + 1))
		state, drawn := ctx.widgets.states[id]
		r := state.last_rect
		if state.clip_rect.w > 0 do r = intersect(r, state.clip_rect)
		if !drawn || r.w <= 0 || r.h <= 0 {
			fail(fmt.tprintf("%s: that tab isn't in view", line))
			return true
		}
		click({r.x + r.w * 0.5, r.y + r.h * 0.5})
		report(true, line)
		return false

	case "save_viewport_render":
		// The viewport's last render as a PNG (its own pixels, never the screen), to look at
		pixels, size := Viewport_LastRender()
		if size.x > 0 && len(pixels) >= size.x * size.y * 4 do _ = stbi.write_png(strings.clone_to_cstring(rest, context.temp_allocator), i32(size.x), i32(size.y), 4, raw_data(pixels), i32(size.x) * 4)
		report(size.x > 0, line)
		return false

	case "save_code_render":
		// The shown code tab's own render (never the screen), to look at
		if problem := CodeEditor_SaveRender(CodeTabs_Active(s), rest); problem != "" {
			fail(fmt.tprintf("%s: %s", line, problem))
			return true
		}
		report(true, line)
		return false

	case "write_project_file":
		// A project file's whole text, as another program would write it ("\n" for line breaks,
		// "\t" for tabs); its modification time a second ahead, so the change always shows
		file, _, text := strings.partition(rest, " ")
		text, _ = strings.replace_all(text, "\\n", "\n", context.temp_allocator)
		text, _ = strings.replace_all(text, "\\t", "\t", context.temp_allocator)
		path := joinPath(s.project.rootPath, file, allocator = context.temp_allocator)
		// Its folder too (scripts/ in a project without scripts)
		_ = os.make_directory_all(filepath.dir(path))
		if os.write_entire_file(path, transmute([]byte)text) != nil {
			fail(fmt.tprintf("%s: can't write %s", line, path))
			return true
		}
		later := time.time_add(time.now(), time.Second)
		_ = os.change_times(path, later, later)
		report(true, line)
		return false

	case "code_import_path":
		// Where the shown code tab's "Import Keybindings from Zed / VSCode" reads (a fixture)
		source, _, file := strings.partition(rest, " ")
		CodeEditor_SetImportPath(CodeTabs_Active(s), source == "zed", codeAbsolutePath(file))
		report(true, line)
		return false

	case "code_dialog_pick":
		// Answers the file dialog the code editor asked for (Open, Save As): a project path
		if s.codeDialog == .None {
			fail(fmt.tprintf("%s: no dialog was asked for", line))
			return true
		}
		// Absolute, as dialogs answer
		path := codeAbsolutePath(joinPath(s.project.rootPath, rest, allocator = context.temp_allocator))
		skald.send(ctx, Msg(Code_Dialog_Picked{path = strings.clone(path), cancelled = false}))
		driver.waitFrames = INPUT_SETTLE_FRAMES
		report(true, line)
		return false

	case "close_current_tab":
		// Clicks the × of the open scene's (or component's) tab, wherever it is in the strip
		for scene, i in ViewportTabScenes(s) do if scene == s.currentScene {
			return runCommand(s, ctx, fmt.tprintf("click_widget scene-tab-close-%d", i))
		}
		fail(fmt.tprintf("%s: the open scene has no tab", line))
		return true

	case "copy_into_project":
		// "copy_into_project <file> <project path>": a file (from the editor's folder) into the
		// project, its folders made, as another program would put it there
		from, _, to := strings.partition(rest, " ")
		dest := joinPath(s.project.rootPath, strings.trim_space(to), allocator = context.temp_allocator)
		_ = os.make_directory_all(filepath.dir(dest))
		data, readErr := os.read_entire_file(Editor_ArgumentPath(from), context.temp_allocator)
		if readErr != nil || os.write_entire_file(dest, data) != nil {
			fail(fmt.tprintf("%s: can't copy %s to %s", line, from, dest))
			return true
		}
		report(true, line)
		return false

	case "live_select":
		// Chooses a node of the running game in the Live tab by its name (its rows' order changes
		// with the game's tree)
		for n in s.live.nodes do if n.name == rest {
			skald.send(ctx, Msg(Live_Selected(strings.clone(n.id, context.temp_allocator))))
			driver.waitFrames = INPUT_SETTLE_FRAMES
			report(true, line)
			return false
		}
		fail(fmt.tprintf("%s: the game has no node named %s", line, rest))
		return true

	case "touch_project_file":
		// Another program changes a project file: appends a line, with a modification time a
		// second ahead (so a change in the same second as the last write still shows)
		file, _, text := strings.partition(rest, " ")
		path := joinPath(s.project.rootPath, file, allocator = context.temp_allocator)
		// A missing file is created (a new file, as git or another editor would make)
		old, _ := os.read_entire_file(path, context.temp_allocator)
		if err := os.write_entire_file(path, transmute([]byte)strings.concatenate({string(old), text, "\n"}, context.temp_allocator)); err != nil {
			fail(fmt.tprintf("%s: can't write %s", line, path))
			return true
		}
		later := time.time_add(time.now(), time.Second)
		_ = os.change_times(path, later, later)
		report(true, line)
		return false

	case "double_click_widget":
		rect, ok := widgetRect(ctx, rest)
		if !ok {
			fail(fmt.tprintf("%s: no widget with key '%s' was drawn last frame", line, rest))
			return true
		}
		at := [2]f32{rect.x + rect.w * 0.5, rect.y + rect.h * 0.5}
		pushMouse(.MOUSE_MOTION, at)
		queueBatch(mouseEvent(.MOUSE_BUTTON_DOWN, at))
		queueBatch(mouseEvent(.MOUSE_BUTTON_UP, at))
		second := mouseEvent(.MOUSE_BUTTON_DOWN, at)
		second.button.clicks = 2
		queueBatch(second)
		queueBatch(mouseEvent(.MOUSE_BUTTON_UP, at))
		driver.waitFrames = INPUT_SETTLE_FRAMES
		report(true, line)
		return false

	case "wheel_widget":
		rect, ok := widgetRect(ctx, args[0] if len(args) > 0 else "")
		if !ok || len(args) < 2 {
			fail(fmt.tprintf("%s: expected a drawn widget and wheel steps", line))
			return true
		}
		at := [2]f32{rect.x + rect.w * 0.5, rect.y + rect.h * 0.5}
		pushMouse(.MOUSE_MOTION, at)
		event: sdl.Event
		event.type = .MOUSE_WHEEL
		event.wheel.y = f32(atoi(args, 1, 1))
		event.wheel.mouse_x, event.wheel.mouse_y = at.x, at.y
		queueBatch(event)
		driver.waitFrames = INPUT_SETTLE_FRAMES
		report(true, line)
		return false

	case "double_click_row":
		rect, ok := widgetRect(ctx, args[0] if len(args) > 0 else "")
		if !ok || len(args) < 2 {
			fail(fmt.tprintf("%s: expected a drawn tree and a row", line))
			return true
		}
		top := ctx.widgets.states[skald.hash_id(args[0])].last_rect.y
		at := [2]f32{rect.x + rect.w * 0.5, top + (f32(atoi(args, 1, 0)) + 0.5) * s.settings.rowHeight}
		pushMouse(.MOUSE_MOTION, at)
		queueBatch(mouseEvent(.MOUSE_BUTTON_DOWN, at))
		queueBatch(mouseEvent(.MOUSE_BUTTON_UP, at))
		second := mouseEvent(.MOUSE_BUTTON_DOWN, at)
		second.button.clicks = 2
		queueBatch(second)
		queueBatch(mouseEvent(.MOUSE_BUTTON_UP, at))
		driver.waitFrames = INPUT_SETTLE_FRAMES
		report(true, line)
		return false

	case "box_select", "drag_to_viewport":
		canvas, ok := widgetRect(ctx, "viewport-canvas")
		if !ok || len(args) < (command == "box_select" ? 4 : 3) {
			fail(fmt.tprintf("%s: the viewport isn't drawn, or arguments are missing", line))
			return true
		}
		viewOrigin := ctx.widgets.states[skald.hash_id("viewport-canvas")].last_rect
		toWindow :: proc(s: ^State, canvas: skald.Rect, world: [2]f32) -> [2]f32 {
			return Viewport_WorldToView(&s.viewport, world) + {canvas.x + RULER_SIZE, canvas.y + RULER_SIZE}
		}
		from, to: [2]f32
		if command == "box_select" {
			from = toWindow(s, viewOrigin, {f32(atoi(args, 0, 0)), f32(atoi(args, 1, 0))})
			to = toWindow(s, viewOrigin, {f32(atoi(args, 2, 0)), f32(atoi(args, 3, 0))})
		} else {
			tree, drawn := widgetRect(ctx, "browser-tree")
			if !drawn {
				fail(fmt.tprintf("%s: the browser isn't drawn", line))
				return true
			}
			top := ctx.widgets.states[skald.hash_id("browser-tree")].last_rect.y
			from = {tree.x + tree.w * 0.5, top + (f32(atoi(args, 0, 0)) + 0.5) * s.settings.rowHeight}
			center := [2]f32{canvas.x + RULER_SIZE + (canvas.w - RULER_SIZE) * 0.5, canvas.y + RULER_SIZE + (canvas.h - RULER_SIZE) * 0.5}
			to = center + {f32(atoi(args, 1, 0)), f32(atoi(args, 2, 0))}
		}
		pushMouse(.MOUSE_MOTION, from)
		queueBatch(mouseEvent(.MOUSE_BUTTON_DOWN, from))
		STEPS :: 6
		for i in 1..=STEPS do queueBatch(mouseEvent(.MOUSE_MOTION, from + (to - from) * f32(i) / STEPS))
		queueBatch(mouseEvent(.MOUSE_BUTTON_UP, to))
		driver.waitFrames = INPUT_SETTLE_FRAMES
		report(true, line)
		return false

	case "send":
		name, _, value := strings.partition(rest, " ")
		msg: Msg
		switch name {
		case "Recent_Project_Chosen":
			// The File menu's i-th recent project (the menu bar can't be clicked)
			i, _ := strconv.parse_int(value)
			shown := Recent_Shown(s)
			if i < 0 || i >= len(shown) {
				fail(fmt.tprintf("%s: the File menu lists %d recent projects", line, len(shown)))
				return true
			}
			msg = Recent_Project_Chosen(shown[i])
		case "New_Script_Kind_Changed":
			kind, ok := reflect.enum_from_name(ScriptKind, value)
			if ok do msg = New_Script_Kind_Changed(kind)
		case "Global_Added":          msg = Global_Added(strings.clone(value, context.temp_allocator))
		case "New_Script_Opened":     msg = New_Script_Opened{}
		case "Open_Grid_Settings":    msg = Open_Grid_Settings{}
		case "New_Data_Opened":       msg = New_Data_Opened{}
		case "New_Data_Type_Changed": msg = New_Data_Type_Changed(strings.clone(value, context.temp_allocator))
		case "Project_Settings_Tab_Changed":
			tab, ok := reflect.enum_from_name(ProjectSettingsTab, value)
			if ok do msg = Project_Settings_Tab_Changed(tab)
		case "Scene_Tab_Changed":
			if i, ok := strconv.parse_int(value); ok do msg = Scene_Tab_Changed(i)
		case "Code_Open_Requested":
			msg = Code_Open_Requested{path = Editor_ArgumentPath(value)}
		case "Git_Switch_Branch":
			msg = Git_Op_Requested{op = .Switch_Branch, arg = strings.clone(value, context.temp_allocator)}
		case "Node_Script_Added":     msg = Node_Script_Added(strings.clone(value, context.temp_allocator))
		case "Atlas_Created":         msg = Atlas_Created{}
		case "Settings_Theme_Preset_Chosen": msg = Settings_Theme_Preset_Chosen(strings.clone(value, context.temp_allocator))
		// A bottom tab by its name (the strip scrolls in a narrow window)
		case "Bottom_Tab":
			if tab, ok := reflect.enum_from_name(BottomTab, value); ok do msg = Bottom_Tab_Changed(int(tab))
		case "Right_Sidebar_Width":
			// The right sidebar (the inspector) that wide, as a drag of its divider would make it
			if width, ok := strconv.parse_f32(value); ok {
				layout := s.layout
				left, _ := FittedSidebarWidths(&layout)
				msg = Center_Resized(layout.workspace.x - left - DIVIDER - width - DIVIDER)
			}
		case "Dialogue_Created":      msg = Dialogue_Created{}
		case "Dialogue_Select_Node":  if i, ok := strconv.parse_int(value); ok do msg = Dialogue_View{op = .Select_Node, index = i}
		// A node's texture or region as its dropdown would set it (atlas_edit.odin)
		case "Node_Texture":          msg = Node_Text_Changed{.Texture, strings.clone(value, context.temp_allocator)}
		case "Node_Region":           msg = Node_Text_Changed{.Region, strings.clone(value, context.temp_allocator)}
		case "Live_Property_Edited":
			// "<property> <value>", as typed in the Live tab for the chosen node
			name, _, text := strings.partition(value, " ")
			msg = Live_Property_Edited{name = strings.clone(name, context.temp_allocator), text = strings.clone(text, context.temp_allocator)}
		}
		if msg == nil {
			fail(fmt.tprintf("%s: unknown message or value", line))
			return true
		}
		skald.send(ctx, msg)
		driver.waitFrames = INPUT_SETTLE_FRAMES
		report(true, line)
		return false

	case "action":
		// Menu bar entries without a shortcut (menus can't be clicked by key): send the action
		action, known := reflect.enum_from_name(Action, rest)
		if !known {
			fail(fmt.tprintf("%s: unknown action", line))
			return true
		}
		skald.send(ctx, Msg(action))
		driver.waitFrames = INPUT_SETTLE_FRAMES
		report(true, line)
		return false

	case "archive_project":
		skald.send(ctx, Msg(Project_Archive_Path_Chosen{path = Editor_ArgumentPath(rest)}))
		driver.waitFrames = INPUT_SETTLE_FRAMES
		report(true, line)
		return false
	case "open_archive":
		archive, _, folder := strings.partition(rest, " | ")
		if archive == "" || folder == "" {
			fail(fmt.tprintf("%s (expected open_archive <archive> | <folder>)", line))
			return false
		}
		skald.send(ctx, Msg(Project_Archive_Open_Chosen{path = Editor_ArgumentPath(archive)}))
		skald.send(ctx, Msg(Project_Archive_Destination_Chosen{path = Editor_ArgumentPath(folder)}))
		driver.waitFrames = INPUT_SETTLE_FRAMES
		report(true, line)
		return false
	case "select_node":
		scene := &s.project.scenes[s.currentScene]
		index := -1
		for node, i in scene.nodes do if node.name == rest do index = i
		if index < 0 {
			fail(fmt.tprintf("%s: no node '%s' in the scene", line, rest))
			return true
		}
		skald.send(ctx, Msg(Node_Picked(index)))
		driver.waitFrames = INPUT_SETTLE_FRAMES
		report(true, line)
		return false

	case "console_fill":
		// console_fill <n> [<Level> [<category>]]: lines added as a game's would be
		count := atoi(args, 0, 1)
		level := LogLevel.Info
		if len(args) > 1 {
			if l, ok := reflect.enum_from_name(LogLevel, args[1]); ok do level = l
		}
		category := len(args) > 2 ? args[2] : e.LOG_DEFAULT_CATEGORY
		skald.send(ctx, Msg(Log_Test_Lines{count = count, level = level, category = strings.clone(category, context.temp_allocator)}))
		driver.waitFrames = INPUT_SETTLE_FRAMES
		report(true, line)
		return false

	case "frame_times":
		// frame_times <frames> [<lines a frame>]: times that many frames (each forced), adding lines
		// to the Console each frame. Run with SKALD_BENCH_UNCAP=1 SKALD_BENCH_FRAMES=1000000000 to
		// draw every frame without waiting for the display
		driver.timing = max(atoi(args, 0, 120), 2)
		driver.timingLines = atoi(args, 1, 0)
		driver.timingLast = {}
		return false

	case "open_project":
		// Kept: the message may be handled after this frame's temp memory is freed (test-only, tiny)
		skald.send(ctx, Msg(Open_Project_Chosen{path = Editor_ArgumentPath(rest)}))
		driver.waitFrames = INPUT_SETTLE_FRAMES
		report(true, line)
		return false

	case "drag_node":
		if len(args) < 3 {
			fail(fmt.tprintf("%s: expected a node name and dx dy", line))
			return true
		}
		scene := &s.project.scenes[s.currentScene]
		index := -1
		for node, i in scene.nodes do if node.name == args[0] do index = i
		start, ok := ViewportNodePosition(s, ctx, index)
		if !ok {
			fail(fmt.tprintf("%s: no visible node '%s' in the viewport", line, args[0]))
			return true
		}
		delta := [2]f32{f32(atoi(args, 1, 0)), f32(atoi(args, 2, 0))}
		// "alt": Alt held through the drag (Skald reads modifiers from key events)
		alt := len(args) > 3 && args[3] == "alt"
		pushMouse(.MOUSE_MOTION, start)
		if alt do pushKey(.KEY_DOWN, {.LALT})
		queueBatch(mouseEvent(.MOUSE_BUTTON_DOWN, start))
		// Move in steps over several frames, like a real drag, then release
		STEPS :: 4
		for i in 1..=STEPS do queueBatch(mouseEvent(.MOUSE_MOTION, start + delta * f32(i) / STEPS))
		queueBatch(mouseEvent(.MOUSE_BUTTON_UP, start + delta))
		if alt {
			release: sdl.Event
			release.type = .KEY_UP
			release.key.scancode = .LALT
			queueBatch(release)
		}
		driver.waitFrames = INPUT_SETTLE_FRAMES
		report(true, line)
		return false

	case "scroll":
		center, ok := viewportCenter(ctx)
		if !ok {
			fail(fmt.tprintf("%s: the viewport hasn't been drawn", line))
			return true
		}
		// A last argument "shift" or "ctrl" holds that key; "sideways" turns the wheel sideways
		args := args
		mods: sdl.Keymod
		sideways := false
		if len(args) > 1 {
			switch args[len(args) - 1] {
			case "shift":    mods = {.LSHIFT}
			case "ctrl":     mods = {.LCTRL}
			case "sideways": sideways = true
			}
			if mods != {} || sideways do args = args[:len(args) - 1]
		}
		if len(args) >= 3 {
			rect, _ := widgetRect(ctx, "viewport-canvas")
			fx, _ := strconv.parse_f32(args[1])
			fy, _ := strconv.parse_f32(args[2])
			center = {rect.x + RULER_SIZE + (rect.w - RULER_SIZE) * fx, rect.y + RULER_SIZE + (rect.h - RULER_SIZE) * fy}
		}
		pushMouse(.MOUSE_MOTION, center)
		if mods != {} do pushKey(.KEY_DOWN, mods)
		event: sdl.Event
		event.type = .MOUSE_WHEEL
		if sideways do event.wheel.x = f32(atoi(args, 0, 1))
		else do event.wheel.y = f32(atoi(args, 0, 1))
		event.wheel.mouse_x, event.wheel.mouse_y = center.x, center.y
		queueBatch(event)
		if mods != {} {
			release: sdl.Event
			release.type = .KEY_UP
			release.key.scancode = .LCTRL in mods ? .LCTRL : .LGUI in mods ? .LGUI : .LSHIFT
			queueBatch(release)
		}
		driver.waitFrames = INPUT_SETTLE_FRAMES
		report(true, line)
		return false

	case "click":
		click({f32(atoi(args, 0, 0)), f32(atoi(args, 1, 0))})
		report(true, line)
		return false

	case "move":
		pushMouse(.MOUSE_MOTION, {f32(atoi(args, 0, 0)), f32(atoi(args, 1, 0))})
		driver.waitFrames = INPUT_SETTLE_FRAMES
		return false

	case "key":
		if !pressKey(rest) {
			fail(fmt.tprintf("%s: unknown key", line))
			return true
		}
		report(true, line)
		return false

	case "type":
		// One event per character, as a keyboard types (the code editor completes after a ".")
		for r in rest {
			event: sdl.Event
			event.type = .TEXT_INPUT
			event.text.text = strings.clone_to_cstring(fmt.tprint(r)) // Read by Skald next frame; tiny, kept
			_ = sdl.PushEvent(&event)
		}
		driver.waitFrames = INPUT_SETTLE_FRAMES
		report(true, line)
		return false

	case "right_click_asset", "double_click_asset", "drag_asset_to":
		// The asset's browser row (its folder opened), right-clicked (its context menu),
		// double-clicked, or dragged onto a widget (`drag_asset_to <path start> <widget>`)
		wanted, widget := rest, ""
		if command == "drag_asset_to" do wanted, _, widget = strings.partition(rest, " ")
		for asset, i in s.project.assets {
			if command == "drag_asset_to" ? !strings.has_prefix(asset.path, wanted) : asset.path != rest do continue
			s.browserOpen[AssetFolder(asset.kind)] = true
			for row, r in BrowserRows(s) {
				if row.kind != .Asset || row.index != i do continue
				// Scroll the browser to it first
				tree := ctx.widgets.states[skald.hash_id("browser-tree")]
				y := tree.last_rect.y + (f32(r) + 0.5) * s.settings.rowHeight
				if !rowVisible(ctx, "browser-tree", y) && driver.scrollAttempts < 5 {
					scroll := &ctx.widgets.states[skald.hash_id("browser-scroll")]
					area := scroll.last_rect
					scroll.scroll_y = max(scroll.scroll_y + y - (area.y + area.h * 0.5), 0)
					driver.scrollAttempts += 1
					driver.line -= 1
					driver.waitFrames = INPUT_SETTLE_FRAMES
					return false
				}
				driver.scrollAttempts = 0
				if command == "drag_asset_to" do return runCommand(s, ctx, fmt.tprintf("drag_row_to browser-tree %d %s", r, widget))
				return runCommand(s, ctx, fmt.tprintf("%s browser-tree %d", command == "right_click_asset" ? "right_click_row" : "double_click_row", r))
			}
		}
		fail(fmt.tprintf("%s: no asset %s", line, rest))
		return true

	case "select_asset":
		// Selects an asset's browser row (its folder opened), as a click on it would
		for asset, i in s.project.assets {
			if asset.path != rest do continue
			s.browserOpen[AssetFolder(asset.kind)] = true
			for row, r in BrowserRows(s) do if row.kind == .Asset && row.index == i do skald.send(ctx, Msg(Browser_Selected(r)))
			driver.waitFrames = INPUT_SETTLE_FRAMES
			report(true, line)
			return false
		}
		fail(fmt.tprintf("%s: no asset %s", line, rest))
		return true

	case "import_many":
		// Several files, as the Import dialog sends them when several are chosen
		paths := make([]string, len(args), context.temp_allocator)
		for a, i in args do paths[i] = Editor_ArgumentPath(a)
		if len(paths) > 0 do skald.send(ctx, Msg(Asset_Import_Result{path = paths[0], paths = paths}))
		driver.waitFrames = INPUT_SETTLE_FRAMES
		report(true, line)
		return false

	case "import":
		skald.send(ctx, Msg(Asset_Import_Result{path = Editor_ArgumentPath(rest)}))
		driver.waitFrames = INPUT_SETTLE_FRAMES
		report(true, line)
		return false

	case "quit":
		driver.line = len(driver.lines)
		return true
	}

	fail(fmt.tprintf("unknown command: %s", line))
	return true
}

// Evaluates a check against the state. Returns whether it passed and what was found
@(private="file")
runCheck :: proc(s: ^State, ctx: ^skald.Ctx(Msg), check: string) -> (ok: bool, found: string) {
	name, _, value := strings.partition(check, " ")
	value = strings.trim_space(value)
	scene := &s.project.scenes[s.currentScene]
	selected := s.selectedNode >= 0 && s.selectedNode < len(scene.nodes) ? &scene.nodes[s.selectedNode] : nil

	switch name {
	case "scene_dirty":
		// The open scene's (or component's) unsaved changes, as its tab's dot shows them
		found = fmt.tprint(Scene_IsDirty(s, s.currentScene))
		return found == strings.trim_space(value), found
	case "scene":
		found = scene.name
	case "selected":
		found = selected != nil ? selected.name : "none"
	case "parent":
		if selected == nil do return false, "nothing selected"
		found = selected.parent >= 0 ? scene.nodes[selected.parent].name : "none"
	case "nodes":
		found = fmt.tprint(len(scene.nodes))
	case "play":
		found = fmt.tprint(s.playState)
	case "tab":
		found = fmt.tprint(s.bottomTab)
	case "bottom":
		found = s.layout.bottomOpen ? "open" : "closed"
	case "tool":
		found = fmt.tprint(s.tool)
	case "zoom":
		found = fmt.tprint(int(math.round(s.viewport.zoom * 100)))
	case "viewport_center":
		found = fmt.tprintf("%d %d", int(math.round(s.viewport.center.x)), int(math.round(s.viewport.center.y)))
	case "viewport_center_not":
		// Passes when the view's center isn't that point (it moved)
		center := fmt.tprintf("%d %d", int(math.round(s.viewport.center.x)), int(math.round(s.viewport.center.y)))
		found = center != value ? value : fmt.tprintf("still %s", center)
	case "typing":
		found = fmt.tprint(IsTyping(ctx))
	case "assets":
		found = fmt.tprint(len(s.project.assets))
	case "browser_rows":
		found = fmt.tprint(len(BrowserRows(s)))
	case "preview":
		found = "none"
		if s.browserSelection.kind == .Asset && s.browserSelection.index < len(s.project.assets) {
			found = strings.to_lower(fmt.tprint(s.project.assets[s.browserSelection.index].kind), context.temp_allocator)
		}
	case "components":
		count := 0
		for &sc in s.project.scenes do if Scene_IsComponent(&sc) do count += 1
		found = fmt.tprint(count)
	case "kind":
		found = selected != nil ? fmt.tprint(selected.kind) : "none"
	case "texture":
		found = selected != nil ? selected.texture : "none"
	case "preview_visible":
		found = fmt.tprint(previewImageArea.x >= 32 && previewImageArea.y >= 32)
		if found != value do return false, fmt.tprintf("%s: the picture is %v, the window %v, the workspace %v", found, previewImageArea,
			ctx.renderer != nil ? ctx.renderer.fb_size : [2]u32{}, s.layout.workspace)
	case "audio":
		found = AudioPreview_IsPlaying() ? "playing" : "stopped"
	case "ldtk_preview":
		// What the viewport built for the selected LDtkLevel node: levels, entities, collision shapes
		engineNode := Preview_Node(s.selectedNode)
		if engineNode == nil || !e.Node_Is(engineNode, e.LDtkLevelNode) do return false, "the selected node isn't a built LDtkLevel"
		level := cast(^e.LDtkLevelNode)engineNode
		shapes := 0
		for view in level.views do for child in view.children do if child.name == "Collision" do shapes += len(child.children)
		found = fmt.tprintf("%d %d %d", len(level.views), len(level.spawned), shapes)
	case "aseprite":
		// The selected node's Aseprite settings: aseprite layers|pivot|nine|slice <value> ("none")
		if selected == nil do return false, "nothing selected"
		field, _, expected := strings.partition(value, " ")
		pick :: proc(v: string) -> string { return v == "" ? "none" : v }
		switch field {
		case "layers": found = pick(selected.asepriteLayers)
		case "pivot":  found = pick(selected.pivotSlice)
		case "nine":   found = pick(selected.nineSlice)
		case "slice":  found = pick(selected.slice)
		case: return false, fmt.tprintf("unknown aseprite field '%s'", field)
		}
		return found == strings.trim_space(expected), found
	case "tilemap":
		// The selected TileMap's settings: tilemap file|frame|layers|collision <value>
		if selected == nil || selected.kind != .TileMap do return false, "no TileMap selected"
		field, _, expected := strings.partition(value, " ")
		t := selected.tilemap
		switch field {
		case "file":      found = t.file
		case "frame":     found = fmt.tprint(t.frame)
		case "layers":    found = t.layers == "" ? "all" : t.layers
		case "collision": found = fmt.tprint(t.collision)
		case: return false, fmt.tprintf("unknown tilemap field '%s'", field)
		}
		return found == strings.trim_space(expected), found
	case "tile_brush":
		found = fmt.tprint(s.tilePainter.tile & e.ASEPRITE_TILE_ID)
	case "timeline":
		// timeline clip|clips|tracks|playhead|playing|autoplay <value>
		node, _ := Timeline_Animator(s)
		if node == nil do return false, "the Timeline shows no Animator"
		field, _, expected := strings.partition(value, " ")
		clip := Timeline_Clip(s)
		switch field {
		case "clip":     found = clip != nil ? clip.name : "none"
		case "clips":    found = fmt.tprint(len(node.animator.clips))
		case "tracks":   found = clip != nil ? fmt.tprint(len(clip.tracks)) : "0"
		case "playhead": found = fmt.tprintf("%.2f", s.timeline.playhead)
		case "playing":  found = fmt.tprint(s.timeline.playing)
		case "autoplay": found = node.animator.autoplay == "" ? "none" : node.animator.autoplay
		case "keys":
			t := s.timeline.track
			found = clip != nil && t >= 0 && t < len(clip.tracks) ? fmt.tprint(len(clip.tracks[t].keys)) : "no track"
		case: return false, fmt.tprintf("unknown timeline field '%s'", field)
		}
		return found == strings.trim_space(expected), found
	case "timeline_key":
		// timeline_key <track> <key> <seconds> <value>
		clip := Timeline_Clip(s)
		parts := strings.fields(value, context.temp_allocator)
		if clip == nil || len(parts) < 3 do return false, "expected a clip, and a track, key and time"
		track, _ := strconv.parse_int(parts[0])
		key, _ := strconv.parse_int(parts[1])
		if track < 0 || track >= len(clip.tracks) || key < 0 || key >= len(clip.tracks[track].keys) do return false, fmt.tprintf("no key %d on track %d", key, track)
		k := clip.tracks[track].keys[key]
		found = fmt.tprintf("%.2f %s", k.time, k.value)
		// Without a value, only the time
		if len(parts) == 3 do found = fmt.tprintf("%.2f", k.time)
		want := strings.join(parts[2:], " ", context.temp_allocator)
		return found == want, found
	case "ui":
		if selected == nil || !NodeKind_IsControl(selected.kind) do return false, "no UI control selected"
		field, _, expected := strings.partition(value, " ")
		u := selected.ui
		pick :: proc(v: string) -> string { return v == "" ? "none" : v }
		switch field {
		case "layout": found = fmt.tprint(u.layout)
		case "anchor": found = fmt.tprint(u.anchor)
		case "text":   found = pick(selected.text)
		case "action": found = pick(u.action)
		case "width":  found = fmt.tprint(u.size.x)
		case "height": found = fmt.tprint(u.size.y)
		case "theme":  found = pick(u.theme)
		case "value":  found = fmt.tprint(u.value)
		case "min":    found = fmt.tprint(u.minValue)
		case "max":    found = fmt.tprint(u.maxValue)
		case "step":   found = fmt.tprint(u.step)
		case "checked": found = fmt.tprint(u.checked)
		case: return false, fmt.tprintf("unknown ui field '%s'", field)
		}
		return found == strings.trim_space(expected), found
	case "nav":
		if selected == nil || (selected.kind != .NavRegion && selected.kind != .NavAgent) do return false, "no NavRegion or NavAgent selected"
		field, _, expected := strings.partition(value, " ")
		n := selected.nav
		switch field {
		case "cellSize":    found = fmt.tprint(n.cellSize)
		case "agentRadius": found = fmt.tprint(n.agentRadius)
		case "diagonal":    found = fmt.tprint(n.diagonal)
		case "speed":       found = fmt.tprint(n.speed)
		case "autoMove":    found = fmt.tprint(n.autoMove)
		case "width":       found = fmt.tprint(selected.shapeSize.x)
		case: return false, fmt.tprintf("unknown nav field '%s'", field)
		}
		return found == strings.trim_space(expected), found
	case "camtool":
		if selected == nil do return false, "nothing selected"
		field, _, expected := strings.partition(value, " ")
		c := selected.cameraTools
		switch field {
		case "factorX":    found = fmt.tprint(c.factor.x)
		case "repeatX":    found = fmt.tprint(c.repeatX)
		case "transition": found = fmt.tprint(c.transition)
		case "zoom":       found = fmt.tprint(c.zoom)
		case "camera":     found = selected.viewCamera == "" ? "none" : selected.viewCamera
		case: return false, fmt.tprintf("unknown camtool field '%s'", field)
		}
		return found == strings.trim_space(expected), found
	case "cam":
		if selected == nil || selected.kind != .Camera do return false, "no Camera selected"
		field, _, expected := strings.partition(value, " ")
		c := selected.camera
		switch field {
		case "target":     found = selected.cameraTarget == "" ? "none" : selected.cameraTarget
		case "mode":       found = fmt.tprint(c.follow.mode)
		case "smoothTime": found = fmt.tprint(c.follow.smoothTime)
		case "maxSpeed":   found = fmt.tprint(c.follow.maxSpeed)
		case "deadzoneX":  found = fmt.tprint(c.follow.deadzone.x)
		case "offsetY":    found = fmt.tprint(c.follow.offset.y)
		case "lookAheadX": found = fmt.tprint(c.follow.lookAhead.x)
		case "limits":
			names := make([dynamic]string, context.temp_allocator)
			for side in e.CameraSide do if side in c.limits do append(&names, fmt.tprint(side))
			found = len(names) == 0 ? "none" : strings.join(names[:], ",", context.temp_allocator)
		case "limitLeft":  found = fmt.tprint(c.limitMin.x)
		case "limitRight": found = fmt.tprint(c.limitMax.x)
		case "shakeStrength": found = fmt.tprint(c.shake.strength)
		case "zoom":       found = fmt.tprint(selected.zoom)
		case: return false, fmt.tprintf("unknown cam field '%s'", field)
		}
		return found == strings.trim_space(expected), found
	case "states":
		node, _ := States_Machine(s)
		if node == nil do return false, "the States tab shows no StateMachine"
		field, _, expected := strings.partition(value, " ")
		m := &node.stateMachine
		switch field {
		case "states":      found = fmt.tprint(len(m.states))
		case "transitions": found = fmt.tprint(len(m.transitions))
		case "params":      found = fmt.tprint(len(m.params))
		case "start":       found = m.start
		case "selected":    found = s.states.state >= 0 && s.states.state < len(m.states) ? m.states[s.states.state].name : "none"
		case "position":
			if s.states.state < 0 || s.states.state >= len(m.states) do return false, "no state selected"
			p := m.states[s.states.state].position
			found = fmt.tprintf("%v, %v", p.x, p.y)
		case: return false, fmt.tprintf("unknown states field '%s'", field)
		}
		return found == strings.trim_space(expected), found
	case "live":
		field, _, expected := strings.partition(value, " ")
		switch field {
		case "connected":  found = fmt.tprint(s.live.connected)
		case "paused":     found = fmt.tprint(s.live.paused)
		case "shapes":     found = fmt.tprint(s.live.shapes)
		case "nodes":      found = fmt.tprint(len(s.live.nodes))
		case "properties": found = fmt.tprint(len(s.live.properties))
		case "selected":   found = fmt.tprint(s.live.selected != "")
		case "scene":      found = s.live.scene
		case "prop":
			// "live prop <name> <value>": the chosen node's property as the game sent it
			name, _, want := strings.partition(expected, " ")
			found = "(none)"
			for p in s.live.properties do if p.name == name do found = p.value
			return found == strings.trim_space(want), found
		case: return false, fmt.tprintf("unknown live field '%s'", field)
		}
		// Counts: "> n" passes for more than n
		if strings.has_prefix(expected, "> ") {
			n, _ := strconv.parse_int(expected[2:])
			have, _ := strconv.parse_int(found)
			return have > n, found
		}
		return found == strings.trim_space(expected), found
	case "scene_lit":
		found = fmt.tprint(s.project.scenes[s.currentScene].settings.lighting)
	case "viewport_unlit":
		found = fmt.tprint(s.viewport.unlit)
	case "light":
		if selected == nil || selected.kind != .Light2D do return false, "no Light2D selected"
		field, _, expected := strings.partition(value, " ")
		l := selected.light
		switch field {
		case "kind":    found = fmt.tprint(l.kind)
		case "energy":  found = fmt.tprint(l.energy)
		case "radius":  found = fmt.tprint(l.radius)
		case "angle":   found = fmt.tprint(l.angle)
		case "shadows": found = fmt.tprint(l.shadows)
		case: return false, fmt.tprintf("unknown light field '%s'", field)
		}
		return found == strings.trim_space(expected), found
	case "traced":
		// "traced <node> <n | > n>": the traced CollisionShapes under a node
		name, _, expected := strings.partition(value, " ")
		body := -1
		for node, i in scene.nodes do if node.name == name do body = i
		count := 0
		for node in scene.nodes do if body >= 0 && node.parent == body && node.kind == .CollisionShape && strings.has_prefix(node.name, "Traced") do count += 1
		found = fmt.tprint(count)
		expected = strings.trim_space(expected)
		if strings.has_prefix(expected, "> ") {
			n, _ := strconv.parse_int(expected[2:])
			return count > n, found
		}
		return found == expected, found
	case "material":
		// "material <friction | restitution | density> <value>": the inspector's material, two decimals
		field, _, expected := strings.partition(value, " ")
		if s.materialSelection < 0 || s.materialSelection >= len(s.project.materials) do return false, "no material shown"
		m := s.project.materials[s.materialSelection].material
		switch field {
		case "friction":    found = fmt.tprintf("%.2f", m.friction)
		case "restitution": found = fmt.tprintf("%.2f", m.restitution)
		case "density":     found = fmt.tprintf("%.2f", m.density)
		case: return false, fmt.tprintf("unknown material field '%s'", field)
		}
		return found == strings.trim_space(expected), found
	case "node_material":
		found = selected != nil ? (selected.material == "" ? "none" : selected.material) : "nothing selected"
	case "themes":
		found = fmt.tprint(len(s.project.themes))
	case "theme":
		if s.themeSelection < 0 || s.themeSelection >= len(s.project.themes) do return false, "the inspector shows no theme"
		field, _, expected := strings.partition(value, " ")
		v, known := e.UITheme_Get(s.project.themes[s.themeSelection].theme, field)
		if !known do return false, fmt.tprintf("no theme field '%s'", field)
		found = v
		return found == strings.trim_space(expected), found
	case "ui_theme":
		found = s.project.uiTheme == "" ? "none" : s.project.uiTheme
	case "tile_tool":
		found = fmt.tprint(s.tilePainter.tool)
	case "tile":
		// tile <layer> <column> <row> <value>: a cell of the selected TileMap, painted or the file's
		parts := strings.fields(value, context.temp_allocator)
		if len(parts) < 4 do return false, "expected a layer, column, row and value"
		scene := &s.project.scenes[s.currentScene]
		if s.selectedNode < 0 || s.selectedNode >= len(scene.nodes) || scene.nodes[s.selectedNode].kind != .TileMap do return false, "no TileMap selected"
		node := &scene.nodes[s.selectedNode]
		ase := AsepriteEdit_File(s.project.rootPath, node.tilemap.file)
		if ase == nil do return false, "its file can't be read"
		column, _ := strconv.parse_int(parts[1])
		row, _ := strconv.parse_int(parts[2])
		found = fmt.tprint(TilePaint_TileAt(node, ase, parts[0], column, row) & e.ASEPRITE_TILE_ID)
		return found == parts[3], found
	case "tilemap_built":
		// What the viewport built for the selected TileMap: layers, solid and one-way shapes, areas
		engineNode := Preview_Node(s.selectedNode)
		if engineNode == nil || !e.Node_Is(engineNode, e.TileMapNode) do return false, "the selected node isn't a built TileMap"
		tilemap := cast(^e.TileMapNode)engineNode
		shapes, areas := 0, 0
		for child in tilemap.children {
			if child.name == "Collision" do shapes += len(child.children)
			if e.Node_Is(child, e.Area) do areas += 1
		}
		found = fmt.tprintf("%d %d %d", len(tilemap.tileLayers), shapes, areas)
	case "ldtk_areas":
		// The Areas the selected LDtkLevel node's collision values made: "<name> <shapes>", or "none"
		engineNode := Preview_Node(s.selectedNode)
		if engineNode == nil || !e.Node_Is(engineNode, e.LDtkLevelNode) do return false, "the selected node isn't a built LDtkLevel"
		level := cast(^e.LDtkLevelNode)engineNode
		parts := make([dynamic]string, context.temp_allocator)
		for view in level.views do for child in view.children do if e.Node_Is(child, e.Area) do append(&parts, fmt.tprintf("%s %d", child.name, len(child.children)))
		found = len(parts) > 0 ? strings.join(parts[:], ", ", context.temp_allocator) : "none"
	case "dialog":
		found = s.removeConfirm.open ? "open" : "closed"
	case "add_dialog":
		found = s.addNode.open ? "open" : "closed"
	case "context_menu":
		found = s.contextMenu.open ? "open" : "closed"
	case "scene_clipboard":
		found = s.hasSceneClipboard ? "true" : "false"
	case "live_theme":
		// The look the editor shows: the applied settings' or the Settings dialog's draft
		applied := Settings_Theme(&s.settings).color == ctx.theme.color
		draft := Settings_Theme(&s.settingsDialog.draft).color == ctx.theme.color
		found = applied && draft ? "applied, draft" : applied ? "applied" : draft ? "draft" : "neither"
		return strings.contains(found, value), found
	case "theme_color":
		// theme_color <key> <#RRGGBB>: a color the editor shows now
		key, _, expected := strings.partition(value, " ")
		for which in ThemeColor do if THEME_COLOR_KEYS[which] == key {
			colors := ctx.theme.color
			found = ThemeColor_Format(ThemeColor_Field(&colors, which)^)
			return found == strings.trim_space(expected), found
		}
		return false, "no such color"
	case "import_folder":
		// import_folder <end of the path>: where the Import dialog opens next
		found = FixedText_String(&s.settings.importFolder)
		slashed, _ := strings.replace_all(found, "\\", "/", context.temp_allocator)
		return strings.has_suffix(slashed, value), found
	case "local_axes":
		found = s.viewport.localAxes ? "on" : "off"
	case "guides":
		found = fmt.tprint(len(scene.guides))
	case "guide":
		// guide <i> <x | y> <at>
		parts := strings.fields(value, context.temp_allocator)
		if len(parts) < 3 do return false, "expected an index, x or y, and a value"
		i, _ := strconv.parse_int(parts[0])
		if i < 0 || i >= len(scene.guides) do return false, fmt.tprintf("%d guides", len(scene.guides))
		g := scene.guides[i]
		found = fmt.tprintf("%s %v", g.vertical ? "x" : "y", math.round(g.at))
		return found == fmt.tprintf("%s %s", parts[1], parts[2]), found
	case "context_item":
		// The label is everything before the last word
		cut := strings.last_index_byte(value, ' ')
		if cut < 0 do return false, "expected a label and a state"
		label, expected := value[:cut], value[cut + 1:]
		found = "missing"
		if s.contextMenu.open {
			items := ContextMenu_Items(s)
			if parent, index, ok := contextItemFind(items, label); ok {
				item := parent >= 0 ? items[parent].submenu[index] : items[index]
				found = item.checked ? "checked" : item.disabled ? "disabled" : "enabled"
				if expected == "enabled" && found == "checked" do found = "enabled"
			}
		}
		return found == expected, found
	case "row":
		index, _, expected := strings.partition(value, " ")
		rows := SceneTreeRows(scene)
		row, _ := strconv.parse_int(index)
		found = row >= 0 && row < len(rows) ? scene.nodes[rows[row]].name : "none"
		return found == strings.trim_space(expected), found
	case "clipboard":
		found = fmt.tprint(len(s.clipboard))
	case "selection":
		found = fmt.tprint(len(s.selection))
	case "scenes":
		names := make([dynamic]string, context.temp_allocator)
		append(&names, ..Project_SceneNames(&s.project))
		found = strings.join(names[:], ",", context.temp_allocator)
	case "start_scene":
		found = s.project.startScene
	case "project_settings":
		found = s.projectSettings.open ? "open" : "closed"
	case "script":
		if selected == nil do return false, "nothing selected"
		found = selected.script == "" ? "none" : selected.script
	case "scripts":
		found = fmt.tprint(s.scripts.status)
	case "asset":
		// "asset <path> <exists | missing | filter <f> | msdf <bool>>": a project asset (import settings)
		path, _, rest := strings.partition(value, " ")
		field, _, expected := strings.partition(rest, " ")
		index := -1
		for a, i in s.project.assets do if a.path == path do index = i
		switch field {
		case "exists":  return index >= 0, index >= 0 ? "listed" : "not listed"
		case "missing": return index < 0, index >= 0 ? "listed" : "not listed"
		}
		if index < 0 do return false, "not listed"
		a := s.project.assets[index]
		switch field {
		case "filter": found = fmt.tprint(a.filter)
		case "msdf":   found = fmt.tprint(a.msdf)
		case: return false, fmt.tprintf("unknown asset field '%s'", field)
		}
		return found == strings.trim_space(expected), found
	case "file_exists":
		// A file in the project folder
		ok := os.exists(joinPath(s.project.rootPath, value, allocator = context.temp_allocator))
		return ok, ok ? "there" : "missing"
	case "atlas":
		// "atlas <regions | padding | filter> <value>": the atlas the inspector shows
		if s.atlasSelection < 0 || s.atlasSelection >= len(s.project.atlases) do return false, "no atlas shown"
		a := s.project.atlases[s.atlasSelection].data
		field, _, expected := strings.partition(value, " ")
		switch field {
		case "regions": found = fmt.tprint(len(a.regions))
		case "padding": found = fmt.tprint(a.padding)
		case "filter":  found = fmt.tprint(a.filter)
		case: return false, fmt.tprintf("unknown atlas field '%s'", field)
		}
		return found == strings.trim_space(expected), found
	case "plugin":
		// "plugin <folder> <Waiting|Building|Loaded|Failed>"
		folder, _, expected := strings.partition(value, " ")
		found = "missing"
		for p in Plugins_List() do if p.folder == folder do found = fmt.tprint(p.status)
		return found == strings.trim_space(expected), found
	case "dialogue":
		// "dialogue <shown | nodes | start | steps | node | step <i> <text|speaker|kind|options>> <value>":
		// the Dialogue tab's dialogue and its selected node
		def := Dialogue_Shown(s)
		field, _, expected := strings.partition(value, " ")
		if field == "shown" {
			found = def != nil ? def.path : "none"
			return found == strings.trim_space(expected), found
		}
		if def == nil do return false, "no dialogue shown"
		d := &def.data
		node := s.dialogue.node
		switch field {
		case "nodes": found = fmt.tprint(len(d.nodes))
		case "start": found = d.start
		case "node":  found = node >= 0 && node < len(d.nodes) ? d.nodes[node].name : "none"
		case "steps": found = node >= 0 && node < len(d.nodes) ? fmt.tprint(len(d.nodes[node].steps)) : "none"
		case "step":
			index, _, rest := strings.partition(expected, " ")
			what, _, want := strings.partition(rest, " ")
			i, _ := strconv.parse_int(index)
			if node < 0 || node >= len(d.nodes) || i < 0 || i >= len(d.nodes[node].steps) do return false, "no such step"
			st := d.nodes[node].steps[i]
			switch what {
			case "text":    found = st.text
			case "speaker": found = st.speaker
			case "kind":    found = fmt.tprint(st.kind)
			case "options": found = fmt.tprint(len(st.options))
			case "target":  found = st.target
			case: return false, fmt.tprintf("unknown step field '%s'", what)
			}
			return found == strings.trim_space(want), found
		case: return false, fmt.tprintf("unknown dialogue field '%s'", field)
		}
		return found == strings.trim_space(expected), found
	case "region":
		if selected == nil do return false, "nothing selected"
		found = selected.region == "" ? "none" : selected.region
	case "node_type":
		// The selected node's node type of the project's code ("none")
		if selected == nil do return false, "nothing selected"
		found = selected.customKind == "" ? "none" : selected.customKind
	case "more_scripts":
		// The selected node's more scripts, comma-separated ("none")
		if selected == nil do return false, "nothing selected"
		names := make([dynamic]string, context.temp_allocator)
		for extra in selected.moreScripts do append(&names, extra.name)
		found = len(names) == 0 ? "none" : strings.join(names[:], ",", context.temp_allocator)
	case "script_prop":
		// "script_prop <script or node type> <field> <value>": a value stored for one of the
		// selected node's more scripts or its node type ("(default)" when not set)
		if selected == nil do return false, "nothing selected"
		owner, _, rest := strings.partition(value, " ")
		field, _, expected := strings.partition(rest, " ")
		props: []ScriptPropDef
		if owner == selected.customKind do props = selected.customProps[:]
		if owner == selected.script do props = selected.props[:]
		for extra in selected.moreScripts do if extra.name == owner do props = extra.props[:]
		found = "(default)"
		for p in props do if p.name == field do found = p.value
		return found == strings.trim_space(expected), found
	case "prop":
		if selected == nil do return false, "nothing selected"
		propName, _, expected := strings.partition(value, " ")
		found = "(default)"
		for p in selected.props do if p.name == propName do found = p.value
		return found == strings.trim_space(expected), found
	case "new_script_dialog":
		found = s.newScript.open ? "open" : "closed"
	case "particle", "particle_linked":
		if selected == nil || selected.kind != .ParticleEmitter do return false, "no ParticleEmitter selected"
		setting, _, expected := strings.partition(value, " ")
		if name == "particle_linked" {
			found = fmt.tprint(ParticleField_Index(setting) in s.particleLinks)
		} else {
			known: bool
			found, known = e.ParticleSettings_Get(selected.particles, setting)
			if !known do return false, fmt.tprintf("no particle setting '%s'", setting)
		}
		return found == strings.trim_space(expected), found
	case "particle_near":
		if selected == nil || selected.kind != .ParticleEmitter do return false, "no ParticleEmitter selected"
		parts := strings.fields(value, context.temp_allocator)
		if len(parts) < 3 do return false, "expected a setting, a value and a tolerance"
		text, _ := e.ParticleSettings_Get(selected.particles, parts[0])
		got, _ := strconv.parse_f32(text)
		want, _ := strconv.parse_f32(parts[1])
		tolerance, _ := strconv.parse_f32(parts[2])
		return abs(got - want) <= tolerance, text
	case "ramp_stops":
		if selected == nil || selected.kind != .ParticleEmitter do return false, "no ParticleEmitter selected"
		found = fmt.tprint(selected.particles.colorRamp.count)
	case "buses":
		found = fmt.tprint(len(s.project.buses))
	case "code_state":
		// A field of the code editor's state (its control package's JSON, by dotted path, e.g.
		// find.open, cursors, selected_text), or peek_open, refs_open, refs, status, dialog
		field, _, expected := strings.partition(value, " ")
		expected = strings.trim_space(expected)
		// "..." keeps leading and trailing spaces
		if len(expected) >= 2 && expected[0] == '"' && expected[len(expected) - 1] == '"' do expected = expected[1:len(expected) - 1]
		path := CodeTabs_Active(s)
		peek, refsOpen, refs := CodeEditor_Navigation(path)
		switch field {
		case "peek_open": found = fmt.tprint(peek)
		case "refs_open": found = fmt.tprint(refsOpen)
		case "refs":      found = fmt.tprint(refs)
		case "status":
			found = CodeEditor_StatusText(path)
			return strings.contains(found, expected), found
		case "dialog":    found = fmt.tprint(s.codeDialog)
		case:
			parsed, err := json.parse_string(CodeEditor_StateJSON(path), allocator = context.temp_allocator)
			if err != nil do return false, "no state"
			v := parsed
			for part in strings.split(field, ".", context.temp_allocator) {
				object, ok := v.(json.Object)
				if !ok do return false, fmt.tprintf("no field %s", field)
				v = object[part]
			}
			#partial switch x in v {
			case json.String:  found = string(x)
			case json.Boolean: found = fmt.tprint(bool(x))
			case json.Integer: found = fmt.tprint(i64(x))
			case json.Float:   found = fmt.tprintf("%g", f64(x))
			case json.Array:   found = fmt.tprint(len(x))
			case:              found = fmt.tprint(v)
			}
			// Text compares with \n and \t spelled out
			expected, _ = strings.replace_all(expected, "\\n", "\n", context.temp_allocator)
			expected, _ = strings.replace_all(expected, "\\t", "\t", context.temp_allocator)
		}
		return found == expected, found
	case "code_disk_conflict":
		found = fmt.tprint(CodeEditor_HasDiskConflict(CodeTabs_Active(s)))
	case "code_servers":
		running, started := CodeEditor_Servers()
		found = fmt.tprintf("%d running, %d started", running, started)
	case "code_close_dialog":
		found = s.codeClose.open ? "open" : "closed"
	case "toolchain":
		// A tool on Settings > Toolchain: found or missing
		name, _, expected := strings.partition(value, ":")
		// The dialog's draft while it's open (what the page shows)
		checked := s.settingsDialog.open ? &s.settingsDialog.draft : &s.settings
		for tool in Toolchain_Check(checked) do if tool.name == strings.trim_space(name) {
			found = tool.found ? "found" : "missing"
			return found == strings.trim_space(expected), fmt.tprintf("%s (%s)", found, tool.path)
		}
		return false, fmt.tprintf("no tool %q", name)
	case "scene_tabs":
		// The scene tabs' names, in order ("MenuScene,PlayScene")
		names := make([dynamic]string, context.temp_allocator)
		for index in ViewportTabScenes(s) do append(&names, s.project.scenes[index].name)
		found = strings.join(names[:], ",", context.temp_allocator)
	case "code_tabs":
		found = fmt.tprint(len(s.codeTabs))
		return found == value, fmt.tprintf("%s: %v", found, s.codeTabs[:])
	case "code_tab":
		active := CodeTabs_Active(s)
		found = active == "" ? "none" : filepath.base(active)
	case "code_focused":
		found = fmt.tprint(CodeEditor_Focused(ctx))
	case "code_contains":
		want, _, text := strings.partition(value, " ")
		text, _ = strings.replace_all(text, "\\t", "\t", context.temp_allocator)
		text, _ = strings.replace_all(text, "\\n", "\n", context.temp_allocator)
		has := strings.contains(CodeEditor_Text(CodeTabs_Active(s)), text)
		found = fmt.tprint(has)
		return found == want, found
	case "code_dirty":
		found = fmt.tprint(CodeEditor_IsDirty(CodeTabs_Active(s)))
	case "render_path":
		found = Preview_UsesShaders() ? "effects" : Preview_Shared() ? "shared" : Preview_UsesGPU() ? "readback" : "software"
	case "viewport_has_color":
		// `viewport_has_color <#rrggbb> <distance> <true|false>`: a pixel of the last render within
		// `distance` (0 to 255 per channel) of the color
		parts := strings.fields(value, context.temp_allocator)
		if len(parts) < 3 do return false, "expected a color, a distance and true or false"
		want, ok := e.ParseColor(parts[0])
		if !ok do return false, "not a color"
		distance, _ := strconv.parse_int(parts[1])
		pixels, size := Viewport_LastRender()
		hit := false
		for i := 0; i + 3 < len(pixels) && i < size.x * size.y * 4; i += 4 {
			if abs(int(pixels[i]) - int(want.r)) <= distance && abs(int(pixels[i + 1]) - int(want.g)) <= distance && abs(int(pixels[i + 2]) - int(want.b)) <= distance {
				hit = true
				break
			}
		}
		found = fmt.tprint(hit)
		return found == parts[2], found
	case "code_render_path":
		found = CodeEditor_OnGPU() ? "shared" : "software"
	case "code_rendered":
		inked, uploaded := CodeEditor_RenderStats(CodeTabs_Active(s))
		found = fmt.tprint(inked > 500 && uploaded)
	case "code_lsp":
		found = CodeEditor_LspStatus(CodeTabs_Active(s))
		if found == "" do found = "Off"
	case "code_completion_has":
		found = fmt.tprint(CodeEditor_CompletionHas(CodeTabs_Active(s), strings.trim_space(value)))
		_, items := CodeEditor_CompletionVisible(CodeTabs_Active(s))
		return found == "true", fmt.tprintf("%s; %d items from the server", found, items)
	case "code_completion":
		visible, items := CodeEditor_CompletionVisible(CodeTabs_Active(s))
		found = fmt.tprint(visible)
		text := CodeEditor_Text(CodeTabs_Active(s))
		return found == value, fmt.tprintf("%v; %d items from the server; ends %q", visible, items, text[max(len(text) - 80, 0):])
	case "code_caret":
		line, column := CodeEditor_Caret(CodeTabs_Active(s))
		found = fmt.tprintf("%d %d", line, column)
	case "code_read_only":
		found = fmt.tprint(CodeEditor_IsReadOnly(CodeTabs_Active(s)))
	case "meter":
		key, _, expected := strings.partition(value, " ")
		found = levelMeter_Shown(key) > -50 ? "sounding" : "silent"
		return found == strings.trim_space(expected), found
	case "widget_bottom_near":
		parts := strings.fields(value, context.temp_allocator)
		if len(parts) < 3 do return false, "expected two widget keys and a distance"
		a, aOk := ctx.widgets.states[skald.hash_id(parts[0])]
		b, bOk := ctx.widgets.states[skald.hash_id(parts[1])]
		if !aOk || !bOk do return false, "not drawn"
		px, _ := strconv.parse_f32(parts[2])
		gap := (b.last_rect.y + b.last_rect.h) - (a.last_rect.y + a.last_rect.h)
		return abs(gap) <= px, fmt.tprintf("%.0f px apart (fader %.0f px tall)", gap, a.last_rect.h)
	case "scrolled":
		key, _, expected := strings.partition(value, " ")
		state := ctx.widgets.states[skald.hash_id(key)]
		found = fmt.tprint(state.scroll_y > 0.5)
		return found == strings.trim_space(expected), found
	case "row_visible":
		parts := strings.fields(value, context.temp_allocator)
		if len(parts) < 3 do return false, "expected a tree, a row and true or false"
		tree, ok := ctx.widgets.states[skald.hash_id(parts[0])]
		if !ok do return false, "the tree wasn't drawn"
		row, _ := strconv.parse_int(parts[1])
		area := tree.clip_rect.w > 0 ? tree.clip_rect : tree.last_rect
		y := tree.last_rect.y + f32(row) * s.settings.rowHeight
		found = fmt.tprint(y >= area.y - 0.5 && y + s.settings.rowHeight <= area.y + area.h + 0.5)
		return found == parts[2], found
	case "recent_menu":
		index, _, name := strings.partition(value, " ")
		i, _ := strconv.parse_int(index)
		shown := Recent_Shown(s)
		found = i >= 0 && i < len(shown) ? filepath.base(s.recentProjects.folders[shown[i]]) : "none"
		return found == strings.trim_space(name), found
	case "in_window":
		// The widget's whole rect (not clipped) is inside the window: nothing pushed off its edge
		st, ok := ctx.widgets.states[skald.hash_id(value)]
		if !ok || st.last_frame + 1 < ctx.widgets.frame do return false, "not drawn"
		r := st.last_rect
		size := ctx.renderer != nil ? [2]f32{f32(ctx.renderer.fb_size.x), f32(ctx.renderer.fb_size.y)} : [2]f32{}
		return r.w > 0 && r.x >= -0.5 && r.y >= -0.5 && r.x + r.w <= size.x + 0.5 && r.y + r.h <= size.y + 0.5, fmt.tprintf("%v in a %v window", r, size)
	case "game":
		// `game pid <new | same>` (against note_game), `game restartable <true | false>`
		field, _, expected := strings.partition(value, " ")
		switch field {
		case "pid":
			running := s.play.stage == .Running
			found = !running ? "none" : s.play.process.pid == driver.notedPid ? "same" : "new"
			return found == strings.trim_space(expected), fmt.tprintf("%s (pid %d, noted %d)", found, running ? s.play.process.pid : 0, driver.notedPid)
		case "restartable":
			found = fmt.tprint(Play_CanRestart(s))
		case: return false, fmt.tprintf("unknown game field '%s'", field)
		}
		return found == strings.trim_space(expected), found
	case "widget_inside":
		key, _, container := strings.partition(value, " ")
		inner, innerOk := widgetRect(ctx, key)
		outer, outerOk := widgetRect(ctx, strings.trim_space(container))
		if !innerOk || !outerOk do return false, "not both drawn"
		inside := inner.x >= outer.x - 0.5 && inner.y >= outer.y - 0.5 && inner.x + inner.w <= outer.x + outer.w + 0.5 && inner.y + inner.h <= outer.y + outer.h + 0.5
		return inside, fmt.tprintf("%v in %v", inner, outer)
	case "clear_of_scrollbar":
		key, _, container := strings.partition(value, " ")
		// The widget's whole rect, not clipped: what spills under the scrollbar is the point
		_, innerOk := widgetRect(ctx, key)
		inner := ctx.widgets.states[skald.hash_id(key)].last_rect
		outer, outerOk := widgetRect(ctx, strings.trim_space(container))
		if !innerOk || !outerOk do return false, "not both drawn"
		limit := outer.x + outer.w - INSPECTOR_SCROLLBAR_WIDTH
		return inner.x + inner.w <= limit + 0.5, fmt.tprintf("ends at %.1f, the scrollbar starts at %.1f (%v in %v)", inner.x + inner.w, limit, inner, outer)
	case "widget_visible":
		key, _, expected := strings.partition(value, " ")
		_, visible := widgetRect(ctx, key)
		st := ctx.widgets.states[skald.hash_id(key)]
		// Drawn last frame: a widget that's gone keeps its state for a while
		visible = visible && st.last_frame + 1 >= ctx.widgets.frame
		found = fmt.tprint(visible)
		return found == strings.trim_space(expected), fmt.tprintf("%s; rect %v, clip %v", found, st.last_rect, st.clip_rect)
	case "bus":
		parts := strings.fields(value, context.temp_allocator)
		if len(parts) < 3 do return false, "expected an index, a field and a value"
		i, _ := strconv.parse_int(parts[0])
		if i < 0 || i >= len(s.project.buses) do return false, fmt.tprintf("no bus %d", i)
		b := s.project.buses[i]
		switch parts[1] {
		case "name":   found = b.name
		case "volume": found = fmt.tprintf("%.2f", b.volume)
		case "pan":    found = fmt.tprintf("%.2f", b.pan)
		case "mute":   found = fmt.tprint(b.mute)
		case "nodes":  found = fmt.tprint(Bus_NodeCount(&s.project, i == 0 ? "" : b.name))
		case "effects": found = fmt.tprint(b.effectCount)
		case: return false, fmt.tprintf("unknown bus field '%s'", parts[1])
		}
		return found == strings.join(parts[2:], " ", context.temp_allocator), found
	case "bus_effect":
		// `bus_effect <bus> <index> <kind|bypass|cutoff|resonance|delay|feedback|roomSize|damping|mix> <value>`
		parts := strings.fields(value, context.temp_allocator)
		if len(parts) < 4 do return false, "expected a bus, an index, a field and a value"
		bi, _ := strconv.parse_int(parts[0])
		fi, _ := strconv.parse_int(parts[1])
		if bi < 0 || bi >= len(s.project.buses) do return false, fmt.tprintf("no bus %d", bi)
		b := &s.project.buses[bi]
		if fi < 0 || fi >= b.effectCount do return false, fmt.tprintf("bus %d has %d effects", bi, b.effectCount)
		fx := b.effects[fi]
		switch parts[2] {
		case "kind":      found = fmt.tprint(fx.kind)
		case "bypass":    found = fmt.tprint(fx.bypass)
		case "cutoff":    found = fmt.tprintf("%.0f", fx.cutoff)
		case "resonance": found = fmt.tprintf("%.2f", fx.resonance)
		case "delay":     found = fmt.tprintf("%.2f", fx.delay)
		case "feedback":  found = fmt.tprintf("%.2f", fx.feedback)
		case "roomSize":  found = fmt.tprintf("%.2f", fx.roomSize)
		case "damping":   found = fmt.tprintf("%.2f", fx.damping)
		case "mix":       found = fmt.tprintf("%.2f", fx.mix)
		case: return false, fmt.tprintf("unknown effect field '%s'", parts[2])
		}
		return found == parts[3], found
	case "touch":
		// `touch <actions|radius|deadzone|zone|floating|visibility|mouse|opacity|label> <value>`: the selected touch control
		if selected == nil || !NodeKind_IsTouchControl(selected.kind) do return false, "no VirtualJoystick or TouchButton selected"
		field, _, expected := strings.partition(value, " ")
		tc := selected.touch
		switch field {
		case "actions":    found = selected.touchActions == "" ? "none" : selected.touchActions
		case "radius":     found = fmt.tprintf("%.0f", tc.radius)
		case "deadzone":   found = fmt.tprintf("%.2f", tc.deadzone)
		case "zone":       found = fmt.tprintf("%.0fx%.0f", tc.zone.x, tc.zone.y)
		case "floating":   found = fmt.tprint(tc.floating)
		case "visibility": found = fmt.tprint(tc.visibility)
		case "mouse":      found = fmt.tprint(tc.mouse)
		case "opacity":    found = fmt.tprintf("%.2f", tc.opacity)
		case "label":      found = selected.text == "" ? "none" : selected.text
		case: return false, fmt.tprintf("unknown touch field '%s'", field)
		}
		return found == strings.trim_space(expected), found
	case "steam":
		// `steam <app_id|cloud|achievements> <value>`: the project's; `steam draft_achievements <n>`;
		// `steam achievement <i> <name|title|description|hidden> <value>`
		parts := strings.fields(value, context.temp_allocator)
		if len(parts) < 2 do return false, "expected a field and a value"
		switch parts[0] {
		case "app_id":             found = fmt.tprint(s.project.steam.appId)
		case "cloud":              found = fmt.tprint(s.project.steam.cloudSaves)
		case "achievements":       found = fmt.tprint(len(s.project.achievements))
		case "draft_achievements": found = fmt.tprint(len(s.projectSettings.achievements))
		case "achievement":
			if len(parts) < 4 do return false, "expected an index, a field and a value"
			i, _ := strconv.parse_int(parts[1])
			if i < 0 || i >= len(s.project.achievements) do return false, fmt.tprintf("%d achievements", len(s.project.achievements))
			a := s.project.achievements[i]
			switch parts[2] {
			case "name":        found = a.name
			case "title":       found = a.title
			case "description": found = a.description
			case "hidden":      found = fmt.tprint(a.hidden)
			case: return false, fmt.tprintf("unknown achievement field '%s'", parts[2])
			}
			return found == strings.join(parts[3:], " ", context.temp_allocator), found
		case: return false, fmt.tprintf("unknown steam field '%s'", parts[0])
		}
		return found == strings.join(parts[1:], " ", context.temp_allocator), found
	case "players":
		// `players <max|keyboard|join> <value>`: the project's local players settings
		field, _, expected := strings.partition(value, " ")
		pl := s.project.players
		switch field {
		case "max":      found = fmt.tprint(pl.maxPlayers)
		case "keyboard": found = fmt.tprint(pl.keyboard)
		case "join":     found = pl.joinAction == "" ? "default" : pl.joinAction
		case: return false, fmt.tprintf("unknown players field '%s'", field)
		}
		return found == strings.trim_space(expected), found
	case "shader":
		if selected == nil do return false, "no node selected"
		field, _, rest := strings.partition(value, " ")
		if field == "path" {
			found = selected.shader == "" ? "none" : selected.shader
			return found == strings.trim_space(rest), found
		}
		name, _, expected := strings.partition(rest, " ")
		found = "default"
		for p in selected.shaderParams do if p.name == name do found = p.value
		return found == strings.trim_space(expected), found
	case "bus_selection":
		// The bus the inspector shows the effects of (-1 none)
		found = fmt.tprint(s.busSelection)
	case "preview_effects":
		// How many effects the editor's preview plays through: its bus's and Master's ("2 1")
		bus, master := AudioPreview_EffectCounts()
		found = fmt.tprintf("%d %d", bus, master)
	case "music_layer":
		// `music_layer <index> <name|sound|volume> <value>`; `music_layer count <n>`
		if selected == nil || selected.kind != .MusicPlayer do return false, "no MusicPlayer selected"
		parts := strings.fields(value, context.temp_allocator)
		if len(parts) == 2 && parts[0] == "count" {
			found = fmt.tprint(len(selected.musicLayers))
			return found == parts[1], found
		}
		if len(parts) < 2 do return false, "expected an index, a field and a value"
		li, _ := strconv.parse_int(parts[0])
		if li < 0 || li >= len(selected.musicLayers) do return false, fmt.tprintf("%d layers", len(selected.musicLayers))
		l := selected.musicLayers[li]
		switch parts[1] {
		case "name":   found = l.name
		case "sound":  found = l.sound == "" ? "none" : l.sound
		case "volume": found = fmt.tprintf("%.2f", l.volume)
		case: return false, fmt.tprintf("unknown layer field '%s'", parts[1])
		}
		return found == strings.join(parts[2:], " ", context.temp_allocator), found
	case "sound":
		if selected == nil || !isSoundKind(selected.kind) do return false, "no sound node selected"
		field, _, expected := strings.partition(value, " ")
		a := selected.audio
		switch field {
		case "sound":     found = selected.sound == "" ? "none" : selected.sound
		case "bus":       found = selected.bus == "" ? e.MASTER_BUS : selected.bus
		case "volume":    found = fmt.tprintf("%.2f", a.volume)
		case "pitch":     found = fmt.tprintf("%.2f", a.pitch)
		case "pan":       found = fmt.tprintf("%.2f", a.pan)
		case "loop":      found = fmt.tprint(a.loop)
		case "autostart": found = fmt.tprint(a.autostart)
		case "range":     found = fmt.tprintf("%.0f", a.maxDistance)
		case: return false, fmt.tprintf("unknown sound field '%s'", field)
		}
		return found == strings.trim_space(expected), found
	case "animations":
		// What the Animation panel shows: the sprite's own, or its asset's
		src := AnimEdit_Source(s)
		if src.kind == .None do return false, "no animations shown"
		found = fmt.tprint(len(src.animations^))
	case "anim_source":
		src := AnimEdit_Source(s)
		found = src.path == "" ? fmt.tprint(src.kind) : fmt.tprintf("%v %s", src.kind, src.path)
	case "animation_set":
		found = selected != nil && selected.animationSet != "" ? selected.animationSet : "none"
	case "animation_sets":
		found = fmt.tprint(len(s.project.animationSets))
	case "animation":
		_, animation, _ := AnimEdit_Selection(s)
		if animation == nil do return false, "no animation selected"
		field, _, expected := strings.partition(value, " ")
		cells := AnimEdit_Cells(s.project.rootPath, animation^)
		start, end := AnimationDef_Range(animation^, cells)
		g := animation.grid
		switch field {
		case "name":    found = animation.name
		case "start":   found = fmt.tprint(start)
		case "end":     found = fmt.tprint(end)
		case "count":   found = fmt.tprint(end - start + 1)
		case "fps":     found = fmt.tprint(animation.fps)
		case "loop":    found = fmt.tprint(animation.loop)
		case "mode":    found = fmt.tprint(animation.playMode)
		case "sheet":   found = animation.sheet == "" ? "none" : animation.sheet
		case "grid":    found = fmt.tprint(g.mode)
		case "columns": found = fmt.tprint(g.columns)
		case "rows":    found = fmt.tprint(g.rows)
		case "cell":    found = fmt.tprintf("%vx%v", g.cellSize.x, g.cellSize.y)
		case "margin":  found = fmt.tprint(g.margin)
		case "gap":     found = fmt.tprint(g.spacing)
		case "cells":   found = fmt.tprint(cells)
		case "repeat":  found = fmt.tprint(animation.repeat)
		case "durations":
			// Milliseconds, space separated ("none" without frame times)
			ms := make([dynamic]string, context.temp_allocator)
			for d in animation.durations do append(&ms, fmt.tprint(int(d * 1000 + 0.5)))
			found = len(ms) == 0 ? "none" : strings.join(ms[:], " ", context.temp_allocator)
		case: return false, fmt.tprintf("unknown animation field '%s'", field)
		}
		return found == strings.trim_space(expected), found
	case "animation_note":
		_, animation, _ := AnimEdit_Selection(s)
		if animation == nil do return false, "no animation selected"
		found = AnimEdit_SheetNote(s.project.rootPath, animation^)
		if found == "" do found = "none"
	case "autoplay":
		if selected == nil do return false, "nothing selected"
		found = selected.autoplay == "" ? "none" : selected.autoplay
	case "sheet_loaded":
		_, animation, _ := AnimEdit_Selection(s)
		found = animation != nil ? fmt.tprint(AnimationPanel_SheetLoaded(s, animation.sheet)) : "false"
	case "input_actions":
		found = fmt.tprint(len(s.project.actions))
	case "draft_input_actions":
		found = fmt.tprint(len(s.projectSettings.actions))
	case "input_bindings", "draft_input_bindings":
		action: ^ActionDef
		expected := value
		if name == "input_bindings" {
			actionName, _, rest := strings.partition(value, " ")
			expected = rest
			for &a in s.project.actions do if a.name == actionName do action = &a
		} else if d := &s.projectSettings; d.selectedAction >= 0 && d.selectedAction < len(d.actions) {
			action = &d.actions[d.selectedAction]
		}
		if action == nil do return false, "no such action"
		parts := make([dynamic]string, context.temp_allocator)
		for b in action.bindings do append(&parts, e.InputBinding_Describe(b))
		found = strings.join(parts[:], ", ", context.temp_allocator)
		return found == strings.trim_space(expected), found
	case "ramp_stop":
		found = fmt.tprint(s.rampStop)
	case "linked":
		pairName, _, expected := strings.partition(value, " ")
		pair, known := reflect.enum_from_name(LinkedPair, pairName)
		if !known do return false, fmt.tprintf("unknown pair '%s'", pairName)
		found = fmt.tprint(s.inspectorLinks[pair])
		return found == strings.trim_space(expected), found
	case "renaming":
		found = fmt.tprint(s.rename.active)
	case "grid":
		found = s.viewport.gridVisible ? "on" : "off"
	case "snap":
		found = s.viewport.snap ? "on" : "off"
	case "modified":
		found = fmt.tprint(Project_IsModified(s))
	case "project":
		found = s.project.name
	case "ldtk_level":
		// The selected node's LDtk level ("" shows as "first")
		if selected == nil do return false, "nothing selected"
		found = selected.ldtk.level == "" ? "first" : selected.ldtk.level
	case "about_dialog":
		found = s.aboutOpen ? "open" : "closed"
	case "confirm_dialog":
		found = s.session.confirm.open ? "open" : "closed"
	case "new_project_dialog":
		found = s.session.newProject.open ? "open" : "closed"
	case "settings_dialog":
		found = s.settingsDialog.open ? "open" : "closed"
	case "project_grid":
		g := s.project.grid
		found = fmt.tprintf("%d %d %d %d %d", g.size.x, g.size.y, g.majorEvery, g.opacity, g.majorOpacity)
	case "setting":
		setting, _, expected := strings.partition(value, " ")
		switch setting {
		case "font_size":     found = fmt.tprint(s.settings.fontSize)
		case "spacing":       found = fmt.tprint(s.settings.spacing)
		case "row_height":    found = fmt.tprint(s.settings.rowHeight)
		case "theme":         found = fmt.tprint(s.settings.theme)
		case "undo_merge_ms": found = fmt.tprint(s.settings.undoMergeMs)
		case "undo_limit":    found = fmt.tprint(s.settings.undoLimit)
		case "console_limit": found = fmt.tprint(s.settings.consoleLimit)
		case: return false, fmt.tprintf("unknown setting '%s'", setting)
		}
		return found == strings.trim_space(expected), found
	case "chord":
		action_name, _, expected := strings.partition(value, " ")
		action, known := reflect.enum_from_name(Action, action_name)
		if !known do return false, fmt.tprintf("unknown action '%s'", action_name)
		found = Keymap_FormatChords(s.settings.keymap[action])
		if found == "" do found = "-"
		return found == strings.trim_space(expected), found
	case "capture":
		found = s.settingsDialog.capture.active ? "on" : "off"
	case "settings_file_contains":
		data, err := os.read_entire_file(s.settingsPath, context.temp_allocator)
		if err != nil do return false, fmt.tprintf("can't read '%s'", s.settingsPath)
		return strings.contains(string(data), value), "not found"
	case "undo":
		found = fmt.tprint(len(s.history.undo))
	case "redo":
		found = fmt.tprint(len(s.history.redo))
	case "field":
		field, _, expected := strings.partition(value, " ")
		if selected == nil do return false, "nothing selected"
		switch field {
		case "x":        found = fmt.tprint(math.round(selected.position.x))
		case "y":        found = fmt.tprint(math.round(selected.position.y))
		case "rotation": found = fmt.tprint(math.round(selected.rotation))
		case "scale_x":  found = fmt.tprintf("%.2f", selected.scale.x)
		case "scale_y":  found = fmt.tprintf("%.2f", selected.scale.y)
		case "visible":  found = fmt.tprint(selected.visible)
		case "name":     found = selected.name
		case "z":        found = fmt.tprint(selected.zIndex)
		case:            return false, fmt.tprintf("unknown field '%s'", field)
		}
		return found == strings.trim_space(expected), found
	case "export":
		found = Export_Busy(s) ? "running" : "idle"
	case "archive":
		found = s.archive.busy ? "busy" : "idle"
	case "git":
		found = s.git.busy || s.git.refreshing || s.git.stale ? "busy" : "idle"
	case "git_state":
		found = fmt.tprint(s.git.snapshot.availability)
	case "git_branch":
		found = s.git.snapshot.branch
	case "git_changes":
		found = fmt.tprint(len(s.git.snapshot.changes))
	case "git_staged":
		staged := 0
		for change in s.git.snapshot.changes do if change.staged != ' ' && change.staged != '?' do staged += 1
		found = fmt.tprint(staged)
	case "git_commits":
		found = fmt.tprint(len(s.git.snapshot.log))
	case "git_last_commit":
		found = len(s.git.snapshot.log) > 0 ? s.git.snapshot.log[0].subject : "none"
	case "git_diff":
		// The change whose diff shows, "none" when closed
		found = s.git.diffPath == "" ? "none" : s.git.diffPath
	case "git_diff_contains":
		found = strings.contains(s.git.diffText, value) ? value : "(not in the diff)"
	case "git_discard_dialog":
		found = s.git.discardAsk != "" ? "open" : "closed"
	case "export_enabled":
		target_name, _, expected := strings.partition(value, " ")
		target, known := reflect.enum_from_name(ExportTarget, target_name)
		if !known do return false, fmt.tprintf("unknown export target '%s'", target_name)
		found = fmt.tprint(s.project.exports.targets[target].enabled)
		return found == strings.trim_space(expected), found
	case "project_file_missing":
		path := joinPath(s.project.rootPath, value, allocator = context.temp_allocator)
		found = os.exists(path) ? "exists" : "missing"
		return found == "missing", fmt.tprintf("%s %s", path, found)
	case "project_file":
		path := joinPath(s.project.rootPath, value, allocator = context.temp_allocator)
		return os.exists(path), fmt.tprintf("%s doesn't exist", path)
	case "globals", "draft_globals":
		list := name == "globals" ? s.project.globals[:] : s.projectSettings.globals[:]
		names := make([dynamic]string, context.temp_allocator)
		for g in list do append(&names, g.script)
		found = len(names) == 0 ? "none" : strings.join(names[:], ",", context.temp_allocator)
	case "data_count":
		found = fmt.tprint(len(s.project.data))
	case "inspector_data":
		found = s.dataSelection >= 0 && s.dataSelection < len(s.project.data) ? DataName(s.project.data[s.dataSelection].path) : "none"
	case "data_value":
		parts := strings.fields(value, context.temp_allocator)
		if len(parts) < 3 do return false, "expected <name> <field> <value>"
		for d in s.project.data do if DataName(d.path) == parts[0] {
			found = Props_Value(d.values[:], parts[1], "(default)")
			return found == strings.join(parts[2:], " ", context.temp_allocator), found
		}
		return false, "no such data resource"
	case "shapes":
		found = s.viewport.showShapes ? "on" : "off"
	case "physics_debug":
		found = s.project.physics.debugDraw ? "on" : "off"
	case "physics_debug_shown":
		found = PhysicsDebug_Shown(s) ? "on" : "off"
	case "generated_shapes":
		counts: [GeneratedShapeKind]int
		for shape in Preview_GeneratedShapes(s, context.temp_allocator) do counts[shape.kind] += 1
		found = fmt.tprintf("%d %d %d", counts[.Solid], counts[.One_Way], counts[.Area])
	case "project_file_contains", "project_file_lacks":
		path, _, text := strings.partition(value, " ")
		data, err := os.read_entire_file(joinPath(s.project.rootPath, path, allocator = context.temp_allocator), context.temp_allocator)
		if err != nil do return false, fmt.tprintf("can't read %s", path)
		found := strings.contains(string(data), text)
		return name == "project_file_contains" ? found : !found, found ? "found" : "not found"
	case "console_contains", "output_contains":
		lines := LogList_Lines(name == "console_contains" ? &s.console : &s.output)
		for line in lines do if strings.contains(line.text, value) do return true, "found"
		return false, fmt.tprintf("%d lines, none match", len(lines))
	case "console_lacks":
		for line in LogList_Lines(&s.console) do if strings.contains(line.text, value) do return false, line.text
		return true, "none"
	case "console_lines", "output_lines":
		found = fmt.tprint(len(LogList_Lines(name == "console_lines" ? &s.console : &s.output)))
	case "console_shown", "output_shown":
		found = fmt.tprint(len(LogList_Shown(name == "console_shown" ? &s.console : &s.output)))
	case "console_following", "output_following":
		found = (name == "console_following" ? s.console : s.output).paused ? "false" : "true"
	case "console_first":
		lines := LogList_Lines(&s.console)
		if len(lines) == 0 do return false, "no lines"
		return strings.contains(lines[0].text, value), lines[0].text
	case "console_category", "output_category":
		// console_category <name> <shown | hidden | missing>
		list := name == "console_category" ? &s.console : &s.output
		category, _, want := strings.partition(value, " ")
		found = "missing"
		for c in list.categories do if c.name == category do found = c.hidden ? "hidden" : "shown"
		return found == strings.trim_space(want), found
	case "console_line_category":
		// console_line_category <category> <Level> <text>: the first line containing the text came
		// with that category and level
		category, _, rest := strings.partition(value, " ")
		level, _, text := strings.partition(strings.trim_space(rest), " ")
		for line in LogList_Lines(&s.console) do if strings.contains(line.text, strings.trim_space(text)) {
			found = fmt.tprintf("%s %v", LogList_CategoryName(&s.console, line), line.level)
			return found == fmt.tprintf("%s %s", category, level), found
		}
		return false, "no such line"
	case:
		return false, fmt.tprintf("unknown check '%s'", name)
	}
	return found == value, found
}

// The visible part of a widget's rectangle from the last frame (clipped by its scroll container
// and the window), looked up without touching its state
@(private="file")
widgetRect :: proc(ctx: ^skald.Ctx(Msg), key: string) -> (skald.Rect, bool) {
	state, ok := ctx.widgets.states[skald.hash_id(key)]
	if !ok do return {}, false
	rect := state.last_rect
	if state.clip_rect.w > 0 do rect = intersect(rect, state.clip_rect)
	if ctx.renderer != nil {
		rect = intersect(rect, {0, 0, f32(ctx.renderer.fb_size.x), f32(ctx.renderer.fb_size.y)})
	}
	if rect.w <= 0 || rect.h <= 0 do return {}, false
	return rect, true
}

// Whether a widget is wholly inside a scroll area, a margin from its top and bottom (when the area
// has room; at the top of the content, nothing can scroll it further down)
@(private="file")
clearOfEdges :: proc(widget, area: skald.Rect, atTop: bool) -> bool {
	margin := min(f32(24), max((area.h - widget.h) * 0.5, 0))
	return (atTop ? widget.y >= area.y : widget.y >= area.y + margin) && widget.y + widget.h <= area.y + area.h - margin
}

@(private="file")
intersect :: proc(a, b: skald.Rect) -> skald.Rect {
	x0, y0 := max(a.x, b.x), max(a.y, b.y)
	x1, y1 := min(a.x + a.w, b.x + b.w), min(a.y + a.h, b.y + b.h)
	return {x0, y0, max(x1 - x0, 0), max(y1 - y0, 0)}
}

// Move there now, press next frame, release the frame after. Like a real mouse, the pointer
// arrives before the button goes down: widgets that act on press (text fields take focus) check
// hover from the previous frame
@(private="file")
click :: proc(position: [2]f32, mods: sdl.Keymod = {}) {
	pushMouse(.MOUSE_MOTION, position)
	// Skald takes modifiers from key events, so hold the modifier key around the click
	if mods != {} do pushKey(.KEY_DOWN, mods)
	queueBatch(mouseEvent(.MOUSE_BUTTON_DOWN, position))
	queueBatch(mouseEvent(.MOUSE_BUTTON_UP, position))
	if mods != {} {
		release: sdl.Event
		release.type = .KEY_UP
		release.key.scancode = .LCTRL in mods ? .LCTRL : .LGUI in mods ? .LGUI : .LSHIFT
		queueBatch(release)
	}
	driver.waitFrames = INPUT_SETTLE_FRAMES
}

// A modifier key press (Ctrl or Shift) carrying `mods`
@(private="file")
pushKey :: proc(type: sdl.EventType, mods: sdl.Keymod) {
	event: sdl.Event
	event.type = type
	event.key.scancode = .LCTRL in mods ? .LCTRL : .LGUI in mods ? .LGUI : .LALT in mods ? .LALT : .LSHIFT
	event.key.key = sdl.GetKeyFromScancode(event.key.scancode, {}, false)
	event.key.mod = mods
	event.key.down = type == .KEY_DOWN
	_ = sdl.PushEvent(&event)
}

// The optional "ctrl" or "shift" argument of a click command
@(private="file")
clickModifiers :: proc(args: []string, index: int) -> (sdl.Keymod, bool) {
	if index >= len(args) do return {}, true
	switch strings.to_lower(args[index], context.temp_allocator) {
	case "ctrl": return PRIMARY_KEYMOD, true
	case "shift": return {.LSHIFT}, true
	case "alt": return {.LALT}, true
	}
	return {}, false
}

@(private="file")
pushMouse :: proc(type: sdl.EventType, position: [2]f32) {
	event := mouseEvent(type, position)
	_ = sdl.PushEvent(&event)
}

@(private="file")
mouseEvent :: proc(type: sdl.EventType, position: [2]f32, button := sdl.BUTTON_LEFT) -> sdl.Event {
	event: sdl.Event
	event.type = type
	if type == .MOUSE_MOTION {
		event.motion.x, event.motion.y = position.x, position.y
	} else {
		event.button.button = u8(button)
		event.button.down = type == .MOUSE_BUTTON_DOWN
		event.button.clicks = 1
		event.button.x, event.button.y = position.x, position.y
	}
	return event
}

// What a script's "ctrl" holds: the platform's command key (Cmd on macOS, as the keymap's Ctrl
// is there: keymap.odin), so scripts run the same everywhere; "control" is the Control key itself
PRIMARY_KEYMOD :: sdl.Keymod{.LGUI} when ODIN_OS == .Darwin else sdl.Keymod{.LCTRL}

// "ctrl+shift+s" -> key down now, key up next frame
@(private="file")
pressKey :: proc(combo: string) -> bool {
	parts := strings.split(combo, "+", context.temp_allocator)
	mods: sdl.Keymod
	for part in parts[:len(parts) - 1] {
		switch strings.to_lower(part, context.temp_allocator) {
		case "ctrl":  mods += PRIMARY_KEYMOD
		case "control": mods += {.LCTRL}
		case "shift": mods += {.LSHIFT}
		case "alt":   mods += {.LALT}
		case "super": mods += {.LGUI}
		case:         return false
		}
	}
	name := strings.to_upper(parts[len(parts) - 1], context.temp_allocator)
	// SDL's digit scancodes are named _0.._9 in Odin
	if len(name) == 1 && name[0] >= '0' && name[0] <= '9' do name = strings.concatenate({"_", name}, context.temp_allocator)
	scancode, ok := reflect.enum_from_name(sdl.Scancode, name)
	if !ok do return false

	event: sdl.Event
	event.type = .KEY_DOWN
	event.key.scancode = scancode
	// The key code too, as real key events have (the code editor reads those, Skald scancodes)
	event.key.key = sdl.GetKeyFromScancode(scancode, mods, true)
	event.key.mod = mods
	event.key.down = true
	_ = sdl.PushEvent(&event)
	event.type = .KEY_UP
	event.key.down = false
	// Skald takes the modifiers from each key event, so release them too, as letting go of the
	// keys would. Otherwise Ctrl stays held and text inputs ignore later typing.
	event.key.mod = {}
	queueBatch(event)
	driver.waitFrames = INPUT_SETTLE_FRAMES
	return true
}

@(private="file")
atoi :: proc(args: []string, index: int, default: int) -> int {
	if index >= len(args) do return default
	value, ok := strconv.parse_int(args[index])
	return ok ? value : default
}

@(private="file")
report :: proc(passed: bool, text: string) {
	fmt.printfln("[script] %s:%d %s %s", driver.path, driver.line, passed ? "ok  " : "FAIL", text)
}

@(private="file")
fail :: proc(text: string) {
	driver.failures += 1
	report(false, text)
	log.errorf("[script] %s", text)
}

@(private="file")
finish :: proc(ctx: ^skald.Ctx(Msg)) {
	if driver.finished do return
	driver.finished = true
	driver.active = false
	restoreClipboard()
	fmt.printfln("[script] %s: %s (%d failed)", driver.path, driver.failures == 0 ? "PASSED" : "FAILED", driver.failures)
	// Not Action.Quit: that would ask about unsaved changes
	skald.send(ctx, Msg(Quit_Without_Asking{}))
}

// Queues events to push together on a later frame (one frame per queued batch)
@(private="file")
queueBatch :: proc(events: ..sdl.Event) {
	batch := make([dynamic]sdl.Event)
	append(&batch, ..events)
	append(&driver.pending, batch)
}

// Center of the viewport's view area, from last frame's layout
@(private="file")
viewportCenter :: proc(ctx: ^skald.Ctx(Msg)) -> ([2]f32, bool) {
	rect, ok := widgetRect(ctx, "viewport-canvas")
	if !ok do return {}, false
	return {rect.x + RULER_SIZE + (rect.w - RULER_SIZE) * 0.5, rect.y + RULER_SIZE + (rect.h - RULER_SIZE) * 0.5}, true
}

/*
An item of a context menu by its label ("Transform/Reset Scale" through a submenu); a label that
starts an item's label finds it too ("Open Script" for "Open Script (Mover)"), an exact one first.

Returns:
- The submenu's row (-1: none), the item's index in its list, and whether it was found
*/
@(private="file")
contextItemFind :: proc(items: []skald.Menu_Item(Msg), label: string) -> (parent, index: int, ok: bool) {
	find :: proc(items: []skald.Menu_Item(Msg), label: string) -> int {
		for item, i in items do if !item.separator && item.label == label do return i
		for item, i in items do if !item.separator && strings.has_prefix(item.label, label) do return i
		return -1
	}
	head, _, rest := strings.partition(label, "/")
	if rest == "" {
		i := find(items, label)
		return -1, i, i >= 0
	}
	p := find(items, head)
	if p < 0 || len(items[p].submenu) == 0 do return -1, -1, false
	i := find(items[p].submenu, rest)
	return p, i, i >= 0
}

// "Cut, Copy, Transform/..." for failure messages
@(private="file")
contextItemLabels :: proc(items: []skald.Menu_Item(Msg)) -> string {
	labels := make([dynamic]string, context.temp_allocator)
	for item in items do if !item.separator do append(&labels, len(item.submenu) > 0 ? fmt.tprintf("%s/...", item.label) : item.label)
	return strings.join(labels[:], ", ", context.temp_allocator)
}

// Whether a height in a tree is inside the part of the tree's scroll area that's on screen. Rows
// past the end of the tree count, as long as they're inside that area (dropping below the rows)
@(private="file")
rowVisible :: proc(ctx: ^skald.Ctx(Msg), treeKey: string, y: f32) -> bool {
	state := ctx.widgets.states[skald.hash_id(treeKey)]
	area := state.clip_rect.w > 0 ? state.clip_rect : state.last_rect
	return y >= area.y && y < area.y + area.h
}
