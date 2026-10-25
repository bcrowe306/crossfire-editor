package crossfire_editor

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "gui:skald"
import e "engine:."
import sdl "vendor:sdl3"

/*
Animation assets in the editor (the engine's animation_sets.odin plays them): named animations, each
on its own sheet, that AnimatedSprite nodes share (`NodeDef.animationSet`, the scene file's
`animations`).

- **Kinds:** an `.anim.xml` file is an asset of kind Animation (`AnimationSetDef`, in
  `Project.animationSets`, loaded with the project, written by Save when changed: like data
  resources), edited in the Animation panel; an **Aseprite file** (an Image asset) is one too, read
  only: its tags are the animations (`AsepriteEdit_AnimationSet`), edited in Aseprite.
- **Undo:** edits to a set are `.Project` steps (the snapshot holds every set, by file); making or
  removing one touches files and isn't undone, like data resources, except the sprite sheet
  slicer's (`stepMade`: in memory until Save, so undo takes it out of the project again).
- **The Animation panel** edits an `AnimSource`: the selected AnimatedSprite's own animations, the
  set it uses, or the set chosen in the browser (`AnimEditor.asset`).
*/

// The folder new animation assets go in
ANIMATION_FOLDER :: "animations"
// Their files' extension
ANIMATION_EXTENSION :: ".anim.xml"

// An animation asset (an `.anim.xml` file): its animations, each on its own sheet
AnimationSetDef :: struct {
	// The file, relative to the project folder (owned)
	path: string,
	// The animation it starts with ("": the first; owned)
	autoplay: string,
	// Its animations (owned)
	animations: [dynamic]AnimationDef,
	// Made by an undoable step (the sprite sheet slicer's Create animation asset): undo and redo
	// take it out of the project and back (history.odin); not saved
	stepMade: bool,
}

// A copy of an animation (owning its strings and lists)
AnimationDef_Clone :: proc(a: AnimationDef) -> AnimationDef {
	copy := a
	copy.name = strings.clone(a.name)
	copy.sheet = strings.clone(a.sheet)
	copy.rects = make([dynamic]sdl.FRect, 0, len(a.rects))
	append(&copy.rects, ..a.rects[:])
	copy.durations = make([dynamic]f32, 0, len(a.durations))
	append(&copy.durations, ..a.durations[:])
	copy.events = make([dynamic]string, 0, len(a.events))
	for event in a.events do append(&copy.events, strings.clone(event))
	return copy
}

// Frees an animation's strings and lists
AnimationDef_Destroy :: proc(a: ^AnimationDef) {
	delete(a.name)
	delete(a.sheet)
	delete(a.rects)
	delete(a.durations)
	for event in a.events do delete(event)
	delete(a.events)
}

// Whether two animations are the same
AnimationDef_Equal :: proc(a, b: AnimationDef) -> bool {
	if a.name != b.name || a.sheet != b.sheet || a.grid != b.grid || a.start != b.start || a.end != b.end || a.fps != b.fps || a.loop != b.loop || a.playMode != b.playMode || a.repeat != b.repeat || len(a.durations) != len(b.durations) || len(a.rects) != len(b.rects) do return false
	for d, i in a.durations do if d != b.durations[i] do return false
	for r, i in a.rects do if r != b.rects[i] do return false
	if len(a.events) != len(b.events) do return false
	for event, i in a.events do if event != b.events[i] do return false
	return true
}

// An engine animation as the editor's (owned)
AnimationDef_FromData :: proc(a: e.AnimationData) -> AnimationDef {
	def := AnimationDef{name = strings.clone(a.name), sheet = strings.clone(a.sheet), grid = a.grid, start = a.start, end = a.end, fps = a.fps, loop = a.loop, playMode = a.playMode, repeat = a.repeat}
	def.rects = make([dynamic]sdl.FRect, 0, len(a.rects))
	append(&def.rects, ..a.rects[:])
	def.durations = make([dynamic]f32, 0, len(a.durations))
	append(&def.durations, ..a.durations[:])
	def.events = make([dynamic]string, 0, len(a.events))
	for event in a.events do append(&def.events, strings.clone(event))
	return def
}

// The editor's animation as the engine's (its name, sheet and lists borrowed)
AnimationDef_ToData :: proc(a: AnimationDef) -> e.AnimationData {
	return {name = a.name, sheet = a.sheet, grid = a.grid, rects = a.rects, start = a.start, end = a.end, fps = a.fps, loop = a.loop, playMode = a.playMode, durations = a.durations, repeat = a.repeat, events = a.events}
}

// A copy of a set (owning everything)
AnimationSetDef_Clone :: proc(set: AnimationSetDef) -> AnimationSetDef {
	copy := set
	copy.path = strings.clone(set.path)
	copy.autoplay = strings.clone(set.autoplay)
	copy.animations = make([dynamic]AnimationDef, 0, len(set.animations))
	for a in set.animations do append(&copy.animations, AnimationDef_Clone(a))
	return copy
}

// Frees a set's strings and lists
AnimationSetDef_Destroy :: proc(set: ^AnimationSetDef) {
	delete(set.path)
	delete(set.autoplay)
	for &a in set.animations do AnimationDef_Destroy(&a)
	delete(set.animations)
	set^ = {}
}

// Whether two sets are the same
AnimationSetDef_Equal :: proc(a, b: AnimationSetDef) -> bool {
	if a.path != b.path do return false
	if a.autoplay != b.autoplay || len(a.animations) != len(b.animations) do return false
	for x, i in a.animations do if !AnimationDef_Equal(x, b.animations[i]) do return false
	return true
}

// An engine set as the editor's (owned)
AnimationSetDef_FromData :: proc(path: string, set: e.AnimationSetData) -> AnimationSetDef {
	def := AnimationSetDef{path = strings.clone(path), autoplay = strings.clone(set.autoplay)}
	def.animations = make([dynamic]AnimationDef, 0, len(set.animations))
	for a in set.animations do append(&def.animations, AnimationDef_FromData(a))
	return def
}

// The editor's set as the engine's (strings borrowed; the list temp allocated)
AnimationSetDef_ToData :: proc(set: ^AnimationSetDef) -> e.AnimationSetData {
	data := e.AnimationSetData{autoplay = set.autoplay}
	data.animations = make([dynamic]e.AnimationData, 0, len(set.animations), context.temp_allocator)
	for a in set.animations do append(&data.animations, AnimationDef_ToData(a))
	return data
}

// Reads an `.anim.xml` file (owned), or an empty set and why
Project_LoadAnimationSet :: proc(rootPath, path: string) -> (AnimationSetDef, string) {
	text, err := os.read_entire_file(joinPath(rootPath, path, allocator = context.temp_allocator), context.temp_allocator)
	if err != nil do return {path = strings.clone(path)}, fmt.tprintf("Couldn't read %s", path)
	parsed, parseErr := e.ParseAnimationSet(string(text), context.temp_allocator)
	if parseErr != .None do return {path = strings.clone(path)}, fmt.tprintf("%s isn't an animation file (%v)", path, parseErr)
	return AnimationSetDef_FromData(path, parsed), ""
}

// The project's set for a file (-1 if none)
Project_FindAnimationSet :: proc(project: ^Project, path: string) -> int {
	for set, i in project.animationSets do if set.path == path do return i
	return -1
}

// Writes every animation set's file (Project_Save); only changed files are touched
Project_SaveAnimationSets :: proc(project: ^Project) -> string {
	for &set in project.animationSets {
		text := AnimationSetToXML(&set, context.temp_allocator)
		full := joinPath(project.rootPath, set.path, allocator = context.temp_allocator)
		existing, readErr := os.read_entire_file(full, context.temp_allocator)
		if readErr == nil && string(existing) == text do continue
		_ = os.make_directory_all(filepath.dir(full))
		if err := os.write_entire_file(full, text); err != nil do return fmt.tprintf("Couldn't write %s: %v", set.path, err)
	}
	return ""
}

/*
Makes a new animation asset, `animations/<name>.anim.xml` (numbered when taken), from animations
(copied, their sheets too), and writes its file.

Inputs:
- project: The project
- name: Its name (the file's)
- from: What it starts with (its path is ignored)
- write: Write its file now (false: Save writes it, as it writes edited sets)

Returns:
- Its index in `project.animationSets`, or -1 and why
*/
Project_CreateAnimationSet :: proc(project: ^Project, name: string, from: AnimationSetDef, write := true) -> (int, string) {
	base := strings.to_lower(sanitize(strings.trim_space(name)), context.temp_allocator)
	if base == "" do base = "animations"
	taken :: proc(project: ^Project, path: string) -> bool {
		for asset in project.assets do if strings.equal_fold(asset.path, path) do return true
		return os.exists(joinPath(project.rootPath, path, allocator = context.temp_allocator))
	}
	path := fmt.tprintf("%s/%s%s", ANIMATION_FOLDER, base, ANIMATION_EXTENSION)
	for n := 2; taken(project, path); n += 1 do path = fmt.tprintf("%s/%s_%d%s", ANIMATION_FOLDER, base, n, ANIMATION_EXTENSION)
	set := AnimationSetDef_Clone(from)
	delete(set.path)
	set.path = strings.clone(path)
	if len(set.animations) == 0 do append(&set.animations, AnimationDef_Default())
	if write {
		full := joinPath(project.rootPath, path, allocator = context.temp_allocator)
		_ = os.make_directory_all(filepath.dir(full))
		if err := os.write_entire_file(full, AnimationSetToXML(&set, context.temp_allocator)); err != nil {
			AnimationSetDef_Destroy(&set)
			return -1, fmt.tprintf("Couldn't write %s: %v", path, err)
		}
	}
	append(&project.assets, AssetDef{path = strings.clone(path), kind = .Animation})
	append(&project.animationSets, set)
	return len(project.animationSets) - 1, ""
}

// A node's own animations as a set (borrowed: for Project_CreateAnimationSet to copy)
AnimationSet_OfNode :: proc(node: ^NodeDef) -> AnimationSetDef {
	return {autoplay = node.autoplay, animations = node.animations}
}

/*
An Aseprite file's animations, as a set (read only: its tags are edited in Aseprite). Temp
allocated; nil when the file can't be read.
*/
AsepriteEdit_AnimationSet :: proc(root, path: string) -> ^AnimationSetDef {
	ase := AsepriteEdit_File(root, path)
	if ase == nil do return nil
	data := e.AnimationSet_FromAseprite(ase, path, context.temp_allocator)
	context.allocator = context.temp_allocator
	return new_clone(AnimationSetDef_FromData(path, data))
}

// Whether an asset can be an AnimatedSprite's animations: an animation file, or an Aseprite file
Asset_IsAnimations :: proc(asset: AssetDef) -> bool {
	return asset.kind == .Animation || (asset.kind == .Image && e.Aseprite_IsFile(asset.path))
}

// What the Animation panel edits
AnimSourceKind :: enum {
	None,
	// The selected AnimatedSprite's own animations
	Node,
	// An animation asset (an `.anim.xml` file)
	Set,
	// An Aseprite file's tags (read only)
	Aseprite,
}

/*
What the Animation panel shows and edits: pointers to animations (each with its own sheet) and the
one played first, wherever they live (valid for the frame).
*/
AnimSource :: struct {
	kind: AnimSourceKind,
	// The AnimatedSprite selected (nil when the panel shows a set chosen in the browser)
	node: ^NodeDef,
	// The asset (.Set: in Project.animationSets; .Aseprite: temp)
	set: ^AnimationSetDef,
	// The set's index in Project.animationSets (.Set)
	setIndex: int,
	// The asset's path (.Set, .Aseprite)
	path: string,
	autoplay: ^string,
	animations: ^[dynamic]AnimationDef,
	// Aseprite's: shown, not edited
	readOnly: bool,
}

/*
The Animation panel's source: the set chosen in the browser (`AnimEditor.asset`), else the
selected AnimatedSprite's set, else its own animations.
*/
AnimEdit_Source :: proc(s: ^State) -> AnimSource {
	ofSet :: proc(s: ^State, path: string, node: ^NodeDef) -> AnimSource {
		if i := Project_FindAnimationSet(&s.project, path); i >= 0 {
			set := &s.project.animationSets[i]
			return {.Set, node, set, i, path, &set.autoplay, &set.animations, false}
		}
		if e.Aseprite_IsFile(path) {
			if set := AsepriteEdit_AnimationSet(s.project.rootPath, path); set != nil {
				return {.Aseprite, node, set, -1, path, &set.autoplay, &set.animations, true}
			}
		}
		return {kind = .None, node = node, path = path}
	}
	if s.animEditor.asset != "" do return ofSet(s, s.animEditor.asset, nil)
	scene := &s.project.scenes[s.currentScene]
	if s.selectedNode < 0 || s.selectedNode >= len(scene.nodes) do return {}
	node := &scene.nodes[s.selectedNode]
	if node.kind != .AnimatedSprite do return {}
	if node.animationSet != "" do return ofSet(s, node.animationSet, node)
	return {.Node, node, nil, -1, "", &node.autoplay, &node.animations, false}
}

// What a source is called: its node's name, or its file's
AnimSource_Name :: proc(src: AnimSource) -> string {
	if src.kind == .Node && src.node != nil do return src.node.name
	return filepath.base(src.path)
}

// How many AnimatedSprites (in scenes and components) use an animation asset
AnimationSet_UserCount :: proc(project: ^Project, path: string) -> int {
	count := 0
	for scene in project.scenes do for node in scene.nodes do if node.kind == .AnimatedSprite && node.animationSet == path do count += 1
	return count
}

/*
Adds an AnimatedSprite playing an animation asset, named after it, as a child of `parent` (the
selection; -1 for the top level) at a point in the world.

Returns:
- The new node's index
*/
Scene_AddAnimatedSpriteAt :: proc(scene: ^SceneDef, path: string, parent: int, world: [2]f32) -> int {
	parent := parent
	if parent >= len(scene.nodes) do parent = -1
	parent = Scene_ParentFor(scene, parent)
	name := strings.trim_suffix(strings.trim_suffix(filepath.base(path), ANIMATION_EXTENSION), filepath.ext(path))
	index := Scene_InsertNode(scene, Scene_UniqueNodeName(scene, name == "" ? "AnimatedSprite" : name), .AnimatedSprite, parent)
	node := &scene.nodes[index]
	// The asset's animations replace its own
	for &a in node.animations do AnimationDef_Destroy(&a)
	clear(&node.animations)
	delete(node.animationSet)
	node.animationSet = strings.clone(path)
	parentWorld := parent >= 0 ? Scene_WorldTransforms(scene)[parent] : e.TRANSFORM2D_IDENTITY
	local := e.Transform2D_Apply(e.Transform2D_Inverse(parentWorld), world)
	node.position = {f32(int(local.x)), f32(int(local.y))}
	return index
}

/*
The browser's preview of an animation asset: its animations (sheet, frames, speed, looping), how
many sprites use it, and Edit Animations (the Animation panel).
*/
AnimationSet_Preview :: proc(s: ^State, ctx: ^skald.Ctx(Msg), asset: AssetDef) -> skald.View {
	tk := uiTokens(ctx)
	th := ctx.theme
	rows := make([dynamic]skald.View, context.temp_allocator)
	text :: proc(ctx: ^skald.Ctx(Msg), value: string, muted := true) -> skald.View {
		th := ctx.theme
		return skald.text(value, muted ? th.color.fg_muted : th.color.fg, muted ? th.font.size_xs : th.font.size_sm, max_width = previewTextWidth)
	}
	append(&rows, text(ctx, filepath.base(asset.path), false))
	append(&rows, skald.button(ctx, fmt.tprintf("%s  Edit Animations", ICON_FILM), Msg(Anim_Asset_Shown(asset.path)),
		id = skald.hash_id("browser-animations-edit"), bg = th.color.surface, fg = th.color.fg,
		padding = tk.fieldPadding, font_size = th.font.size_xs, radius = th.radius.sm))
	i := Project_FindAnimationSet(&s.project, asset.path)
	if i < 0 {
		append(&rows, uiText(th, .Muted, fmt.tprintf("%s couldn't be read.", asset.path), max_width = previewTextWidth, color = th.color.danger))
	} else {
		set := &s.project.animationSets[i]
		users := AnimationSet_UserCount(&s.project, set.path)
		append(&rows, text(ctx, fmt.tprintf("Used by %d sprite%s", users, users == 1 ? "" : "s")))
		for a in set.animations {
			start, end := AnimationDef_Range(a, AnimEdit_Cells(s.project.rootPath, a))
			speed := len(a.durations) > 0 ? "own durations" : fmt.tprintf("%v fps", a.fps)
			first := set.autoplay == a.name ? "  (first)" : ""
			sheet := a.sheet == "" ? "no sheet yet" : filepath.base(a.sheet)
			append(&rows, text(ctx, fmt.tprintf("•  %s: %s, frames %d-%d, %s%s%s", a.name, sheet, start, end, speed, a.loop ? ", loops" : "", first)))
		}
		append(&rows, text(ctx, "Drag it into the viewport for an AnimatedSprite playing it, or pick it in an AnimatedSprite's Animations."))
	}
	return skald.scroll(ctx, {0, 0}, skald.col(..rows[:], spacing = th.spacing.xs, padding = th.spacing.sm), id = skald.hash_id("browser-animations-preview"))
}
