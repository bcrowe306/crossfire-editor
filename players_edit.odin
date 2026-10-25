package crossfire_editor

import "core:fmt"
import "core:strconv"
import "core:strings"
import "gui:skald"
import e "engine:."

/*
Local multiplayer in the editor (the engine's players.odin): Project Settings > Input's Local
players rows: how many players can join, whether the keyboard is a player's device, and the
action that joins (default: a gamepad's South or Start, the keyboard's Enter or Space).

- **Data:** `Project.players` (the engine's `e.PlayerSettings`; `joinAction` owned), project.xml's
  `<players max keyboard joinAction/>` (written when not the defaults), in the `.Project`
  snapshot. Edited on the dialog's draft (`ProjectSettingsDialog.players`); renaming or removing
  the join action in the Input tab follows.
*/

// A players setting on the draft (`Players_Setting_Changed`)
PlayersField :: enum {
	Max_Players,
	Keyboard,
	Join_Action,
}

// A change to the draft's players settings
Players_Setting_Changed :: struct {
	field: PlayersField,
	text: string,
	flag: bool,
}

// The join action choice meaning the default buttons
PLAYERS_JOIN_DEFAULT :: "(South / Start, Enter / Space)"

// A copy of players settings (its join action owned)
PlayerSettings_Clone :: proc(p: e.PlayerSettings) -> e.PlayerSettings {
	out := p
	out.joinAction = strings.clone(p.joinAction)
	return out
}

// The players messages, on the draft; returns whether `m` was one
PlayersSettings_Update :: proc(s: ^State, m: Msg) -> bool {
	v, ok := m.(Players_Setting_Changed)
	if !ok do return false
	p := &s.projectSettings.players
	switch v.field {
	case .Max_Players:
		if n, parsed := strconv.parse_int(v.text); parsed do p.maxPlayers = clamp(n, 1, e.MAX_LOCAL_PLAYERS)
	case .Keyboard:
		p.keyboard = v.flag
	case .Join_Action:
		delete(p.joinAction)
		p.joinAction = strings.clone(v.text == PLAYERS_JOIN_DEFAULT ? "" : v.text)
	}
	return true
}

/*
The Input tab's Local players rows (under the action list). Keys `input-players-max`,
`input-players-keyboard`, `input-players-join`.
*/
playersSettingRows :: proc(s: ^State, ctx: ^skald.Ctx(Msg)) -> []skald.View {
	tk := uiTokens(ctx)
	th := ctx.theme
	d := &s.projectSettings
	p := d.players
	rows := make([dynamic]skald.View, context.temp_allocator)
	Payload :: struct { field: PlayersField }
	onText :: proc(pl: Payload, v: string) -> Msg { return Players_Setting_Changed{field = pl.field, text = v} }
	counts := make([dynamic]string, context.temp_allocator)
	for n in 1 ..= e.MAX_LOCAL_PLAYERS do append(&counts, fmt.tprint(n))
	joins := make([dynamic]string, context.temp_allocator)
	append(&joins, PLAYERS_JOIN_DEFAULT)
	for a in d.actions do append(&joins, a.name)
	label :: proc(ctx: ^skald.Ctx(Msg), text: string) -> skald.View {
		return tipLabel(ctx, text, uiText(ctx.theme, .Label, text))
	}
	append(&rows,
		skald.spacer(th.spacing.sm),
		skald.divider(ctx),
		uiText(th, .Section, "Local players"),
		skald.row(label(ctx, "Most players"), skald.select(ctx, fmt.tprint(p.maxPlayers), counts[:], Payload{.Max_Players}, onText,
			id = skald.hash_id("input-players-max"), width = tk.fieldXS), spacing = th.spacing.sm, cross_align = .Center),
		skald.row(label(ctx, "Keyboard player"), skald.checkbox(ctx, p.keyboard, "", Payload{.Keyboard},
			proc(pl: Payload, v: bool) -> Msg { return Players_Setting_Changed{field = pl.field, flag = v} }, id = skald.hash_id("input-players-keyboard")),
			spacing = th.spacing.sm, cross_align = .Center),
		label(ctx, "Join with"),
		skald.select(ctx, p.joinAction == "" ? PLAYERS_JOIN_DEFAULT : strings.clone(p.joinAction, context.temp_allocator), joins[:], Payload{.Join_Action}, onText,
			id = skald.hash_id("input-players-join"), width = tk.fieldL),
		uiText(th, .Muted, "While a game is joining (e.Players_StartJoining), a press of this on a free gamepad or the keyboard adds a player. Each player's actions: e.Player_IsActionPressed(player, \"jump\").", max_width = tk.textNarrow),
	)
	return rows[:]
}
