package crossfire_editor

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:sync"
import "core:time"
import "core:slice"
import "core:strings"
import e "engine:."

/*
The typed constants of the generated `scripts/assets.odin` (`Scripts_AssetsSource`), so scripts
name the project's things through the compiler instead of strings:

	TEXTURE_HERO :: e.TextureAsset{"assets/characters/hero.png"}   assets, by kind (since the start)
	ACTION_JUMP :: "jump"                                           input actions
	ACHIEVEMENT_FIRST_BLOOD :: "first_blood"                        Steam achievements
	ANIM_HERO_RUN :: "run"                                          animations, per set or sprite
	STATE_HERO_BRAIN_IDLE :: "idle"                                 state machines' states
	PARAM_HERO_BRAIN_SPEED :: "speed"                               and parameters
	GROUP_ENEMIES :: "enemies"                                      node groups
	BUS_SFX :: "SFX"                                                mix buses
	SCENE_FOREST_SCENE :: "ForestScene"                             scenes
	DIALOGUE_NODE_STORY_START :: "Start"                            dialogue nodes
	PATH_HUD_BOSS_BAR :: "BossBar"                                  node paths in components
	PATH_FOREST_SCENE_HUD :: "/HUD"                                 and in scenes

**Names:** the new kinds (animations onward) split words the way they're written: `bossBar`,
`BossBar` and `boss_bar` are all `BOSS_BAR`, `HUDBar` is `HUD_BAR` (`ConstantWords`). Assets,
actions and achievements keep `ConstantName` (no split: `ACTION_MOVELEFT`), which their names
have always had, so existing code keeps building.
- **Animations:** `ANIM_<SET>_<NAME>` for each animation asset (`animations/boar.anim.xml`: SET
  is `BOAR`) and each Aseprite image's tags (`hero.aseprite`: `HERO`); an AnimatedSprite with
  animations of its own: `ANIM_<OWNER>_<NODE>_<NAME>`, OWNER the scene or component it's in.
  Sprites playing a set use the set's.
- **State machines:** `STATE_<OWNER>_<MACHINE>_<STATE>`, `PARAM_<OWNER>_<MACHINE>_<PARAM>`.
- **Dialogue nodes:** `DIALOGUE_NODE_<DIALOGUE>_<NODE>` (`DIALOGUE_<NAME>` is the file).
- **Node paths** (`Node_FindPath`): in a component, from its root (`PATH_HERO_SPRITE ::
  "Sprite"`: from the node the component is, which its root's scripts are on); in a scene, from
  the scene's top level with a leading `/` (`PATH_LAIR_SCENE_HUD_BOSS_BAR :: "/HUD/BossBar"`,
  from any node; `Scene_FindNode` takes it too). A Component instance's own nodes are included
  under it. Nodes named the same as a sibling share a path: it's listed once.
- **Order and collisions:** sections in a fixed order, under a comment each, and inside them a
  `// - <owner>` line per set, machine, scene or component. Owners, groups, scenes and paths are
  sorted by name (not tree order: moving a node among its siblings changes nothing), a set's
  animations and a machine's states and parameters keep their own order, so saving never
  reorders the file. Two things that make the same name: the first in that order keeps it, the
  next gets `_2`, `_3`... Assets come first, so their names never change.
*/

// What a generated constant names (its section of the file)
ConstantSection :: enum {
	Assets,
	Actions,
	Achievements,
	Animations,
	States,
	Groups,
	Buses,
	Scenes,
	Dialogue_Nodes,
	Node_Paths,
}

// The comment above each new section in the file (assets, actions and achievements have none)
@(private="file")
SECTION_HEADERS := [ConstantSection]string{
	.Assets         = "",
	.Actions        = "",
	.Achievements   = "",
	.Animations     = "// Animations, per animation set and per AnimatedSprite with its own: e.AnimationPlayer_Play(&sprite.animation, ANIM_HERO_RUN)",
	.States         = "// State machines' states and parameters: e.StateMachine_SetFloat(brain, PARAM_HERO_BRAIN_SPEED, speed)",
	.Groups         = "// Node groups: e.Scene_GetGroup(scene, GROUP_ENEMIES)",
	.Buses          = "// Mix buses: e.Audio_SetBusVolume(BUS_MUSIC, 0.5)",
	.Scenes         = "// Scenes: e.Game_ChangeScene(game, SCENE_FOREST_SCENE)",
	.Dialogue_Nodes = "// Dialogue nodes: e.Dialogue_Start(runner, data, DIALOGUE_NODE_STORY_START)",
	.Node_Paths     = "// Node paths: in a component from its root, in a scene from its top level (\"/\"). e.Node_FindPath(self.node, PATH_HERO_SPRITE)",
}

// One constant of scripts/assets.odin
GeneratedConstant :: struct {
	name: string,
	// The Odin value as written (`"run"`, `e.TextureAsset{"assets/..."}`)
	value: string,
	section: ConstantSection,
	// What it names, in a sentence (completion docs and hovers)
	about: string,
	// The comment after it in the file ("" none)
	comment: string,
	// The asset path, scene, or owner it belongs to (providers' previews)
	target: string,
	// Within its section, what it's listed under (a comment line in the file: "scene
	// ForestScene"; "" none)
	group: string,
}

/*
The part of a constant's name a name gives for the new kinds of constants (animations onward):
upper case, words split where the name splits them (an underscore, a dash, a space, a lower case
letter before an upper case one, an acronym before a word), none at either end.

Example:
	ConstantWords("bossBar")     // "BOSS_BAR"
	ConstantWords("HUDBar 2")    // "HUD_BAR_2"
	ConstantWords("ForestScene") // "FOREST_SCENE"
*/
ConstantWords :: proc(name: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	isUpper :: proc(c: u8) -> bool { return c >= 'A' && c <= 'Z' }
	isLower :: proc(c: u8) -> bool { return c >= 'a' && c <= 'z' }
	isDigit :: proc(c: u8) -> bool { return c >= '0' && c <= '9' }
	gap := false
	for i in 0 ..< len(name) {
		c := name[i]
		if !isUpper(c) && !isLower(c) && !isDigit(c) {
			gap = strings.builder_len(b) > 0
			continue
		}
		if strings.builder_len(b) > 0 && !gap && isUpper(c) && i > 0 {
			prev := name[i - 1]
			next := i + 1 < len(name) ? name[i + 1] : 0
			// fooBar, foo2Bar; HUDBar (the B starts a word)
			if isLower(prev) || isDigit(prev) || isUpper(prev) && isLower(next) do gap = true
		}
		if gap do strings.write_byte(&b, '_')
		gap = false
		strings.write_byte(&b, isLower(c) ? c - 32 : c)
	}
	return strings.builder_len(b) > 0 ? strings.to_string(b) : "UNNAMED"
}

/*
Every constant scripts/assets.odin defines, in the file's order, names made unique (temp
allocated).
*/
Scripts_Constants :: proc(project: ^Project) -> []GeneratedConstant {
	out := make([dynamic]GeneratedConstant, context.temp_allocator)
	used := make(map[string]int, allocator = context.temp_allocator)
	unique :: proc(used: ^map[string]int, name: string) -> string {
		if n := used[name]; n > 0 {
			used[name] = n + 1
			return fmt.tprintf("%s_%d", name, n + 1)
		}
		used[name] = 1
		return name
	}
	add :: proc(out: ^[dynamic]GeneratedConstant, used: ^map[string]int, section: ConstantSection, name, value, about: string, comment := "", target := "", group := "") {
		append(out, GeneratedConstant{unique(used, name), value, section, about, comment, target, group})
	}
	quoted :: proc(text: string) -> string { return fmt.tprintf("%q", text) }

	// Assets, by kind then path
	assets := slice.clone(project.assets[:], context.temp_allocator)
	slice.sort_by(assets, proc(a, b: AssetDef) -> bool { return a.kind != b.kind ? a.kind < b.kind : a.path < b.path })
	for asset in assets {
		prefix, type, what: string
		switch asset.kind {
		case .Image: prefix, type, what = "TEXTURE", "TextureAsset", "Image"
		case .Audio: prefix, type, what = "SOUND", "SoundAsset", "Sound"
		case .Music: prefix, type, what = "MUSIC", "MusicAsset", "Music"
		case .Font:  prefix, type, what = "FONT", "FontAsset", "Font"
		case .Data:  prefix, type, what = "DATA", "DataAsset", "Data resource"
		case .Component: prefix, type, what = "COMPONENT", "ComponentAsset", "Component"
		case .LDtk:  prefix, type, what = "LDTK", "LDtkAsset", "LDtk project"
		case .Animation: prefix, type, what = "ANIMATION", "AnimationAsset", "Animation set"
		// A path for e.Node_SetShader
		case .Shader: prefix, type, what = "SHADER", "", "Shader"
		case .Atlas: prefix, type, what = "ATLAS", "", "Texture atlas"
		case .Dialogue: prefix, type, what = "DIALOGUE", "", "Dialogue"
		// Games load every table themselves; scripts use their keys
		case .Translation, .Theme, .PhysicsMaterial: continue
		}
		stem := asset.kind == .Data ? DataName(asset.path) : asset.kind == .Component ? ComponentName(asset.path) : filepath.stem(filepath.base(asset.path))
		if asset.kind == .Animation do stem = strings.trim_suffix(filepath.base(asset.path), ANIMATION_EXTENSION)
		if asset.kind == .Atlas do stem = strings.trim_suffix(filepath.base(asset.path), e.ATLAS_EXTENSION)
		if asset.kind == .Dialogue do stem = strings.trim_suffix(filepath.base(asset.path), e.DIALOGUE_EXTENSION)
		comment := ""
		if asset.kind == .Data {
			if i := Project_FindData(project, asset.path); i >= 0 do comment = fmt.tprintf("  // %s", project.data[i].type)
		}
		// An Aseprite file is an image and animations (its tags) both
		kinds := [2][3]string{{prefix, type, what}, {}}
		if asset.kind == .Image && e.Aseprite_IsFile(asset.path) do kinds[1] = {"ANIMATION", "AnimationAsset", "Animations (an Aseprite file's tags)"}
		for k in kinds do if k[0] != "" {
			value := k[1] == "" ? quoted(asset.path) : fmt.tprintf("e.%s{{%q}", k[1], asset.path)
			add(&out, &used, .Assets, fmt.tprintf("%s_%s", k[0], ConstantName(stem)), value, fmt.tprintf("%s %s", k[2], asset.path), comment, asset.path)
		}
	}
	// The input actions' names (Project Settings > Input): e.Input_IsActionPressed(ACTION_JUMP)
	for action in project.actions {
		add(&out, &used, .Actions, fmt.tprintf("ACTION_%s", ConstantName(action.name)), quoted(action.name), fmt.tprintf("Input action %q (Project Settings > Input)", action.name))
	}
	// Steam achievements' API names (Project Settings > Steam): e.Steam_UnlockAchievement(ACHIEVEMENT_FIRST_BLOOD)
	for a in project.achievements {
		if a.name == "" do continue
		add(&out, &used, .Achievements, fmt.tprintf("ACHIEVEMENT_%s", ConstantName(a.name)), quoted(a.name), fmt.tprintf("Steam achievement %q", a.name))
	}

	// Scenes and components, sorted by their names (owners of animations, machines, paths)
	Owner :: struct { scene: ^SceneDef, name, label: string }
	owners := make([dynamic]Owner, context.temp_allocator)
	for &scene in project.scenes {
		if Scene_IsComponent(&scene) {
			append(&owners, Owner{&scene, ComponentName(scene.component), fmt.tprintf("component %s", ComponentName(scene.component))})
		} else {
			append(&owners, Owner{&scene, scene.name, fmt.tprintf("scene %s", scene.name)})
		}
	}
	slice.sort_by(owners[:], proc(a, b: Owner) -> bool {
		ac, bc := Scene_IsComponent(a.scene), Scene_IsComponent(b.scene)
		return ac != bc ? !ac : a.name < b.name
	})

	// Animations: sets (animation assets), Aseprite files' tags, then sprites' own
	Set :: struct { name, path: string, animations: []string }
	sets := make([dynamic]Set, context.temp_allocator)
	for &set in project.animationSets {
		names := make([dynamic]string, context.temp_allocator)
		for a in set.animations do append(&names, a.name)
		append(&sets, Set{strings.trim_suffix(filepath.base(set.path), ANIMATION_EXTENSION), set.path, names[:]})
	}
	for asset in assets {
		if asset.kind != .Image || !e.Aseprite_IsFile(asset.path) do continue
		// One without tags plays its frames as "default": not worth a constant (they're often
		// another set's sheets)
		names, ok := asepriteTagNames(project.rootPath, asset.path)
		if !ok || len(names) == 0 do continue
		append(&sets, Set{filepath.stem(filepath.base(asset.path)), asset.path, names})
	}
	slice.sort_by(sets[:], proc(a, b: Set) -> bool { return a.name != b.name ? a.name < b.name : a.path < b.path })
	for set in sets {
		seen := make(map[string]bool, allocator = context.temp_allocator)
		for name in set.animations {
			if name == "" || name in seen do continue
			seen[name] = true
			add(&out, &used, .Animations, fmt.tprintf("ANIM_%s_%s", ConstantWords(set.name), ConstantWords(name)), quoted(name), fmt.tprintf("Animation %q of %s", name, set.path), target = set.path, group = set.path)
		}
	}
	for owner in owners {
		Sprite :: struct { node: string, animations: [dynamic]AnimationDef }
		sprites := make([dynamic]Sprite, context.temp_allocator)
		for &node in owner.scene.nodes {
			if node.kind != .AnimatedSprite || node.animationSet != "" || len(node.animations) == 0 do continue
			append(&sprites, Sprite{node.name, node.animations})
		}
		slice.sort_by(sprites[:], proc(a, b: Sprite) -> bool { return a.node < b.node })
		for s in sprites {
			seen := make(map[string]bool, allocator = context.temp_allocator)
			for a in s.animations {
				if a.name == "" || a.name in seen do continue
				seen[a.name] = true
				add(&out, &used, .Animations, fmt.tprintf("ANIM_%s_%s_%s", ConstantWords(owner.name), ConstantWords(s.node), ConstantWords(a.name)), quoted(a.name),
					fmt.tprintf("Animation %q of %s in %s", a.name, s.node, owner.label), target = owner.name, group = fmt.tprintf("%s's own, in %s", s.node, owner.label))
			}
		}
	}

	// State machines' states, then parameters, per machine
	for owner in owners {
		Machine :: struct { node: string, sm: ^e.StateMachineSettings }
		machines := make([dynamic]Machine, context.temp_allocator)
		for &node in owner.scene.nodes do if node.kind == .StateMachine do append(&machines, Machine{node.name, &node.stateMachine})
		slice.sort_by(machines[:], proc(a, b: Machine) -> bool { return a.node < b.node })
		for m in machines {
			prefix := fmt.tprintf("%s_%s", ConstantWords(owner.name), ConstantWords(m.node))
			seen := make(map[string]bool, allocator = context.temp_allocator)
			for st in m.sm.states {
				if st.name == "" || st.name in seen do continue
				seen[st.name] = true
				add(&out, &used, .States, fmt.tprintf("STATE_%s_%s", prefix, ConstantWords(st.name)), quoted(st.name), fmt.tprintf("State %q of %s in %s", st.name, m.node, owner.label), target = owner.name, group = fmt.tprintf("%s in %s", m.node, owner.label))
			}
			clear(&seen)
			for p in m.sm.params {
				if p.name == "" || p.name in seen do continue
				seen[p.name] = true
				add(&out, &used, .States, fmt.tprintf("PARAM_%s_%s", prefix, ConstantWords(p.name)), quoted(p.name), fmt.tprintf("%v parameter %q of %s in %s", p.kind, p.name, m.node, owner.label), target = owner.name, group = fmt.tprintf("%s in %s", m.node, owner.label))
			}
		}
	}

	// Groups, from every scene's and component's nodes
	groups := make([dynamic]string, context.temp_allocator)
	{
		seen := make(map[string]bool, allocator = context.temp_allocator)
		for &scene in project.scenes do for &node in scene.nodes {
			rest := node.groups
			for part in strings.split_iterator(&rest, ",") {
				g := strings.trim_space(part)
				if g == "" || g in seen do continue
				seen[g] = true
				append(&groups, g)
			}
		}
	}
	slice.sort(groups[:])
	for g in groups do add(&out, &used, .Groups, fmt.tprintf("GROUP_%s", ConstantWords(g)), quoted(g), fmt.tprintf("Node group %q", g))

	// Buses, in the Mixer's order (Master first)
	for bus in project.buses {
		if bus.name == "" do continue
		add(&out, &used, .Buses, fmt.tprintf("BUS_%s", ConstantWords(bus.name)), quoted(bus.name), fmt.tprintf("Mix bus %q", bus.name))
	}

	// Scenes
	for owner in owners {
		if Scene_IsComponent(owner.scene) do continue
		add(&out, &used, .Scenes, fmt.tprintf("SCENE_%s", ConstantWords(owner.name)), quoted(owner.name), fmt.tprintf("Scene %s (%d nodes)", owner.name, len(owner.scene.nodes)), target = owner.name)
	}

	// Dialogue nodes, per dialogue (by path)
	dialogues := slice.clone(project.dialogues[:], context.temp_allocator)
	slice.sort_by(dialogues, proc(a, b: DialogueDef) -> bool { return a.path < b.path })
	for d in dialogues {
		stem := strings.trim_suffix(filepath.base(d.path), e.DIALOGUE_EXTENSION)
		names := make([dynamic]string, context.temp_allocator)
		for n in d.data.nodes do append(&names, n.name)
		slice.sort(names[:])
		prev := ""
		for n in names {
			if n == "" || n == prev do continue
			prev = n
			add(&out, &used, .Dialogue_Nodes, fmt.tprintf("DIALOGUE_NODE_%s_%s", ConstantWords(stem), ConstantWords(n)), quoted(n), fmt.tprintf("Node %q of %s", n, d.path), target = d.path)
		}
	}

	// Node paths
	for owner in owners {
		paths := make([dynamic]string, context.temp_allocator)
		component := Scene_IsComponent(owner.scene)
		collectNodePaths(project, owner.scene, component, &paths)
		slice.sort(paths[:])
		prev := ""
		for p in paths {
			if p == prev do continue
			prev = p
			words := strings.builder_make(context.temp_allocator)
			rest := strings.trim_prefix(p, "/")
			for part in strings.split_iterator(&rest, "/") {
				strings.write_byte(&words, '_')
				strings.write_string(&words, ConstantWords(part))
			}
			add(&out, &used, .Node_Paths, fmt.tprintf("PATH_%s%s", ConstantWords(owner.name), strings.to_string(words)), quoted(p),
				fmt.tprintf("Node %s in %s", p, owner.label), target = owner.name, group = owner.label)
		}
	}
	return out[:]
}

// Aseprite files' tag names (the animations the engine's AnimationSet_FromAseprite makes; an
// untagged file's one, "default", isn't listed), read again only when a file changes. On the heap with a
// lock, not in the caller's allocator: tests run on several threads, each with its own
@(private="file")
aseTags: struct {
	lock: sync.Mutex,
	byPath: map[string]AseTagNames,
}

@(private="file")
AseTagNames :: struct {
	modified: time.Time,
	names: []string,
	ok: bool,
}

// An Aseprite file's animation names (temp allocated copies), and whether it could be read
@(private)
asepriteTagNames :: proc(root, path: string) -> ([]string, bool) {
	full := joinPath(root, path, allocator = context.temp_allocator)
	modified, err := os.modification_time_by_path(full)
	if err != nil do return nil, false
	sync.guard(&aseTags.lock)
	heap := runtime.heap_allocator()
	if aseTags.byPath == nil do aseTags.byPath = make(map[string]AseTagNames, allocator = heap)
	entry, found := aseTags.byPath[full]
	if !found || entry.modified != modified {
		if found {
			for n in entry.names do delete(n, heap)
			delete(entry.names, heap)
		}
		entry = {modified = modified}
		ase, loadErr := e.Aseprite_Load(full)
		if loadErr == .None && ase != nil {
			defer e.Aseprite_Destroy(ase)
			names := make([dynamic]string, heap)
			for tag in ase.tags do append(&names, strings.clone(tag.name, heap))
			entry.names, entry.ok = names[:], true
		}
		if !found do aseTags.byPath[strings.clone(full, heap)] = entry
		else do aseTags.byPath[full] = entry
	}
	out := make([]string, len(entry.names), context.temp_allocator)
	for n, i in entry.names do out[i] = strings.clone(n, context.temp_allocator)
	return out, entry.ok
}

// The paths of a scene's nodes (from its top level, "/A/B") or a component's (from its root,
// "B"), with the nodes of Component instances under them (temp allocated)
@(private="file")
collectNodePaths :: proc(project: ^Project, scene: ^SceneDef, component: bool, out: ^[dynamic]string, prefix := "", depth := 0) {
	if depth > 4 do return
	for &node, i in scene.nodes {
		if strings.contains(node.name, "/") || node.name == "" do continue
		// Its path: the names up to the top (a component's root left out)
		parts := make([dynamic]string, context.temp_allocator)
		ok := true
		for at := i; at >= 0; at = scene.nodes[at].parent {
			if strings.contains(scene.nodes[at].name, "/") do ok = false
			inject_at(&parts, 0, scene.nodes[at].name)
			if scene.nodes[at].parent < 0 do break
		}
		if !ok do continue
		if component {
			// The root is the node the component is: paths start under it
			if len(parts) <= 1 do continue
			ordered_remove(&parts, 0)
		}
		path := strings.join(parts[:], "/", context.temp_allocator)
		if prefix != "" do path = fmt.tprintf("%s/%s", prefix, path)
		else if !component do path = fmt.tprintf("/%s", path)
		append(out, path)
		// An instance: its component's nodes under it
		if node.kind == .Component && node.component != "" {
			if c := Project_FindComponent(project, node.component); c >= 0 && &project.scenes[c] != scene {
				collectNodePaths(project, &project.scenes[c], true, out, path, depth + 1)
			}
		}
	}
}

/*
The text of scripts/assets.odin (temp allocated): the marker line, then every constant of
`Scripts_Constants`, grouped by section, each new section under a comment.
*/
Scripts_AssetsSource :: proc(project: ^Project) -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, ASSETS_FILE_MARKER + " Don't edit it: it's\n")
	strings.write_string(&b, "// rewritten when assets are imported, removed or added. Use these instead of paths:\n")
	strings.write_string(&b, "// the compiler checks them, and exports ship every asset named here.\n")
	strings.write_string(&b, "package scripts\n\nimport e \"engine:.\"\n\n")
	section := ConstantSection.Assets
	group := ""
	for c in Scripts_Constants(project) {
		if c.section != section {
			section = c.section
			group = ""
			strings.write_string(&b, "\n")
			if SECTION_HEADERS[section] != "" do fmt.sbprintf(&b, "%s\n", SECTION_HEADERS[section])
		}
		if c.group != group {
			group = c.group
			if group != "" do fmt.sbprintf(&b, "// - %s\n", group)
		}
		fmt.sbprintf(&b, "%s :: %s%s\n", c.name, c.value, c.comment)
	}
	return strings.to_string(b)
}

// The constant with that name, or nil (temp: a constant of `Scripts_Constants`)
Scripts_FindConstant :: proc(constants: []GeneratedConstant, name: string) -> ^GeneratedConstant {
	for &c in constants do if c.name == name do return &c
	return nil
}

// --- what a build needs ------------------------------------------------------------

/*
Where a player build keeps the scripts/assets.odin it was built with (beside the binary), so a
later change to the constants can be told apart from one the build must see
(`Constants_ChangeMatters`).
*/
Constants_SnapshotPath :: proc(binary: string) -> string {
	return fmt.tprintf("%s.constants.txt", binary)
}

// Keeps the project's scripts/assets.odin beside a player about to be built
Constants_Snapshot :: proc(project: ^Project, binary: string) {
	path := joinPath(project.rootPath, SCRIPTS_FOLDER, ASSETS_FILE, allocator = context.temp_allocator)
	text, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil do return
	_ = os.write_entire_file(Constants_SnapshotPath(binary), text)
}

/*
Whether scripts/assets.odin changed since a build in a way the build must see: a constant the
build had is gone or has another value, and another file of the package names it. Constants
that are only new (a node, an animation, a scene added) don't: nothing built can use them yet. So
editing a scene, which rewrites the file's node paths, doesn't make Play build the game again
until a script uses what changed. No snapshot (a build from before them): it matters.

Inputs:
- scriptsDir: The project's scripts folder
- binary: The player the build made
*/
Constants_ChangeMatters :: proc(scriptsDir, binary: string) -> bool {
	old, oldErr := os.read_entire_file(Constants_SnapshotPath(binary), context.temp_allocator)
	if oldErr != nil do return true
	now, nowErr := os.read_entire_file(filepath.join({scriptsDir, ASSETS_FILE}, context.temp_allocator) or_else "", context.temp_allocator)
	if nowErr != nil do return true
	if string(old) == string(now) do return false
	constants :: proc(text: string) -> map[string]string {
		out := make(map[string]string, allocator = context.temp_allocator)
		rest := text
		for line in strings.split_lines_iterator(&rest) {
			name, sep, value := strings.partition(line, " :: ")
			if sep == "" || strings.has_prefix(name, "//") do continue
			out[name] = value
		}
		return out
	}
	before, after := constants(string(old)), constants(string(now))
	// The imports and header aside, nothing but constants: anything else changed matters
	header :: proc(text: string) -> string {
		at := strings.index(text, " :: ")
		if at < 0 do return text
		return text[:strings.last_index_byte(text[:at], '\n') + 1]
	}
	if header(string(old)) != header(string(now)) do return true
	changed := make([dynamic]string, context.temp_allocator)
	for name, value in before do if after[name] != value do append(&changed, name)
	if len(changed) == 0 do return false
	entries, err := os.read_all_directory_by_path(scriptsDir, context.temp_allocator)
	if err != nil do return true
	for entry in entries {
		if entry.type != .Regular || !strings.has_suffix(entry.name, ".odin") || entry.name == ASSETS_FILE do continue
		text, readErr := os.read_entire_file(entry.fullpath, context.temp_allocator)
		if readErr != nil do return true
		for name in changed do if containsWord(string(text), name) do return true
	}
	return false
}

// Whether text names an identifier (not as part of a longer one)
@(private="file")
containsWord :: proc(text, word: string) -> bool {
	isWord :: proc(c: u8) -> bool { return c == '_' || c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' }
	from := 0
	for {
		at := strings.index(text[from:], word)
		if at < 0 do return false
		at += from
		end := at + len(word)
		if (at == 0 || !isWord(text[at - 1])) && (end >= len(text) || !isWord(text[end])) do return true
		from = at + 1
	}
}

/*
The newest modification time of a scripts folder's .odin files that a build made into `binary`
depends on: scripts/assets.odin counts only when its change matters (`Constants_ChangeMatters`).
*/
Scripts_NewestFor :: proc(scriptsDir, binary: string) -> time.Time {
	newest: time.Time
	entries, err := os.read_all_directory_by_path(scriptsDir, context.temp_allocator)
	if err != nil do return newest
	for entry in entries {
		if entry.type != .Regular || !strings.has_suffix(entry.name, ".odin") do continue
		if entry.name == ASSETS_FILE && !Constants_ChangeMatters(scriptsDir, binary) do continue
		if time.diff(newest, entry.modification_time) > 0 do newest = entry.modification_time
	}
	return newest
}
