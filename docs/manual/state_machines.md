---
title: State machines
description: "StateMachine nodes and the States tab: what a character is doing, the conditions that change it, and the animation each state plays."
order: 23
---

# State machines

A **state machine** keeps track of what something is doing, one thing at a time: a character is
**idle**, **running**, **jumping**, **attacking** or **hurt**; a door is **closed**, **opening** or
**open**; an enemy is **patrolling**, **chasing** or **fleeing**. It moves from one state to another
when conditions say so ("start running when the speed is over 10"), and each state can play an
animation. Your scripts only report the facts (the speed, whether it's on the ground, "attack was
pressed"); the state machine decides what that means and picks the animation.

- [The words](#the-words)
- [Your first state machine](#your-first-state-machine)
- [The States tab](#the-states-tab)
- [Conditions](#conditions)
- [Doing things when a state starts](#doing-things-when-a-state-starts)
- [State machines in scripts](#state-machines-in-scripts)
- [How it's stored](#how-its-stored)
- [Questions](#questions)

## The words

- **State**: one thing it can be doing, with a name (`run`) and the animation it plays. It's in
  exactly one state at a time, starting in its **start** state (★).
- **Transition**: an arrow from one state to another, taken when its **condition** holds. An
  arrow from **Any state** can be taken from every other state (an "attack" or "hurt" that can
  interrupt anything).
- **Parameter**: a value scripts set and conditions read: a **Float** (a number: `speed`), a
  **Bool** (true or false: `grounded`) or a **Trigger** (set once, used up when a transition reads
  it: `jump`, `attack`).

## Your first state machine

A character that stands, runs and jumps:

1. **The sprite.** An AnimatedSprite with animations **idle**, **run** and **jump** (see the
   Animation tab).
2. **The machine.** With the sprite selected, **Add Node** (Ctrl+Shift+A) > **StateMachine**. It
   goes inside the sprite, and its states will play the sprite's animations.
3. **Open the graph.** In the inspector press **Edit in the States tab**. It has one state,
   **idle**.
4. **Parameters.** Press **+ Parameter** three times and set them up below the graph: **speed**
   (Float, 0), **grounded** (Bool, true), **jump** (Trigger).
5. **States.** Select **idle** and set **Plays** to **idle**. Press **+ State**, name it **run**,
   **Plays: run**; another, **jump**, **Plays: jump**.
6. **Transitions.** Select **idle** and choose **+ Transition to: run**; select the arrow and set
   **When** to `speed > 10`. From **run**, a transition to **idle**: `speed <= 10`. Select **jump**
   and choose **+ Transition to: \*** (from any state): **When** `jump`. From **jump** to **idle**:
   `grounded`, **After** 0.1 (so it leaves the ground first).
7. **Feed it** from the character's script (its node fields, chosen in the inspector: the machine
   and the CharacterMover):

```odin
Hero :: struct {
	using script: e.Script,
	brain: ^e.StateMachine `export:""`,
	mover: ^e.CharacterMover `export:""`,
}

Hero_update :: proc(self: ^Hero, events: []sdl.Event, dt: f64) {
	e.StateMachine_SetFloat(self.brain, "speed", abs(self.mover.velocity.x))
	e.StateMachine_SetBool(self.brain, "grounded", self.mover.onFloor)
	if e.Input_IsActionJustPressed("jump", self.game) do e.StateMachine_SetTrigger(self.brain, "jump")
}
```

8. **Play** (F5): the animations follow what the character does. The **Live** tab shows the
   machine's **state** as it changes (select it in the Live tab's list).

## The States tab

The graph:

| Mouse | Does |
|---|---|
| Click a state | Selects it; drag to move it |
| Click an arrow | Selects the transition |
| Double-click empty space | A new state there |

States show their name (★ for the start state) and the animation they play; arrows show their
condition.

**The selected state:** **Name** (renaming it renames it in its transitions too), **Plays** (an
animation of the AnimatedSprite it animates, or none), **Starts Here**, **+ Transition to** (another
state, or **\***: from any state into this one), **Remove State** (and its transitions).

**The selected transition:** **When** (its condition: see below; a problem with it shows in
orange), **After** (seconds it must have been in the state first), **When its animation ends** (it
waits for the state's animation to finish: an attack that plays out), **Remove Transition**.

**Parameters:** name (renaming it renames it in the conditions), kind, and starting value.

In the inspector: **Starts in** (the start state) and **Animates** (the AnimatedSprite it plays
animations on; its parent unless you choose another).

## Conditions

A condition is one or more clauses joined by `and`; all must hold:

| Clause | Holds when |
|---|---|
| `grounded` | The Bool is true (or the Trigger is set) |
| `!grounded` | The Bool is false |
| `speed > 10` | The comparison holds: `==`, `!=`, `<`, `<=`, `>`, `>=` |
| `speed > 10 and grounded` | Both hold |
| (empty) | Always (with **After** or **When its animation ends**: a timed or finishing state) |

Transitions are checked in the order they were made; the first one that holds is taken (at most
one per frame). A Trigger is used up when a transition that reads it is taken.

## Doing things when a state starts

The machine's events, in the inspector's **Events** (Listen...):

| Event | When |
|---|---|
| **onStateEntered** | It entered a state (data: the state's name) |
| **onStateExited** | It left a state (data: the state's name) |

With a sound field added to the Hero for the attack:

```odin
Hero :: struct {
	using script: e.Script,
	brain: ^e.StateMachine `export:""`,
	mover: ^e.CharacterMover `export:""`,
	// The attack's sound, chosen in the inspector
	swing: e.SoundAsset `export:""`,
}

Hero_onBrainStateEntered :: proc(self: ^Hero, source: ^e.Node, data: e.EventData) {
	switch data.(string) {
	case "attack": e.Game_PlaySound(self.game, self.swing)
	case "hurt":   e.Camera2D_Shake(self.scene.camera, 4, 0.2)
	}
}
```

## State machines in scripts

| Code | What it does |
|---|---|
| `e.StateMachine_SetFloat(sm, "speed", v)` | Sets a Float |
| `e.StateMachine_SetBool(sm, "grounded", true)` | Sets a Bool |
| `e.StateMachine_SetTrigger(sm, "jump")` | Sets a Trigger (used up by the transition that reads it) |
| `e.StateMachine_Current(sm)`, `e.StateMachine_Is(sm, "run")` | The state it's in |
| `e.StateMachine_TimeInState(sm)` | Seconds in it |
| `e.StateMachine_Travel(sm, "hurt")` | Goes to a state now, whatever the transitions say |

An **Animator** can set the **State** property too (a cutscene putting a character in a pose).

## How it's stored

```xml
<node kind="StateMachine" name="Brain" start="idle">
	<param name="speed" type="Float" value="0"/>
	<param name="grounded" type="Bool" value="true"/>
	<param name="jump" type="Trigger"/>
	<state name="idle" animation="idle" x="40" y="60"/>
	<state name="run" animation="run" x="220" y="60"/>
	<transition from="idle" to="run" when="speed &gt; 10"/>
	<transition from="run" to="idle" when="speed &lt;= 10"/>
	<transition from="*" to="jump" when="jump"/>
</node>
```

(`x` and `y` are where the States tab draws the state. `animates="../Sprite"` names another
AnimatedSprite than the parent.)

## Questions

**It never leaves its start state.** Check the parameter's name in the condition (an unknown name
shows a problem under **When**), and that the script sets it on the right StateMachine.

**The animation doesn't change.** The state's **Plays** must name one of the sprite's animations,
and **Animates** must be that sprite.

**It flickers between two states.** Their conditions overlap (`speed > 10` and `speed >= 10`):
make them exclusive, or add an **After**.
