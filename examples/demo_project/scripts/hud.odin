package scripts

import "core:fmt"
import e "engine:."
import sdl "vendor:sdl3"

/*
Hud: the levels' heads-up display, components/hud.component.xml: UI controls on a screen layer
(the camera doesn't move them), themed by themes/legacy.theme.xml. This script fills them in:

- hearts: a ProgressBar (its fill a picture from the HUD sheet), which trails a hit (the bar
  drains to the new value) and the count beside it;
- coins, gems (this level's: found of how many its LDtk level hides) and the score: RichText;
- a toast in the middle (the level's name, "Progress saved"), faded in and out by tweens
  (`Hud_Toast`);
- a blip as each dialogue line starts: the DialogueBox's onLine event, listened to in the
  component file (`<listener event="onLine" target=".." handler="onDialogueLine"/>`).
*/
Hud :: struct {
	using script: e.Script,
	health: ^e.ProgressBar `export:"default=Stats/Health"`,
	healthText: ^e.RichText `export:"default=Stats/HealthText"`,
	coins: ^e.RichText `export:"default=Stats/Coins"`,
	gems: ^e.RichText `export:"default=Stats/Gems"`,
	gemIcon: ^e.Control `export:"default=Stats/GemIcon"`,
	score: ^e.RichText `export:"default=ScoreBox/Score"`,
	toast: ^e.RichText `export:"default=Toast"`,
	// What the health bar shows: it drains toward the real value after a hit
	shownHealth: f32,
	// Seconds the toast stays
	toastTime: f32,
	// What the texts last said (set only when it changes)
	last: [4]int,
}

/*
Shows a line in the middle of the screen for a few seconds.

Inputs:
- scene: A level scene (its HUD)
- text: The line (RichText tags work)
*/
Hud_Toast :: proc(scene: ^e.Scene, text: string) {
	node := e.Scene_FindNode(scene, "HUD")
	if node == nil do return
	hud := e.Node_GetScript(node, Hud)
	if hud == nil || hud.toast == nil do return
	e.Control_SetText(hud.toast, fmt.tprintf("[size=34]%s[/size]", text))
	hud.toast.visible = true
	hud.toastTime = 2.6
	hud.toast.tint.a = 0
	e.Tween_To(e.Tween_Create(hud.toast), &hud.toast.tint, sdl.Color{255, 255, 255, 255}, 0.4, .OutQuad)
}

@(init)
register_Hud :: proc "contextless" () {
	e.Script_Register(Hud, {
		ready = proc(self: ^Hud) {
			if state := State(); state != nil do self.shownHealth = f32(state.health)
			if self.toast != nil do self.toast.visible = false
			self.last = {-1, -1, -1, -1}
		},
		update = proc(self: ^Hud, _: []sdl.Event, deltaTime: f64) {
			state := State()
			if state == nil do return
			dt := f32(deltaTime)
			target := f32(state.health)
			self.shownHealth = self.shownHealth > target ? max(self.shownHealth - dt * 3, target) : target
			if self.health != nil {
				self.health.settings.maxValue = f32(state.maxHealth)
				e.ProgressBar_SetValue(self.health, self.shownHealth)
			}
			// This level's gems: how many its LDtk level has, less the ones still in it (taken ones go)
			total, gems := 0, 0
			if level := LevelNode(self.scene); level != nil && len(level.views) > 0 {
				for layer in level.views[0].level.layers do for entity in layer.entities do if entity.identifier == "Gem" do total += 1
				gems = total - len(e.LDtk_FindEntityNodes(level, "Gem"))
			}
			if self.gems != nil && self.gemIcon != nil do self.gems.visible, self.gemIcon.visible = total > 0, total > 0
			values := [4]int{state.health, state.run.coins, gems, state.run.score}
			if values[0] != self.last[0] && self.healthText != nil do e.Control_SetText(self.healthText, fmt.tprintf("%d/%d", state.health, state.maxHealth))
			if values[1] != self.last[1] && self.coins != nil do e.Control_SetText(self.coins, fmt.tprintf("%d", state.run.coins))
			if values[2] != self.last[2] && self.gems != nil do e.Control_SetText(self.gems, fmt.tprintf("%d/%d", max(gems, 0), total))
			if values[3] != self.last[3] && self.score != nil do e.Control_SetText(self.score, fmt.tprintf("[color=#7a6040]Score[/color] %d", state.run.score))
			self.last = values
			if self.toast != nil && self.toast.visible {
				self.toastTime -= dt
				if self.toastTime <= 0 {
					self.toast.tint.a = u8(clamp(255 + self.toastTime * 400, 0, 255))
					if self.toastTime < -0.65 do self.toast.visible = false
				}
			}
		},
	})
}

// A dialogue line began: a soft blip (the HUD's DialogueBox's onLine, a listener in hud.component.xml)
Hud_onDialogueLine :: proc(self: ^Hud, source: ^e.Node, data: e.EventData) {
	Sfx(self.game, SOUND_DIALOGUE_BLIP, 0.5)
}

@(init)
register_Hud_onDialogueLine :: proc "contextless" () {
	e.Script_Listener(Hud, "onDialogueLine", Hud_onDialogueLine)
}
