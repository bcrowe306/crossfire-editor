---
title: The UI system
description: Panels, buttons, progress bars, text fields, scroll boxes, rich text, sliders and check boxes for menus, HUDs and options screens, with layouts and themes.
order: 24
---

# The UI system: menus, HUDs and dialogs

The **UI controls** are nodes for the parts of a game that aren't the world: a title menu, a
health bar, a pause screen, a name entry box, a shop list, a line of dialogue. You build them in
the scene like any other nodes, and the editor's viewport shows them as the game will.

| Control | What it is |
|---|---|
| **Panel** | A box that holds other controls and arranges them: in a row, a column or a grid. It draws the theme's background (or an image) |
| **Button** | Something to press, with text or a picture. It can switch scenes or quit by itself, and tells your scripts it was pressed |
| **ProgressBar** | A bar that fills to show a value: health, stamina, a timer, loading |
| **TextField** | A box the player types a line of text in: a name, a code |
| **ScrollBox** | A column of controls that scrolls when there are more than fit: an inventory, a level list, credits |
| **RichText** | Text with colors and sizes, wrapped to a width: a dialogue line, an item's description |
| **Slider** | A value the player drags a knob along a track to pick: music and sound volume, brightness |
| **CheckBox** | A box the player ticks, with its text beside it: fullscreen, subtitles, vibration |

(The older **Label** and **Menu** nodes still work: a Label is one line of plain text, a Menu a
ready-made list of buttons, checkboxes and sliders. The controls here are for building your own
layouts.)

- [Your first menu](#your-first-menu)
- [Where controls go: anchors](#where-controls-go-anchors)
- [Arranging controls: layouts](#arranging-controls-layouts)
- [Sizes](#sizes)
- [Each control's settings](#each-controls-settings)
- [Themes: how controls look](#themes-how-controls-look)
- [Images and 9-patches](#images-and-9-patches)
- [Keyboard and gamepad](#keyboard-and-gamepad)
- [UI in scripts](#ui-in-scripts)
- [Screen size and the camera](#screen-size-and-the-camera)
- [How it's stored](#how-its-stored)
- [Questions](#questions)

## Your first menu

A title screen with two buttons in the middle of the screen:

1. **A panel.** In your menu scene, **Add Node** (Ctrl+Shift+A) > **Panel**. In the inspector set
   **Anchor** to **Center** and **Layout** to **Column**. The panel sits in the middle of the game
   area and will stack what you put in it.
2. **A title.** With the panel selected, **Add Node** > **RichText**. Set its **Text** to
   `[size=40]My Game[/size]`.
3. **Buttons.** Select the panel again and **Add Node** > **Button**. Set its **Text** to `Play`
   and its **Action** to **Go to Level1** (your first level). Add another, `Quit`, with the action
   **Quit the game**.
4. **Make them the same width.** Select the panel and set **Align** to **Stretch**: every child
   becomes as wide as the widest.
5. **Play** (F5). The buttons light up under the mouse; a click does their action. The arrow
   keys (or a gamepad's d-pad, with the project's `ui_*` input actions) move between them, and
   Enter presses.
6. **Make it yours.** In the panel's inspector press **New Theme for Menu**: the panel gets a theme
   of its own. Select it in the browser (**Themes** folder) and change the colors, the font and
   the text size in the inspector ([Themes](#themes-how-controls-look)).

Every change can be undone with Ctrl+Z.

## Where controls go: anchors

A control that isn't arranged by a parent panel's layout is placed by its **Anchor**: a point of
its parent it sticks to.

```
Top_Left      Top       Top_Right
Left         Center         Right
Bottom_Left   Bottom   Bottom_Right
```

The control's matching point goes on that point: with **Bottom_Right**, the control's bottom-right
corner sits on the parent's bottom-right corner. The control's **Position** (the inspector's
first rows, or dragging it in the viewport) then moves it from there: a health bar anchored
**Top_Left** at position 16, 16 stays 16 pixels in from the corner.

Stretched anchors make the control as wide or tall as its parent:

| Anchor | The control |
|---|---|
| **Full** | Fills the parent |
| **Top_Wide**, **Bottom_Wide** | The parent's width, at its top or bottom (a title bar, a HUD strip) |
| **Left_Tall**, **Right_Tall** | The parent's height, at its left or right (a side panel) |

**Edge margin** leaves space between a stretched control and its parent's edges.

What is "the parent"?

- A **top-level** control's parent is the **screen**: the game area (the project's width and
  height). Anchors keep a HUD in its corners whatever the window's size.
- Inside a **panel**, the panel (inside its **Padding**).
- Inside a node that isn't a control (a Node2D, an enemy), that node's position: anchors work
  around a point. A health bar over an enemy: a ProgressBar inside the enemy, anchored **Bottom**,
  position 0, -40.

## Arranging controls: layouts

A Panel's **Layout** says how it places the controls inside it:

| Layout | Places them |
|---|---|
| **None** | Each by its own anchor and position |
| **Row** | Side by side, left to right |
| **Column** | One under another, top to bottom |
| **Grid** | In rows of **Grid columns** cells (an inventory, a level select) |

- **Padding**: space between the panel's edges and its controls.
- **Gap**: space between controls.
  (-1 for either: the theme's.)
- **Align**: where controls go **across** the layout (in a column: left, middle, right) - **Start**,
  **Center**, **End**, or **Stretch** (as wide as the panel, in a column; as tall, in a row).
- **Justify**: where they go **along** it when they don't fill it (in a column: top, middle,
  bottom).
- A control inside a row or column with **Expand** ticked takes the room the others leave: a
  search box filling a toolbar, the middle of a three-part bar.

A control placed by its parent's layout says so in the inspector ("Placed by Menu's column
layout"): its own anchor and position don't apply then.

Panels hold panels: a column of rows makes a form, a row of columns a two-page menu.

## Sizes

**Width** and **Height** set a control's size in pixels. **0** means "as big as what's in it":

- a Button: its text with the padding around it (or its image's size)
- a Panel: what its controls need, laid out, plus padding
- a RichText: its text (with a width set, it wraps at that width and grows down)
- a TextField: ten characters' room; a ProgressBar: 200 x 20; a ScrollBox: 300 x 200
- a Slider: a 200 pixel track with room for its knob at each end (220 x 20), plus its percentage
  when it shows one
- a CheckBox: its box, a gap and its text

## Each control's settings

**Every control:** Width, Height, Anchor (or Expand, in a row or column), **Font size** (0: the
theme's; not on panels, scroll boxes, progress bars and sliders), **UI theme** ([Themes](#themes-how-controls-look)),
**Image** (except text fields, rich text, sliders and check boxes: [Images](#images-and-9-patches)).

**Button**

| Setting | What it does |
|---|---|
| **Text** | Its text; `@key` shows that key's translation in the player's language |
| **Action** | What pressing it does: **Go to** a scene, **Quit the game**, or nothing (scripts listen to it) |
| **Can't be used** | Grayed out; can't be pressed or focused |
| **Text align** | Where the text goes (Auto: centered) |

A button always fires its **onPressed** event when it's pressed (with the mouse, or Enter / a
gamepad's accept button while it has focus).

**ProgressBar**

| Setting | What it does |
|---|---|
| **Value**, **Min**, **Max** | The value and its range: 30 of 0 to 100 fills 30% |
| **Fills toward** | Right, Left, Up or Down |
| **Show percent** | Writes "30%" on it |
| **Image** | An image for the filled part (the theme's color otherwise) |

**TextField**

| Setting | What it does |
|---|---|
| **Text** | What's in it to begin with |
| **Placeholder** | Dimmed text shown while it's empty ("Your name") |
| **Max length** | The most characters it takes (0: any) |
| **Can't be used** | Can't be typed in |

Click it (or move the focus to it) and type; Backspace, Delete, Left, Right, Home and End work,
and **Enter** fires its **onSubmitted** event. Every change fires **onChanged**. A click elsewhere
takes the focus away.

**Slider**

| Setting | What it does |
|---|---|
| **Value**, **Min**, **Max** | The value and its range: the left end is Min, the right end Max |
| **Step** | The steps the value snaps to: 5 on a 0 to 100 slider gives 0, 5, 10... (0: any value) |
| **Show percent** | Writes "80%" right of the track |
| **Can't be used** | Grayed out; can't be dragged or focused |

Press anywhere on it and the value jumps there; keep the button down and drag, and the knob
follows the mouse (even past the slider's ends). While it has the focus, **Left** and **Right**
(the ui_left and ui_right actions, so a gamepad's d-pad too) move the value by one step, or by a
twentieth of the range when Step is 0; **Up** and **Down** still move the focus. Every change
the player makes fires its **onValueChanged** event, with the new value.

The track is the theme's **Bar background** with the filled part in **Bar fill**; the knob is
drawn in the button colors (**Button color**, **Hovered** under the mouse, **Pressed** while
dragged).

**CheckBox**

| Setting | What it does |
|---|---|
| **Text** | Its text, right of the box; `@key` translates |
| **Checked** | Ticked when the scene starts |
| **Can't be used** | Grayed out; can't be ticked or focused |

A click (on the box or its text), or Enter / Space / a gamepad's accept button while it has the
focus, ticks or unticks it and fires its **onToggled** event (true when ticked). The box is
the theme's **Field color** (the button colors under the mouse), the tick its **Check mark**.

**ScrollBox**: a column (Align, Padding, Gap apply). What doesn't fit wholly is hidden; the mouse
wheel over it scrolls it, and moving the focus to a hidden button scrolls to it. Give it a Width
and Height.

**RichText**: its **Text** takes tags:

| Tag | Does |
|---|---|
| `[color=#ff8000]gold[/color]` | Colors the text between (`#rrggbb` or `#rrggbbaa`) |
| `[size=32]big[/size]` | Sets the text size between |

Tags nest: `[size=30][color=#ffd040]Crossfire[/color][/size]`. It wraps at its Width (0: only at
line breaks). **Text align** puts each line at the left (Auto), in the middle or at the right of
its width (or, with no width, of its widest line): centered titles, credits, a score on the right.

## Themes: how controls look

A **theme** is a file (`.theme.xml`, in the browser's **Themes** folder) of colors, sizes and a
font that controls are drawn with. Without any, controls use the built-in dark blue theme.

**Making one:** a control's inspector has **New Theme for (its name)**, which makes a theme and
gives it to that control. Or right-click the browser and choose **New UI Theme**.

**Editing one:** select it in the browser: the inspector shows its **Font** (any font asset, or
the built-in one) and every value, grouped:

| Group | Values |
|---|---|
| Text | Text size, text color, disabled text |
| Panels | Panel color, border color and width, corner radius, padding, spacing |
| Buttons | Button color, hovered, pressed, disabled, button text, focus outline |
| Text fields | Field color, placeholder, caret |
| Progress bars | Bar background, bar fill (sliders' tracks too) |
| Scroll boxes | Scrollbar |
| Check boxes | Check mark |

Colors have a picker and an alpha slider (transparency); numbers a slider (type a value in its box,
or reset it with the button beside it). The viewport shows every change at once.

**Who uses which theme:** a control uses its **UI theme**, else its parent's, else its parent's
parent's, and so on, else **the whole project's theme** (the tick box at the top of a theme's
inspector), else the built-in one. So setting a theme on a menu's top panel themes the whole
menu, and the project's theme themes every control that doesn't say otherwise.

## Images and 9-patches

A Panel, Button or ScrollBox with an **Image** draws it instead of the theme's fill, stretched to
the control's size; a ProgressBar uses it for the filled part. A framed image would stretch its
frame too, so set its **Edges**: how many pixels at the left, top, right and bottom don't stretch.
The corners stay as drawn, the edges stretch one way, the middle both: a **9-patch**. An image
button: a Button with an Image and no text.

## Keyboard and gamepad

Buttons, text fields, sliders and check boxes take **focus**: the focused one has an outline (the theme's focus color).
Players move it without a mouse:

- If the project has the **ui_*** input actions (Project Settings > Input: ui_up, ui_down,
  ui_left, ui_right, ui_accept; new projects have them), those move the focus and press, so
  gamepads work.
- Otherwise the arrow keys and Tab move it, Enter or Space press.

The focus moves to the nearest control in the direction pressed. When nothing has focus, the
first press focuses the first control. In a text field, Left and Right move the caret instead;
on a slider, they move its value.

## UI in scripts

Give a script a field for the control (drag it from the scene tree onto the code), then:

```odin
Hud :: struct {
	using script: e.Script,
	health: ^e.ProgressBar `export:"default=Health"`,
	score: ^e.RichText `export:"default=Score"`,
	hp, coins: int,
}

Hud_update :: proc(self: ^Hud, events: []sdl.Event, dt: f64) {
	e.ProgressBar_SetValue(self.health, f32(self.hp))
	e.Control_SetText(self.score, fmt.tprintf("[color=#ffd040]%d[/color] coins", self.coins))
}
```

Listen to a button in the inspector's **Events** (its `onPressed`), a text field's
`onSubmitted`, a slider's `onValueChanged` or a check box's `onToggled`, like any node's events.
An options screen, with a script on its panel:

```odin
Options :: struct {
	using script: e.Script,
	music: ^e.Slider `export:"default=Music"`,
	fullscreen: ^e.CheckBox `export:"default=Fullscreen"`,
}

Options_ready :: proc(self: ^Options) {
	e.Slider_SetValue(self.music, 80)
	e.CheckBox_SetChecked(self.fullscreen, e.Game_IsFullscreen(self.game))
	e.Event_Subscribe(&self.music.onValueChanged, proc(_: ^e.EventSubject, _: rawptr, data: e.EventData, _: rawptr) {
		e.Audio_SetBusVolume("Music", data.(f32) / 100)
	}, nil)
	e.Event_Subscribe(&self.fullscreen.onToggled, proc(_: ^e.EventSubject, source: rawptr, data: e.EventData, _: rawptr) {
		box := cast(^e.CheckBox)source
		e.Game_SetFullscreen(box.scene.game, data.(bool))
	}, nil)
}
```

Setting them from code (`e.Slider_SetValue`, `e.CheckBox_SetChecked`) sends no event, so a
script can show the saved settings without acting on them again.

| Procedure | What it does |
|---|---|
| `e.Control_SetText(control, text)` | A button's, field's or rich text's text |
| `e.ProgressBar_SetValue(bar, value)` | A bar's value (kept in its range) |
| `e.Slider_SetValue(slider, value)` | A slider's value (kept in its range, snapped to its step; no event) |
| `e.CheckBox_SetChecked(box, checked)` | Ticks or unticks a check box (no event) |
| `slider.settings.value`, `box.settings.checked` | What the player chose |
| `e.Control_Focus(scene, control)` | Gives it the focus (nil: takes it away) |
| `e.Control_Focused(scene)` | The focused control |
| `e.Control_GetRect(control)` | Where it is on the screen |
| `control.offset = {x, y}` | Moves it from its anchor (its `position` is the layout's) |
| `control.settings.disabled = true` | Grays it out (any setting can be changed) |
| `e.CreatePanel`, `e.CreateButton`, `e.CreateProgressBar`, `e.CreateTextField`, `e.CreateScrollBox`, `e.CreateRichText`, `e.CreateSlider`, `e.CreateCheckBox` | Make controls from code |

An **Animator** can animate controls too: its Position track moves a control's offset (a menu
sliding in).

## Screen size and the camera

Controls work in the game's own resolution (Project Settings: width and height), which the window
scales up or down, so a menu laid out for 1280 x 720 looks the same in any window.

If the scene has a **camera**, put the UI on a layer the camera doesn't move: in the scene's
settings (the browser's scene preview) tick that layer under **Screen layers**, and give the UI
nodes that **Layer**. Otherwise the HUD scrolls away with the world.

## How it's stored

Controls are nodes in the scene file; their settings are attributes, written only when they
aren't the defaults:

```xml
<node kind="Panel" name="Menu" anchor="Center" layout="Column" align="Stretch" theme="themes/menu.theme.xml">
	<node kind="RichText" name="Title" text="[size=40]My Game[/size]"/>
	<node kind="Button" name="Play" text="Play" action="scene:Level1"/>
	<node kind="Button" name="Quit" text="Quit" action="quit"/>
</node>
<node kind="Panel" name="Options" anchor="Center" layout="Column">
	<node kind="Slider" name="Music" value="80" max="100" step="5" showValue="true"/>
	<node kind="CheckBox" name="Fullscreen" text="Fullscreen" checked="true"/>
</node>
```

A theme file holds its font and the values that differ from the built-in theme:

```xml
<theme formatVersion="13" font="assets/fonts/pixel.ttf" textSize="24" buttonColor="#3a5a8cff"/>
```

## Questions

**My control doesn't move when I drag it.** Its parent panel lays it out (the inspector says so).
Change the order in the scene tree to move it within the layout, or set the parent's layout to
None.

**My HUD scrolls with the level.** Put it on a screen layer ([Screen size and the camera](#screen-size-and-the-camera)).

**The keyboard doesn't reach my buttons.** Another control has the focus, or a Menu node takes the
keys. Click a button, or call `e.Control_Focus` when the scene starts.

**Can a ScrollBox scroll sideways?** Not yet: it scrolls a column.
