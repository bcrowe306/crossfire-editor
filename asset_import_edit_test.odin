package crossfire_editor

import "core:log"
import "core:os"
import "core:strings"
import "core:testing"
import e "engine:."
import stbi "vendor:stb/image"

// Import settings (asset_import_edit.odin) and atlases (atlas_edit.odin) in the editor: set,
// saved and read back, MSDF atlases made, sounds converted, atlases packed and drawn from

@(private="file")
sendTo :: proc(state: ^State, msg: Msg) {
	state^, _ = update(state^, msg)
}

@(private="file")
freshState :: proc(dir: string) -> State {
	os.make_directory("build")
	removeAll(dir)
	os.make_directory(dir)
	root := joinPath(dir, "Game", allocator = context.temp_allocator)
	state := State{project = Project_CreateEmpty(root, "Game"), browserSelection = {kind = .None}, selectedNode = -1, settings = Settings_Default(),
		timeline = {node = -1, track = -1, key = -1}, states = {node = -1, state = -1, transition = -1}, themeSelection = -1, dataSelection = -1,
		materialSelection = -1, atlasSelection = -1, trace = DEFAULT_TRACE_SETTINGS, busSelection = -1}
	state.settings.builtInCodeEditor = false
	testing.expect_value(nil, Project_Save(&state.project), "")
	return state
}

// A PNG of one color in the project
@(private="file")
writePNG :: proc(path: string, size: [2]int, color: [4]u8) {
	pixels := make([]u8, size.x * size.y * 4, context.temp_allocator)
	color := color
	for i in 0 ..< size.x * size.y do copy(pixels[i * 4:][:4], color[:])
	_ = os.make_directory_all(dirOf(path))
	_ = stbi.write_png(strings.clone_to_cstring(path, context.temp_allocator), i32(size.x), i32(size.y), 4, raw_data(pixels), i32(size.x * 4))
}

@(private="file")
dirOf :: proc(path: string) -> string {
	i := strings.last_index_byte(path, '/')
	return i < 0 ? "." : path[:i]
}

@(test)
import_settings_in_the_editor :: proc(t: ^testing.T) {
	dir := "build/test_asset_import"
	state := freshState(dir)
	defer removeAll(dir)
	defer State_Destroy(&state)
	root := state.project.rootPath

	// An image's filtering, and the project's
	writePNG(joinPath(root, "assets/hero.png", allocator = context.temp_allocator), {4, 4}, {255, 0, 0, 255})
	hero, problem := Project_ImportAsset(&state.project, joinPath(root, "assets/hero.png", allocator = context.temp_allocator))
	testing.expect_value(t, problem, "")
	sendTo(&state, Asset_Filter_Changed{hero, .Pixel})
	testing.expect_value(t, state.project.assets[hero].filter, e.TextureFilter.Pixel)
	testing.expect(t, state.session.assetsChanged, "an asset change")
	ProjectSettings_Open(&state)
	sendTo(&state, Project_Settings_Texture_Filter_Changed(.Smooth))
	sendTo(&state, Project_Settings_Applied{})
	testing.expect_value(t, state.project.textureFilter, e.TextureFilter.Smooth)
	sendTo(&state, Action.Undo)
	testing.expect_value(t, state.project.textureFilter, e.TextureFilter.Default)
	sendTo(&state, Action.Redo)

	// A bitmap font: a font asset; its pages go with exports
	fnt := `info face="T" size=8
common lineHeight=10 base=8 pages=1
page id=0 file="pixel_0.png"
char id=65 x=0 y=0 width=4 height=6 xoffset=0 yoffset=2 xadvance=5 page=0
`
	_ = os.make_directory_all(joinPath(root, "assets/fonts", allocator = context.temp_allocator))
	_ = os.write_entire_file(joinPath(root, "assets/fonts/pixel.fnt", allocator = context.temp_allocator), transmute([]byte)string(fnt))
	writePNG(joinPath(root, "assets/fonts/pixel_0.png", allocator = context.temp_allocator), {8, 8}, {255, 255, 255, 255})
	pixel, fntProblem := Project_ImportAsset(&state.project, joinPath(root, "assets/fonts/pixel.fnt", allocator = context.temp_allocator))
	testing.expect_value(t, fntProblem, "")
	testing.expect_value(t, state.project.assets[pixel].kind, AssetKind.Font)
	has :: proc(list: []string, name: string) -> bool {
		for f in list do if f == name do return true
		return false
	}
	files := Fonts_ExportFiles(&state.project, context.temp_allocator)
	testing.expect(t, has(files, "assets/fonts/pixel_0.png"), "the page image is exported")

	// A TrueType font's MSDF atlas (with the font tool)
	_ = os.write_entire_file(joinPath(root, "assets/fonts/Sans.ttf", allocator = context.temp_allocator), #load("../odin_sdl_engine/Open_Sans/static/OpenSans-Regular.ttf"))
	sans, _ := Project_ImportAsset(&state.project, joinPath(root, "assets/fonts/Sans.ttf", allocator = context.temp_allocator))
	tools, found := Toolchain_ShaderTools()
	if found && tools.msdfAtlasGen != "" {
		sendTo(&state, Asset_MSDF_Changed{sans, true})
		testing.expect(t, state.project.assets[sans].msdf, "on")
		testing.expect(t, os.exists(joinPath(root, "assets/fonts/Sans.ttf.msdf.json", allocator = context.temp_allocator)), "its atlas made")
		files = Fonts_ExportFiles(&state.project, context.temp_allocator)
		testing.expect(t, has(files, "assets/fonts/Sans.ttf.msdf.bmp") && has(files, "assets/fonts/Sans.ttf.msdf.json"), "exported")
	} else {
		log.info("No font tool: skipping the MSDF atlas")
	}

	// Saved and read back
	testing.expect_value(t, Project_Save(&state.project), "")
	loaded, message, _ := Project_Load(root)
	defer Project_Destroy(&loaded)
	testing.expect_value(t, message, "")
	testing.expect_value(t, loaded.textureFilter, e.TextureFilter.Smooth)
	for a in loaded.assets do if a.path == "assets/hero.png" do testing.expect_value(t, a.filter, e.TextureFilter.Pixel)
	if found && tools.msdfAtlasGen != "" {
		for a in loaded.assets do if a.path == "assets/fonts/Sans.ttf" do testing.expect(t, a.msdf, "MSDF kept")
	}

	// Sounds: converted to Ogg (with ffmpeg); a node playing it follows
	if ffmpeg := Toolchain_FFmpeg(); ffmpeg != "" {
		_ = os.copy_file(joinPath(root, "assets/beep.wav", allocator = context.temp_allocator), "tests/fixtures/beep.wav")
		beep, _ := Project_ImportAsset(&state.project, joinPath(root, "assets/beep.wav", allocator = context.temp_allocator))
		sendTo(&state, Add_Node_Kind_Chosen(.AudioPlayer))
		player := &state.project.scenes[state.currentScene].nodes[state.selectedNode]
		delete(player.sound)
		player.sound = strings.clone("assets/beep.wav")
		output := joinPath(root, "assets/beep.ogg", allocator = context.temp_allocator)
		convertProblem := Audio_ConvertFile(ffmpeg, joinPath(root, "assets/beep.wav", allocator = context.temp_allocator), output)
		testing.expectf(t, convertProblem == "", "converted: %s", convertProblem)
		delete(convertProblem)
		sendTo(&state, Audio_Converted{beep, strings.clone("assets/beep.wav"), strings.clone(output), strings.clone("")})
		testing.expect_value(t, state.project.assets[beep].path, "assets/beep.ogg")
		testing.expect_value(t, state.project.scenes[state.currentScene].nodes[state.selectedNode].sound, "assets/beep.ogg")
	} else {
		log.info("No ffmpeg: skipping the conversion")
	}
	testing.expect(t, Audio_NeedsConversion("song.M4A") && !Audio_NeedsConversion("song.ogg"), "which need converting")
}

@(test)
atlases_in_the_editor :: proc(t: ^testing.T) {
	dir := "build/test_atlas_edit"
	state := freshState(dir)
	defer removeAll(dir)
	defer State_Destroy(&state)
	root := state.project.rootPath
	writePNG(joinPath(root, "assets/coin.png", allocator = context.temp_allocator), {8, 8}, {255, 200, 0, 255})
	writePNG(joinPath(root, "assets/gem.png", allocator = context.temp_allocator), {6, 10}, {0, 200, 255, 255})
	_, _ = Project_ImportAsset(&state.project, joinPath(root, "assets/coin.png", allocator = context.temp_allocator))
	_, _ = Project_ImportAsset(&state.project, joinPath(root, "assets/gem.png", allocator = context.temp_allocator))

	// New Atlas: shown in the inspector, its files written
	sendTo(&state, Atlas_Created{})
	testing.expect_value(t, len(state.project.atlases), 1)
	testing.expect_value(t, state.atlasSelection, 0)
	atlas := &state.project.atlases[0]
	testing.expect(t, os.exists(joinPath(root, atlas.path, allocator = context.temp_allocator)), "the atlas file")
	// Images packed as they're added
	sendTo(&state, Atlas_Image_Added("assets/coin.png"))
	sendTo(&state, Atlas_Image_Added("assets/gem.png"))
	sendTo(&state, Atlas_Image_Added("assets/gem.png"))
	atlas = &state.project.atlases[0]
	testing.expect_value(t, len(atlas.data.regions), 2)
	testing.expect(t, atlas.data.regions[0].name == "coin" && atlas.data.regions[0].rect[2] == 8, "coin packed")
	testing.expect(t, atlas.data.regions[1].rect[2] == 6 && atlas.data.regions[1].rect[3] == 10, "gem packed")
	pixels, w, h, ok := Image_LoadRGBA(joinPath(root, atlas.data.image, allocator = context.temp_allocator))
	testing.expect(t, ok && w >= 14 && h >= 10, "the picture")
	gem := atlas.data.regions[1].rect
	at := (gem[1] * w + gem[0]) * 4
	testing.expect(t, ok && pixels[at] == 0 && pixels[at + 2] == 255, "the gem's pixels where its region is")
	sendTo(&state, Atlas_Padding_Changed(0))
	sendTo(&state, Atlas_Filter_Changed(.Pixel))
	testing.expect(t, state.project.atlases[0].data.padding == 0 && state.project.atlases[0].data.filter == .Pixel, "settings")

	// A Sprite drawing one of its images
	sendTo(&state, Add_Node_Kind_Chosen(.Sprite))
	sprite := state.selectedNode
	sendTo(&state, Node_Text_Changed{.Texture, state.project.atlases[0].path})
	node := &state.project.scenes[state.currentScene].nodes[sprite]
	testing.expect_value(t, node.region, "coin")
	sendTo(&state, Node_Text_Changed{.Region, "gem"})
	testing.expect_value(t, state.project.scenes[state.currentScene].nodes[sprite].region, "gem")
	sendTo(&state, Action.Undo)
	testing.expect_value(t, state.project.scenes[state.currentScene].nodes[sprite].region, "coin")
	sendTo(&state, Action.Redo)
	// The packed picture is exported; scripts get the atlas's constant
	exported := Export_ProjectFiles(&state.project, context.temp_allocator)
	found := false
	for f in exported do if f == state.project.atlases[0].data.image do found = true
	testing.expect(t, found, "the picture exported")
	testing.expect(t, strings.contains(Scripts_AssetsSource(&state.project), "ATLAS_ATLAS :: \"atlases/atlas.atlas.xml\""), "ATLAS_ constant")

	// Saved and read back
	testing.expect_value(t, Project_Save(&state.project), "")
	loaded, message, _ := Project_Load(root)
	defer Project_Destroy(&loaded)
	testing.expect_value(t, message, "")
	testing.expect_value(t, len(loaded.atlases), 1)
	testing.expect(t, e.AtlasData_Equal(loaded.atlases[0].data, state.project.atlases[0].data), "the atlas")
	for &s in loaded.scenes do for &n in s.nodes do if n.kind == .Sprite do testing.expect_value(t, n.region, "gem")

	// Removing an image packs again (the atlas chosen in the browser again: the Sprite took the
	// inspector); removing the asset forgets the atlas
	testing.expect_value(t, state.atlasSelection, -1)
	state.atlasSelection = 0
	sendTo(&state, Atlas_Image_Removed(0))
	testing.expect_value(t, len(state.project.atlases[0].data.regions), 1)
	testing.expect_value(t, state.project.atlases[0].data.regions[0].rect[0], 0)
	for a, i in state.project.assets do if a.kind == .Atlas {
		testing.expect_value(t, Project_RemoveAsset(&state.project, i, false), "")
		break
	}
	testing.expect_value(t, len(state.project.atlases), 0)
}
