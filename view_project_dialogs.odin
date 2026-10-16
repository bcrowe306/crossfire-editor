package editor

import "core:fmt"
import "gui:skald"

/*
Dialogs for the project session (project_session.odin):

	save changes?   before quitting or switching projects with unsaved changes:
	                Save / Don't Save / Cancel
	new project     a name and a folder to create it in

Widget keys for UI tests: `confirm-save`, `confirm-discard`, `confirm-cancel`, `new-project-name`,
`new-project-location`, `new-project-browse`, `new-project-create`, `new-project-cancel`.
*/
confirmDialogView :: proc(s: ^State, ctx: ^skald.Ctx(Msg)) -> skald.View {
	th := ctx.theme
	what := "continuing"
	#partial switch s.session.confirm.pending {
	case .Quit:         what = "quitting"
	case .New_Project:  what = "creating a new project"
	case .Open_Project: what = "opening another project"
	}
	return skald.dialog(ctx,
		open = s.session.confirm.open,
		on_dismiss = proc() -> Msg { return Confirm_Chosen(.Cancel) },
		content = skald.col(
			skald.text(fmt.tprintf("Save changes to %s?", s.project.name), th.color.fg, th.font.size_lg),
			skald.text(fmt.tprintf("The project has unsaved changes. Save them before %s?", what), th.color.fg_muted, th.font.size_sm),
			skald.spacer(th.spacing.sm),
			skald.row(
				skald.button(ctx, "Cancel", Msg(Confirm_Chosen(.Cancel)), id = skald.hash_id("confirm-cancel"),
					bg = th.color.surface, fg = th.color.fg, font_size = th.font.size_sm),
				skald.flex(1, skald.spacer(0)),
				skald.button(ctx, "Don't Save", Msg(Confirm_Chosen(.Discard)), id = skald.hash_id("confirm-discard"),
					bg = th.color.danger, fg = th.color.on_primary, font_size = th.font.size_sm),
				skald.button(ctx, "Save", Msg(Confirm_Chosen(.Save)), id = skald.hash_id("confirm-save"),
					font_size = th.font.size_sm),
				spacing = th.spacing.sm,
			),
			spacing = th.spacing.xs,
			padding = th.spacing.lg,
			cross_align = .Stretch,
		),
		id = skald.hash_id("confirm-dialog"),
		initial_focus = skald.hash_id("confirm-save"),
	)
}

newProjectDialogView :: proc(s: ^State, ctx: ^skald.Ctx(Msg)) -> skald.View {
	th := ctx.theme
	np := &s.session.newProject
	label :: proc(ctx: ^skald.Ctx(Msg), text: string) -> skald.View {
		return skald.col(skald.text(text, ctx.theme.color.fg, ctx.theme.font.size_sm), width = 80)
	}
	return skald.dialog(ctx,
		open = np.open,
		on_dismiss = proc() -> Msg { return New_Project_Cancelled{} },
		content = skald.col(
			skald.text("New Project", th.color.fg, th.font.size_lg),
			skald.row(
				label(ctx, "Name"),
				skald.flex(1, skald.text_input(ctx, np.name,
					proc(v: string) -> Msg { return New_Project_Name_Changed(v) },
					id = skald.hash_id("new-project-name"))),
				spacing = th.spacing.sm,
				cross_align = .Center,
			),
			skald.row(
				label(ctx, "Location"),
				skald.flex(1, skald.text_input(ctx, np.location,
					proc(v: string) -> Msg { return New_Project_Location_Changed(v) },
					id = skald.hash_id("new-project-location"))),
				skald.button(ctx, "Browse...", Msg(New_Project_Browse{}), id = skald.hash_id("new-project-browse"),
					bg = th.color.surface, fg = th.color.fg, font_size = th.font.size_sm),
				spacing = th.spacing.sm,
				cross_align = .Center,
			),
			skald.text(fmt.tprintf("Creates the folder %s/%s with project.xml, a Main scene and assets/.", np.location, np.name),
				th.color.fg_muted, th.font.size_xs, max_width = 440),
			skald.spacer(th.spacing.sm),
			skald.row(
				skald.flex(1, skald.spacer(0)),
				skald.button(ctx, "Cancel", Msg(New_Project_Cancelled{}), id = skald.hash_id("new-project-cancel"),
					bg = th.color.surface, fg = th.color.fg, font_size = th.font.size_sm),
				skald.button(ctx, "Create", Msg(New_Project_Created{}), id = skald.hash_id("new-project-create"),
					font_size = th.font.size_sm),
				spacing = th.spacing.sm,
			),
			spacing = th.spacing.sm,
			padding = th.spacing.lg,
			cross_align = .Stretch,
		),
		id = skald.hash_id("new-project-dialog"),
		initial_focus = skald.hash_id("new-project-name"),
		width = 480,
	)
}

/*
New Script: a name, then Create writes scripts/<name>.odin from the template, attaches it to the
selected node, opens it in the code editor and builds the scripts. Keys: `new-script-name`,
`new-script-create`, `new-script-cancel`.
*/
newScriptDialogView :: proc(s: ^State, ctx: ^skald.Ctx(Msg)) -> skald.View {
	th := ctx.theme
	name := s.newScript.name
	problem := ScriptNameProblem(name)
	scene := &s.project.scenes[s.currentScene]
	target := s.selectedNode >= 0 && s.selectedNode < len(scene.nodes) ? fmt.tprintf(" and attaches it to %s", scene.nodes[s.selectedNode].name) : ""
	info := name == "" ? "A struct and its ready/update procedures, in the project's scripts package." :
		problem != "" ? problem : fmt.tprintf("Creates %s%s, then opens it in your code editor.", ScriptFileFor(name), target)
	return skald.dialog(ctx,
		open = s.newScript.open,
		on_dismiss = proc() -> Msg { return New_Script_Cancelled{} },
		content = skald.col(
			skald.text("New Script", th.color.fg, th.font.size_lg),
			skald.row(
				skald.col(skald.text("Name", th.color.fg, th.font.size_sm), width = 60),
				skald.flex(1, skald.text_input(ctx, name,
					proc(v: string) -> Msg { return New_Script_Name_Changed(v) },
					id = skald.hash_id("new-script-name"), placeholder = "PlayerController")),
				spacing = th.spacing.sm,
				cross_align = .Center,
			),
			skald.text(info, problem != "" && name != "" ? th.color.warning : th.color.fg_muted, th.font.size_xs, max_width = 400),
			skald.spacer(th.spacing.sm),
			skald.row(
				skald.flex(1, skald.spacer(0)),
				skald.button(ctx, "Cancel", Msg(New_Script_Cancelled{}), id = skald.hash_id("new-script-cancel"),
					bg = th.color.surface, fg = th.color.fg, font_size = th.font.size_sm),
				skald.button(ctx, "Create", Msg(New_Script_Created{}), id = skald.hash_id("new-script-create"),
					font_size = th.font.size_sm, disabled = problem != ""),
				spacing = th.spacing.sm,
			),
			spacing = th.spacing.sm,
			padding = th.spacing.lg,
			cross_align = .Stretch,
		),
		id = skald.hash_id("new-script-dialog"),
		initial_focus = skald.hash_id("new-script-name"),
		width = 440,
	)
}
