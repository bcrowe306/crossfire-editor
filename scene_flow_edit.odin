package crossfire_editor

import "core:fmt"
import "core:reflect"
import "core:strings"
import "gui:skald"
import e "engine:."

/*
Scene changes in the editor (the engine's scene_flow.odin): the project's transition and loading
scene, edited in Project Settings > General (its draft, applied as one `.Project` step), and the
Button actions that open a scene over the playing one (`push:<Name>`) or close it (`pop`).

- **Data:** `Project.transition` (`e.Transition`, plain) and `Project.loadingScene` (owned),
  written on project.xml's root (`transition`, `transitionTime`, `transitionColor`,
  `loadingScene`) when set; in the `.Project` snapshot. Renaming a scene renames them and the
  actions that name it (`Project_RenameScene`); removing the loading scene clears it.
- **Messages:** `Project_Settings_Transition_Changed{field, text, value}` and
  `Project_Settings_Loading_Changed`, on the dialog's draft (`ProjectSettingsDialog.transition`,
  `loadingScene`), applied with the rest.
*/

// What a transition message changes
TransitionField :: enum {
	Kind,
	Duration,
	Color,
}

// The Project Settings draft's transition: its kind (`text`), duration (`value`) or color (`text`)
Project_Settings_Transition_Changed :: struct {
	field: TransitionField,
	text: string,
	value: f64,
}

// The Project Settings draft's loading scene ("" or SCENE_NONE: none)
Project_Settings_Loading_Changed :: distinct string

// The transition time's number field (number_field.odin)
TransitionTimeTarget :: struct {}

// The loading scene choice for none
LOADING_NONE :: "(none: every scene is built at the start)"

/*
Applies a transition or loading scene message to the Project Settings draft.

Returns:
- Whether the message was this file's
*/
SceneFlowEdit_Update :: proc(s: ^State, m: Msg) -> bool {
	d := &s.projectSettings
	#partial switch v in m {
	case Project_Settings_Transition_Changed:
		switch v.field {
		case .Kind: if k, ok := reflect.enum_from_name(e.TransitionKind, v.text); ok do d.transition.kind = k
		case .Duration: d.transition.duration = clamp(f32(v.value), 0, 10)
		case .Color: if c, ok := e.ParseColor(v.text); ok do d.transition.color = c
		}
	case Project_Settings_Loading_Changed:
		delete(d.loadingScene)
		d.loadingScene = strings.clone(string(v) == LOADING_NONE ? "" : string(v))
	case:
		return false
	}
	return true
}

/*
Project Settings > General's rows for scene changes.
*/
sceneFlowSettingRows :: proc(ctx: ^skald.Ctx(Msg), s: ^State) -> []skald.View {
	th := ctx.theme
	d := &s.projectSettings
	rows := make([dynamic]skald.View, context.temp_allocator)
	Payload :: struct { field: TransitionField }
	kinds := reflect.enum_field_names(e.TransitionKind)
	append(&rows, settingRow(ctx, "Scene change", skald.select(ctx, fmt.tprint(d.transition.kind), kinds, Payload{.Kind},
		proc(p: Payload, v: string) -> Msg { return Project_Settings_Transition_Changed{field = p.field, text = v} },
		id = skald.hash_id("project-settings-transition"), width = 160)))
	if d.transition.kind != .None {
		append(&rows, settingRow(ctx, "Change time", numberField(ctx, s, "project-settings-transition-time", TransitionTimeTarget{}, f64(d.transition.duration), 0.1, 2, 120, 0, 10)))
		c := d.transition.color
		linear := skald.rgb(u32(c.r) << 16 | u32(c.g) << 8 | u32(c.b))
		append(&rows, settingRow(ctx, "Change color", skald.color_picker(ctx, linear, Payload{.Color},
			proc(p: Payload, color: skald.Color) -> Msg { return Project_Settings_Transition_Changed{field = p.field, text = fmt.tprintf("#%s", skald.color_to_hex(color))} },
			id = skald.hash_id("project-settings-transition-color"), width = 160)))
	}
	append(&rows, skald.text("How the screen changes when a Menu item or Button goes to another scene (or code calls e.Game_ChangeScene): covered by a fade or a wipe over the first half of the time, the scene changes, uncovered over the second half.",
		th.color.fg_muted, th.font.size_xs, max_width = 420))
	scenes := make([dynamic]string, context.temp_allocator)
	append(&scenes, LOADING_NONE)
	for name in Project_SceneNames(&s.project) do append(&scenes, name)
	append(&rows, settingRow(ctx, "Loading scene", skald.select(ctx, d.loadingScene == "" ? LOADING_NONE : strings.clone(d.loadingScene, context.temp_allocator), scenes[:],
		proc(v: string) -> Msg { return Project_Settings_Loading_Changed(v) },
		id = skald.hash_id("project-settings-loading"), width = 200)))
	append(&rows, skald.text("With a loading scene, the game builds only the start scene and the loading scene when it starts; any other scene is built when it's entered, after the loading scene has shown while its images and sounds load. A ProgressBar with Shows loading in the loading scene shows how far it's got.",
		th.color.fg_muted, th.font.size_xs, max_width = 420))
	return rows[:]
}

// A labelled row like the other Project Settings rows (their helper is private to its file)
@(private="file")
settingRow :: proc(ctx: ^skald.Ctx(Msg), label: string, control: skald.View) -> skald.View {
	return skald.row(
		skald.col(tipLabel(ctx, label, skald.text(label, ctx.theme.color.fg, ctx.theme.font.size_sm)), width = 120),
		control,
		spacing = ctx.theme.spacing.sm,
		cross_align = .Center,
	)
}
