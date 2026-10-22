package crossfire_editor

import "core:fmt"
import "gui:skald"

/*
Tooltips for the inspector's, Settings' and Project Settings' rows: hovering a row's label
explains the setting (what it does, its units and range). `inspectorRow` and `settingRow` look
the label up in `fieldTip`, so a row gets its tooltip by having a label listed here; a label
used in several places has one explanation that fits them all. Toolbar and panel buttons have
their own (`toolButton`, `panelButton`, with the shortcut).
*/

// The explanation shown for a row label, "" for none
fieldTip :: proc(label: string) -> string {
	switch label {
	// Every node
	case "Type":           return "The node's kind (Add Node lists them all)."
	case "Name":           return "The node's name: scripts find it with e.Scene_FindNode, joints name their bodies with it."
	case "Position":       return "Where the node is, in pixels, relative to its parent."
	case "Position X":     return "Horizontal position in pixels, relative to the parent (right is positive)."
	case "Position Y":     return "Vertical position in pixels, relative to the parent (down is positive)."
	case "Rotation":       return "Rotation in degrees, clockwise, relative to the parent."
	case "Scale X":        return "Horizontal scale (1 = normal size; negative mirrors)."
	case "Scale Y":        return "Vertical scale (1 = normal size; negative flips)."
	case "Layer":          return "The render layer: layers draw in order, Layer1 first (at the back)."
	case "Visible":        return "Hidden nodes and everything under them aren't drawn (they still update)."
	case "Z index":        return "Draw order within the layer: higher draws on top. Nodes with the same z keep the tree's order."
	case "Y sort":         return "Draws this node's children by their y position, lower ones in front (top-down games)."
	case "Blend":          return "How the node's pixels mix with what's behind: normal blending, additive (glows), multiply, modulate or none."
	case "Process":        return "When the node updates: Inherit (its parent's), Pausable (stops while the scene is paused), When paused (pause menus), Always, or Disabled."
	case "Groups":         return "Group names, comma-separated: scripts get every node of a group with e.Scene_GetGroup."
	// Drawing
	case "Texture":        return "The image the node draws (an asset of kind Image)."
	case "Sheet":          return "The sprite sheet the animations' frames come from."
	case "Animations":     return "Its own animations, or an animation asset's (an .anim.xml file, or an Aseprite file's tags) that other sprites can share."
	case "Columns":        return "How many frames across the sprite sheet."
	case "Rows":           return "How many frames down the sprite sheet."
	case "Margin":         return "Pixels around the sheet's edge before the first frame."
	case "Spacing":        return "Pixels between frames (or between items, for menus)."
	case "Centered":       return "Draws the image centered on the node's position (otherwise its top-left corner is there)."
	case "Expand":         return "In its parent's row or column: takes the room the others leave (shared with other expanding controls)."
	case "Anchor":         return "Where it sits in its parent (the screen for a top-level control): a corner, an edge's middle, the middle, or stretched across. Its position moves it from there."
	case "Edge margin":    return "Stretched anchors (Full, Top_Wide...): the space left between it and its parent's edges."
	case "Layout":         return "How it places the controls in it: None (each by its anchor), Row, Column or Grid."
	case "Grid columns":   return "Cells in each row of a Grid layout."
	case "Align":          return "Where its controls go across the layout: Start, Center, End, or Stretch (as wide or tall as it)."
	case "Justify":        return "Where its controls go along a row or column when they don't fill it."
	case "Padding":        return "Space between its edges and what's in it, in pixels (-1: the theme's)."
	case "Gap":            return "Space between the controls in it, in pixels (-1: the theme's)."
	case "Action":         return "What pressing it does: go to a scene, quit, or nothing (scripts listen to its onPressed event either way)."
	case "Can't be used":  return "Grayed out: it can't be pressed, typed in or focused."
	case "Text align":     return "Where its text goes: Auto (centered on buttons), Left, Center or Right."
	case "Value":          return "The bar's value, between Min and Max (scripts: e.ProgressBar_SetValue)."
	case "Min":            return "The value of an empty bar."
	case "Max":            return "The value of a full bar."
	case "Fills toward":   return "Which way the bar fills as the value grows."
	case "Show percent":   return "Writes how full it is on the bar (60%)."
	case "Placeholder":    return "Shown in the field, dimmed, while it's empty."
	case "Max length":     return "The most characters it takes (0: any)."
	case "Image":          return "An image drawn instead of the theme's fill (a progress bar's fill), stretched to the control."
	case "Edges L / T":    return "Pixels at the image's left and top that don't stretch: its frame stays sharp (a 9-patch)."
	case "Edges R / B":    return "Pixels at the image's right and bottom that don't stretch."
	case "UI theme":       return "How it and the controls in it look (a .theme.xml asset). Its parent's, or the project's, when none."
	case "Font":           return "The theme's font (a font asset), or the built-in one."
	case "Follows camera X": return "How much the layer moves with the camera sideways: 1 like the world, 0.5 half as fast (far away), 0 not at all."
	case "Follows camera Y": return "How much the layer moves with the camera up and down."
	case "Repeat across":  return "Its image tiles across the screen sideways (a horizon that never ends)."
	case "Repeat down":    return "Its image tiles up and down."
	case "Room width":     return "The room's width in pixels, from the node's position (its left edge)."
	case "Room height":    return "The room's height in pixels, from the node's position (its top edge)."
	case "Slide time":     return "Seconds the view takes to slide into this room from another."
	case "View width":     return "The view's width on the screen, in pixels."
	case "View height":    return "The view's height on the screen, in pixels."
	case "Shows camera":   return "The Camera node whose view it shows."
	case "View zoom":      return "Zoom on top of its camera's: 0.25 shows four times as much (a minimap)."
	case "Border":         return "The width of the frame around it, in pixels (0: none)."
	case "Starts in":      return "The state the StateMachine starts in when the scene starts."
	case "Animates":       return "The AnimatedSprite whose animations its states play (its parent by default)."
	case "Scene change":   return "How the screen changes between scenes: at once (None), a fade, a wipe from a side, or a closing circle."
	case "Change time":    return "Seconds the change takes: covering, then uncovering."
	case "Change color":   return "The color the screen is covered with during the change."
	case "Loading scene":  return "A scene shown while other scenes load (they're built when entered, not all at the start)."
	case "Shows loading":  return "In a loading scene: the bar shows how far the loading has got, instead of its value."
	case "Area width":     return "How wide the walkable area is, in pixels, from the node's position (its left edge)."
	case "Area height":    return "How tall the walkable area is, in pixels, from the node's position (its top edge)."
	case "Cell size":      return "The grid's cell size in pixels: smaller finds narrower gaps but takes longer."
	case "Agent radius":   return "Half the characters' width: walls are grown by it, so paths keep them clear of walls."
	case "Diagonal moves": return "Paths may go diagonally (never across a blocked corner)."
	case "Walk speed":     return "How fast it moves along its path, in pixels per second."
	case "Arrive within":  return "How close to its target counts as arrived, in pixels."
	case "Keep apart":     return "Other agents closer than this push it away, in pixels (0: it doesn't avoid them)."
	case "Move parent":    return "It moves its parent along its path itself; off, scripts read its velocity and move it."
	case "Light kind":     return "Point: shines all around. Spot: a cone the way the node faces."
	case "Light color":    return "The light's color at its center."
	case "Energy":         return "How bright: its color times this (2: twice as bright, up to white)."
	case "Reach":          return "How far the light goes, in pixels: it fades to nothing there."
	case "Cone":           return "A spot light's width, in degrees."
	case "Shadows":        return "The light stops at LightOccluder nodes (and static bodies, when the scene says so)."
	case "First clip":     return "The clip the Animator plays when the scene starts (None: it waits for a script's e.Animator_Play)."
	case "Clip speed":     return "How fast its clips play: 2 is twice as fast, 0 holds them."
	case "Starts with":    return "The animation the sprite plays when the scene starts."
	case "Text":           return "The text shown. Text starting with @ is a translation key (@menu.play), shown in the game's language."
	case "Font size":      return "Text size in pixels."
	case "Color":          return "The color it's drawn with."
	case "Alpha":          return "Opacity, 0 (invisible) to 255 (opaque)."
	case "Background":     return "The color behind everything (the window is cleared to it)."
	case "Zoom":           return "The camera's zoom: 2 shows things twice as big."
	case "Component":      return "The component this node is an instance of. Its name, position, rotation, scale, layer and visibility are the instance's own."
	// Physics
	case "Kind":           return "What sort of thing it is (a shape's form, a joint's type...)."
	case "Shape":          return "The collision shape's form: rectangle, circle, capsule, polygon or segment."
	case "Width":          return "Width in pixels."
	case "Height":         return "Height in pixels."
	case "Radius":         return "Radius in pixels."
	case "Points":         return "The shape's points as x,y pairs in the node's space, separated by spaces."
	case "Disabled":       return "Leaves the shape out of its body (it collides with nothing)."
	case "One way":        return "A one-way platform: only its top stops what comes down on it; bodies pass through from below and the sides."
	case "Layers":         return "The collision layers (1-16) this body is on."
	case "Collides":       return "The collision layers this body collides with."
	case "Hits":           return "The collision layers the ray hits."
	case "Friction":       return "How much it grips what it slides on: 0 is ice, 0.6 is typical."
	case "Bounce":         return "Restitution: 0 doesn't bounce, 1 bounces back as fast as it came."
	case "Density":        return "Mass per area: heavier bodies push lighter ones."
	case "Gravity":        return "Gravity in pixels per second² (y down: 980 is Earth's at 100 px per meter)."
	case "Damping":        return "Slows its movement over time (air resistance): 0 is none."
	case "Spin damp":      return "Slows its spin over time: 0 is none."
	case "No rotation":    return "The body never turns (characters, crates that should stay upright)."
	case "Bullet":         return "Continuous collision for fast bodies, so they don't pass through thin walls."
	case "Floor angle":    return "The steepest slope, in degrees, that counts as floor for the mover."
	case "Target X":       return "Where the ray ends, x, relative to the node."
	case "Target Y":       return "Where the ray ends, y, relative to the node."
	case "Enabled":        return "Whether it's active."
	case "Skip own body":  return "The ray ignores the body it's under."
	case "Body A":         return "The first body the joint connects: the one it's under, or the world."
	case "Body B":         return "The other body the joint connects, by name."
	case "Offset X":       return "Body B's anchor, x, relative to the joint (Distance joints)."
	case "Offset Y":       return "Body B's anchor, y, relative to the joint (Distance joints)."
	case "Limit":          return "Limits how far the joint turns or slides."
	case "Strength":       return "The motor's maximum torque (turning joints) or force (sliding ones)."
	case "Motor":          return "Drives the joint at a speed, with a maximum force or torque."
	case "Spring":         return "Makes the joint springy instead of rigid."
	case "Stiffness Hz":   return "The spring's stiffness: oscillations per second."
	case "Bodies collide": return "Whether the two connected bodies collide with each other."
	// Sound
	case "Sound":          return "The sound it plays (loaded whole)."
	case "Music":          return "The music it plays (streamed from the file)."
	case "Bus":            return "The mix bus it plays through (the Mixer tab): its volume and mute apply."
	case "Volume":         return "Loudness, 0 (silent) to 2 (twice as loud); 1 is the file as it is."
	case "Pitch":          return "Playback speed and pitch together: 2 is an octave up."
	case "Speed":          return "Playback speed: 2 is twice as fast (and an octave up)."
	case "Pan":            return "Left (-1) to right (1); 0 is the middle."
	case "Loop":           return "Starts again when it ends."
	case "Autostart":      return "Plays as soon as the scene starts."
	case "Range":          return "How far away, in pixels, it can be heard (2D sound)."
	case "Falloff":        return "How the volume drops with distance."
	case "Fade in (s)":    return "Seconds the music takes to fade in when it starts."
	case "Fade out (s)":   return "Seconds the music takes to fade out when it stops."
	case "Ramp":           return "Colors over the particle's life: click the bar to add a stop, drag stops to move them."
	// LDtk
	case "LDtk file":      return "The LDtk project (.ldtk) the level comes from."
	case "Level":          return "Which level of the LDtk project to show."
	case "Whole world":    return "Shows every level of the world, laid out as in LDtk."
	case "Collision":      return "The IntGrid layer whose cells become collision (a static body)."
	case "Becomes":        return "What the entity type's nodes are: Auto (its component if mapped, else code's, else its rectangle), a component, code (e.LDtk_RegisterEntity), its rectangle, or nothing."
	case "Runs":           return "The script its nodes run: Auto (the one named like the entity, unless its component has one), none, or another."
	case "Entities":       return "LDtk entities become nodes: their components, or scripts named like them."
	case "Tilemap file":   return "The Aseprite file whose tilemap layers the node draws."
	case "Frame":          return "The frame of the Aseprite file its tilemaps come from."
	case "Animate":        return "Plays the Aseprite file's frames (or a tag's) at their durations."
	case "Tag":            return "The Aseprite tag whose frames it plays."
	case "Pivot slice":    return "An Aseprite slice whose pivot is put on the node's origin, frame by frame."
	case "9-patch":        return "An Aseprite 9-patch slice drawn stretched: the corners keep their size."
	case "9-patch size":   return "The 9-patch's width and height in pixels (0: the slice's own)."
	case "Slice":          return "An Aseprite slice of its sprite whose rectangle it takes, frame by frame (a hitbox)."
	case "Tile collision": return "Tiles with a collision property in Aseprite (solid, one-way, area) become physics bodies."
	case "Smooth tiles":   return "Linear filtering for the tiles (off: crisp pixel art)."
	// Settings
	case "Theme":          return "Dark or light editor colors."
	case "Text size":      return "The editor's text size."
	case "Row height":     return "Height of the browser's and scene tree's rows, in pixels."
	case "Merge edits within": return "Edits to the same field closer together than this become one undo step."
	case "Longest merged edit": return "A run of merged edits is cut into a new undo step after this long (0: never)."
	case "Undo steps kept": return "How many undo steps are kept."
	case "Grid width":     return "The width of a viewport grid cell, in world units (snapping uses it)."
	case "Grid height":    return "The height of a viewport grid cell, in world units (snapping uses it)."
	case "Major lines every": return "A more opaque grid line every this many cells, dividing the grid into blocks. 0: none."
	case "Line opacity":   return "How opaque the grid's lines are, in percent."
	case "Major line opacity": return "How opaque the grid's major lines are, in percent."
	case "Code editor":    return "Open scripts in the built-in code editor, or in the external program below."
	case "External program": return "The program that opens scripts when the built-in editor is off: a path, or a name found in PATH."
	case "Arguments":      return "The external program's arguments: {file} and {line} are replaced, {folder} is the scripts folder."
	case "Language server": return "OLS, the Odin language server, for completion and errors in the built-in editor (empty: found automatically)."
	case "Odin program":   return "The Odin compiler games with scripts are built with (empty: found automatically)."
	case "LDtk program":   return "The LDtk level editor, for Open in LDtk."
	case "Aseprite program": return "The Aseprite pixel art editor, for Open in Aseprite."
	case "Optimized Play": return "Builds games for Play with -o:speed: faster games, slower builds."
	case "Wheel pans":     return "The mouse wheel pans the viewport and Ctrl + wheel zooms (for touchpads)."
	// Project Settings
	case "Resolution":     return "The game's size in pixels: all drawing and positions use it, scaled to the window."
	case "Scaling":        return "How the game's resolution fits the window: letterboxed, stretched, whole multiples, cropped, or not at all."
	case "Renderer":       return "What the game draws with (Auto: the system's choice)."
	case "Window":         return "How the game's window starts."
	case "Sound output":   return "The sample rate and channels the game asks its sound device for (stereo at 48 kHz works everywhere)."
	case "Audio device":   return "Where Play's game and the editor's previews play their sound (System default, or a device of this computer)."
	case "Start scene":    return "The scene the game starts in."
	case "Icon":           return "The game window's icon (the taskbar's): one of the project's images. None: the Crossfire logo."
	case "Language":       return "The language the game starts in, as the translation tables name it (empty: the player's)."
	case "Pixels per meter": return "Physics works in meters: a body of 1 m is this many pixels."
	case "Show shapes":    return "The game draws its collision shapes when you Play (exports never do; F9 toggles them while playing)."
	case "Smooth motion":  return "Draws moving bodies between physics steps, so they glide on fast screens."
	case "Deadzone":       return "How far a stick must move before the action counts (0 to 1)."
	case "Key":            return "Add a key binding to the action."
	case "Mouse":          return "Add a mouse button binding to the action."
	case "Gamepad":        return "Add a gamepad button binding to the action."
	case "Stick, trigger": return "Add a stick direction or trigger binding to the action."
	case "For":            return "Which gamepad the new binding is for (any, or one by number)."
	}
	return ""
}

/*
A row's label with its tooltip (`fieldTip`), or just the label when it has none.

Inputs:
- label: The label's text
- labelView: The label as drawn
- extra: More to say after the general explanation (a range, a default); may be ""
*/
tipLabel :: proc(ctx: ^skald.Ctx(Msg), label: string, labelView: skald.View, extra := "") -> skald.View {
	tip := fieldTip(label)
	if extra != "" do tip = tip == "" ? extra : fmt.tprintf("%s %s", tip, extra)
	if tip == "" do return labelView
	// Rows are built in the same order every frame: a running number keeps each one's id
	rowTipCount += 1
	return skald.tooltip(ctx, labelView, tip, id = skald.hash_id(fmt.tprintf("row-tip-%d", rowTipCount)))
}

// Rows with a tooltip so far this frame (reset by `view`; per thread: unit tests run in parallel)
@(thread_local)
rowTipCount: int

// A script field's tooltip: its type, range and default (from the script's tags)
scriptFieldTip :: proc(field: ^ScriptFieldDesc) -> string {
	tip := fmt.tprintf("A field of the script: %v.", field.type)
	lo, hasMin := field.min.?
	hi, hasMax := field.max.?
	switch {
	case hasMin && hasMax: tip = fmt.tprintf("%s From %v to %v.", tip, lo, hi)
	case hasMin:           tip = fmt.tprintf("%s At least %v.", tip, lo)
	case hasMax:           tip = fmt.tprintf("%s At most %v.", tip, hi)
	}
	if field.defaultValue != "" do tip = fmt.tprintf("%s Default %s.", tip, field.defaultValue)
	return tip
}

// The bottom panel's tab strip
BOTTOM_TABS_TIP :: "Console: the game's log while it plays. Output: builds and exports. Animation: the selected sprite's animations. Mixer: the mix buses. Git: version control. Tiles: paint the selected TileMap. Timeline: the selected Animator's keyframe clips. Live: the game running from Play: pause, step, frame times, its nodes' values. States: the selected StateMachine's graph."
