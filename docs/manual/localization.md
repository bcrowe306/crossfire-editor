---
title: Localization
description: Translate your game's text into other languages with CSV translation tables, "@key" texts in labels, buttons and menus, and Tr(key) in scripts.
order: 28
---

# Localization

Localization means your game speaks the player's language: "Play" for English players, "Jouer"
for French ones, "Spielen" for German ones. You write every piece of text once per language in a
**translation table**, and put **keys** in your scenes and scripts instead of the text itself.
The game shows each key's text in the current language.

- [Translation tables](#translation-tables)
- [Adding a table to the project](#adding-a-table-to-the-project)
- [Keys in labels, buttons and menus](#keys-in-labels-buttons-and-menus)
- [Keys in scripts: Tr](#keys-in-scripts-tr)
- [Which language the game uses](#which-language-the-game-uses)
- [Changing the language while playing](#changing-the-language-while-playing)
- [When a text is missing](#when-a-text-is-missing)
- [Questions](#questions)

## Translation tables

A translation table is a **CSV file** (comma-separated values, the kind a spreadsheet saves),
laid out like Godot's:

```
key,en,fr,de
menu.play,Play,Jouer,Spielen
menu.quit,Quit,Quitter,Beenden
# The HUD
hud.coins,"Coins: %d","Pièces : %d","Münzen: %d"
```

- **The first row names the languages.** The first column is the keys (its title can be anything:
  `key`, `id`); each other column is a language, by its code: `en`, `fr`, `de`, `pt_BR`,
  `fr_CA`.
- **Each row after it is a key and its text** in each language.
- **The first language is the fallback**: text missing in another language shows in that one.
- Rows with an empty key, or a key starting with `#`, are comments.
- Put a text in **double quotes** when it has commas or line breaks. A quote inside quoted text is
  written twice (`""`).
- Keys are up to you. Dotted names grouped by place (`menu.play`, `hud.coins`, `shop.buy`) are
  easy to keep tidy.

Any spreadsheet program edits these files: save as CSV, in UTF-8 so accents and other alphabets
come through.

## Adding a table to the project

1. **File > Import Asset...** (Ctrl+I) and choose the `.csv` file. It's copied into `assets/` and
   listed in the browser's **Translations** folder.
2. Select it there. The preview shows how many keys it has, its languages, and the first keys
   with their text in the first language. If the file can't be read as a table, the preview
   says so: the first row must be `key,<language>,<language>...`.

A project can have several tables (one for menus, one for dialogue...). The game loads them all,
in the order they're listed; a key that's in two tables takes the later table's text, and a
language only one table has is still offered.

The game reads the tables each time it starts, so edit the copy in `assets/` in your
spreadsheet, save it, and Play: no need to import it again.

## Keys in labels, buttons and menus

Write a key with **`@` in front** where the text would go:

| Node | Where |
|---|---|
| Label | The inspector's **Text** row: `@menu.play` |
| Button | Its **Text** row |
| RichText | Its **Text** row |
| TextField | Its **Placeholder** row |
| Menu | Its items' labels and a select item's options (in the scene file: `<item label="@menu.play" action="scene:PlayScene"/>`; the inspector doesn't edit menu items yet) |

The game shows the key's text in the current language, and changes it at once when the language
changes. To show text that really starts with `@`, write `@@` (`@@home` shows `@home`).

The viewport doesn't load the tables, so it shows the key itself (`menu.play`). Press Play to see
the translations.

## Keys in scripts: Tr

`e.Tr(key)` gives a key's text in the current language:

```odin
Title :: proc(scene: ^e.Scene) {
	// "@" text follows the language as it changes
	e.CreateLabel(scene, "@menu.play", {320, 200}, 24, {255, 255, 255, 255})
	// Tr gives the text once, in the language of the moment
	log.info(e.Tr("menu.quit"))
}
```

For text with numbers in it, put a `%d` (a whole number) or `%s` (text) in the table's text and
fill it in with `fmt.tprintf`. Different languages can put it in different places:

```odin
CoinCounter :: struct {
	using script: e.Script,
	label: ^e.Label `export:"default=."`,
	coins: int,
}

@(init)
register_CoinCounter :: proc "contextless" () {
	e.Script_Register(CoinCounter, {
		update = proc(self: ^CoinCounter, events: []sdl.Event, dt: f64) {
			if self.label == nil do return
			// "Coins: %d" in English, "Pièces : %d" in French...
			self.label.text = fmt.tprintf(e.Tr("hud.coins"), self.coins)
		},
	})
}
```

(Put the script on the Label: its `label` field's path `.` is the node itself. Setting the text
every frame keeps it in the current language. `fmt` is `import "core:fmt"`.)

Translation tables don't get constants in `scripts/assets.odin`: scripts use the keys.

## Which language the game uses

**File > Project Settings...**, tab **General**, **Language**:

| Setting | The game starts in |
|---|---|
| Empty (the default) | **The player's system language**, if a table has it; otherwise the tables' first language |
| A language code (`fr`) | That language, whatever the player's system says (useful to test a translation) |

Languages match loosely: `fr` picks a table's `fr_FR` or `fr_CA` when there's no plain `fr`,
and a player whose system says `fr_CA` gets `fr`. An exact match wins, and case doesn't matter.
If the project's Language isn't in any table, the Console warns and the game uses the first
language.

**Apply** makes it an undoable step; it's saved in `project.xml` as `locale="fr"`.

## Changing the language while playing

An options menu can switch the language. Everything written with `@` changes at once:

```odin
LanguageButton :: struct {
	using script: e.Script,
}

@(init)
register_LanguageButton :: proc "contextless" () {
	e.Script_Register(LanguageButton, {
		update = proc(self: ^LanguageButton, events: []sdl.Event, dt: f64) {
			if !e.Input_IsKeyJustPressed(.L) do return
			// The next language the tables have, round and round
			locales := e.Locale_List(self.game)
			if len(locales) == 0 do return
			current := e.Locale_Get(self.game)
			next := 0
			for name, i in locales do if name == current do next = (i + 1) % len(locales)
			e.Locale_Set(self.game, locales[next])
			log.infof("Language: %s", e.Locale_Get(self.game))
		},
	})
}
```

| Code | What it does |
|---|---|
| `e.Locale_Set(game, "fr")` | Switches language (matching loosely, as above). Returns false, and keeps the language, when no table has it |
| `e.Locale_Get(game)` | The language in use, as the tables name it |
| `e.Locale_List(game)` | Every language the tables have, the fallback first (for a language menu) |
| `e.Locale_System()` | The player's system language (`fr_CA`, or `fr`); `""` when unknown |
| `e.Locale_LoadFile(game, path)` | Loads one more table while playing (a file of the project) |

```odin
Languages :: proc(game: ^e.Game) {
	if !e.Locale_Set(game, "fr") do log.warn("no French text")
	log.infof("the player's system: %s", e.Locale_System())
	e.Locale_LoadFile(game, "assets/extra.csv")
}
```

The language isn't remembered between runs by itself. To keep the player's choice, store it in a
saved field of a [global script](globals_data_saves.md) and call `e.Locale_Set` with it after
`e.Load_Game()`.

## When a text is missing

The game never shows nothing:

1. The key's text in the current language,
2. else its text in the first language (the fallback column),
3. else **the key itself** (`hud.coins`), so missing text is easy to spot while playing.

## How it's stored

A table is an asset of kind Translation in `project.xml`, and the language is on its root:

```xml
<project name="My Game" locale="fr">
	<asset path="assets/strings.csv" kind="Translation"/>
</project>
```

## Questions

**My label shows `menu.play` instead of "Play".** In the viewport that's normal: press Play. In
the game, check the key is spelled the same in the table, and that the table is in the
Translations folder.

**My label shows `@menu.play` with the @.** It's a node that doesn't translate: only Labels,
Buttons, RichText, TextField placeholders and Menu items do. Use `e.Tr` and set the text from a
script.

**Accented letters come out wrong.** Save the CSV as UTF-8, and use a font that has those letters.

**The game is in English on my French computer.** The project's Language is set (it wins over the
system); empty it to follow the system.

**My text has a comma and the columns are off.** Put the text in double quotes.
