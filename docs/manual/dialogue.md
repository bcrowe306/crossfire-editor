---
title: Dialogue
description: Write conversations with lines, choices, conditions and variables in the Dialogue tab, import Yarn Spinner scripts, and show them in the game with a typewriter DialogueBox.
order: 31
---

# Dialogue

Characters talking, the player choosing what to answer, a shopkeeper who remembers you: that's a
**dialogue**. In this editor a dialogue is an asset you write in the bottom panel's **Dialogue**
tab (or import from Yarn Spinner), and a **DialogueBox** node shows it in the game: the speaker's
name, each line typed out letter by letter, the choices to pick from.

- [How a dialogue is built](#how-a-dialogue-is-built)
- [Writing one in the Dialogue tab](#writing-one-in-the-dialogue-tab)
- [Variables and conditions](#variables-and-conditions)
- [Showing it: the DialogueBox](#showing-it-the-dialoguebox)
- [Commands: making things happen](#commands-making-things-happen)
- [Importing Yarn Spinner files](#importing-yarn-spinner-files)
- [From scripts](#from-scripts)

## How a dialogue is built

A dialogue is a set of **nodes**, like scenes of a conversation ("Greeting", "Shop", "Goodbye").
Each node is a list of **steps**, run from top to bottom:

| Step | What it does |
|---|---|
| **Line** | Someone says something: a speaker (or none, for narration) and the text |
| **Options** | The player chooses: each option's text and the node it leads to |
| **Jump** | Carries on in another node |
| **Set** | Changes a variable: `$gold` = `$gold - 5` |
| **Command** | Tells the game to do something (`shake 2`, `give sword`); `wait 1` pauses |
| **Stop** | Ends the conversation |

A conversation starts in the dialogue's start node (★). When a node runs out of steps, the
conversation ends.

## Writing one in the Dialogue tab

1. In the browser, right-click > **New Dialogue** (or the Dialogue tab's New Dialogue). The bottom
   panel opens on the **Dialogue** tab with a Start node saying "Hello!".
2. **The graph** at the top shows the nodes as boxes, with arrows for jumps and options (labeled
   with the option's text). Click a node to edit it; drag to arrange; double-click empty space
   (or **+ Node**) for a new node. **Starts in** picks the start node.
3. **The selected node's steps** are listed under the graph. Each has its fields:
   - a Line's **Speaker** and **Says** (`{$gold}` puts a variable's value in the text);
   - an Options step's options: the text, the node it goes to (→), and a condition (**shown
     if...**); **+ Option** adds one;
   - a Jump's node, a Set's variable and value, a Command's text;
   - **If** on every step: it runs only when the condition is true.
   ↑ and ↓ move a step, the trash removes it. **+ Line**, **+ Options**... add a step after the
   selected one.
4. Rename a node in its **Name** field: the jumps and options leading to it follow.

Every edit can be undone (Ctrl+Z). Save writes the dialogue's file (`dialogues/name.dialogue.xml`).

## Variables and conditions

Variables start with `$`: `$gold`, `$met_guide`, `$name`. A variable nobody set yet is 0. Set them
with Set steps, read them in conditions and in text (`You have {$gold} gold`). They're the game's:
every DialogueBox shares them, so `$met_guide` set in one conversation is true in the next.

Conditions and values are expressions:

| Write | Means |
|---|---|
| `5`, `"text"`, `true`, `false` | values |
| `$gold + 5`, `$gold * 2`, `-$x`, `7 % 3` | arithmetic (`+` also joins text) |
| `$gold >= 5`, `$name == "Ada"`, `$x != 3` | comparisons (also `is`, `eq`, `neq`, `lt`, `lte`, `gt`, `gte`) |
| `$a and $b`, `$a or $b`, `not $a` | logic (also `&&`, `||`, `!`) |
| `visited("Shop")`, `visited_count("Shop")` | whether (how often) a node has been entered |
| `random()`, `random_range(1, 6)`, `dice(6)` | chance |

An option whose condition is false isn't shown; an Options step with no option showing is skipped.

## Showing it: the DialogueBox

1. **Add Node** > **DialogueBox** (under User interface). Put it where the box should be: it's
   drawn at its position, `Box width` x `Box height` big, without the camera (put it on a screen
   layer of the scene, like a HUD).
2. In the inspector: **Dialogue** (the asset) and **Start node** (the dialogue's own start when
   not set). With **Starts playing** it begins when the scene starts; else a script starts it.
3. Its look: **Type speed** (letters a second; 0 shows each line at once), **Letter size**, **Box
   padding**, the colors, **Box font**. **Hide when done** hides the box between conversations.

The viewport shows its first line, so you can arrange it. In the game:

- **Space**, **Enter**, a click, or the `ui_accept` input action: shows the whole line if it's
  still typing, else goes on to the next.
- At options: **Up** / **Down** (or `ui_up` / `ui_down`) pick, `ui_accept` chooses; or click one.

## Commands: making things happen

A **Command** step's text goes to the game: a DialogueBox fires its `onCommand` event with it,
then carries on. Listen to it in a script (the inspector's Events section) to shake the camera,
give an item, play a sound:

```odin
Shop :: struct {
	using script: e.Script,
}

Shop_onCommand :: proc(self: ^Shop, source: ^e.Node, data: e.EventData) {
	text := data.(string)
	box := cast(^e.DialogueBox)source
	switch text {
	case "give sword":
		// ... add it to the inventory
	case "walk away":
		// Keep the conversation waiting until the walk is done
		e.DialogueBox_Hold(box)
		// later: e.DialogueBox_Continue(box)
	}
}
```

`wait 1.5` is built in: the box waits that long by itself. Its other events: `onLine` (each line
shown) and `onFinished` (the conversation ended).

## Importing Yarn Spinner files

[Yarn Spinner](https://yarnspinner.dev) is a popular language for game dialogue. Import a `.yarn`
file (Ctrl+I) and it becomes a dialogue asset you can play and edit:

- each Yarn node becomes a node (its `position:` kept);
- `Name: text` lines become lines (`#tags` dropped); `{$var}` works as it does in Yarn;
- `->` options become an Options step; each option's indented lines become a node of their own
  (`Shop.1.1`), and what follows the options a node they continue in (`Shop.after1`);
- `<<if>>`, `<<elseif>>`, `<<else>>` become conditions on the steps inside them; `<<if ...>>`
  after a line or option is that one's condition;
- `<<jump>>`, `<<set>>`, `<<stop>>` become Jump, Set and Stop steps; `<<declare $x = 5>>` sets
  `$x` the first time its node runs; any other command (`<<wait 1>>`, `<<shake 2>>`) a Command.

The Console lists what didn't convert: `<<once>>`, line groups (`=>`), enums, smart variables,
functions your game would define.

## From scripts

```odin
box := cast(^e.DialogueBox)e.Scene_FindNode(scene, "HUD/Talk")

// Start a conversation (in a node, or the box's start node)
e.DialogueBox_Start(box, "Shop")
if e.DialogueBox_IsPlaying(box) {
	// The player can't move while talking
}

// Variables: the game's, shared by every box
e.DialogueVariables_Set(&game.dialogueVariables, "$gold", f64(25))
gold := e.DialogueVariables_Get(&game.dialogueVariables, "$gold")
_ = gold

// The line showing now
speaker, text := box.runner.speaker, box.runner.text
_, _ = speaker, text
```

The editor writes a constant for each dialogue asset (`DIALOGUE_SHOP` in `scripts/assets.odin`).
Dialogue variables aren't in save games by themselves: copy what you need into a global script's
fields.

## Questions

**My option doesn't show.** Its condition is false (check the variable), or it leads nowhere and
ends the conversation when chosen.

**The box doesn't appear.** Check its Dialogue is set and Starts playing is on (or a script calls
`DialogueBox_Start`); it's hidden between conversations when Hide when done is on. On a scene with
a camera, put it on a screen layer.

**Text runs out of the box.** Lines wrap at the box's width; make the box taller or the text
smaller.
