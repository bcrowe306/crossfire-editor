package crossfire_editor

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "gui:skald"
import e "engine:."
import sdl "vendor:sdl3"

/*
The browser preview for scripts and scenes: what they are and where they're used, rather than
their contents.

A script file (`scriptInfoPreview`): each script it registers (`Script_Register(Name`, found in
its text, so it works before a build) as a global (listed in Project Settings > Globals) or a
node script, with the nodes it's attached to (a click opens the scene and selects the node) and,
once built, its exported fields; each data type it registers (`Data_Register(Name`) with its
data resources.

A scene (`scenePreview`): whether it's the start scene, its file, its nodes by kind, its camera,
the scripts and components it uses, Open / Play Scene / Set as Start, and its own settings
(scene_settings.odin): screen layers, background, gravity.

Widget keys: `preview-open-script`, `preview-script-usage-<i>`, `preview-scene-open`,
`preview-scene-play`, `preview-scene-start`, `scene-settings-layer-<1..8>`,
`scene-settings-background`, `scene-settings-background-color`, `scene-settings-gravity`,
`scene-settings-gravity-x`, `scene-settings-gravity-y`.
*/

// What a script file registers, found in its text
ScriptFileInfo :: struct {
	scripts: []string,
	dataTypes: []string,
}

/*
The scripts and data types a script file registers: the names in its `Script_Register(Name`
and `Data_Register(Name` calls.

Inputs:
- text: The file's text

Returns:
- Their names, in file order (temp allocated)
*/
ScriptFile_Registrations :: proc(text: string) -> ScriptFileInfo {
	find :: proc(text, call: string) -> []string {
		names := make([dynamic]string, context.temp_allocator)
		rest := text
		for {
			at := strings.index(rest, call)
			if at < 0 do break
			rest = rest[at + len(call):]
			end := 0
			for end < len(rest) && (rest[end] == '_' || (rest[end] >= 'a' && rest[end] <= 'z') || (rest[end] >= 'A' && rest[end] <= 'Z') || (rest[end] >= '0' && rest[end] <= '9')) do end += 1
			if end > 0 && !slice.contains(names[:], rest[:end]) do append(&names, rest[:end])
		}
		return names[:]
	}
	return {find(text, "Script_Register("), find(text, "Data_Register(")}
}

// A node using a script: the scene (or component) and the node, by index
ScriptUsage :: struct {
	scene, node: int,
}

// Every node, in scenes and components, with a script attached
Script_Usages :: proc(project: ^Project, script: string) -> []ScriptUsage {
	found := make([dynamic]ScriptUsage, context.temp_allocator)
	for &scene, i in project.scenes do for &node, j in scene.nodes do if NodeDef_Runs(&node, script) do append(&found, ScriptUsage{i, j})
	return found[:]
}

// The preview of a script file (replaces showing its contents)
@(private)
scriptInfoPreview :: proc(s: ^State, ctx: ^skald.Ctx(Msg), file: string) -> skald.View {
	tk := uiTokens(ctx)
	th := ctx.theme
	path, _ := filepath.join({s.project.rootPath, file}, context.temp_allocator)
	absolute, err := os.get_absolute_path(path, context.temp_allocator)
	if err != nil do absolute = path
	data, readErr := os.read_entire_file(path, context.temp_allocator)
	rows := make([dynamic]skald.View, context.temp_allocator)
	muted :: proc(ctx: ^skald.Ctx(Msg), text: string) -> skald.View {
		return uiText(ctx.theme, .Muted, text, max_width = previewTextWidth)
	}
	if readErr != nil {
		append(&rows, skald.text(fmt.tprintf("Couldn't read %s", file), th.color.danger, th.font.size_sm, max_width = previewTextWidth))
	} else {
		info := ScriptFile_Registrations(string(data))
		usageIndex := 0
		for name in info.scripts {
			global := false
			for g in s.project.globals do if g.script == name do global = true
			usages := Script_Usages(&s.project, name)
			kind := global ? "Global script: runs for the whole game (Project Settings > Globals)" : "Node script"
			append(&rows, uiText(th, .Value, fmt.tprintf("%s  %s", ICON_CODE, name), max_width = previewTextWidth))
			append(&rows, muted(ctx, kind))
			if !global {
				if len(usages) == 0 {
					append(&rows, muted(ctx, "Not attached to any node yet: pick it in a node's Script section."))
				} else {
					append(&rows, muted(ctx, fmt.tprintf("Attached to %d node%s:", len(usages), len(usages) == 1 ? "" : "s")))
				}
				for u in usages {
					scene := &s.project.scenes[u.scene]
					label := fmt.tprintf("%s %s / %s", Scene_IsComponent(scene) ? ICON_CUBES : ICON_FILM, scene.name, Scene_NodePath(scene, -1, u.node, context.temp_allocator)[1:])
					// Clickable text rather than a button: a long path wraps instead of overflowing
					id := skald.hash_id(fmt.tprintf("preview-script-usage-%d", usageIndex))
					hovered := skald.widget_hovered(ctx, id)
					append(&rows, skald.clickable(ctx,
						skald.col(skald.text(label, hovered ? th.color.primary : th.color.fg, th.font.size_xs, max_width = previewTextWidth - th.spacing.sm * 2),
							padding = th.spacing.xs, bg = th.color.surface, radius = th.radius.sm),
						Msg(Script_Usage_Clicked{u.scene, u.node}), id = id, focusable = false))
					usageIndex += 1
				}
			}
			// Its exported fields, once built
			for &desc in s.scripts.scripts do if desc.name == name && len(desc.fields) > 0 {
				names := make([dynamic]string, context.temp_allocator)
				for f in desc.fields do append(&names, f.type == .Node ? fmt.tprintf("%s (^%s)", f.name, f.hint) : f.name)
				append(&rows, muted(ctx, fmt.tprintf("Fields: %s", strings.join(names[:], ", ", context.temp_allocator))))
			}
			// The events it publishes, once built
			for &desc in s.scripts.scripts do if desc.name == name && len(desc.events) > 0 {
				names := make([dynamic]string, context.temp_allocator)
				for ev in desc.events do append(&names, Event_ShortName(ev.name))
				append(&rows, muted(ctx, fmt.tprintf("Events: %s", strings.join(names[:], ", ", context.temp_allocator))))
			}
			append(&rows, skald.spacer(th.spacing.xs))
		}
		for name in info.dataTypes {
			count := 0
			for d in s.project.data do if d.type == name do count += 1
			append(&rows, uiText(th, .Value, fmt.tprintf("%s  %s", ICON_DATABASE, name), max_width = previewTextWidth))
			append(&rows, muted(ctx, fmt.tprintf("Data type: %d data resource%s (the browser's Data folder)", count, count == 1 ? "" : "s")))
			append(&rows, skald.spacer(th.spacing.xs))
		}
		if len(info.scripts) == 0 && len(info.dataTypes) == 0 {
			append(&rows, muted(ctx, "Registers no script or data type: helper code the scripts share."))
		}
		if s.scripts.status != .Ready && len(info.scripts) > 0 {
			append(&rows, muted(ctx, fmt.tprintf("Build Scripts%s to see their fields.", keyParen(s, .Build_Scripts))))
		}
	}
	return skald.col(
		skald.row(
			uiText(th, .Value, fmt.tprintf("%s  %s", ICON_FILE_CODE, filepath.base(file)), max_width = previewTextWidth - tk.fieldXS),
			skald.flex(1, skald.spacer(0)),
			skald.button(ctx, "Open", Msg(Script_Open_File{file = strings.clone(absolute, context.temp_allocator), line = 1}),
				id = skald.hash_id("preview-open-script"), font_size = th.font.size_sm, padding = tk.fieldPadding),
			cross_align = .Center,
		),
		skald.flex(1, skald.scroll(ctx, {0, 0}, skald.col(..rows[:], spacing = tk.xxs, cross_align = .Start), id = skald.hash_id("preview-script-scroll"))),
		spacing = th.spacing.xs,
		cross_align = .Stretch,
	)
}

// The preview of a scene: what's in it, its actions and its own settings
@(private)
scenePreview :: proc(s: ^State, ctx: ^skald.Ctx(Msg), index: int) -> skald.View {
	tk := uiTokens(ctx)
	th := ctx.theme
	scene := &s.project.scenes[index]
	rows := make([dynamic]skald.View, context.temp_allocator)
	muted :: proc(ctx: ^skald.Ctx(Msg), text: string) -> skald.View {
		return uiText(ctx.theme, .Muted, text, max_width = previewTextWidth)
	}
	small :: proc(ctx: ^skald.Ctx(Msg), label, key: string, msg: Msg) -> skald.View {
		tk := uiTokens(ctx)
		th := ctx.theme
		return skald.button(ctx, label, msg, id = skald.hash_id(key), bg = th.color.surface, fg = th.color.fg, font_size = th.font.size_xs, padding = tk.fieldPadding)
	}
	start := s.project.startScene == scene.name
	append(&rows, uiText(th, .Value, fmt.tprintf("%s  %s%s", ICON_FILM, scene.name, start ? "  (start scene)" : ""), max_width = previewTextWidth))
	append(&rows, muted(ctx, fmt.tprintf("scenes/%s.scene.xml", scene.name)))

	// Its nodes by kind, most first
	counts: [NodeKind]int
	for node in scene.nodes do counts[node.kind] += 1
	Count :: struct { kind: NodeKind, n: int }
	list := make([dynamic]Count, context.temp_allocator)
	for n, kind in counts do if n > 0 do append(&list, Count{kind, n})
	slice.sort_by(list[:], proc(a, b: Count) -> bool { return a.n > b.n || (a.n == b.n && a.kind < b.kind) })
	parts := make([dynamic]string, context.temp_allocator)
	for c in list do append(&parts, fmt.tprintf("%d %v", c.n, c.kind))
	append(&rows, muted(ctx, len(scene.nodes) == 0 ? "No nodes" : fmt.tprintf("%d node%s: %s", len(scene.nodes), len(scene.nodes) == 1 ? "" : "s", strings.join(parts[:], ", ", context.temp_allocator))))
	camera := ""
	for node in scene.nodes do if node.kind == .Camera {
		camera = node.name
		break
	}
	append(&rows, muted(ctx, camera == "" ? "No camera: the game shows the game area as it is" : fmt.tprintf("Camera: %s", camera)))
	scripts := make([dynamic]string, context.temp_allocator)
	components := make([dynamic]string, context.temp_allocator)
	for node in scene.nodes {
		if node.script != "" && !slice.contains(scripts[:], node.script) do append(&scripts, node.script)
		for extra in node.moreScripts do if !slice.contains(scripts[:], extra.name) do append(&scripts, extra.name)
		if node.customKind != "" && !slice.contains(scripts[:], node.customKind) do append(&scripts, node.customKind)
		if node.kind == .Component && node.component != "" {
			name := ComponentName(node.component)
			if !slice.contains(components[:], name) do append(&components, name)
		}
	}
	if len(scripts) > 0 do append(&rows, muted(ctx, fmt.tprintf("Scripts: %s", strings.join(scripts[:], ", ", context.temp_allocator))))
	if len(components) > 0 do append(&rows, muted(ctx, fmt.tprintf("Components: %s", strings.join(components[:], ", ", context.temp_allocator))))
	buttons := make([dynamic]skald.View, context.temp_allocator)
	append(&buttons, small(ctx, "Open", "preview-scene-open", Msg(Scene_Action{.Open, index})))
	append(&buttons, small(ctx, "Play Scene", "preview-scene-play", Msg(Scene_Action{.Play, index})))
	if !start do append(&buttons, small(ctx, "Set as Start", "preview-scene-start", Msg(Scene_Action{.Set_Start, index})))
	append(&rows, skald.wrap_row(..buttons[:], spacing = th.spacing.xs))

	// Its own settings
	append(&rows, skald.spacer(th.spacing.xs))
	append(&rows, uiText(th, .Value, "Scene settings", max_width = previewTextWidth))
	settings := scene.settings
	layers := make([dynamic]skald.View, context.temp_allocator)
	for layer in e.RenderLayer {
		on := layer in settings.screenLayers
		append(&layers, skald.button(ctx, fmt.tprintf("%d", int(layer) + 1), Msg(Scene_Screen_Layer_Toggled{index, layer}),
			id = skald.hash_id(fmt.tprintf("scene-settings-layer-%d", int(layer) + 1)),
			bg = on ? th.color.primary : th.color.surface, fg = on ? th.color.on_primary : th.color.fg_muted,
			font_size = th.font.size_xs, padding = {tk.xs, tk.hair}))
	}
	append(&rows, muted(ctx, "Screen layers: drawn without the camera (HUDs, menus)"))
	append(&rows, skald.wrap_row(..layers[:], spacing = tk.xxs))

	Payload :: struct { scene: int, on: bool, color: sdl.Color }
	bgPayload := Payload{index, settings.hasBackground, settings.background}
	background := SceneSettings_Background(&s.project, scene)
	bgRow := make([dynamic]skald.View, context.temp_allocator)
	append(&bgRow, skald.checkbox(ctx, settings.hasBackground, "Own background", bgPayload,
		proc(p: Payload, on: bool) -> Msg { return Scene_Background_Changed{p.scene, on, p.color, on} },
		id = skald.hash_id("scene-settings-background")))
	if settings.hasBackground {
		linear := skald.rgb(u32(background.r) << 16 | u32(background.g) << 8 | u32(background.b))
		append(&bgRow, skald.color_picker(ctx, linear, bgPayload, proc(p: Payload, c: skald.Color) -> Msg {
			color, _ := e.ParseColor(fmt.tprintf("#%s", skald.color_to_hex(c)))
			return Scene_Background_Changed{p.scene, true, color, false}
		}, id = skald.hash_id("scene-settings-background-color"), width = tk.fieldXS))
	}
	append(&rows, skald.wrap_row(..bgRow[:], spacing = th.spacing.xs))

	append(&rows, ..sceneLightingRows(ctx, s, index, previewTextWidth))

	gravity := SceneSettings_Gravity(&s.project, scene)
	GravityPayload :: struct { scene: int }
	append(&rows, skald.checkbox(ctx, settings.hasGravity, "Own gravity", GravityPayload{index},
		proc(p: GravityPayload, on: bool) -> Msg { return Scene_Gravity_Toggled{p.scene, on} },
		id = skald.hash_id("scene-settings-gravity")))
	if settings.hasGravity {
		append(&rows, skald.row(
			numberField(ctx, s, "scene-settings-gravity-x", SceneGravityTarget{index, 0}, f64(gravity.x), 10, 0, 80),
			numberField(ctx, s, "scene-settings-gravity-y", SceneGravityTarget{index, 1}, f64(gravity.y), 10, 0, 80),
			uiText(th, .Muted, "px/s²", max_width = previewTextWidth),
			spacing = th.spacing.xs,
			cross_align = .Center,
		))
	} else {
		append(&rows, muted(ctx, fmt.tprintf("The project's: %v, %v px/s²", gravity.x, gravity.y)))
	}
	return skald.scroll(ctx, {0, 0}, skald.col(..rows[:], spacing = tk.xs, cross_align = .Start), id = skald.hash_id("preview-scene-scroll"))
}
