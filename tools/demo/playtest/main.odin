/*
The demo's playtest: plays examples/demo_project headless, with the player's own engine and the
demo's scripts, by pressing keys (SDL key events, as a player's would arrive), and checks what
happens: the title, a new game's opening dialogue, moving, jumping, attacking, stomping, being
hurt, picking things up, rune stones saving, the pause menu, the options (volumes, a rebound
key), each level played through by a simple bot to its exit, the boss's phases and defeat, the
game over and victory screens. Frames are saved as PNG files from the engine's own renderer
(SDL's software renderer on an offscreen window), never from the desktop.

	SDL_VIDEO_DRIVER=offscreen SDL_AUDIO_DRIVER=dummy \
	odin run tools/demo/playtest -collection:engine=../odin_sdl_engine \
		-collection:project=examples/demo_project -- examples/demo_project build/playtest

(`task demo:playtest` does it.) The exit code is the number of failed checks. Saves go to their
own folder ("Legacy Playtest"), so a player's saves aren't touched.
*/
package playtest

import "core:fmt"
import "core:log"
import "core:math"
import "core:os"
import "core:strconv"
import "core:strings"
import e "engine:."
import scripts "project:scripts"
import sdl "vendor:sdl3"

DT :: 1.0 / 60

Harness :: struct {
	app: e.Application,
	game: ^e.Game,
	out: string,
	frame: int,
	failures: int,
	checks: int,
	// Keys held now, and last frame
	held, wasHeld: map[sdl.Scancode]bool,
	pending: [dynamic]sdl.Event,
}

h: Harness

check :: proc(ok: bool, what: string, args: ..any) {
	h.checks += 1
	text := fmt.tprintf(what, ..args)
	if ok {
		fmt.printfln("  ok    %s", text)
	} else {
		h.failures += 1
		fmt.printfln("  FAIL  %s", text)
	}
}

scene :: proc() -> ^e.Scene {
	return h.game.currentScene
}

sceneName :: proc() -> string {
	return scene() != nil ? scene().name : ""
}

// One frame: this frame's key events, an update of 1/60 s, a draw
step :: proc(frames := 1) {
	for _ in 0 ..< frames {
		for key, down in h.held do if down && !h.wasHeld[key] do append(&h.pending, keyEvent(key, true))
		for key, down in h.wasHeld do if down && !h.held[key] do append(&h.pending, keyEvent(key, false))
		clear(&h.wasHeld)
		for key, down in h.held do h.wasHeld[key] = down
		game := h.game
		game->update(h.pending[:], DT)
		clear(&h.pending)
		// Drawing is slow on the software renderer: every frame only when asked (pictures draw
		// their own frame), else one in ten, so drawing code still runs all along
		if h.frame % 10 == 0 do draw()
		free_all(context.temp_allocator)
		h.frame += 1
		if game.shouldQuit {
			fmt.printfln("  (the game asked to quit, frame %d, scene %s)", h.frame, sceneName())
			return
		}
	}
}

// Draws the game's frame (as the player's frame loop does)
draw :: proc() {
	game := h.game
	clearColor := game.backgroundColor
	if game.currentScene != nil do if c, set := game.currentScene.background.?; set do clearColor = c
	sdl.SetRenderDrawColor(h.app.renderer, clearColor.r, clearColor.g, clearColor.b, clearColor.a)
	sdl.RenderClear(h.app.renderer)
	game->draw()
	sdl.RenderPresent(h.app.renderer)
}

keyEvent :: proc(key: sdl.Scancode, down: bool) -> sdl.Event {
	ev: sdl.Event
	ev.key.type = down ? .KEY_DOWN : .KEY_UP
	ev.key.scancode = key
	ev.key.down = down
	return ev
}

hold :: proc(key: sdl.Scancode) { h.held[key] = true }
release :: proc(key: sdl.Scancode) { h.held[key] = false }
releaseAll :: proc() { clear(&h.held) }

// A key pressed for a few frames, then let go (and a frame for it to be seen)
tap :: proc(key: sdl.Scancode, frames := 3) {
	hold(key)
	step(frames)
	release(key)
	step(2)
}

// Steps until `done` holds (or `seconds` pass); whether it did
waitFor :: proc(done: proc() -> bool, seconds: f32) -> bool {
	for _ in 0 ..< int(seconds * 60) {
		if done() do return true
		step()
	}
	return done()
}

// Saves the renderer's picture as a PNG in the output folder
capture :: proc(name: string) {
	draw()
	surface := sdl.RenderReadPixels(h.app.renderer, nil)
	if surface == nil {
		fmt.printfln("  (no picture for %s: %s)", name, sdl.GetError())
		return
	}
	defer sdl.DestroySurface(surface)
	rgba := sdl.ConvertSurface(surface, .RGBA32)
	defer sdl.DestroySurface(rgba)
	path := fmt.ctprintf("%s/%s.png", h.out, name)
	if !sdl.SavePNG(rgba, path) do fmt.printfln("  (couldn't save %s: %s)", path, sdl.GetError())
	else do fmt.printfln("  saved %s", path)
}

// The share of a picture's pixels that aren't the scene's background (a blank frame is ~0)
picturedShare :: proc() -> f32 {
	draw()
	surface := sdl.RenderReadPixels(h.app.renderer, nil)
	if surface == nil do return 0
	defer sdl.DestroySurface(surface)
	rgba := sdl.ConvertSurface(surface, .RGBA32)
	defer sdl.DestroySurface(rgba)
	pixels := ([^]u8)(rgba.pixels)
	first := [4]u8{pixels[0], pixels[1], pixels[2], pixels[3]}
	differ, total := 0, 0
	for y := 0; y < int(rgba.h); y += 8 {
		for x := 0; x < int(rgba.w); x += 8 {
			p := pixels[y * int(rgba.pitch) + x * 4:]
			pixel := [4]u8{p[0], p[1], p[2], p[3]}
			if pixel != first do differ += 1
			total += 1
		}
	}
	return f32(differ) / f32(max(total, 1))
}

find :: proc(path: string) -> ^e.Node {
	return scene() != nil ? e.Scene_FindNode(scene(), path) : nil
}

hero :: proc() -> ^scripts.Hero { return scripts.currentHero }
state :: proc() -> ^scripts.GameState { return scripts.State() }

heroAt :: proc() -> [2]f32 {
	if hero() == nil do return {}
	return scripts.Hero_Feet(hero())
}

// Puts the hero somewhere in the level (cells), standing still
teleport :: proc(cell: [2]f32) {
	if hero() == nil do return
	mover := scripts.Hero_Mover(hero())
	mover.position = cell * 16 + {8, 0}
	mover.velocity = {}
	hero().safe = mover.position
	if scene().camera != nil do e.Camera2D_SnapTo(scene().camera, mover.position)
}

// Waits for a scene (through the transition and the loading screen) and its hero
enterScene :: proc(name: string, seconds: f32 = 8) -> bool {
	@(static) want: string
	want = name
	ok := waitFor(proc() -> bool { return sceneName() == want && !e.Game_IsChangingScene(h.game) }, seconds)
	if ok && scripts.IsLevel(name) do ok = waitFor(proc() -> bool { return hero() != nil }, 2)
	step(5)
	return ok
}

// Plays a dialogue through: Enter until it ends (the first option each time, unless told)
finishDialogue :: proc(pick := 0, seconds: f32 = 40) -> int {
	choice := pick
	lines := 0
	for _ in 0 ..< int(seconds * 60 / 6) {
		if !scripts.Dialogue_Playing(scene()) do break
		box := level().box
		if box != nil && box.runner.state == .Options && choice > 0 {
			for _ in 0 ..< choice do tap(.DOWN, 2)
			choice = 0
		}
		tap(.RETURN, 2)
		lines += 1
		step(2)
	}
	step(10)
	return lines
}

level :: proc() -> ^scripts.Level {
	return scripts.Level_Get(scene())
}

main :: proc() {
	// The engine's and the scripts' warnings and errors show (info is too chatty here)
	context.logger = log.create_console_logger(.Warning, {.Level})
	args := os.args
	project := len(args) > 1 ? args[1] : "examples/demo_project"
	h.out = len(args) > 2 ? args[2] : "build/playtest"
	only := len(args) > 3 ? args[3] : ""
	os.make_directory(h.out)
	h.held = make(map[sdl.Scancode]bool)
	h.wasHeld = make(map[sdl.Scancode]bool)

	// The software renderer unless PLAYTEST_RENDERER names another ("gpu": the hit flash's shader runs)
	renderer := os.get_env("PLAYTEST_RENDERER", context.temp_allocator)
	options := e.PlayerOptions{projectDir = project, folderGiven = true, renderer = renderer != "" ? renderer : "software"}
	if !e.Player_Setup(options, &h.app) {
		fmt.println("Couldn't start the demo")
		os.exit(1)
	}
	h.game = h.app.queuedGame
	h.app.game = h.game
	h.app.queuedGame = nil
	e.Game_Init(h.game, h.app.window, h.app.renderer, h.app.mixer)
	// Its own saves: a player's aren't touched (and every run starts without one)
	h.game.name = "Legacy Playtest"
	for slot in ([]string{"save", "bindings"}) do e.Save_Delete(slot, h.game)
	scripts.State().saved = {}
	e.Input_ResetBindings()
	step(2)

	fmt.printfln("Playtest of %s (frames saved in %s)", project, h.out)
	if only == "" || strings.contains(only, "title") do titleAndOptions()
	if only == "" || strings.contains(only, "forest") do forest()
	if only == "" || strings.contains(only, "hollow") do hollow()
	if only == "" || strings.contains(only, "lair") do lair()
	if only == "" || strings.contains(only, "gameover") do gameOver()
	if only == "views" do views(args[4:])

	fmt.printfln("\n%d checks, %d failed", h.checks, h.failures)
	for slot in ([]string{"save", "bindings"}) do e.Save_Delete(slot, h.game)
	e.Application_Cleanup(&h.app)
	os.exit(h.failures)
}

// --- The title, the options -----------------------------------------------------------------

titleAndOptions :: proc() {
	fmt.println("\nThe title screen")
	check(enterScene("TitleScene"), "the game starts on the title screen")
	step(90)
	capture("01_title")
	check(picturedShare() > 0.5, "the title screen draws its forest and menu (%.0f%% of the picture)", picturedShare() * 100)
	cont := find("Menu/Continue")
	check(cont != nil && !cont.visible, "no save: Continue is hidden")
	focused := e.Control_Focused(scene())
	check(focused != nil && focused.name == "NewGame", "New Game has the focus")
	// Down to Options, Enter: the options open over the title
	tap(.DOWN)
	tap(.DOWN)
	focused = e.Control_Focused(scene())
	check(focused != nil && focused.name == "Credits", "the arrows move the focus (now on %s)", focused != nil ? focused.name : "nothing")
	tap(.UP)
	tap(.RETURN)
	step(10)
	top := e.Game_TopScene(h.game)
	check(top != nil && top.name == "OptionsScene", "Options opens over the title")
	step(20)
	capture("02_options")
	options()
	tap(.ESCAPE)
	step(10)
	top = e.Game_TopScene(h.game)
	check(top != nil && top.name == "TitleScene", "Escape closes the options")
	// The credits roll, and close
	tap(.DOWN)
	tap(.RETURN)
	step(120)
	top = e.Game_TopScene(h.game)
	check(top != nil && top.name == "CreditsScene", "Credits opens over the title")
	capture("03_credits")
	tap(.ESCAPE)
	step(10)
}

options :: proc() {
	st := state()
	music := find("Panel/Music/Slider")
	if music == nil do music = e.Scene_FindNode(e.Game_TopScene(h.game), "Panel/Music/Slider")
	top := e.Game_TopScene(h.game)
	slider := cast(^e.Slider)e.Scene_FindNode(top, "Panel/Music/Slider")
	check(slider != nil && e.Control_Focused(top) == slider, "the music slider has the focus")
	before := st.musicVolume
	tap(.LEFT)
	tap(.LEFT)
	check(st.musicVolume < before - 0.05, "Left turns the music down (%.2f -> %.2f)", before, st.musicVolume)
	bus := e.Audio_GetBus("Music", h.game)
	check(bus != nil && abs(bus.volume - st.musicVolume) < 0.001, "the Music bus follows (%.2f)", bus != nil ? bus.volume : -1)
	// To the sounds slider, down too
	tap(.DOWN)
	before = st.sfxVolume
	tap(.LEFT)
	check(st.sfxVolume < before, "the sounds slider turns the SFX bus down (%.2f)", e.Audio_GetBus("SFX", h.game).volume)
	// Rebinding jump: its keyboard button, then K... then back to Space
	jump := cast(^e.Button)e.Scene_FindNode(top, "Panel/Controls/Jump/Key")
	check(jump != nil, "the controls list jump's keyboard binding")
	if jump != nil {
		// Down the list with the keys: the scroll box scrolls to the hidden rows
		for _ in 0 ..< 12 {
			if e.Control_Focused(top) == jump do break
			tap(.DOWN, 2)
		}
		check(e.Control_Focused(top) == jump && !jump.clipped, "the keys reach it down the scrolling list")
		tap(.RETURN)
		step(2)
		check(e.Input_IsCapturing(h.game), "pressing it waits for a key")
		tap(.L)
		step(4)
		bindings := e.Input_GetBindings(scripts.ACTION_JUMP, h.game)
		hasL := false
		for b in bindings do if b == e.InputBinding(e.KeyBinding{.L}) do hasL = true
		check(hasL, "jump is now L (%v)", bindings)
		check(strings.contains(jump.text, "L"), "the button says so (%s)", jump.text)
		reset := cast(^e.Button)e.Scene_FindNode(top, "Panel/Buttons/Reset")
		for _ in 0 ..< 12 {
			if e.Control_Focused(top) == reset do break
			tap(.DOWN, 2)
		}
		tap(.RETURN)
		step(2)
		hasSpace := false
		for b in e.Input_GetBindings(scripts.ACTION_JUMP, h.game) do if b == e.InputBinding(e.KeyBinding{.Space}) do hasSpace = true
		check(hasSpace, "Reset puts Space back")
	}
	st.musicVolume, st.sfxVolume = 0.8, 0.9
	scripts.GameState_ApplySettings(st)
}

// --- The forest ------------------------------------------------------------------------------

forest :: proc() {
	fmt.println("\nA new game: the Whispering Woods")
	if sceneName() != "TitleScene" {
		e.Game_ChangeScene(h.game, "TitleScene")
		enterScene("TitleScene")
	}
	e.Control_Focus(scene(), cast(^e.Control)find("Menu/NewGame"))
	step(2)
	tap(.RETURN)
	sawLoading := waitFor(proc() -> bool { return sceneName() == "LoadingScene" }, 3)
	check(sawLoading, "the loading screen shows on the way")
	if sawLoading {
		step(10)
		capture("04_loading")
	}
	check(enterScene("ForestScene", 10), "New Game starts the forest")
	st := state()
	check(st != nil && st.saved.level == "ForestScene", "a new game is saved at once (%s)", st.saved.level)
	check(scripts.Dialogue_Playing(scene()), "the opening dialogue plays")
	check(st.cutscene > 0, "the hero waits while it plays")
	step(80)
	capture("05_intro_dialogue")
	lines := finishDialogue(pick = 1)
	check(!scripts.Dialogue_Playing(scene()) && st.cutscene == 0, "the dialogue ends (%d presses) and the hero is free", lines)
	step(30)
	capture("06_forest_start")

	mechanics()
	// Then the whole level, from its start
	teleport({5, 23})
	step(10)
	playLevel("ForestScene", "HollowScene", 200)
}

// The hero's moves, one by one
mechanics :: proc() {
	st := state()
	// Running right: she speeds up, then keeps her top speed.
	// Safe while her moves are measured (a snail's touch would stop the game for a hitstop), on
	// the step after the first pit: flat, and no creature reaches it
	st.invulnerable = 60
	teleport({38, 21})
	step(20)
	start := heroAt()
	hold(.D)
	step(3)
	early := scripts.Hero_Mover(hero()).velocity.x
	step(35)
	top := scripts.Hero_Mover(hero()).velocity.x
	release(.D)
	check(early > 20 && early < top && abs(top - hero().speed) < 1, "running speeds up (%.0f, then %.0f px/s)", early, top)
	check(heroAt().x > start.x + 60, "and moves her right (%.0f px)", heroAt().x - start.x)
	step(20)
	check(abs(scripts.Hero_Mover(hero()).velocity.x) < 1, "she stops when let go")
	check(e.StateMachine_Is(hero().brain, "idle"), "the state machine is back in idle (%s)", e.StateMachine_Current(hero().brain))

	// A held jump goes higher than a tap
	floor := heroAt().y
	hold(.SPACE)
	highest := floor
	for _ in 0 ..< 60 {
		step()
		highest = min(highest, heroAt().y)
	}
	release(.SPACE)
	step(40)
	held := floor - highest
	tap(.SPACE, 2)
	highest = floor
	for _ in 0 ..< 50 {
		step()
		highest = min(highest, heroAt().y)
	}
	step(30)
	short := floor - highest
	check(held > 60 && held < 100, "a held jump rises %.0f px (about 4-5 cells)", held)
	check(short < held * 0.7, "a tapped one less (%.0f px)", short)
	check(abs(heroAt().y - floor) < 1, "and she lands where she was")

	// Jump buffering: pressed just before landing, it still jumps
	hold(.SPACE)
	step(4)
	release(.SPACE)
	for _ in 0 ..< 90 {
		step()
		if scripts.Hero_Mover(hero()).velocity.y > 0 && heroAt().y > floor - 6 do break
	}
	tap(.SPACE, 2)
	step(6)
	check(scripts.Hero_Mover(hero()).velocity.y < 0 || heroAt().y < floor - 4, "a jump pressed just before landing is kept (buffered)")
	step(70)

	// The attack: the state machine plays it, the first snail takes hits and falls
	snailNode := firstEnemy("Snail")
	check(snailNode != nil, "a snail crawls nearby")
	if snailNode != nil {
		snail := e.Node_GetScript(snailNode, scripts.Snail)
		// Put her beside it, facing it
		at := e.Node_GetWorldPosition(snailNode)
		teleport({(at.x - 30) / 16, at.y / 16})
		hero().facing = 1
		st.invulnerable = 5
		hits := 0
		for _ in 0 ..< 8 {
			if snail == nil || !scripts.Enemy_Alive(&snail.enemy) do break
			hero().facing = e.Node_GetWorldPosition(snailNode).x > heroAt().x ? 1 : -1
			tap(.J, 2)
			step(30)
			hits += 1
		}
		check(snail == nil || !scripts.Enemy_Alive(&snail.enemy), "attacking defeats the snail (%d swings)", hits)
		check(st.run.score >= 10, "its points go to the score (%d)", st.run.score)
		step(60)
	}

	// Being hurt: a heart, a knockback, a moment of safety
	st.invulnerable = 0
	health := st.health
	scripts.Hero_Hurt(hero(), heroAt().x + 10)
	check(st.health == health - 1, "a hit takes a heart (%d -> %d)", health, st.health)
	check(scripts.Hero_Mover(hero()).velocity.x < 0, "and knocks her back")
	scripts.Hero_Hurt(hero(), heroAt().x + 10)
	check(st.health == health - 1, "she's safe for a moment after it")
	step(20)
	check(e.StateMachine_Is(hero().brain, "hurt") || e.StateMachine_Is(hero().brain, "idle") || e.StateMachine_Is(hero().brain, "fall"), "the hurt state played (%s)", e.StateMachine_Current(hero().brain))
	step(90)

	// Coins: touching one takes it (its Area's collisionEnter)
	st.invulnerable = 30
	coins := st.run.coins
	if coin := firstEntity("Coin"); coin != nil {
		at := e.Node_GetWorldPosition(coin)
		teleport({math.floor(at.x / 16), math.floor(at.y / 16) + 1})
		step(10)
		check(st.run.coins > coins, "a coin is picked up (%d)", st.run.coins)
	}

	// The pause menu: Escape opens it over the level, which stops; the music is muffled
	tap(.ESCAPE)
	step(10)
	paused := e.Game_TopScene(h.game)
	check(paused != nil && paused.name == "PauseScene", "Escape pauses")
	frozen := heroAt()
	hold(.D)
	step(20)
	release(.D)
	check(heroAt() == frozen, "the level stops under the pause menu")
	check(len(e.Audio_GetBusEffects("Music", h.game)) == 1, "the music goes muffled (a low-pass on its bus)")
	capture("07_pause")
	tap(.ESCAPE)
	step(10)
	paused = e.Game_TopScene(h.game)
	check(paused != nil && paused.name == sceneName() && sceneName() == "ForestScene", "Escape again resumes")
	check(len(e.Audio_GetBusEffects("Music", h.game)) == 0, "and the music is clear")
}

firstEntity :: proc(name: string) -> ^e.Node {
	lvl := scripts.LevelNode(scene())
	if lvl == nil do return nil
	nodes := e.LDtk_FindEntityNodes(lvl, name)
	return len(nodes) > 0 ? nodes[0] : nil
}

firstEnemy :: proc(name: string) -> ^e.Node {
	return firstEntity(name)
}

// --- A level played through ----------------------------------------------------------------

Bot :: struct {
	// The furthest she got, and when
	best: f32,
	bestFrame: int,
	stuck: int,
	jumpHeld: int,
	// Where the nearest platform was last frame (which way it's going)
	platformX: f32,
	// Frames since she jumped off a platform (no steering back onto it)
	leaving: int,
	// The plank she's climbing to (0: none)
	climbX: f32,
}


/*
Plays a level to its exit with a simple bot: run right, jump at walls, gaps and water, wait for
moving platforms over gaps, attack what's ahead. She's kept safe (the checks of hurting are
elsewhere): this is about the level being finishable. Where it can't get on, it's put a little
further and the place is reported, so the level's design can be looked at.
*/
playLevel :: proc(name, next: string, seconds: f32) -> bool {
	st := state()
	bot: Bot
	lvlSize := scripts.LevelSize(scene())
	shots := 0
	runestones := 0
	for i in 0 ..< int(seconds * 60) {
		if sceneName() != name do break
		if hero() == nil do break
		st.invulnerable = 2
		st.health = st.maxHealth
		if scripts.Dialogue_Playing(scene()) {
			releaseAll()
			tap(.RETURN, 2)
			continue
		}
		if e.Game_TopScene(h.game) != scene() {
			step()
			continue
		}
		drive(&bot)
		step()
		at := heroAt()
		if at.x > bot.best + 16 {
			bot.best = at.x
			bot.bestFrame = h.frame
		}
		if h.frame - bot.bestFrame > 60 * 6 {
			fmt.printfln("  (stuck near cell %.0f, %.0f: moved on)", at.x / 16, at.y / 16)
			if pl := nearestPlatform(at); pl != nil do fmt.printfln("   (the nearest platform is at %v; she's at %v, on the floor: %v)", e.Node_GetWorldPosition(pl), at, scripts.Hero_Mover(hero()).onFloor)
			capture(fmt.tprintf("stuck_%s_%d", name, bot.stuck))
			bot.stuck += 1
			teleportAhead(at)
			bot.bestFrame = h.frame
		}
		if st.run.checkpoint != "" && runestones == 0 {
			runestones = 1
		}
		// A picture every so often
		if i % (60 * 12) == 300 && shots < 6 {
			capture(fmt.tprintf("%s_%d", strings.to_lower(name[:len(name) - 5], context.temp_allocator), shots))
			shots += 1
		}
		_ = lvlSize
	}
	releaseAll()
	reached := enterScene(next, 12)
	check(reached, "%s is played through to %s (stuck %d times)", name, next, bot.stuck)
	check(bot.stuck <= 2, "the bot got through %s nearly on its own (%d)", name, bot.stuck)
	return reached
}

// Moves her on past where she got stuck: the next cell to the right she can stand on
teleportAhead :: proc(at: [2]f32) {
	cell := [2]int{int(at.x / 16), int(at.y / 16)}
	for dx in 3 ..< 40 {
		for dy := -8; dy <= 8; dy += 1 {
			c := [2]f32{f32(cell.x + dx), f32(cell.y + dy)}
			feet := c * 16 + {8, 0}
			if !scripts.Level_Floor(scene(), feet + {0, 4}) || scripts.Level_Solid(scene(), feet - {0, 8}) || scripts.Level_Solid(scene(), feet - {0, 24}) do continue
			teleport(c)
			return
		}
	}
}

drive :: proc(bot: ^Bot) {
	sc := scene()
	hr := hero()
	mover := scripts.Hero_Mover(hr)
	feet := scripts.Hero_Feet(hr)
	ahead := feet + {14, 0}
	releaseAll()
	run := true
	jump := false

	wall := scripts.Level_Solid(sc, ahead - {0, 8}) || scripts.Level_Solid(sc, ahead - {0, 24})
	gap := !scripts.Level_Floor(sc, feet + {20, 6}) && !scripts.Level_Floor(sc, feet + {20, 22}) && !scripts.Level_Floor(sc, feet + {20, 38})
	water := e.LDtk_IntGridAtPosition(scripts.LevelNode(sc), "Ground", feet + {30, 8}) == scripts.GROUND_WATER || e.LDtk_IntGridAtPosition(scripts.LevelNode(sc), "Ground", feet + {30, 24}) == scripts.GROUND_WATER

	// A moving platform over the gap: wait at the edge until it comes (a jump at a run carries
	// about 110 px), then jump to it
	platform := nearestPlatform(feet)
	if (gap || water) && mover.onFloor && platform != nil {
		p := e.Node_GetWorldPosition(platform)
		d := p.x - feet.x
		coming := p.x < bot.platformX - 0.01
		run = false
		if (coming && d > 60 && d < 120) || (!coming && d > 20 && d < 70) do jump, run = true, true
		if abs(p.y - feet.y) > 40 && abs(d) < 40 do jump, run = true, false
	} else if mover.onFloor && (wall || gap || water) {
		jump = true
	}
	if platform != nil do bot.platformX = e.Node_GetWorldPosition(platform).x
	// On a platform: ride it until ground is in reach ahead (or, rising, until the ledge is)
	if platform != nil && mover.onFloor {
		p := e.Node_GetWorldPosition(platform)
		if abs(p.x - feet.x) < 30 && abs(p.y - 13 - feet.y) < 8 {
			reach := false
			for dx := f32(24); dx <= 88; dx += 8 {
				for dy := f32(-48); dy <= 16; dy += 16 {
					if scripts.Level_Floor(sc, feet + {dx, dy + 4}) && !scripts.Level_Solid(sc, feet + {dx, dy - 8}) do reach = true
				}
			}
			run = !(gap || water) || reach
			jump = (gap || water || wall) && reach
			if jump do bot.leaving = 50
		}
	}
	// A wall too tall to jump: climb the planks (a floor up to 4 cells higher, near), one by one
	tall := true
	for dy := f32(8); dy <= 72; dy += 16 do if !scripts.Level_Solid(sc, ahead - {0, dy}) do tall = false
	if wall && tall && mover.onFloor {
		best: [2]f32
		bestScore := f32(1e9)
		for cy := 2; cy <= 4; cy += 1 {
			for cx := -7; cx <= 7; cx += 1 {
				at := feet + {f32(cx) * 16, -f32(cy) * 16}
				if !scripts.Level_Floor(sc, at + {0, 4}) || scripts.Level_Solid(sc, at - {0, 8}) || scripts.Level_Solid(sc, at - {0, 24}) do continue
				score := abs(f32(cx)) - f32(cy) * 0.5
				if score < bestScore do best, bestScore = at, score
			}
		}
		if bestScore < 1e9 {
			run = false
			d := best.x - feet.x
			if abs(d) > 12 {
				hold(d > 0 ? .D : .A)
			} else {
				jump = true
			}
			bot.climbX = best.x
		}
	}
	// Jumping up to a plank: steer under it
	if !mover.onFloor && bot.climbX != 0 {
		run = false
		if feet.x < bot.climbX - 4 do hold(.D)
		if feet.x > bot.climbX + 4 do hold(.A)
	}
	if mover.onFloor && !jump do bot.climbX = 0
	if jump do bot.jumpHeld = 18
	if bot.jumpHeld > 0 {
		bot.jumpHeld -= 1
		hold(.SPACE)
	}
	// In the air over a platform's gap: steer onto the platform
	steer := false
	if bot.leaving > 0 do bot.leaving -= 1
	if !mover.onFloor && platform != nil && bot.leaving == 0 {
		p := e.Node_GetWorldPosition(platform)
		if p.y > feet.y - 8 && abs(p.x - feet.x) < 140 && !scripts.Level_Floor(sc, {feet.x, p.y}) {
			steer = true
			if feet.x < p.x - 6 do hold(.D)
			if feet.x > p.x + 6 do hold(.A)
		}
	}
	if run && !steer do hold(.D)
	// Something to fight ahead: swing
	for enemy in scripts.liveEnemies {
		if !scripts.Enemy_Alive(enemy) do continue
		d := scripts.Enemy_Center(enemy) - scripts.Hero_Center(hr)
		if d.x > -10 && d.x < 50 && abs(d.y) < 40 && h.frame % 20 == 0 do hold(.J)
	}
	// Lore stones and dialogue are read on the way? No: the bot doesn't stop to read
}

nearestPlatform :: proc(feet: [2]f32) -> ^e.Node {
	lvl := scripts.LevelNode(scene())
	if lvl == nil do return nil
	best: ^e.Node
	bestDistance := f32(200)
	for node in e.LDtk_FindEntityNodes(lvl, "Platform") {
		p := e.Node_GetWorldPosition(node)
		d := abs(p.x - feet.x) + abs(p.y - feet.y) * 0.5
		if d < bestDistance && p.x > feet.x - 40 {
			best, bestDistance = node, d
		}
	}
	return best
}

// --- The hollow ------------------------------------------------------------------------------

hollow :: proc() {
	fmt.println("\nThe Shadowed Hollow")
	if sceneName() != "HollowScene" {
		start("HollowScene")
	}
	sc := scene()
	check(sc != nil && sc.lighting.enabled, "the hollow is lit by lights (2D lighting on)")
	check(hero() != nil && hero().lantern != nil && hero().lantern.visible, "her lantern is on")
	check(len(e.Audio_GetBusEffects("SFX", h.game)) == 1, "sounds echo in the caves (a reverb on the SFX bus)")
	step(60)
	capture("10_hollow_start")
	// Into the caves: a picture where it's dark and lit
	teleport({70, 39})
	step(60)
	capture("11_hollow_cave")
	// A hunting bee finds its way to her
	bee: ^scripts.Bee
	for enemy in scripts.liveEnemies {
		if b := e.Node_GetScript(enemy.node, scripts.Bee); b != nil && b.chase && bee == nil && e.Scene_FindNavRegion(scene(), e.Node_GetWorldPosition(b.node)) != nil do bee = b
	}
	check(bee != nil, "bees in the caves hunt")
	if bee != nil {
		at := e.Node_GetWorldPosition(bee.node)
		teleport({math.floor(at.x / 16) - 6, 39})
		state().invulnerable = 10
		start := e.Node_GetWorldPosition(bee.node)
		step(90)
		end := e.Node_GetWorldPosition(bee.node)
		target := scripts.Hero_Center(hero())
		check(abs(end.x - target.x) + abs(end.y - target.y) < abs(start.x - target.x) + abs(start.y - target.y) - 20, "a hunting bee comes for her through the cave (NavAgent)")
	}
	teleport({5, 17})
	step(20)
	playLevel("HollowScene", "LairScene", 200)
}

// --- The lair and the boss -------------------------------------------------------------------

lair :: proc() {
	fmt.println("\nThe Heart of the Forest")
	if sceneName() != "LairScene" do start("LairScene")
	st := state()
	step(60)
	capture("12_lair_start")
	// Walk into the arena: the gate drops, the boss's entrance plays, its speech
	teleport({40, 23})
	hold(.D)
	ok := waitFor(proc() -> bool { return state().cutscene > 0 }, 6)
	release(.D)
	check(ok, "walking into the arena starts the boss's entrance")
	waitFor(proc() -> bool { return scripts.Dialogue_Playing(scene()) }, 6)
	capture("13_boss_intro")
	finishDialogue()
	boss := scripts.currentBoss
	check(boss != nil && boss.mode != .Asleep, "the fight starts after the speech (%v)", boss != nil ? boss.mode : scripts.BossMode.Asleep)
	gateClosed := false
	if lvl := scripts.LevelNode(scene()); lvl != nil {
		for node in e.LDtk_FindEntityNodes(lvl, "Gate") do if g := e.Node_GetScript(node, scripts.Gate); g != nil && g.closed do gateClosed = true
	}
	check(gateClosed, "the gate dropped behind her")
	bar := find("HUD/BossBar")
	check(bar != nil && bar.visible, "the boss's health shows")
	// Fight: she stays safe and swings whenever it's close; the phases come as its health falls
	phases := [4]bool{}
	stunned := false
	for i in 0 ..< 60 * 120 {
		if boss == nil || scripts.Boss_Defeated(boss) do break
		st.invulnerable = 2
		st.health = st.maxHealth
		phases[boss.phase] = true
		if boss.mode == .Stunned do stunned = true
		releaseAll()
		d := e.Node_GetWorldPosition(boss.node).x - heroAt().x
		hero().facing = d > 0 ? 1 : -1
		if abs(d) > 60 do hold(d > 0 ? .D : .A)
		if abs(d) < 90 && i % 16 == 0 do hold(.J)
		if i == 60 * 8 do capture("14_boss_fight")
		step()
	}
	releaseAll()
	check(boss != nil && scripts.Boss_Defeated(boss), "the boss is defeated")
	check(phases[1] && phases[2] && phases[3], "through all three phases (%v)", phases)
	check(stunned, "it was stunned by a wall at least once")
	step(60)
	capture("15_boss_defeated")
	ok = waitFor(proc() -> bool { return scripts.Dialogue_Playing(scene()) }, 8)
	check(ok, "the ending plays")
	finishDialogue()
	check(enterScene("VictoryScene", 8), "then the victory screen")
	step(90)
	capture("16_victory")
	stats := find("Panel/Stats")
	check(stats != nil && strings.contains((cast(^e.RichText)stats).text, "Score"), "with the run's totals")
	check(!scripts.GameState_CanContinue(st) && st.finished, "the story is over: no Continue, the best score kept (%d)", st.bestScore)
}

// Starts a level directly (a fresh run there), as the editor's Play Scene would
start :: proc(name: string) {
	st := state()
	delete(st.run.level)
	delete(st.run.checkpoint)
	st.run.level = strings.clone(name)
	st.run.checkpoint = {}
	st.health = st.maxHealth
	e.Game_ChangeScene(h.game, name)
	enterScene(name, 10)
	step(10)
	for scripts.Dialogue_Playing(scene()) do finishDialogue()
}

// --- Falling: game over, retry from the rune stone ------------------------------------------

gameOver :: proc() {
	fmt.println("\nA defeat, and a retry from the rune stone")
	st := state()
	scripts.GameState_NewGame(st)
	enterScene("ForestScene", 10)
	finishDialogue()
	// Touch the first rune stone: saved there
	stone := firstEntity("Runestone")
	check(stone != nil, "the forest has rune stones")
	if stone == nil do return
	at := e.Node_GetWorldPosition(stone)
	teleport({math.floor(at.x / 16) - 3, math.floor(at.y / 16) - 1})
	hold(.D)
	ok := waitFor(proc() -> bool { return state().saved.checkpoint != "" }, 4)
	release(.D)
	check(ok, "touching a rune stone saves the run there")
	step(30)
	capture("08_runestone")
	coinsSaved := st.saved.coins
	st.run.coins += 7
	// Falling into a pit costs a heart and puts her back
	health := st.health
	safe := hero().safe
	teleport({32, 20})
	hero().safe = safe
	step(150)
	if st.health == health do diag("after the pit")
	check(st.health == health - 1, "a pit costs a heart (%d -> %d)", health, st.health)
	// Out of hearts: down, then the game over screen
	st.invulnerable = 0
	st.health = 1
	scripts.Hero_Hurt(hero(), heroAt().x + 10)
	check(hero().dead, "at no hearts she falls")
	check(enterScene("GameOverScene", 8), "the game over screen comes")
	step(60)
	capture("09_game_over")
	check(st.saved.deaths >= 1, "the fall is counted (%d)", st.saved.deaths)
	// Try again: back at the rune stone, what was gathered since lost
	tap(.RETURN)
	check(enterScene("ForestScene", 10), "Try again goes back to the level")
	step(10)
	near := hero() != nil && abs(heroAt().x - at.x) < 48
	check(near, "she starts at the rune stone (%.0f against %.0f)", heroAt().x, at.x)
	check(st.run.coins == coinsSaved, "with the coins she had there (%d)", st.run.coins)
	// Back on the title, Continue is offered
	e.Game_ChangeScene(h.game, "TitleScene")
	enterScene("TitleScene")
	step(30)
	cont := find("Menu/Continue")
	check(cont != nil && cont.visible, "with a save, the title offers Continue")
}

// Pictures of places: `views <Scene> <cellX> <cellY> [<Scene> <x> <y>...]` (for looking at levels)
views :: proc(places: []string) {
	for i := 0; i + 2 < len(places); i += 3 {
		name := places[i]
		if sceneName() != name do start(name)
		x, _ := strconv.parse_f32(places[i + 1])
		y, _ := strconv.parse_f32(places[i + 2])
		teleport({x, y})
		state().invulnerable = 10
		step(40)
		capture(fmt.tprintf("view_%s_%s_%s", name, places[i + 1], places[i + 2]))
	}
}

// What the game is doing (when a check fails for a reason that isn't clear)
diag :: proc(where_: string) {
	top := e.Game_TopScene(h.game)
	mover := hero() != nil ? scripts.Hero_Mover(hero()) : nil
	fmt.printfln("  (%s: scene %s, top %s, overlays %d, paused %v, changing %v, time scale %v, hitstop %v, cutscene %d, hero %v moving %v)",
		where_, sceneName(), top != nil ? top.name : "", len(h.game.flow.overlays), scene() != nil && scene().paused, e.Game_IsChangingScene(h.game),
		h.game.timeScale, h.game.hitStop, state().cutscene, heroAt(), mover != nil ? mover.velocity : [2]f32{})
	if mover != nil {
		for b in mover.touching do fmt.printfln("    touching %s (%v) at %v", b.name, b.kind, e.Node_GetWorldPosition(b))
		for a in e.PhysicsBody_GetAreas(mover) do fmt.printfln("    in the area %s", a.name)
		fmt.printfln("    floor %v wall %v ceiling %v", mover.onFloor, mover.onWall, mover.onCeiling)
	}
}

