package crossfire_editor

import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"
import e "engine:."

// A fresh folder under the system temp directory (temp allocated)
@(private="file")
indexTestDir :: proc(name: string) -> string {
	base, _ := os.temp_directory(context.temp_allocator)
	dir, _ := filepath.join({base, name}, context.temp_allocator)
	_ = removeAll(dir)
	_ = os.make_directory_all(dir)
	return dir
}

@(test)
constant_words_split_names :: proc(t: ^testing.T) {
	testing.expect_value(t, ConstantWords("bossBar"), "BOSS_BAR")
	testing.expect_value(t, ConstantWords("BossBar"), "BOSS_BAR")
	testing.expect_value(t, ConstantWords("boss_bar"), "BOSS_BAR")
	testing.expect_value(t, ConstantWords("HUDBar 2"), "HUD_BAR_2")
	testing.expect_value(t, ConstantWords("HUD"), "HUD")
	testing.expect_value(t, ConstantWords("ForestScene"), "FOREST_SCENE")
	testing.expect_value(t, ConstantWords("level2Boss"), "LEVEL2_BOSS")
	testing.expect_value(t, ConstantWords("-é-"), "UNNAMED")
	free_all(context.temp_allocator)
}

// A project with every kind of name the constants take
@(private="file")
constantsProject :: proc(dir: string) -> Project {
	project := Project_CreateTestProject(dir)
	play := &project.scenes[1] // PlayScene: World, Camera, Spaceship...
	world := 0
	for n, i in play.nodes do if n.name == "World" do world = i
	// Two names that make the same constant, and a group
	a := Scene_InsertNode(play, "Boss Bar", .Node2D, world)
	b := Scene_InsertNode(play, "BossBar", .Node2D, world)
	play.nodes[a].groups = strings.clone("enemies, flying")
	play.nodes[b].groups = strings.clone("enemies")
	// An AnimatedSprite with animations of its own
	sprite := Scene_InsertNode(play, "Flame", .AnimatedSprite, world)
	append(&play.nodes[sprite].animations, AnimationDef{name = strings.clone("burn")}, AnimationDef{name = strings.clone("fadeOut")})
	// A state machine
	brain := Scene_InsertNode(play, "Brain", .StateMachine, world)
	sm := &play.nodes[brain].stateMachine
	append(&sm.states, e.StateMachineState{name = strings.clone("idle")}, e.StateMachineState{name = strings.clone("run")})
	append(&sm.params, e.StateMachineParam{name = strings.clone("onFloor"), kind = .Bool})
	// A component, with a child, used in the scene
	coin := SceneDef{name = strings.clone("coin"), component = strings.clone("components/coin.component.xml")}
	root := Scene_InsertNode(&coin, "Coin", .Area, -1)
	_ = Scene_InsertNode(&coin, "Sprite", .Sprite, root)
	append(&project.scenes, coin)
	instance := Scene_InsertNode(&project.scenes[1], "Pickup", .Component, world)
	project.scenes[1].nodes[instance].component = strings.clone("components/coin.component.xml")
	// An animation set and a bus
	append(&project.animationSets, AnimationSetDef{path = strings.clone("animations/boar.anim.xml")})
	append(&project.animationSets[0].animations, AnimationDef{name = strings.clone("walk")}, AnimationDef{name = strings.clone("hit")})
	append(&project.buses, BusDef{name = strings.clone("SFX"), volume = 1})
	// A dialogue
	d := DialogueDef{path = strings.clone("dialogues/story.dialogue.xml")}
	append(&d.data.nodes, e.DialogueNode{name = strings.clone("Start")}, e.DialogueNode{name = strings.clone("Intro_Why")})
	append(&project.dialogues, d)
	return project
}

@(test)
generated_constants_name_everything :: proc(t: ^testing.T) {
	dir := indexTestDir("editor_test_constants")
	defer removeAll(dir)
	project := constantsProject(dir)
	defer Project_Destroy(&project)
	source := Scripts_AssetsSource(&project)
	want := []string{
		"ANIM_BOAR_WALK :: \"walk\"",
		"ANIM_BOAR_HIT :: \"hit\"",
		"ANIM_PLAY_SCENE_FLAME_BURN :: \"burn\"",
		"ANIM_PLAY_SCENE_FLAME_FADE_OUT :: \"fadeOut\"",
		"STATE_PLAY_SCENE_BRAIN_IDLE :: \"idle\"",
		"PARAM_PLAY_SCENE_BRAIN_ON_FLOOR :: \"onFloor\"",
		"GROUP_ENEMIES :: \"enemies\"",
		"GROUP_FLYING :: \"flying\"",
		"BUS_MASTER :: \"Master\"",
		"BUS_SFX :: \"SFX\"",
		"SCENE_PLAY_SCENE :: \"PlayScene\"",
		"SCENE_MENU_SCENE :: \"MenuScene\"",
		"DIALOGUE_NODE_STORY_START :: \"Start\"",
		"DIALOGUE_NODE_STORY_INTRO_WHY :: \"Intro_Why\"",
		// Scenes from their top level; an instance's nodes under it; components from their root
		"PATH_PLAY_SCENE_WORLD :: \"/World\"",
		"PATH_PLAY_SCENE_WORLD_PICKUP :: \"/World/Pickup\"",
		"PATH_PLAY_SCENE_WORLD_PICKUP_SPRITE :: \"/World/Pickup/Sprite\"",
		"PATH_COIN_SPRITE :: \"Sprite\"",
		// The collision: "/World/Boss Bar" sorts first and keeps the name
		"PATH_PLAY_SCENE_WORLD_BOSS_BAR :: \"/World/Boss Bar\"",
		"PATH_PLAY_SCENE_WORLD_BOSS_BAR_2 :: \"/World/BossBar\"",
		// Grouped under comments
		"// Scenes: e.Game_ChangeScene(game, SCENE_FOREST_SCENE)",
		"// - scene PlayScene",
		"// - component coin",
		"// - Brain in scene PlayScene",
	}
	for w in want do testing.expectf(t, strings.contains(source, w), "has %q", w)
	// Scenes aren't components' and a component's root has no path of its own
	testing.expect(t, !strings.contains(source, "SCENE_COIN"), "no scene constant for a component")
	testing.expect(t, !strings.contains(source, "PATH_COIN :: "), "no path for a component's root")
	// The sections keep their order: assets and actions first
	testing.expect(t, strings.index(source, "ACTION_") < strings.index(source, "ANIM_"), "actions before the new kinds")
	testing.expect(t, strings.index(source, "SCENE_") < strings.index(source, "PATH_"), "paths last")
	free_all(context.temp_allocator)
}

@(test)
generated_constants_are_deterministic :: proc(t: ^testing.T) {
	dir := indexTestDir("editor_test_constants_order")
	defer removeAll(dir)
	project := constantsProject(dir)
	defer Project_Destroy(&project)
	first := strings.clone(Scripts_AssetsSource(&project))
	defer delete(first)
	testing.expect_value(t, Scripts_AssetsSource(&project), first)
	// Siblings in another order (moved in the tree): the same file
	play := &project.scenes[1]
	a, b := -1, -1
	for n, i in play.nodes {
		if n.name == "Boss Bar" do a = i
		if n.name == "BossBar" do b = i
	}
	play.nodes[a], play.nodes[b] = play.nodes[b], play.nodes[a]
	testing.expect_value(t, Scripts_AssetsSource(&project), first)
	free_all(context.temp_allocator)
}

@(test)
generated_constants_of_an_empty_project :: proc(t: ^testing.T) {
	project: Project
	source := Scripts_AssetsSource(&project)
	// Only the header: no section comments without constants
	testing.expect(t, strings.has_prefix(source, ASSETS_FILE_MARKER), "the marker first")
	testing.expect(t, strings.has_suffix(source, "import e \"engine:.\"\n\n"), "nothing after the import")
	testing.expect(t, !strings.contains(source, "// Scenes"), "no empty sections")
	free_all(context.temp_allocator)
}

@(test)
constant_changes_that_need_a_build :: proc(t: ^testing.T) {
	dir := indexTestDir("editor_test_constant_changes")
	defer removeAll(dir)
	scripts := joinPath(dir, SCRIPTS_FOLDER, allocator = context.temp_allocator)
	_ = os.make_directory_all(scripts)
	binary := joinPath(dir, "player", allocator = context.temp_allocator)
	assets := joinPath(scripts, ASSETS_FILE, allocator = context.temp_allocator)
	write :: proc(path, text: string) { _ = os.write_entire_file(path, transmute([]u8)text) }
	HEADER :: ASSETS_FILE_MARKER + "\npackage scripts\n\nimport e \"engine:.\"\n\n"
	write(joinPath(scripts, "hero.odin", allocator = context.temp_allocator), "package scripts\nx := ANIM_HERO_RUN\n// PATH_HUD in a comment counts too: it's only text\n")
	write(assets, HEADER + "ANIM_HERO_RUN :: \"run\"\nPATH_OLD :: \"/Old\"\n")
	testing.expect(t, Constants_ChangeMatters(scripts, binary), "no snapshot: it matters")
	_ = os.write_entire_file(Constants_SnapshotPath(binary), transmute([]u8)string(HEADER + "ANIM_HERO_RUN :: \"run\"\nPATH_OLD :: \"/Old\"\n"))
	testing.expect(t, !Constants_ChangeMatters(scripts, binary), "unchanged")
	// A node added and one unused gone: no build needed
	write(assets, HEADER + "ANIM_HERO_RUN :: \"run\"\nPATH_NEW :: \"/New\"\n")
	testing.expect(t, !Constants_ChangeMatters(scripts, binary), "new and unused constants")
	// A used one changed: it matters
	write(assets, HEADER + "ANIM_HERO_RUN :: \"sprint\"\n")
	testing.expect(t, Constants_ChangeMatters(scripts, binary), "a used constant changed")
	write(assets, HEADER + "PATH_NEW :: \"/New\"\n")
	testing.expect(t, Constants_ChangeMatters(scripts, binary), "a used constant gone")
	free_all(context.temp_allocator)
}
