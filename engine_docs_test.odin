package crossfire_editor

import "core:log"
import "core:strings"
import "core:testing"
import "core:time"

// The engine's documentation read from its source: a procedure's comment rendered, a type, F1's
// page, the name at a column, and how long reading and a lookup take
@(test)
engine_docs_read_render_and_link :: proc(t: ^testing.T) {
	start := time.tick_now()
	table := EngineDocs_Load(ENGINE_DIR)
	if !testing.expect(t, table != nil, "the engine's docs") do return
	log.infof("engine docs: %d declarations from %d files in %v (the first read: %v)", len(table.decls), table.files, table.took, time.tick_since(start))
	follow, ok := table.decls["Camera2D_Follow"]
	if !testing.expect(t, ok, "Camera2D_Follow is there") do return
	testing.expect_value(t, follow.kind, "proc")
	testing.expect_value(t, follow.file, "camera.odin")
	testing.expect(t, strings.has_prefix(follow.decl, "Camera2D_Follow :: proc(camera: ^Camera2D") && !strings.contains(follow.decl, "{"), "the signature, no body")
	md := EngineDoc_Markdown(follow)
	testing.expectf(t, strings.has_prefix(md, "```odin\nCamera2D_Follow :: proc("), "the declaration first: %s", md)
	testing.expect(t, strings.contains(md, "Eases the camera toward a world position using the settings in `camera.follow`. Call once per frame"), "the summary, its lines joined (the hover wraps it)")
	testing.expect(t, strings.contains(md, "**Inputs:**\n- camera: The camera to move"), "the inputs")
	testing.expect(t, strings.contains(md, "**Example:**\n```odin\n// Given: player: ^e.Node\ne.Camera2D_Follow("), "the example as code")
	testing.expect_value(t, EngineDoc_URL(follow), "https://crossfireengine.io/api/camera/#camera2d_follow")

	// A type, a long struct cut short; a constant
	camera, isType := table.decls["Camera2D"]
	testing.expect(t, isType && camera.kind == "struct", "Camera2D is a struct")
	testing.expect(t, strings.count(EngineDoc_Markdown(camera), "\n") < ENGINE_DOC_DECL_LINES + 40, "a struct's fields are cut")
	testing.expect_value(t, EngineDoc_URL(camera), "https://crossfireengine.io/api/camera/#camera2d")
	path, isPath := table.decls["NodePath"]
	testing.expect(t, isPath && path.file == "names.odin", "a name type")
	testing.expect_value(t, EngineDoc_URL(path), "https://crossfireengine.io/api/scripts-globals-data-saves/#nodepath")
	// Pages and anchors checked on crossfireengine.io (2026-10-23: each page has the anchor's id)
	for check in ([][2]string{
		{"Script_Register", "https://crossfireengine.io/api/scripts-globals-data-saves/#script_register"},
		{"Node_FindPath", "https://crossfireengine.io/api/core/#node_findpath"},
		{"Audio_SetBusVolume", "https://crossfireengine.io/api/audio/#audio_setbusvolume"},
		{"AnimationPlayer_Play", "https://crossfireengine.io/api/animation/#animationplayer_play"},
	}) {
		d, has := table.decls[check[0]]
		testing.expectf(t, has && EngineDoc_URL(d) == check[1], "%s's page: %s", check[0], has ? EngineDoc_URL(d) : "none")
	}
	_, private := table.decls["multiplyColor"]
	testing.expect(t, !private, "private procedures aren't documented")

	// The name at a column, through the file's import name
	line := "\te.Camera2D_Follow(self.cam, pos, dt) // e.Nope"
	found, at := EngineDocs_At(table, line, strings.index(line, "Follow"), "e")
	testing.expect(t, at && found.name == "Camera2D_Follow", "at the call")
	_, at = EngineDocs_At(table, line, strings.index(line, "cam,"), "e")
	testing.expect(t, !at, "not on another name")
	_, at = EngineDocs_At(table, line, strings.index(line, "Nope"), "e")
	testing.expect(t, !at, "not a declaration")
	other := "\tcf.Node_FindPath(self.node, \"x\")"
	_, at = EngineDocs_At(table, other, strings.index(other, "Find"), "e")
	testing.expect(t, !at, "another package's")
	found, at = EngineDocs_At(table, other, strings.index(other, "Find"), "cf")
	testing.expect(t, at && found.name == "Node_FindPath", "the file's own import name")
	typed := "\tcam: ^e.Camera2D,"
	found, at = EngineDocs_At(table, typed, len(typed) - 1, "e")
	testing.expect(t, at && found.name == "Camera2D", "right after the name")

	// A lookup and its Markdown: what a hover costs
	lookup := time.tick_now()
	for _ in 0 ..< 100 {
		d, _ := EngineDocs_At(table, line, strings.index(line, "Follow"), "e")
		_ = EngineDoc_Markdown(d)
	}
	each := time.tick_since(lookup) / 100
	log.infof("engine docs hover: %v each", each)
	testing.expectf(t, each < time.Millisecond, "a hover's lookup is quick (%v)", each)

	// Every engine file has an API area (the website's build fails otherwise: this catches a new one)
	files := make(map[string]bool, allocator = context.temp_allocator)
	for _, d in table.decls do files[d.file] = true
	for file in files do testing.expectf(t, EngineAPI_Area(file) != "", "%s has an API area (ENGINE_API_AREAS)", file)
	free_all(context.temp_allocator)
}
