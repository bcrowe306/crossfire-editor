package crossfire_editor

import "base:runtime"
import "core:fmt"
import "core:odin/ast"
import "core:odin/parser"
import "core:odin/tokenizer"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sync"
import "core:time"
import vmem "core:mem/virtual"
import "gui:skald"

/*
The engine's documentation in the code editor: hovers over an engine procedure, type or constant
show its doc comment rendered (its declaration, summary, Inputs, Returns, Example), and F1 on one
opens its page of the API reference on crossfireengine.io.

- **Read from the engine's source** the editor builds with (`Toolchain_EngineDir`: a checkout, or
  the `engine/` folder a release ships), with `core:odin/parser` like the website's docgen
  (crossfire_astro/tools/docgen), whose rules it follows: every public top-level declaration
  (also inside `when` blocks), its doc comment (the comment group the parser attached, or the one
  ending on the line above), markers stripped and the common indentation removed. Once per run,
  on a worker (`EngineDocs_Start`, from the script index's tick, after the name table); until
  it's read, hovers say nothing more than OLS. The table is never freed (one per run, on the
  heap, shared by tests on several threads).
- **Hovers** (`EngineDocs_Hover`) are a map lookup and a little text: the declaration as a code
  block (a long struct cut after `ENGINE_DOC_DECL_LINES` lines), the comment with `Inputs:`,
  `Returns:` and `Example:` as the website shows them (the example a code block). They stand in
  for OLS's answer, which would repeat the declaration and the raw comment.
- **The API page** (`EngineDoc_URL`): `https://crossfireengine.io/api/<area>/#<anchor>`. The area
  is the website's (scripts/api-groups.json: every engine file in one area; copied here as
  `ENGINE_API_AREAS`, which `engine_api_areas_match_the_website` checks against the website's
  file when it's checked out beside the editor); the anchor is the name lower-cased (Starlight's
  heading ids: scripts/build-api.mjs's `anchorOf`). A file in no area goes to the reference's
  index.
*/

// The website's API reference
ENGINE_API_URL :: "https://crossfireengine.io/api/"

// The longest declaration a hover shows (lines; a struct's fields after that are cut)
ENGINE_DOC_DECL_LINES :: 14

// One public declaration of the engine
EngineDoc :: struct {
	name: string,
	// "proc", "proc_group", "struct", "enum", "union", "type", "constant", "variable" (docgen's)
	kind: string,
	// The file's name (`camera.odin`) and the declaration's line (1-based)
	file: string,
	line: int,
	// The declaration as written (a procedure's signature without its body)
	decl: string,
	// Its doc comment, markers stripped ("" none)
	doc:  string,
}

// The engine's declarations by name (EngineDocs_Get)
EngineDocs :: struct {
	decls: map[string]EngineDoc,
	// Each file's overview (docgen's: the first `/* */` block after the package line, before the
	// first declaration and not its doc comment), by file name; doc.odin's block above `package`
	// is the package's overview
	overviews: map[string]string,
	packageDoc: string,
	// The folder it was read from, the files parsed and how long it took
	engineDir: string,
	files: int,
	took: time.Duration,
}

@(private="file")
engineDocs: struct {
	lock: sync.Mutex,
	table: ^EngineDocs,
	loading: bool,
}

// The table, or nil while it isn't read yet
EngineDocs_Get :: proc() -> ^EngineDocs {
	sync.guard(&engineDocs.lock)
	return engineDocs.table
}

/*
Reads the table from an engine folder now, unless it's already read (tests; the worker's job).

Returns:
- The table (nil when the folder has no engine)
*/
EngineDocs_Load :: proc(engineDir: string) -> ^EngineDocs {
	if t := EngineDocs_Get(); t != nil do return t
	table := EngineDocs_Read(engineDir, runtime.heap_allocator())
	sync.guard(&engineDocs.lock)
	engineDocs.loading = false
	if engineDocs.table == nil do engineDocs.table = table
	return engineDocs.table
}

// The worker's answer: the engine's documentation was read
EngineDocs_Loaded :: struct {}

/*
Starts reading the engine's documentation on a worker, once (the script index's tick).

Returns:
- The worker's command, or nothing when it's read or being read
*/
EngineDocs_Start :: proc() -> skald.Command(Msg) {
	{
		sync.guard(&engineDocs.lock)
		if engineDocs.table != nil || engineDocs.loading do return {}
		engineDocs.loading = true
	}
	dir, _ := Toolchain_EngineDir()
	Job :: struct { dir: string }
	return skald.cmd_thread(Msg, Job{strings.clone(dir)}, proc(job: Job) -> Msg {
		EngineDocs_Load(job.dir)
		delete(job.dir)
		return EngineDocs_Loaded{}
	})
}

/*
Reads the public declarations and doc comments of an engine folder (pure: tests call it).

Inputs:
- engineDir: The engine's folder (its top-level .odin files, tests left out)
- allocator: For the table and everything in it

Returns:
- The table (nil when the folder can't be read or has no declarations)
*/
EngineDocs_Read :: proc(engineDir: string, allocator := context.allocator) -> ^EngineDocs {
	start := time.tick_now()
	entries, err := os.read_all_directory_by_path(engineDir, context.temp_allocator)
	if err != nil do return nil
	arena: vmem.Arena
	if vmem.arena_init_growing(&arena) != nil do return nil
	defer vmem.arena_destroy(&arena)
	scratch := vmem.arena_allocator(&arena)

	table := new(EngineDocs, allocator)
	table.decls = make(map[string]EngineDoc, allocator = allocator)
	table.overviews = make(map[string]string, allocator = allocator)
	table.engineDir = strings.clone(engineDir, allocator)
	for entry in entries {
		if !strings.has_suffix(entry.name, ".odin") || strings.has_suffix(entry.name, "_test.odin") do continue
		data, readErr := os.read_entire_file(entry.fullpath, scratch)
		if readErr != nil do continue
		table.files += 1
		{
			context.allocator = scratch
			file := ast.new(ast.File, tokenizer.Pos{}, tokenizer.Pos{})
			file.src = string(data)
			file.fullpath = entry.fullpath
			p := parser.default_parser()
			p.err = proc(pos: tokenizer.Pos, msg: string, args: ..any) {}
			p.warn = proc(pos: tokenizer.Pos, msg: string, args: ..any) {}
			if !parser.parse_file(&p, file) && len(file.decls) == 0 do continue
			private := false
			for tag in file.tags do if strings.contains(tag.text, "private") do private = true
			if private do continue
			for decl in file.decls do docsCollect(table, file, decl, entry.name, allocator)
		}
	}
	if len(table.decls) == 0 {
		context.allocator = allocator
		for _, d in table.decls do engineDocFree(d)
		delete(table.decls)
		for k, v in table.overviews { delete(k); delete(v) }
		delete(table.overviews)
		delete(table.packageDoc)
		delete(table.engineDir)
		free(table)
		return nil
	}
	table.took = time.tick_since(start)
	return table
}

// A file's overview (docgen's rule; temp allocated, "" none)
@(private="file")
docsOverview :: proc(file: ^ast.File) -> string {
	if file.pkg_decl == nil do return ""
	first: ^ast.Stmt
	for stmt in file.decls {
		#partial switch _ in stmt.derived {
		case ^ast.Import_Decl, ^ast.Foreign_Import_Decl: continue
		}
		if first == nil || stmt.pos.line < first.pos.line do first = stmt
	}
	firstLine := first != nil ? first.pos.line : max(int)
	firstDocs: ^ast.Comment_Group
	if first != nil do if vd, ok := first.derived.(^ast.Value_Decl); ok do firstDocs = vd.docs
	for group in file.comments {
		if group == file.docs || len(group.list) == 0 || group.pos.offset < file.pkg_decl.end.offset do continue
		if group.pos.line > firstLine || group == firstDocs || group.end.line == firstLine - 1 do break
		if !strings.has_prefix(group.list[0].text, "/*") do continue
		return docsCommentText(group)
	}
	return ""
}

@(private="file")
engineDocFree :: proc(d: EngineDoc) {
	delete(d.name); delete(d.kind); delete(d.file); delete(d.decl); delete(d.doc)
}

// One top-level statement's declarations (into `when` blocks)
@(private="file")
docsCollect :: proc(table: ^EngineDocs, file: ^ast.File, stmt: ^ast.Stmt, fileName: string, allocator: runtime.Allocator) {
	#partial switch d in stmt.derived {
	case ^ast.When_Stmt:
		docsCollect(table, file, d.body, fileName, allocator)
		if d.else_stmt != nil do docsCollect(table, file, d.else_stmt, fileName, allocator)
	case ^ast.Block_Stmt:
		for s in d.stmts do docsCollect(table, file, s, fileName, allocator)
	case ^ast.Foreign_Block_Decl:
		if d.body != nil && !docsPrivate(d.attributes[:]) do docsCollect(table, file, d.body, fileName, allocator)
	case ^ast.Value_Decl:
		if docsPrivate(d.attributes[:]) do return
		group := d.docs
		if group == nil do group = docsAbove(file, d)
		for nameExpr, i in d.names {
			ident, ok := nameExpr.derived.(^ast.Ident)
			if !ok || strings.has_prefix(ident.name, "_") || ident.name in table.decls do continue
			value: ^ast.Expr
			if i < len(d.values) do value = d.values[i]
			else if len(d.values) == 1 do value = d.values[0]
			kind, text := docsDescribe(file, d, ident, value)
			table.decls[strings.clone(ident.name, allocator)] = EngineDoc{
				name = strings.clone(ident.name, allocator),
				kind = strings.clone(kind, allocator),
				file = strings.clone(fileName, allocator),
				line = ident.pos.line,
				decl = strings.clone(text, allocator),
				doc = group != nil ? strings.clone(docsCommentText(group), allocator) : strings.clone("", allocator),
			}
		}
	}
}

// The comment group ending on the line above a declaration (or its attributes), when the parser
// didn't attach it (docgen's docs_above)
@(private="file")
docsAbove :: proc(file: ^ast.File, d: ^ast.Value_Decl) -> ^ast.Comment_Group {
	line := d.pos.line
	for a in d.attributes do line = min(line, a.pos.line)
	for group in file.comments {
		if group.end.line == line - 1 do return group
		if group.pos.line >= line do break
	}
	return nil
}

@(private="file")
docsPrivate :: proc(attributes: []^ast.Attribute) -> bool {
	for attr in attributes do for elem in attr.elems {
		#partial switch e in elem.derived {
		case ^ast.Ident:
			if e.name == "private" do return true
		case ^ast.Field_Value:
			if id, ok := e.field.derived.(^ast.Ident); ok && id.name == "private" do return true
		}
	}
	return false
}

// A declaration's kind and text (docgen's describe: a procedure without its body)
@(private="file")
docsDescribe :: proc(file: ^ast.File, d: ^ast.Value_Decl, ident: ^ast.Ident, value: ^ast.Expr) -> (kind, text: string) {
	src :: proc(file: ^ast.File, start, end: int) -> string {
		return file.src[clamp(start, 0, len(file.src)):clamp(end, 0, len(file.src))]
	}
	start := len(d.names) > 1 ? d.names[0].pos.offset : ident.pos.offset
	end := d.end.offset
	if value != nil do end = max(end, value.end.offset)
	kind = "constant"
	if d.is_mutable {
		kind = "variable"
	} else if value != nil {
		#partial switch v in value.derived {
		case ^ast.Proc_Lit:
			kind = "proc"
			end = v.type.end.offset
			if v.type.results != nil do end = max(end, v.type.results.end.offset)
			for w in v.where_clauses do end = max(end, w.end.offset)
			if v.body == nil do end = value.end.offset
		case ^ast.Proc_Group:  kind = "proc_group"
		case ^ast.Struct_Type: kind = "struct"
		case ^ast.Enum_Type:   kind = "enum"
		case ^ast.Union_Type:  kind = "union"
		case ^ast.Bit_Set_Type, ^ast.Distinct_Type, ^ast.Pointer_Type, ^ast.Array_Type, ^ast.Dynamic_Array_Type, ^ast.Map_Type, ^ast.Proc_Type:
			kind = "type"
		case ^ast.Ident, ^ast.Selector_Expr:
			upper := true
			for c in ident.name do if c >= 'a' && c <= 'z' do upper = false
			kind = upper ? "constant" : "type"
		}
	}
	text = strings.trim_right_space(src(file, start, end))
	if kind == "proc" && strings.has_suffix(text, "---") do text = strings.trim_right_space(text[:len(text) - 3])
	return
}

// A comment group's text: markers stripped, the common indentation removed, blank edges trimmed
// (docgen's comment_text; temp allocated)
@(private="file")
docsCommentText :: proc(group: ^ast.Comment_Group) -> string {
	lines := make([dynamic]string, context.temp_allocator)
	allLine := true
	for tok in group.list {
		text := tok.text
		if strings.has_prefix(text, "/*") {
			allLine = false
			text = strings.trim_suffix(strings.trim_prefix(text, "/*"), "*/")
			for line in strings.split_lines(text, context.temp_allocator) do append(&lines, strings.trim_right_space(line))
		} else {
			append(&lines, strings.trim_right_space(strings.trim_prefix(text, "//")))
		}
	}
	if allLine {
		every := true
		for l in lines do if l != "" && !strings.has_prefix(l, " ") do every = false
		if every do for &l in lines do l = strings.trim_prefix(l, " ")
	}
	// The indentation every line shares (tabs and spaces as written)
	first := ""
	for l in lines do if strings.trim_space(l) != "" { first = l; break }
	common := -1
	for l in lines {
		if strings.trim_space(l) == "" do continue
		n := 0
		for n < len(l) && n < len(first) && (l[n] == ' ' || l[n] == '\t') && l[n] == first[n] do n += 1
		common = common < 0 ? n : min(common, n)
	}
	if common > 0 do for &l in lines do if len(l) >= common do l = l[common:]
	for len(lines) > 0 && strings.trim_space(lines[0]) == "" do ordered_remove(&lines, 0)
	for len(lines) > 0 && strings.trim_space(lines[len(lines) - 1]) == "" do pop(&lines)
	return strings.join(lines[:], "\n", context.temp_allocator)
}

/*
A declaration's documentation as the hover's Markdown: the declaration as an Odin code block, then
the comment, its `Inputs:` and `Returns:` headings bold and its `Example:` (and any other
tab-indented block) as code.

Returns:
- The Markdown (temp allocated)
*/
EngineDoc_Markdown :: proc(d: EngineDoc) -> string {
	b := strings.builder_make(context.temp_allocator)
	decl := d.decl
	lines := strings.split_lines(decl, context.temp_allocator)
	if len(lines) > ENGINE_DOC_DECL_LINES {
		decl = fmt.tprintf("%s\n\t// ... %d more lines", strings.join(lines[:ENGINE_DOC_DECL_LINES], "\n", context.temp_allocator), len(lines) - ENGINE_DOC_DECL_LINES)
	}
	fmt.sbprintf(&b, "```odin\n%s\n```", decl)
	if d.doc == "" {
		fmt.sbprintf(&b, "\n\n*No documentation* (%s:%d)", d.file, d.line)
		return strings.to_string(b)
	}
	strings.write_string(&b, "\n\n")
	// The comment's lines: a paragraph's (or a list item's) wrapped lines joined into one, so the
	// hover wraps them to its own width; code blocks kept as they are
	out := make([dynamic]string, context.temp_allocator)
	inCode, joinable := false, false
	for line in strings.split_lines(d.doc, context.temp_allocator) {
		indented := strings.has_prefix(line, "\t") || strings.has_prefix(line, "    ")
		blank := strings.trim_space(line) == ""
		if inCode && !indented && !blank {
			append(&out, "```")
			inCode = false
		}
		if !inCode && indented && !strings.has_prefix(strings.trim_left_space(line), "- ") {
			append(&out, "```odin")
			inCode, joinable = true, false
		}
		switch {
		case inCode:
			append(&out, strings.has_prefix(line, "\t") ? line[1:] : strings.trim_prefix(line, "    "))
		case blank:
			append(&out, "")
			joinable = false
		case line == "Inputs:" || line == "Returns:" || line == "Example:":
			append(&out, fmt.tprintf("**%s**", line))
			joinable = false
		case joinable && !strings.has_prefix(line, "- "):
			out[len(out) - 1] = fmt.tprintf("%s %s", out[len(out) - 1], strings.trim_space(line))
		case:
			append(&out, line)
			joinable = true
		}
	}
	if inCode do append(&out, "```")
	strings.write_string(&b, strings.join(out[:], "\n", context.temp_allocator))
	return strings.trim_right_space(strings.to_string(b))
}

// One area of the website's API reference (crossfire_astro/scripts/api-groups.json): its page's slug,
// title and description, and the engine files it documents
EngineAPIArea :: struct {
	slug, title, description: string,
	files: []string,
}

// The engine's files by the website's API areas (crossfire_astro/scripts/api-groups.json, in its
// order; checked by `engine_api_areas_match_the_website`)
ENGINE_API_AREAS := [?]EngineAPIArea{
	{"core", "Core: application, game, scenes and nodes", "The application and its frame loop, the game and its scenes, nodes and their transforms, events, timers and the package's memory model.", {"app.odin", "game.odin", "scene.odin", "node.odin", "transform.odin", "event.odin", "node_events.odin", "timer.odin", "ticker.odin", "layers.odin", "custom_nodes.odin"}},
	{"rendering", "Rendering", "Drawing shapes and textures in a node's space, render targets, texture atlases, tile batches and the choice of renderer.", {"primitives.odin", "render_target.odin", "render_backend.odin", "atlas.odin", "tile_batch.odin"}},
	{"text-and-fonts", "Text and fonts", "Drawing and measuring text, bitmap and MSDF fonts, and localization.", {"text_primitives.odin", "fonts.odin", "font_compile.odin", "localization.odin"}},
	{"camera", "Camera", "The Camera2D node, follow modes and pans, parallax layers, camera zones, smooth zoom and camera views.", {"camera.odin", "camera_tools.odin"}},
	{"input", "Input", "Keyboard, mouse and gamepad state, input actions, and rebinding.", {"input.odin", "input_rebind.odin"}},
	{"physics", "Physics", "The Box2D world, physics nodes and joints, contact and area events, queries, materials, collision traced from images and debug drawing.", {"physics.odin", "physics_nodes.odin", "physics_events.odin", "physics_joints.odin", "physics_debug.odin", "physics_material.odin", "collision_trace.odin"}},
	{"audio", "Audio", "SDL_mixer setup, sound and music nodes, mix buses, bus effects, level meters and adaptive music.", {"audio.odin", "audio_nodes.odin", "audio_effects.odin", "audio_meter.odin", "music_layers.odin"}},
	{"animation", "Animation", "Sprite animations and their player, animation assets, Animator keyframe clips, tweens, easing curves, state machines and skeletal animation.", {"animation.odin", "animation_player.odin", "animation_sets.odin", "animator.odin", "tween.odin", "easing.odin", "state_machine.odin", "skeleton.odin", "dragonbones.odin"}},
	{"particles-and-lines", "Particles and lines", "Particle emitters on the CPU and the GPU, Line2D and Trail2D.", {"particles.odin", "gpu_particles.odin", "lines.odin"}},
	{"lighting", "Lighting", "2D lights, occluders, shadows and the scene's light map.", {"lighting.odin"}},
	{"shaders-and-screen-effects", "Shaders and screen effects", "Shader bundles and materials on nodes, compiling GLSL, and ScreenEffect nodes.", {"shaders.odin", "shader_compile.odin", "screen_effects.odin"}},
	{"ui", "UI", "Labels, menus, UI controls (panels, buttons, progress bars, text fields, scroll boxes, rich text), layouts and themes.", {"ui_label.odin", "ui_menu.odin", "ui_menu_draw.odin", "ui_menu_input.odin", "ui_style.odin", "ui_controls.odin", "ui_theme.odin"}},
	{"tilemaps-and-aseprite", "Tilemaps and Aseprite", "Aseprite files, their use in a running game, and TileMap nodes.", {"aseprite.odin", "aseprite_nodes.odin", "tilemap.odin", "inflate.odin"}},
	{"ldtk", "LDtk", "LDtk projects as plain data, and LDtkLevel nodes built from them.", {"ldtk.odin", "ldtk_nodes.odin"}},
	{"dialogue", "Dialogue", "Dialogue files and their runner, Yarn Spinner import, and the DialogueBox node.", {"dialogue.odin", "dialogue_box.odin", "yarn.odin"}},
	{"navigation", "Navigation", "Navigation regions and grids, A* paths, and NavAgent nodes.", {"navigation.odin"}},
	{"scripts-globals-data-saves", "Scripts, globals, data and saves", "Scripts attached to nodes, global scripts, data resources, saved games, hot reload's snapshots, the name types engine procedures take (scenes, node paths, animations, actions...), and the code uses editors write for each kind of thing.", {"script.odin", "names.odin", "code_uses.odin", "globals.odin", "data.odin", "save.odin", "hot_reload.odin"}},
	{"scene-changes", "Scene changes", "Transitions, scenes over scenes, loading screens and menu actions.", {"scene_flow.odin"}},
	{"project-format-and-loading", "Project format and loading", "The project and scene XML format, its parser, and building scenes from parsed data.", {"project_format.odin", "project_loader.odin"}},
	{"assets-and-import", "Assets and import", "The resource manager, typed asset handles and import settings.", {"resource_manager.odin", "assets.odin", "asset_import.odin"}},
	{"platform-player-web", "Platform, player and web", "The player program, the platform layer (desktop and browser), the browser player, data packs and static SDL linking.", {"player.odin", "platform_native.odin", "platform_web.odin", "player_web.odin", "pack.odin", "sdl_static.odin"}},
	{"steam-touch-multiplayer", "Steam, touch and local multiplayer", "Steam achievements, stats and cloud files; touch input and on-screen controls; local multiplayer players and split screen.", {"steam.odin", "touch.odin", "players.odin"}},
	{"debug-and-live", "Debug, logging and live", "Debug drawing and the debug overlay, logging (levels, categories, SDL's messages), and the live link with the editor.", {"debug.odin", "logging.odin", "logging_windows.odin", "logging_darwin.odin", "live.odin", "live_native.odin", "live_web.odin"}},
	{"utilities", "Utilities", "Paths, running other programs, and the package overview.", {"paths.odin", "process_exec.odin", "doc.odin"}},
}

// The API reference's area of an engine file ("" when it's in none)
EngineAPI_Area :: proc(file: string) -> string {
	base := filepath.base(file)
	for area in ENGINE_API_AREAS do for f in area.files do if f == base do return area.slug
	return ""
}

/*
A declaration's page on the website: `https://crossfireengine.io/api/<area>/#<name lower-cased>`,
or the reference's index when its file is in no area.

Returns:
- The address (temp allocated)
*/
EngineDoc_URL :: proc(d: EngineDoc) -> string {
	area := EngineAPI_Area(d.file)
	if area == "" do return ENGINE_API_URL
	return fmt.tprintf("%s%s/#%s", ENGINE_API_URL, area, strings.to_lower(d.name, context.temp_allocator))
}

/*
The engine declaration named at a column of a line of code: an identifier after the engine's
import name and a dot (`e.Camera2D_Follow`, `^e.Camera2D`).

Inputs:
- line: The line's text
- column: A byte column inside the name, or right after it
- alias: The file's import name of the engine (`e`)

Returns:
- The declaration (from the table), and whether there's one
*/
EngineDocs_At :: proc(table: ^EngineDocs, line: string, column: int, alias: string) -> (EngineDoc, bool) {
	if table == nil || alias == "" do return {}, false
	isWord :: proc(c: u8) -> bool { return c == '_' || c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' }
	start, end := clamp(column, 0, len(line)), clamp(column, 0, len(line))
	for start > 0 && isWord(line[start - 1]) do start -= 1
	for end < len(line) && isWord(line[end]) do end += 1
	if start == end do return {}, false
	// The package before the dot, a whole word
	dot := start - 1
	if dot < len(alias) || line[dot] != '.' || line[dot - len(alias):dot] != alias do return {}, false
	if dot - len(alias) > 0 && isWord(line[dot - len(alias) - 1]) do return {}, false
	d, ok := table.decls[line[start:end]]
	return d, ok
}
