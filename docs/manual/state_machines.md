---
title: State machines
description: "StateMachine nodes and the States tab: what a character is doing, the conditions that change it, and the animation each state plays."
order: 27
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
- [Which transition is taken](#which-transition-is-taken)
- [Guards](#guards)
- [Watching it play](#watching-it-play)
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
- **Guard**: a check that can stop a transition (a transition's **Guard**) or keep the machine in
  a state (a state's **Can exit when**, its exit guard). A **code guard** is an Odin procedure of
  your scripts, called by name: `can_attack()`.
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
5. **States.** Select **idle** and set **Plays** to **idle** in the sidebar on the right. Press
   **+ State**, name it **run**, **Plays: run**; another, **jump**, **Plays: jump**.
6. **Transitions.** Select **idle** and choose **+ Transition to: run**; select the arrow, press
   **+ Condition** under **When** and make the row read `speed` `>` `10`. From **run**, a
   transition to **idle**: `speed <= 10`. Select **jump** and choose **+ Transition to: \***
   (from any state): **When** `jump`. From **jump** to **idle**: `grounded`, **Exit after** 0.1
   (so it leaves the ground first).
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

The graph on the left, the **sidebar** on the right with the selected state's or transition's
properties. In a narrow panel (a tiled or short window) the sidebar goes under the graph. One
scroll holds them both.

The graph:

| Mouse | Does |
|---|---|
| Click a state | Selects it; drag to move it |
| Click an arrow | Selects the transition |
| Double-click empty space | A new state there |

States show their name (★ for the start state, ⊘ when it has an exit guard) and the animation
they play; arrows show their condition, `[guard]`, exit time, priority (`p5`) and `interrupts`.

**The selected state** (the sidebar):

| Row | What it does |
|---|---|
| **State name** | Its name: renaming it renames it in its transitions too |
| **Plays** | An animation of the AnimatedSprite it animates, or none |
| **Play speed** | Its animation's speed in this state (2: twice as fast) |
| **Play loop** | Its animation **As made**, or always **Loop**, or play **Once** (so a transition waiting for its end can be taken) |
| **Can exit when** | Its exit guard (see [Guards](#guards)): while it doesn't hold, the machine stays |
| **Enter event**, **Exit event** | Names the machine sends (`onStateEvent`) when it's entered or left |

Then **Starts Here**, **+ Transition to** (another state, or **\***: from any state into this
one) and **Remove State** (and its transitions).

**The selected transition:** **When** (its condition: see below), **Guard** (more conditions:
see [Guards](#guards)), **Priority**, **Exit after (s)** (seconds it must have been in the state
first), **When its animation ends** (it waits for the state's animation to finish: an attack that
plays out), **Ignores the exit guard** (it interrupts), **Remove Transition**. A problem with a
condition shows in orange under it.

**Parameters** (under the graph): name (renaming it renames it in the conditions, guards and exit
guards), kind, and starting value.

In the inspector: **Starts in** (the start state) and **Animates** (the AnimatedSprite it plays
animations on; its parent unless you choose another).

## Conditions

A condition is clauses joined by `and` (all must hold) or `or` (one is enough):

| Clause | Holds when |
|---|---|
| `grounded` | The Bool is true (or the Trigger is set, or the Float isn't 0) |
| `!grounded`, `not grounded` | The Bool is false |
| `speed > 10` | The comparison holds: `==`, `!=`, `<`, `<=`, `>`, `>=` |
| `can_attack()` | The code guard `can_attack` (a procedure of your scripts) says yes |
| `speed > 10 and grounded` | Both hold (`&&` too) |
| `hurt or dead` | Either holds (`||` too) |
| `(speed > 10 or dashing) and grounded` | Parentheses group; `and` binds tighter than `or` |
| (empty) | Always (with **Exit after** or **When its animation ends**: a timed or finishing state) |

In the sidebar a condition whose clauses are all joined the same way is a list of rows: **All
of** or **Any of** at the top, then per clause **is** / **not**, what it reads (a parameter, or a
code guard ending in `()`), the comparison (**is true**, `>`...) and the number. **+ Condition**
adds a clause, **+ Code guard** one calling a guard. Under the rows is the condition as text:
type anything there, parentheses too (a condition mixing `and` and `or` shows as text only).

A Trigger is used up when a transition that reads it is taken.

## Which transition is taken

Every frame the machine tries the transitions out of its current state (and those from **Any
state**), **highest priority first**; transitions of the same priority in the order they were
made. The first one that can be taken is taken, and that's all for the frame. One can be taken
when:

1. its **exit time** has come: **Exit after** seconds in the state, and the animation's end when
   **When its animation ends** is ticked;
2. its **When** holds;
3. its **Guard** holds;
4. the state can be left: its **Can exit when** holds, or the transition **ignores the exit
   guard** (it interrupts).

Give a transition that must win a higher **Priority** (a death over a hurt, a hurt over an
attack) instead of relying on the order you made them in.

**Crossfades:** there are none. A state's animation starts at once: an AnimatedSprite shows one
frame of one animation at a time, so there's nothing to blend.

## Guards

- **A transition's Guard**: more conditions, like **When**, kept apart so you can tell why it
  isn't taken (the sidebar says "Blocked by its guard" while the game plays). A Trigger in
  **When** waits while the guard fails: it's only used up when the transition is taken.
- **A state's Can exit when** (its exit guard): while it doesn't hold, no transition leaves the
  state, except those that **ignore the exit guard**. An attack that can't be cancelled:
  `can exit when` `!attacking()`, and the hurt transition ignores it.
- **Code guards**: procedures your scripts register by name, used in any condition as
  `name()`. The sidebar offers the names your scripts give (it reads them as you type, no build
  needed) and warns about a name no script gives.

```odin
package scripts

import e "engine:."

@(init)
register_guards :: proc "contextless" () {
	// "can_attack()" in a condition: not in the first quarter second of a state
	e.StateMachine_RegisterGuard("can_attack", proc(sm: ^e.StateMachine) -> bool {
		return e.StateMachine_TimeInState(sm) > 0.25
	})
}
```

A guard that needs a script's own state is set on the machine with the script as `self`, in its
`ready`:

```odin
package scripts

import e "engine:."

Knight :: struct {
	using script: e.Script,
	brain: ^e.StateMachine `export:""`,
	stamina: f32,
}

Knight_ready :: proc(self: ^Knight) {
	e.StateMachine_SetGuard(self.brain, "has_stamina", proc(self: ^Knight) -> bool {
		return self.stamina > 10
	}, self)
}
```

Keep guards quick and without side effects: the machine calls them every frame while their
transition is tried, and the editor calls them while it watches the game.

## Watching it play

While the game runs from **Play** (or **Play Scene**), the States tab watches the running
machine (the one at the same place in the playing scene, or the Live tab's chosen one): the
toolbar says which state it's in, the graph lights it (▶) and draws the transitions it would
take in green, and the sidebar marks each clause ✓ or ×, says why a transition isn't taken
(waiting for its exit time, its condition, its guard, the state's exit guard) and whether the
current state can be left. Parameters show their value in the game.

## Doing things when a state starts

The machine's events, in the inspector's **Events** (Listen...):

| Event | When |
|---|---|
| **onStateEntered** | It entered a state (data: the state's name) |
| **onStateExited** | It left a state (data: the state's name) |
| **onTransition** | It moved from a state to another (data: a `^e.StateMachineTransitionInfo`: `from`, `to`, the transition's `index`, -1 for `StateMachine_Travel`) |
| **onStateEvent** | A state's **Enter event** or **Exit event** (data: its name) |

To listen to one state from code, `e.StateMachine_OnEnter(brain, "attack", proc(sm: ^e.StateMachine, state: string, user: rawptr) {...}, self)`
(and `e.StateMachine_OnExit`).

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
| `e.StateMachine_ResetTrigger(sm, "jump")` | Clears a Trigger no transition used |
| `e.StateMachine_Current(sm)`, `e.StateMachine_Is(sm, "run")` | The state it's in |
| `e.StateMachine_Previous(sm)` | The state it was in before |
| `e.StateMachine_TimeInState(sm)` | Seconds in it |
| `e.StateMachine_CanExit(sm)` | Whether its state can be left now (its exit guard holds) |
| `e.StateMachine_Travel(sm, "hurt")` | Goes to a state now, whatever the transitions and guards say |
| `e.StateMachine_TryTravel(sm, "dodge")` | Goes there only if the state can be left |
| `e.StateMachine_TransitionStatus(sm, i)` | Why transition `i` is or isn't taken now |
| `e.StateMachine_RegisterGuard`, `e.StateMachine_SetGuard` | Code guards (see [Guards](#guards)) |
| `e.StateMachine_OnEnter`, `e.StateMachine_OnExit` | Listens to one state |

Drop a state from the sidebar's grip onto code for **Travel to it**, **If it's the current
state**, **Travel to it if the state can be left**, **When it's entered** and **When it's left**;
a StateMachine node for **Its state** and **If its state can be left**.

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
	<state name="attack" animation="attack" x="400" y="60" canExit="!busy()" loop="Once" onEnter="swing"/>
	<transition from="*" to="jump" when="jump" guard="grounded"/>
	<transition from="*" to="hurt" when="hurt" priority="10" interrupts="true"/>
</node>
```

(`x` and `y` are where the States tab draws the state. `animates="../Sprite"` names another
AnimatedSprite than the parent. A state's `canExit`, `speed`, `loop`, `onEnter`, `onExit` and a
transition's `guard`, `priority`, `interrupts` are written only when set.)

## Questions

**It never leaves its start state.** Check the parameter's name in the condition (an unknown name
shows a problem under **When**), and that the script sets it on the right StateMachine.

**The animation doesn't change.** The state's **Plays** must name one of the sprite's animations,
and **Animates** must be that sprite.

**It flickers between two states.** Their conditions overlap (`speed > 10` and `speed >= 10`):
make them exclusive, or add an **Exit after**.

**A transition is never taken, though its condition holds.** Play and select it: the sidebar
says what keeps it (its guard, the state's exit guard, its exit time), or a transition tried
before it (a higher priority) is taken instead.

**"no code guard 'x'".** No script registers that name: check the spelling, and that the script
calls `e.StateMachine_RegisterGuard` (or `StateMachine_SetGuard` in a `ready` that runs).
