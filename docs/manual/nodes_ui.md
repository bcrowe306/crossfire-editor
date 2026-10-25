---
title: "Node guides: user interface"
description: "Guides for the user interface nodes: labels, menus, panels, buttons, bars, text fields, scroll boxes, rich text, sliders, check boxes, dialogue boxes and touch controls."
order: 50
---

# Node guides: user interface

These nodes make the parts of a game that aren't the world: titles, menus, HUDs, options screens,
conversations and on-screen touch controls. Each section below is one node kind's guide: what it
does, its properties, how to set it up in the editor, how a script reaches it, an example and its
API. The overview of every kind is [Node guides](nodes.md); the full stories are
[The UI system](ui.md), [Dialogue](dialogue.md) and [Touch controls and Steam](touch_and_steam.md).

- [Label](#label)
- [Menu](#menu)
- [Panel](#panel)
- [Button](#button)
- [ProgressBar](#progressbar)
- [TextField](#textfield)
- [ScrollBox](#scrollbox)
- [RichText](#richtext)
- [Slider](#slider)
- [CheckBox](#checkbox)
- [DialogueBox](#dialoguebox)
- [VirtualJoystick](#virtualjoystick)
- [TouchButton](#touchbutton)
- [Questions](#questions)

## Label

A Label draws one line of plain text in the built-in font: a title, a score, a hint. It follows
its parent's position but doesn't turn or scale with it. Text starting with `@` is a translation
key, shown in the player's language. For your own fonts, wrapping or several colors, use a
[RichText](#richtext) instead. In code it's an `e.Label`.

**Properties**

| Property | What it does |
|---|---|
| **Text** | The words shown, or `@key` for a translated text |
| **Font size** | The text's size |
| **Color** | Its color |
| **Centered** | Ticked: the text is centered on the node's position; unticked: its top-left corner is there |

**In the editor**

1. **Add Node** (Ctrl+Shift+A) > **Label** (under User interface). It needs no parent or children.
2. Type its **Text** and set **Font size**, **Color** and **Centered**.
3. Drag it into place in the viewport. If the scene has a camera and the text should stay put on
   the screen, give it a screen **Layer** (the scene's **Screen layers**).
4. **Play** (F5) and check it reads well at the game's resolution.

**From code**

A script gets it with a node field (`label: ^e.Label`) and sets `label.text`, `label.color`,
`label.size` or `label.centered`. A string you assign must outlive the label: text from
`fmt.tprintf` lasts only until the end of the frame, so set it every frame (as below) or keep the
string yourself. `e.CreateLabel(scene, text, pos, size, color)` makes one from code (and copies
the text).

**Example**

```odin
Countdown :: struct {
	using script: e.Script,
	label: ^e.Label `export:"default=Time"`,
	seconds: f32 `export:"default=60 min=0"`,
}

Countdown_update :: proc(self: ^Countdown, events: []sdl.Event, dt: f64) {
	if self.label == nil do return
	self.seconds = max(self.seconds - f32(dt), 0)
	// tprintf text lasts one frame: it's set again every frame
	self.label.text = fmt.tprintf("Time: %d", int(self.seconds))
	self.label.color = self.seconds < 10 ? {255, 80, 80, 255} : {255, 255, 255, 255}
}

@(init)
register_Countdown :: proc "contextless" () {
	e.Script_Register(Countdown, {update = Countdown_update})
}
```

**API**: [e.Label](https://crossfireengine.io/api/ui/#label),
[e.CreateLabel](https://crossfireengine.io/api/ui/#createlabel),
[e.Tr_Text](https://crossfireengine.io/api/text-and-fonts/#tr_text)

More: [Sprites and images](sprites_and_images.md#labels-text-on-the-screen),
[Localization](localization.md#keys-in-labels-buttons-and-menus)

## Menu

A Menu is a ready-made vertical list of rows with its own keyboard, gamepad and mouse
navigation. In a scene file its rows are buttons that switch scenes or quit; a script can add
labels, checkboxes, radios, sliders and select boxes. The node's position is the top middle of
its first row. For layouts of your own, use a [Panel](#panel) with [Buttons](#button). In code
it's an `e.Menu`.

**Properties**

| Property | What it does |
|---|---|
| Its buttons | The inspector lists each button's text and action (`scene:Level1`, `quit`). They can't be edited there yet: a new Menu has one button, `Button`, that quits |

**In the editor**

1. **Add Node** (Ctrl+Shift+A) > **Menu** (under User interface). It needs no parent or children.
2. Place it where the first row should be (its position is that row's top middle).
3. Change its buttons in the scene file (`<item label="Play" action="scene:Level1"/>` inside the
   node), or add rows from a script.
4. **Play** (F5): the arrow keys (or the project's `ui_*` actions), Enter and a click work it.

**From code**

A script on the Menu casts `self.node` (or uses a node field, `menu: ^e.Menu`). Add rows with
`e.Menu_AddLabel`, `e.Menu_AddButton`, `e.Menu_AddCheckbox`, `e.Menu_AddRadio`,
`e.Menu_AddSlider` and `e.Menu_AddSelect` (at most `MAX_MENU_ITEMS`, 32); each takes a callback
run when it's pressed or changes. `menu.onBack` runs on Escape / `ui_cancel`. Its events are
`onButtonPressed`, `onValueChanged`, `onFocusChanged` (data: the row's index) and
`onBackPressed`. `e.Menu_Command` drives it from code; `menu.style` (an `e.MenuStyle`) sets its
look.

**Example**

```odin
TitleMenu :: struct {
	using script: e.Script,
}

TitleMenu_ready :: proc(self: ^TitleMenu) {
	if !e.Node_Is(self.node, e.Menu) do return
	menu := cast(^e.Menu)self.node
	e.Menu_AddCheckbox(menu, "Fullscreen", e.Game_IsFullscreen(self.game), proc(menu: ^e.Menu, item: ^e.MenuItem) {
		e.Game_SetFullscreen(menu.scene.game, item.checked)
	})
	e.Menu_AddSlider(menu, "Music", 0.8, 0, 1, 0.1, proc(menu: ^e.Menu, item: ^e.MenuItem) {
		e.Audio_SetBusVolume("Music", item.value)
	})
}

@(init)
register_TitleMenu :: proc "contextless" () {
	e.Script_Register(TitleMenu, {ready = TitleMenu_ready})
}
```

**API**: [e.Menu](https://crossfireengine.io/api/ui/#menu),
[e.CreateMenu](https://crossfireengine.io/api/ui/#createmenu),
[e.Menu_AddButton](https://crossfireengine.io/api/ui/#menu_addbutton),
[e.Menu_AddCheckbox](https://crossfireengine.io/api/ui/#menu_addcheckbox),
[e.Menu_AddSlider](https://crossfireengine.io/api/ui/#menu_addslider),
[e.Menu_AddSelect](https://crossfireengine.io/api/ui/#menu_addselect),
[e.Menu_Command](https://crossfireengine.io/api/ui/#menu_command),
[e.MenuStyle](https://crossfireengine.io/api/ui/#menustyle)

More: [The UI system](ui.md), [Localization](localization.md#keys-in-labels-buttons-and-menus)

## Panel

A Panel is a box that holds other controls and arranges them: each by its own anchor, or in a
row, a column or a grid. It draws the theme's panel color, or an image stretched as a 9-patch.
Panels hold panels, so a column of rows makes a form. In code it's an `e.Panel`.

**Properties**

| Property | What it does |
|---|---|
| **Width**, **Height** | Its size (0: as big as what's in it) |
| **Anchor**, **Edge margin** | Where it sticks in its parent (or the screen); a stretched anchor's space from the edges. In a parent's row or column: **Expand** instead |
| **Layout** | None, Row, Column or Grid (**Grid columns** cells a row) |
| **Align**, **Justify** | Where children go across the layout (Start, Center, End, Stretch) and along it |
| **Padding**, **Gap** | Space inside its edges and between children (-1: the theme's) |
| **Image**, **Edges L / T**, **Edges R / B** | A picture instead of the fill, and its pixels that don't stretch |
| **UI theme** | Its theme (and its children's); **New Theme for ...** makes one |

**In the editor**

1. **Add Node** (Ctrl+Shift+A) > **Panel**, at the top of the scene or inside another panel.
2. Set **Anchor** (Center for a menu, Top_Left for a HUD corner) and **Layout**.
3. Select it and add its controls as children: they're placed by the layout (their inspector says
   "Placed by ...").
4. Set **Align** to Stretch for equal-width buttons, and **Padding** and **Gap**.
5. **Play** (F5) and resize the window: anchored panels keep their corners.

**From code**

A node field (`panel: ^e.Panel`) reaches it. Show or hide it with `panel.visible`, move it with
`panel.offset` (not `position`, which the layout sets), change any setting in `panel.settings`
(`layout`, `align`, `padding`...). `e.CreatePanel(scene, .Column)` makes one;
`e.Node_AddChild(panel, control)` puts a control in it.

**Example**

```odin
PauseScreen :: struct {
	using script: e.Script,
	panel: ^e.Panel `export:"default=Pause"`,
	resume: ^e.Button `export:"default=Pause/Resume"`,
}

PauseScreen_ready :: proc(self: ^PauseScreen) {
	if self.panel != nil do self.panel.visible = false
}

PauseScreen_update :: proc(self: ^PauseScreen, events: []sdl.Event, dt: f64) {
	if self.panel == nil || !e.Input_IsActionJustPressed("ui_cancel", self.game) do return
	self.panel.visible = !self.panel.visible
	// Keyboard and gamepad players start on Resume
	e.Control_Focus(self.scene, self.panel.visible ? self.resume : nil)
}

@(init)
register_PauseScreen :: proc "contextless" () {
	e.Script_Register(PauseScreen, {ready = PauseScreen_ready, update = PauseScreen_update})
}
```

**API**: [e.Panel](https://crossfireengine.io/api/ui/#panel),
[e.CreatePanel](https://crossfireengine.io/api/ui/#createpanel),
[e.UISettings](https://crossfireengine.io/api/ui/#uisettings),
[e.UILayout](https://crossfireengine.io/api/ui/#uilayout),
[e.UIAnchor](https://crossfireengine.io/api/ui/#uianchor),
[e.Control_Focus](https://crossfireengine.io/api/ui/#control_focus)

More: [The UI system](ui.md#arranging-controls-layouts)

## Button

A Button is something to press, with text, an image, or both. Its **Action** can switch scenes,
open a scene over this one, close it or quit with no code at all, and it always fires its
`onPressed` event so scripts can react. It takes the keyboard's and gamepads' focus. In code
it's an `e.Button`.

**Properties**

| Property | What it does |
|---|---|
| **Text** | Its text (`@key` translates) |
| **Action** | What pressing it does: **Go to** a scene, **Open ... over this**, **Close this (back to the scene under it)**, **Quit the game**, or nothing |
| **Can't be used** | Grayed out: can't be pressed or focused |
| **Text align**, **Font size** | Where its text goes (Auto: centered) and its size (0: the theme's) |
| **Image**, **Edges** | A picture instead of the fill (an image button: an Image and no Text) |
| **Width**, **Height**, **Anchor**, **UI theme** | As on every control |

**In the editor**

1. Select a Panel and **Add Node** (Ctrl+Shift+A) > **Button**, so the panel lays it out (or add it
   alone and set its **Anchor**).
2. Type its **Text** and choose its **Action**.
3. To run code, select the button, open **Events** in the inspector and **Listen...** to
   `onPressed`.
4. **Play** (F5): hover, click, and try the arrow keys and Enter.

**From code**

A node field (`button: ^e.Button`) reaches it. Subscribe to `button.onPressed` (data: its action
string), change the text with `e.Control_SetText`, gray it out with `button.settings.disabled`,
or change `button.settings.action`. `e.CreateButton(scene, "Play", "scene:Level1")` makes one.

**Example**

```odin
ShopKeeper :: struct {
	using script: e.Script,
	buy: ^e.Button `export:"default=Shop/Buy"`,
	coins: int `export:"default=30"`,
}

ShopKeeper_ready :: proc(self: ^ShopKeeper) {
	if self.buy == nil do return
	e.Event_Subscribe(&self.buy.onPressed, proc(_: ^e.EventSubject, _: rawptr, _: e.EventData, user: rawptr) {
		shop := cast(^ShopKeeper)user
		shop.coins -= 10
		e.Control_SetText(shop.buy, fmt.tprintf("Buy a potion (%d coins left)", shop.coins))
		// No more money: gray it out
		shop.buy.settings.disabled = shop.coins < 10
	}, self)
}

@(init)
register_ShopKeeper :: proc "contextless" () {
	e.Script_Register(ShopKeeper, {ready = ShopKeeper_ready})
}
```

**API**: [e.Button](https://crossfireengine.io/api/ui/#button),
[e.CreateButton](https://crossfireengine.io/api/ui/#createbutton),
[e.Control_SetText](https://crossfireengine.io/api/ui/#control_settext),
[e.Game_RunAction](https://crossfireengine.io/api/scene-changes/#game_runaction)

More: [The UI system](ui.md#each-controls-settings),
[Scene changes](scene_changes.md#scenes-over-scenes-pause-menus)

## ProgressBar

A ProgressBar fills to show a value in its range: health, stamina, a timer, or (with **Shows
loading**) how far a loading screen has got. It doesn't take focus. In code it's an
`e.ProgressBar`.

**Properties**

| Property | What it does |
|---|---|
| **Value**, **Min**, **Max** | The value and its range: 30 of 0 to 100 fills 30% |
| **Fills toward** | Right, Left, Up or Down |
| **Show percent** | Writes the percentage on it |
| **Shows loading** | In a loading scene: shows the loading's progress instead of its value |
| **Image**, **Edges** | A picture for the filled part (the theme's bar fill otherwise) |
| **Width**, **Height**, **Anchor**, **UI theme** | As on every control (0 x 0: 200 x 20) |

**In the editor**

1. **Add Node** (Ctrl+Shift+A) > **ProgressBar**: at the top of the scene for a HUD (with
   **Anchor** Top_Left and a position of 16, 16), or inside an enemy for a bar over its head.
2. Set **Max** to the most the value can be (100 health) and **Value** to where it starts.
3. Put it on a screen layer if the scene has a camera and the bar belongs to the HUD.
4. **Play** (F5) and check the bar moves as the script sets it.

**From code**

A node field (`bar: ^e.ProgressBar`) reaches it. `e.ProgressBar_SetValue(bar, value)` sets the
value, kept in its range; the range is `bar.settings.minValue` and `bar.settings.maxValue`.
`e.CreateProgressBar(scene, value, maxValue)` makes one.

**Example**

```odin
HealthHud :: struct {
	using script: e.Script,
	bar: ^e.ProgressBar `export:"default=HUD/Health"`,
	hp: f32 `export:"default=100 min=0"`,
}

HealthHud_ready :: proc(self: ^HealthHud) {
	if self.bar != nil do self.bar.settings.maxValue = self.hp
}

HealthHud_update :: proc(self: ^HealthHud, events: []sdl.Event, dt: f64) {
	if self.bar == nil do return
	// Poison: lose 2 health a second
	self.hp = max(self.hp - 2 * f32(dt), 0)
	e.ProgressBar_SetValue(self.bar, self.hp)
}

@(init)
register_HealthHud :: proc "contextless" () {
	e.Script_Register(HealthHud, {ready = HealthHud_ready, update = HealthHud_update})
}
```

**API**: [e.ProgressBar](https://crossfireengine.io/api/ui/#progressbar),
[e.CreateProgressBar](https://crossfireengine.io/api/ui/#createprogressbar),
[e.ProgressBar_SetValue](https://crossfireengine.io/api/ui/#progressbar_setvalue),
[e.ProgressDirection](https://crossfireengine.io/api/ui/#progressdirection)

More: [The UI system](ui.md#each-controls-settings),
[Scene changes](scene_changes.md#loading-screens)

## TextField

A TextField is a box the player types one line of text in: a name, a chat line, a code. It takes
typing while it has focus (a click, or the focus moved to it); Enter fires `onSubmitted`. In code
it's an `e.TextField`.

**Properties**

| Property | What it does |
|---|---|
| **Text** | What's in it to begin with |
| **Placeholder** | Dimmed text shown while it's empty ("Your name") |
| **Max length** | The most characters it takes (0: any) |
| **Can't be used** | Can't be typed in or focused |
| **Font size**, **Width**, **Height**, **Anchor**, **UI theme** | As on every control (no Image) |

**In the editor**

1. **Add Node** (Ctrl+Shift+A) > **TextField**, usually in a Panel's column under a RichText that
   says what to type.
2. Set its **Placeholder** and **Max length**; give it a **Width** (0 leaves room for about ten
   characters).
3. Listen to its `onSubmitted` (or `onChanged`) in the inspector's **Events**.
4. **Play** (F5), click it and type: Backspace, Delete, the arrows, Home and End work.

**From code**

A node field (`field: ^e.TextField`) reaches it. `field.text` is what's typed now;
`e.Control_SetText(field, text)` replaces it. Its events are `onChanged` (every change) and
`onSubmitted` (Enter), both with the text as data. `e.Control_Focus(scene, field)` puts the caret
in it. `e.CreateTextField(scene, text, placeholder)` makes one.

**Example**

```odin
NameEntry :: struct {
	using script: e.Script,
	field: ^e.TextField `export:"default=Form/Name"`,
}

NameEntry_ready :: proc(self: ^NameEntry) {
	if self.field == nil do return
	// Ready to type at once
	e.Control_Focus(self.scene, self.field)
	e.Event_Subscribe(&self.field.onSubmitted, proc(_: ^e.EventSubject, _: rawptr, data: e.EventData, user: rawptr) {
		entry := cast(^NameEntry)user
		name := data.(string)
		if len(name) == 0 do return
		log.infof("Welcome, %s", name)
		e.Game_ChangeScene(entry.game, "Level1")
	}, self)
}

@(init)
register_NameEntry :: proc "contextless" () {
	e.Script_Register(NameEntry, {ready = NameEntry_ready})
}
```

**API**: [e.TextField](https://crossfireengine.io/api/ui/#textfield),
[e.CreateTextField](https://crossfireengine.io/api/ui/#createtextfield),
[e.Control_SetText](https://crossfireengine.io/api/ui/#control_settext),
[e.Control_Focus](https://crossfireengine.io/api/ui/#control_focus)

More: [The UI system](ui.md#each-controls-settings)

## ScrollBox

A ScrollBox is a column of controls that scrolls when there are more than fit: an inventory, a
level list, credits. Children that don't fit wholly are hidden; the mouse wheel over it scrolls,
and moving the focus to a hidden button scrolls to it. It scrolls up and down only. In code it's
an `e.ScrollBox`.

**Properties**

| Property | What it does |
|---|---|
| **Width**, **Height** | Its size: set both (0 x 0: 300 x 200) |
| **Align** | Where its children go across the column (Stretch: all as wide as the box) |
| **Padding**, **Gap** | Space inside its edges and between children (-1: the theme's) |
| **Image**, **Edges** | A picture instead of the fill |
| **Anchor**, **UI theme** | As on every control |

**In the editor**

1. **Add Node** (Ctrl+Shift+A) > **ScrollBox**, alone or in a Panel. Give it a **Width** and
   **Height**.
2. Select it and add its children (Buttons, RichTexts, Panels for rows): it stacks them as a
   column, so their own positions are ignored.
3. Set **Align** to Stretch so the rows line up.
4. **Play** (F5): scroll with the wheel, or move the focus down with the arrow keys.

**From code**

A node field (`box: ^e.ScrollBox`) reaches it. `box.scroll` is how far it's scrolled in pixels
and `box.contentHeight` the height of what's in it. Fill it from code: make controls
(`e.CreateButton`...) and `e.Node_AddChild(box, control)`. `e.CreateScrollBox(scene, size)` makes
one.

**Example**

```odin
LevelList :: struct {
	using script: e.Script,
	list: ^e.ScrollBox `export:"default=Levels"`,
	count: int `export:"default=12 min=1"`,
}

LevelList_ready :: proc(self: ^LevelList) {
	if self.list == nil do return
	for i in 1 ..= self.count {
		// One button per level, going to the scene Level1, Level2...
		button := e.CreateButton(self.scene, fmt.tprintf("Level %d", i), fmt.tprintf("scene:Level%d", i))
		e.Node_AddChild(self.list, button)
	}
}

@(init)
register_LevelList :: proc "contextless" () {
	e.Script_Register(LevelList, {ready = LevelList_ready})
}
```

**API**: [e.ScrollBox](https://crossfireengine.io/api/ui/#scrollbox),
[e.CreateScrollBox](https://crossfireengine.io/api/ui/#createscrollbox),
[e.CreateButton](https://crossfireengine.io/api/ui/#createbutton),
[e.Node_AddChild](https://crossfireengine.io/api/core/#node_addchild)

More: [The UI system](ui.md#each-controls-settings)

## RichText

A RichText is text with colors and sizes, in the theme's font, wrapped at its width: a title, a
line of dialogue, an item's description, a score. Tags change part of it:
`[color=#ff8000]gold[/color]` and `[size=28]big[/size]`, nested if you like. In code it's an
`e.RichText`.

**Properties**

| Property | What it does |
|---|---|
| **Text** | The text with its tags (`@key` translates) |
| **Text align** | Each line at the left (Auto), in the middle or at the right |
| **Width** | Where it wraps (0: only at line breaks) |
| **Font size**, **Height**, **Anchor**, **UI theme** | As on every control (no Image) |

**In the editor**

1. **Add Node** (Ctrl+Shift+A) > **RichText**, alone (with an **Anchor**) or in a Panel.
2. Type its **Text**, for example `[size=40]My Game[/size]`.
3. Give it a **Width** if it should wrap, and a **Text align**.
4. **Play** (F5) and check the colors and the wrapping.

**From code**

A node field (`text: ^e.RichText`) reaches it. `e.Control_SetText(text, value)` sets its text,
tags included (it copies the string, so `fmt.tprintf` is fine). `e.CreateRichText(scene, text,
width)` makes one; `e.RichText_Layout` measures tagged text without a node.

**Example**

```odin
CoinCounter :: struct {
	using script: e.Script,
	label: ^e.RichText `export:"default=HUD/Coins"`,
	coins: int,
	shown: int,
}

CoinCounter_ready :: proc(self: ^CoinCounter) {
	self.shown = -1
}

CoinCounter_update :: proc(self: ^CoinCounter, events: []sdl.Event, dt: f64) {
	if self.label == nil || self.coins == self.shown do return
	// Only when it changed: the text is copied each time
	self.shown = self.coins
	e.Control_SetText(self.label, fmt.tprintf("[color=#ffd040]%d[/color] coins", self.coins))
}

@(init)
register_CoinCounter :: proc "contextless" () {
	e.Script_Register(CoinCounter, {ready = CoinCounter_ready, update = CoinCounter_update})
}
```

**API**: [e.RichText](https://crossfireengine.io/api/ui/#richtext),
[e.CreateRichText](https://crossfireengine.io/api/ui/#createrichtext),
[e.Control_SetText](https://crossfireengine.io/api/ui/#control_settext),
[e.RichText_Layout](https://crossfireengine.io/api/ui/#richtext_layout)

More: [The UI system](ui.md#each-controls-settings)

## Slider

A Slider picks a value by dragging a knob along a track, or with Left and Right while it has
focus: music and sound volume, brightness, difficulty. Every change the player makes fires
`onValueChanged` with the new value. In code it's an `e.Slider`.

**Properties**

| Property | What it does |
|---|---|
| **Value**, **Min**, **Max** | The value and its range (the left end is Min) |
| **Step** | The steps it snaps to and the keys move it by (0: any value; keys move a twentieth of the range) |
| **Show percent** | Writes the percentage right of the track |
| **Can't be used** | Grayed out: can't be dragged or focused |
| **Width**, **Height**, **Anchor**, **UI theme** | As on every control (0 x 0: 220 x 20) |

**In the editor**

1. **Add Node** (Ctrl+Shift+A) > **Slider**, usually in an options Panel beside a RichText naming
   it (a Row panel holding both).
2. Set **Min**, **Max** (0 and 100 for a volume) and **Step** (5).
3. Listen to its `onValueChanged` in the inspector's **Events**, or subscribe from a script.
4. **Play** (F5): drag the knob, then focus it and press Left and Right.

**From code**

A node field (`slider: ^e.Slider`) reaches it. `slider.settings.value` is the value now;
`e.Slider_SetValue(slider, value)` sets it (kept in range, snapped, and sending no event, so a
script can show a saved setting without acting on it). Subscribe to `slider.onValueChanged`
(data: the `f32` value). `e.CreateSlider(scene, value, minValue, maxValue, step)` makes one.

**Example**

```odin
SoundOptions :: struct {
	using script: e.Script,
	sounds: ^e.Slider `export:"default=Options/Sounds"`,
}

SoundOptions_ready :: proc(self: ^SoundOptions) {
	if self.sounds == nil do return
	e.Slider_SetValue(self.sounds, 80)
	e.Event_Subscribe(&self.sounds.onValueChanged, proc(_: ^e.EventSubject, _: rawptr, data: e.EventData, _: rawptr) {
		// The slider goes 0 to 100, a bus volume 0 to 1
		e.Audio_SetBusVolume("SFX", data.(f32) / 100)
	}, nil)
}

@(init)
register_SoundOptions :: proc "contextless" () {
	e.Script_Register(SoundOptions, {ready = SoundOptions_ready})
}
```

**API**: [e.Slider](https://crossfireengine.io/api/ui/#slider),
[e.CreateSlider](https://crossfireengine.io/api/ui/#createslider),
[e.Slider_SetValue](https://crossfireengine.io/api/ui/#slider_setvalue),
[e.Audio_SetBusVolume](https://crossfireengine.io/api/audio/#audio_setbusvolume)

More: [The UI system](ui.md#each-controls-settings)

## CheckBox

A CheckBox is a box the player ticks, with its text beside it: on / off settings like
fullscreen, subtitles or vibration. A click (on the box or its text), or Enter / Space /
`ui_accept` while it has focus, ticks or unticks it and fires `onToggled`. In code it's an
`e.CheckBox`.

**Properties**

| Property | What it does |
|---|---|
| **Text** | Its text, right of the box (`@key` translates) |
| **Checked** | Ticked when the scene starts |
| **Can't be used** | Grayed out: can't be ticked or focused |
| **Font size**, **Width**, **Height**, **Anchor**, **UI theme** | As on every control (no Image) |

**In the editor**

1. **Add Node** (Ctrl+Shift+A) > **CheckBox**, usually in an options Panel's column.
2. Type its **Text** and set **Checked** to the setting's usual value.
3. Listen to its `onToggled` in the inspector's **Events**, or subscribe from a script.
4. **Play** (F5): click it, and try it with the arrow keys and Enter.

**From code**

A node field (`box: ^e.CheckBox`) reaches it. `box.settings.checked` is whether it's ticked;
`e.CheckBox_SetChecked(box, checked)` sets it without sending `onToggled`. Subscribe to
`box.onToggled` (data: true when ticked). `e.CreateCheckBox(scene, text, checked)` makes one.

**Example**

```odin
ScreenOptions :: struct {
	using script: e.Script,
	fullscreen: ^e.CheckBox `export:"default=Options/Fullscreen"`,
}

ScreenOptions_ready :: proc(self: ^ScreenOptions) {
	if self.fullscreen == nil do return
	// Show the window's state, without toggling it again
	e.CheckBox_SetChecked(self.fullscreen, e.Game_IsFullscreen(self.game))
	e.Event_Subscribe(&self.fullscreen.onToggled, proc(_: ^e.EventSubject, source: rawptr, data: e.EventData, _: rawptr) {
		box := cast(^e.CheckBox)source
		e.Game_SetFullscreen(box.scene.game, data.(bool))
	}, nil)
}

@(init)
register_ScreenOptions :: proc "contextless" () {
	e.Script_Register(ScreenOptions, {ready = ScreenOptions_ready})
}
```

**API**: [e.CheckBox](https://crossfireengine.io/api/ui/#checkbox),
[e.CreateCheckBox](https://crossfireengine.io/api/ui/#createcheckbox),
[e.CheckBox_SetChecked](https://crossfireengine.io/api/ui/#checkbox_setchecked),
[e.Game_SetFullscreen](https://crossfireengine.io/api/core/#game_setfullscreen)

More: [The UI system](ui.md#each-controls-settings)

## DialogueBox

A DialogueBox shows a conversation from a dialogue asset (written in the Dialogue tab, or a
Yarn file imported): the speaker's name, each line typed out a letter at a time, and the options
to choose from. The player goes on with `ui_accept` (Space, Enter, a click) and picks options with
`ui_up` / `ui_down`. It draws at its position, in screen space. In code it's an `e.DialogueBox`.

**Properties**

| Property | What it does |
|---|---|
| **Dialogue**, **Start node** | The dialogue asset and the node it starts in (the dialogue's own start when not set) |
| **Box width**, **Box height**, **Box padding** | Its size and the space inside its edge |
| **Type speed** | Letters a second (0: each line at once) |
| **Letter size**, **Box font** | The text's size and font |
| **Box color**, **Text color**, **Name color**, **Chosen color** | Its colors (the speaker's name, the option picked) |
| **Starts playing** | Begins when the scene starts (else a script starts it) |
| **Hide when done** | Hidden between conversations, shown when one starts |

**In the editor**

1. **Add Node** (Ctrl+Shift+A) > **DialogueBox**. It needs no parent or children; put it on a
   screen layer of a scene with a camera, like a HUD.
2. Choose its **Dialogue** and **Start node**; **Edit in the Dialogue tab** opens the asset in the
   bottom panel's Dialogue tab.
3. Place it (its position is its top-left corner) and set its size, **Type speed** and colors:
   the viewport shows its first line.
4. Untick **Starts playing** if a script should start it (when the player talks to someone).
5. **Play** (F5) and go through the conversation with Space and the arrow keys.

**From code**

A node field (`box: ^e.DialogueBox`) reaches it. `e.DialogueBox_Start(box, "Node")` starts a
conversation (and shows the box); `e.DialogueBox_IsPlaying(box)` says whether one is going on.
Its events: `onLine` (data: the line's text), `onCommand` (data: the command's text; call
`e.DialogueBox_Hold` to make it wait, then `e.DialogueBox_Continue`) and `onFinished`.
`box.runner.speaker` and `box.runner.text` are what shows now; the variables are the game's,
`game.dialogueVariables`.

**Example**

```odin
Villager :: struct {
	using script: e.Script,
	talk: ^e.DialogueBox `export:"default=/HUD/Talk"`,
	talked: int,
}

Villager_ready :: proc(self: ^Villager) {
	if self.talk == nil do return
	e.Event_Subscribe(&self.talk.onFinished, proc(_: ^e.EventSubject, _: rawptr, _: e.EventData, user: rawptr) {
		villager := cast(^Villager)user
		villager.talked += 1
	}, self)
}

Villager_update :: proc(self: ^Villager, events: []sdl.Event, dt: f64) {
	if self.talk == nil || e.DialogueBox_IsPlaying(self.talk) do return
	if e.Input_IsActionJustPressed("interact", self.game) {
		// The first time a greeting, then a shorter line
		e.DialogueBox_Start(self.talk, self.talked == 0 ? "Greeting" : "Again")
	}
}

@(init)
register_Villager :: proc "contextless" () {
	e.Script_Register(Villager, {ready = Villager_ready, update = Villager_update})
}
```

**API**: [e.DialogueBox](https://crossfireengine.io/api/dialogue/#dialoguebox),
[e.DialogueBox_Start](https://crossfireengine.io/api/dialogue/#dialoguebox_start),
[e.DialogueBox_IsPlaying](https://crossfireengine.io/api/dialogue/#dialoguebox_isplaying),
[e.DialogueBox_Hold](https://crossfireengine.io/api/dialogue/#dialoguebox_hold),
[e.DialogueBox_Continue](https://crossfireengine.io/api/dialogue/#dialoguebox_continue),
[e.DialogueBoxSettings](https://crossfireengine.io/api/dialogue/#dialogueboxsettings)

More: [Dialogue](dialogue.md#showing-it-the-dialoguebox),
[commands](dialogue.md#commands-making-things-happen)

## VirtualJoystick

A VirtualJoystick is an on-screen stick for touch screens. A finger (or the mouse, to try it on
a desktop) moves it, and it presses up to four input actions as far as it's pushed, so code
reading `e.Input_GetVector` moves the same with keys, a gamepad or the stick. A **Floating** one
appears where the thumb lands in its touch zone. In code it's an `e.VirtualJoystick`.

**Properties**

| Property | What it does |
|---|---|
| **Left action**, **Right action**, **Up action**, **Down action** | The input actions it presses (from Project Settings > Input) |
| **Size radius** | The stick's radius in game pixels (64) |
| **Deadzone** | A push smaller than this fraction of the radius counts as centered (0.2) |
| **Touch zone width**, **Touch zone height** | The area that takes a finger, centered on the node (0 x 0: the circle itself) |
| **Floating** | It starts where the finger lands in its zone |
| **Shows** | Touch_Screens (once the screen is touched, and in Play from the editor), Always, or Never |
| **Mouse works it**, **Control color**, **Opacity** | The mouse drives it too; its look |

**In the editor**

1. Make sure the project has input actions (Project Settings > Input), and choose the scene's
   **Screen layers** (the browser's scene preview).
2. **Add Node** (Ctrl+Shift+A) > **VirtualJoystick** and set its **Layer** to a screen layer (the
   inspector warns when it would scroll with the camera).
3. Place it where the left thumb rests: its position is the middle of the stick.
4. Choose its four actions, and for a floating stick a big **Touch zone** and **Floating**.
5. **Play** (F5): it shows in Play from the editor; drag it with the mouse.

**From code**

Most code doesn't touch the node: it reads the actions (`e.Input_GetVector`,
`e.Input_IsActionPressed`). A node field (`stick: ^e.VirtualJoystick`) gives
`e.VirtualJoystick_GetVector(stick)` (-1 to 1 each way, y down) and `stick.settings` (an
`e.TouchControlSettings`). `e.TouchControl_SetActions` changes its actions;
`e.CreateVirtualJoystick(scene, {"left", "right", "up", "down"})` makes one.

**Example**

```odin
TouchShip :: struct {
	using script: e.Script,
	stick: ^e.VirtualJoystick `export:"default=/HUD/Stick"`,
	speed: f32 `export:"default=300 min=0"`,
}

TouchShip_update :: proc(self: ^TouchShip, events: []sdl.Event, dt: f64) {
	// Keys, a gamepad and the stick all press these actions
	move := e.Input_GetVector("ui_left", "ui_right", "ui_up", "ui_down", self.game)
	self.node.position += move * self.speed * f32(dt)
	// Turn the ship the way the stick points while a thumb is on it
	if self.stick != nil && self.stick.held {
		v := e.VirtualJoystick_GetVector(self.stick)
		if v != {0, 0} do self.node.rotation = math.to_degrees(math.atan2(v.y, v.x))
	}
}

@(init)
register_TouchShip :: proc "contextless" () {
	e.Script_Register(TouchShip, {update = TouchShip_update})
}
```

**API**: [e.VirtualJoystick](https://crossfireengine.io/api/steam-touch-multiplayer/#virtualjoystick),
[e.VirtualJoystick_GetVector](https://crossfireengine.io/api/steam-touch-multiplayer/#virtualjoystick_getvector),
[e.CreateVirtualJoystick](https://crossfireengine.io/api/steam-touch-multiplayer/#createvirtualjoystick),
[e.TouchControlSettings](https://crossfireengine.io/api/steam-touch-multiplayer/#touchcontrolsettings),
[e.TouchControl_SetActions](https://crossfireengine.io/api/steam-touch-multiplayer/#touchcontrol_setactions),
[e.Input_GetVector](https://crossfireengine.io/api/input/#input_getvector)

More: [Touch controls and Steam](touch_and_steam.md#a-virtual-joystick)

## TouchButton

A TouchButton is a round on-screen button for touch screens: it presses one input action while a
finger holds it (jump, fire), shows a short label, and fires `onPressed` and `onReleased`. Each
touch control takes its own finger, so one thumb on a stick and another on a button work at
once. In code it's an `e.TouchButton`.

**Properties**

| Property | What it does |
|---|---|
| **Input action** | The action it presses while held (from Project Settings > Input) |
| **Label** | Its text (`A`, `Jump`) |
| **Size radius** | Its radius in game pixels (40) |
| **Touch zone width**, **Touch zone height** | The area that takes a finger (0 x 0: the circle itself) |
| **Shows** | Touch_Screens, Always, or Never |
| **Mouse works it**, **Control color**, **Opacity** | The mouse presses it too; its look |

**In the editor**

1. **Add Node** (Ctrl+Shift+A) > **TouchButton**, on a screen layer like the joystick.
2. Place it where the right thumb rests: its position is the middle of the button.
3. Choose its **Input action** and give it a **Label**.
4. **Play** (F5) and click it: the action is pressed while the mouse button is down.

**From code**

Code usually reads the action (`e.Input_IsActionJustPressed("jump")`). A node field
(`button: ^e.TouchButton`) gives `e.TouchButton_IsPressed(button)`, its events `onPressed` and
`onReleased` (no data), and `button.text`. `e.CreateTouchButton(scene, "jump", "A")` makes one.

**Example**

```odin
FireButton :: struct {
	using script: e.Script,
	fire: ^e.TouchButton `export:"default=/HUD/Fire"`,
	shots: int,
}

FireButton_ready :: proc(self: ^FireButton) {
	if self.fire == nil do return
	e.Event_Subscribe(&self.fire.onPressed, proc(_: ^e.EventSubject, _: rawptr, _: e.EventData, user: rawptr) {
		gun := cast(^FireButton)user
		gun.shots += 1
		log.infof("shot %d", gun.shots)
	}, self)
}

FireButton_update :: proc(self: ^FireButton, events: []sdl.Event, dt: f64) {
	// Dim the button while it's held
	if self.fire != nil do self.fire.settings.opacity = e.TouchButton_IsPressed(self.fire) ? 0.9 : 0.5
}

@(init)
register_FireButton :: proc "contextless" () {
	e.Script_Register(FireButton, {ready = FireButton_ready, update = FireButton_update})
}
```

**API**: [e.TouchButton](https://crossfireengine.io/api/steam-touch-multiplayer/#touchbutton),
[e.TouchButton_IsPressed](https://crossfireengine.io/api/steam-touch-multiplayer/#touchbutton_ispressed),
[e.CreateTouchButton](https://crossfireengine.io/api/steam-touch-multiplayer/#createtouchbutton),
[e.Input_IsActionJustPressed](https://crossfireengine.io/api/input/#input_isactionjustpressed)

More: [Touch controls and Steam](touch_and_steam.md#a-touch-button)

## Questions

**My control doesn't move when I drag it, or my script's `position` does nothing.** A parent
Panel or ScrollBox lays it out (its inspector says "Placed by ..."). Reorder it in the scene tree,
set the parent's **Layout** to None, or move it from code with `control.offset`, not `position`.

**My HUD, joystick or dialogue box scrolls away with the level.** Put it on one of the scene's
**Screen layers** (select the scene in the browser). The touch controls' inspector warns about it.

**The keyboard doesn't reach my buttons.** A Menu node on screen takes the keys too, or another
control has the focus. Don't mix a Menu and controls on one screen, or call `e.Control_Focus`
in a script's `ready`.

**A script's `Slider_SetValue` or `CheckBox_SetChecked` doesn't run my listener.** On purpose:
changes from code send no event, so showing a saved setting doesn't act on it again. Do the work
yourself after setting it.

**My Label's text goes blank or turns to garbage.** A Label keeps the string you give it, not a
copy: text from `fmt.tprintf` lasts one frame. Set it every frame, keep the string yourself, or
use a RichText with `e.Control_SetText` (which copies).

**I don't see my touch controls in the exported game.** **Shows** is Touch_Screens: they appear
once the screen is touched (and always in Play from the editor). Set **Shows** to Always to see
them on a desktop.
