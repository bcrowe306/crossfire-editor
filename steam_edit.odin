package crossfire_editor

import "core:fmt"
import "core:strconv"
import "core:strings"
import "gui:skald"
import e "engine:."

/*
Steam in the editor (the engine's steam.odin): Project Settings > Steam edits the project's Steam
app ID, whether saves go to Steam Cloud, and its achievements (name, title, description,
hidden).

- **Data:** `Project.steam` (the engine's `e.SteamSettings`, plain) and `Project.achievements`
  (owned strings), in project.xml (`steamAppId`, `steamCloud`, `<achievement>`) and the
  `.Project` undo snapshot.
- **Editing** is on the dialog's draft (`ProjectSettingsDialog.steam`, `achievements`) like the
  other tabs; Apply is the undo step.
- **Scripts:** `scripts/assets.odin` gets `ACHIEVEMENT_<NAME>` constants.
- The engine runs Steam's **stub** backend until the Steamworks SDK is in: achievements and
  stats are kept with the game's saves (Play's apart, as "<name> (dev)").
*/

// An achievement (the engine's data; strings owned)
AchievementDef :: e.SteamAchievementData

// A Steam setting on the draft (`Steam_Setting_Changed`)
SteamField :: enum {
	App_ID,
	Cloud_Saves,
	Name,
	Title,
	Description,
	Hidden,
}

// A change to the Steam tab's draft: the app ID or an achievement's field (`index`)
Steam_Setting_Changed :: struct {
	field: SteamField,
	index: int,
	text: string,
	flag: bool,
}
// An achievement added to the draft; one removed (its index)
Steam_Achievement_Added :: struct {}
Steam_Achievement_Removed :: distinct int

// Copies of achievements (strings owned)
Achievements_Clone :: proc(list: []AchievementDef) -> [dynamic]AchievementDef {
	out := make([dynamic]AchievementDef, 0, len(list))
	for a in list do append(&out, AchievementDef{strings.clone(a.name), strings.clone(a.title), strings.clone(a.description), a.hidden})
	return out
}

// Frees achievements and their strings
Achievements_Destroy :: proc(list: ^[dynamic]AchievementDef) {
	for a in list {
		delete(a.name)
		delete(a.title)
		delete(a.description)
	}
	delete(list^)
	list^ = nil
}

// Whether two lists of achievements are the same
Achievements_Equal :: proc(a, b: []AchievementDef) -> bool {
	if len(a) != len(b) do return false
	for x, i in a do if x != b[i] do return false
	return true
}

/*
Why an achievement name won't do ("" when it's fine): Steam's API names are letters, digits and
underscores, unique.
*/
AchievementNameProblem :: proc(list: []AchievementDef, index: int) -> string {
	name := list[index].name
	if name == "" do return "Needs a name (Steam's API name: FIRST_BLOOD)."
	for c in name {
		if !((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '_') do return "Use letters, digits and _ (Steam's API names)."
	}
	for other, i in list do if i != index && other.name == name do return "Another achievement has this name."
	return ""
}

// The Steam tab's messages, on the draft; returns whether `m` was one
SteamSettings_Update :: proc(s: ^State, m: Msg) -> bool {
	d := &s.projectSettings
	#partial switch v in m {
	case Steam_Setting_Changed:
		switch v.field {
		case .App_ID:
			if v.text == "" {
				d.steam.appId = 0
			} else if n, ok := strconv.parse_uint(strings.trim_space(v.text)); ok && n <= uint(max(u32)) {
				d.steam.appId = u32(n)
			}
		case .Cloud_Saves:
			d.steam.cloudSaves = v.flag
		case .Name, .Title, .Description, .Hidden:
			if v.index < 0 || v.index >= len(d.achievements) do break
			a := &d.achievements[v.index]
			#partial switch v.field {
			case .Name:
				delete(a.name)
				a.name = strings.clone(strings.trim_space(v.text))
			case .Title:
				delete(a.title)
				a.title = strings.clone(v.text)
			case .Description:
				delete(a.description)
				a.description = strings.clone(v.text)
			case .Hidden:
				a.hidden = v.flag
			}
		}
	case Steam_Achievement_Added:
		// A free name: ACHIEVEMENT_1, ACHIEVEMENT_2...
		name: string
		for n := len(d.achievements) + 1; ; n += 1 {
			name = fmt.tprintf("ACHIEVEMENT_%d", n)
			taken := false
			for a in d.achievements do if a.name == name do taken = true
			if !taken do break
		}
		append(&d.achievements, AchievementDef{name = strings.clone(name), title = strings.clone(""), description = strings.clone("")})
	case Steam_Achievement_Removed:
		i := int(v)
		if i < 0 || i >= len(d.achievements) do break
		a := d.achievements[i]
		delete(a.name)
		delete(a.title)
		delete(a.description)
		ordered_remove(&d.achievements, i)
	case:
		return false
	}
	return true
}

/*
Project Settings > Steam: the app ID, Steam Cloud saves, and the achievements (each: API name,
title, description, hidden, remove), Add Achievement. Keys `project-settings-steam-app-id`,
`project-settings-steam-cloud`, `steam-achievement-<i>-name|title|description|hidden|remove`,
`steam-achievement-add`.
*/
SteamTab :: proc(s: ^State, ctx: ^skald.Ctx(Msg)) -> skald.View {
	tk := uiTokens(ctx)
	th := ctx.theme
	d := &s.projectSettings
	rows := make([dynamic]skald.View, context.temp_allocator)
	note :: proc(ctx: ^skald.Ctx(Msg), text: string, warning := false) -> skald.View {
		tk := uiTokens(ctx)
		return skald.text(text, warning ? ctx.theme.color.warning : ctx.theme.color.fg_muted, ctx.theme.font.size_xs, max_width = tk.textWide)
	}
	Payload :: struct { field: SteamField, index: int }
	onText :: proc(p: Payload, v: string) -> Msg { return Steam_Setting_Changed{field = p.field, index = p.index, text = v} }
	onFlag :: proc(p: Payload, v: bool) -> Msg { return Steam_Setting_Changed{field = p.field, index = p.index, flag = v} }
	appID := d.steam.appId == 0 ? "" : fmt.tprint(d.steam.appId)
	append(&rows,
		note(ctx, "Achievements, stats and cloud saves through Steam. Until the Steamworks SDK is part of the engine, games run its stub: achievements and stats are kept with the game's saves (and logged), so scripts can use them now and work unchanged on Steam later."),
		settingRow(ctx, "Steam app ID", skald.text_input(ctx, appID, Payload{.App_ID, -1}, onText, id = skald.hash_id("project-settings-steam-app-id"),
			width = tk.fieldM, placeholder = "480", padding = InspectorFieldPadding(ctx))),
		settingRow(ctx, "Cloud saves", skald.checkbox(ctx, d.steam.cloudSaves, "e.Save_Game and e.Load_Game use Steam Cloud files", Payload{.Cloud_Saves, -1}, onFlag,
			id = skald.hash_id("project-settings-steam-cloud"))),
		skald.divider(ctx),
		uiText(th, .Section, "Achievements"),
	)
	if len(d.achievements) == 0 do append(&rows, note(ctx, "None yet. Their names must match the API names set up on Steamworks."))
	key :: proc(i: int, field: string) -> skald.Widget_ID { return skald.hash_id(fmt.tprintf("steam-achievement-%d-%s", i, field)) }
	for a, i in d.achievements {
		remove := skald.button(ctx, ACTION_ICONS[.Delete], Msg(Steam_Achievement_Removed(i)), id = key(i, "remove"),
			bg = th.color.surface, fg = th.color.fg_muted, font_size = th.font.size_xs, padding = {tk.xs, tk.hair})
		hidden := skald.checkbox(ctx, a.hidden, "Hidden", Payload{.Hidden, i}, onFlag, id = key(i, "hidden"))
		// Two lines, so a narrow dialog (a tiled window) keeps every control in view
		append(&rows,
			skald.row(
				skald.text_input(ctx, a.name, Payload{.Name, i}, onText, id = key(i, "name"), width = tk.fieldM, placeholder = "API name", padding = InspectorFieldPadding(ctx)),
				skald.text_input(ctx, a.title, Payload{.Title, i}, onText, id = key(i, "title"), width = tk.fieldM, placeholder = "Title", padding = InspectorFieldPadding(ctx)),
				remove,
				spacing = th.spacing.xs, cross_align = .Center),
			skald.row(
				skald.text_input(ctx, a.description, Payload{.Description, i}, onText, id = key(i, "description"), width = tk.fieldXL, placeholder = "How to get it", padding = InspectorFieldPadding(ctx)),
				hidden,
				spacing = th.spacing.xs, cross_align = .Center),
		)
		if problem := AchievementNameProblem(d.achievements[:], i); problem != "" do append(&rows, note(ctx, problem, warning = true))
	}
	append(&rows,
		skald.button(ctx, fmt.tprintf("%s  Add Achievement", ACTION_ICONS[.Add]), Msg(Steam_Achievement_Added{}), id = skald.hash_id("steam-achievement-add"),
			bg = th.color.surface, fg = th.color.fg, padding = tk.fieldPadding, font_size = th.font.size_xs, radius = th.radius.sm),
		note(ctx, "Scripts unlock them by name: e.Steam_UnlockAchievement(ACHIEVEMENT_FIRST_BLOOD) (constants in scripts/assets.odin). Stats need no list: e.Steam_AddStat(\"ENEMIES\", 1), then e.Steam_StoreStats()."),
	)
	return skald.col(..rows[:], spacing = th.spacing.sm, padding = th.spacing.xs, cross_align = .Start)
}

// A labelled row of the Steam tab (its label has a tooltip: tooltips.odin)
@(private="file")
settingRow :: proc(ctx: ^skald.Ctx(Msg), label: string, control: skald.View) -> skald.View {
	tk := uiTokens(ctx)
	return skald.row(skald.col(tipLabel(ctx, label, uiText(ctx.theme, .Label, label)), width = tk.labelWidthWide), control,
		spacing = ctx.theme.spacing.sm, cross_align = .Center)
}
