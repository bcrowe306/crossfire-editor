package editor

import "core:fmt"
import "core:strings"
import "gui:skald"
import e "engine:."

/*
The Project Settings dialog (File > Project Settings): the game's name, resolution, how it scales
to the window, its background color, and the scene it starts in. Apply makes them one undoable
change (scene_actions.odin). Widget keys for UI tests: `project-settings-name`,
`project-settings-start`, `project-settings-apply`, `project-settings-cancel`.
*/
projectSettingsDialogView :: proc(s: ^State, ctx: ^skald.Ctx(Msg)) -> skald.View {
	th := ctx.theme
	d := &s.projectSettings
	row :: proc(ctx: ^skald.Ctx(Msg), label: string, control: skald.View) -> skald.View {
		return skald.row(
			skald.col(skald.text(label, ctx.theme.color.fg, ctx.theme.font.size_sm), width = 120),
			control,
			spacing = ctx.theme.spacing.sm,
			cross_align = .Center,
		)
	}
	scenes := make([dynamic]string, context.temp_allocator)
	for scene in s.project.scenes do append(&scenes, scene.name)
	modes := make([dynamic]string, context.temp_allocator)
	for mode in e.ScaleMode do append(&modes, fmt.tprint(mode))
	content: skald.View = skald.View_Spacer{size = 0}
	if d.open {
		content = skald.col(
			skald.text("Project Settings", th.color.fg, th.font.size_lg),
			// Copies: d lives in this frame's copy of the state (see the rule in CLAUDE.md)
			row(ctx, "Name", skald.text_input(ctx, strings.clone(d.name, context.temp_allocator),
				proc(v: string) -> Msg { return Project_Settings_Name_Changed(v) },
				id = skald.hash_id("project-settings-name"), width = 260)),
			row(ctx, "Resolution", skald.row(
				numberField(ctx, s, "project-settings-width", GameSizeTarget(0), f64(d.gameSize.x), 16, 0, 120, 16, 16384),
				skald.text("x", th.color.fg_muted, th.font.size_sm),
				numberField(ctx, s, "project-settings-height", GameSizeTarget(1), f64(d.gameSize.y), 16, 0, 120, 16, 16384),
				spacing = th.spacing.xs,
				cross_align = .Center,
			)),
			row(ctx, "Scaling", skald.select(ctx, fmt.tprint(d.scaleMode), modes[:],
				proc(v: string) -> Msg { return Project_Settings_Scale_Changed(v) },
				id = skald.hash_id("project-settings-scale"), width = 160)),
			row(ctx, "Background", skald.color_picker(ctx, d.background,
				proc(c: skald.Color) -> Msg { return Project_Settings_Background_Changed(c) },
				id = skald.hash_id("project-settings-background"), width = 160)),
			row(ctx, "Start scene", skald.select(ctx, strings.clone(d.startScene, context.temp_allocator), scenes[:],
				proc(v: string) -> Msg { return Project_Settings_Start_Changed(v) },
				id = skald.hash_id("project-settings-start"), width = 200)),
			skald.text("The scene the game starts in (Play, and exports). Play Scene (Ctrl+F5) starts in the open scene instead.",
				th.color.fg_muted, th.font.size_xs, max_width = 420),
			skald.spacer(th.spacing.sm),
			skald.row(
				skald.flex(1, skald.spacer(0)),
				skald.button(ctx, "Cancel", Msg(Project_Settings_Cancelled{}), id = skald.hash_id("project-settings-cancel"),
					bg = th.color.surface, fg = th.color.fg, font_size = th.font.size_sm),
				skald.button(ctx, "Apply", Msg(Project_Settings_Applied{}), id = skald.hash_id("project-settings-apply"),
					font_size = th.font.size_sm),
				spacing = th.spacing.sm,
			),
			spacing = th.spacing.sm,
			padding = th.spacing.lg,
			cross_align = .Stretch,
		)
	}
	return skald.dialog(ctx,
		open = d.open,
		on_dismiss = proc() -> Msg { return Project_Settings_Cancelled{} },
		content = content,
		id = skald.hash_id("project-settings-dialog"),
		width = 460,
	)
}
