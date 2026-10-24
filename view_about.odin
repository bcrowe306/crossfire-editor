package crossfire_editor

import "core:fmt"
import "core:strings"
import "gui:skald"
import sdl "vendor:sdl3"
import stbi "vendor:stb/image"

/*
Help > About: the logo, the editor's version (`EDITOR_VERSION`: the release tag CI builds with,
`git describe` in local builds), the Odin it builds games with and links to the project.
*/

// The editor's version: the release tag (CI passes -define:EDITOR_VERSION=v0.2.0), else "dev"
EDITOR_VERSION :: #config(EDITOR_VERSION, "dev")

// Where the source and releases are
EDITOR_REPOSITORY :: "https://github.com/bcrowe306/crossfire-editor"
ENGINE_REPOSITORY :: "https://github.com/bcrowe306/crossfire-engine"
ENGINE_DOCS :: "https://bcrowe306.github.io/crossfire-engine/engine/"

// The logo as a Skald image (uploaded the first time the dialog shows)
@(private="file")
ABOUT_LOGO :: "about-logo"
@(private="file")
logoUploaded: bool

// Opens a web page in the browser (an About link)
About_Link_Opened :: distinct string

aboutDialogView :: proc(s: ^State, ctx: ^skald.Ctx(Msg)) -> skald.View {
	// Closed: no content (its buttons would stay clickable where they were drawn: closedDialog)
	if !s.aboutOpen do return closedDialog(ctx, "about-dialog")
	th := ctx.theme
	if !logoUploaded && ctx.renderer != nil {
		logoUploaded = true
		w, h, channels: i32
		pixels := stbi.load_from_memory(raw_data(WINDOW_ICON), i32(len(WINDOW_ICON)), &w, &h, &channels, 4)
		if pixels != nil {
			defer stbi.image_free(pixels)
			_ = skald.image_load_pixels(ctx.renderer, ABOUT_LOGO, u32(w), u32(h), pixels[:w * h * 4])
		}
	}
	Logo :: struct { ready: bool }
	data := new_clone(Logo{logoUploaded}, context.temp_allocator)
	logo := skald.canvas(ctx, data, proc(d: ^Logo, p: skald.Canvas_Painter) {
		if d.ready do skald.draw_image(p.r, ABOUT_LOGO, p.bounds, .Contain)
	}, id = skald.hash_id("about-logo"), width = 128, height = 128)
	link :: proc(ctx: ^skald.Ctx(Msg), key, label, url: string) -> skald.View {
		th := ctx.theme
		return skald.button(ctx, label, Msg(About_Link_Opened(url)), id = skald.hash_id(key),
			bg = th.color.surface, fg = th.color.primary, padding = {th.spacing.sm, 2}, font_size = th.font.size_sm, radius = th.radius.sm)
	}
	return skald.dialog(ctx,
		open = s.aboutOpen,
		on_dismiss = proc() -> Msg { return About_Closed{} },
		content = skald.col(
			skald.row(skald.flex(1, skald.spacer(0)), logo, skald.flex(1, skald.spacer(0))),
			skald.text(APP_NAME, th.color.fg, th.font.size_lg),
			skald.text(fmt.tprintf("Version %s", EDITOR_VERSION), th.color.fg_muted, th.font.size_sm),
			skald.text(fmt.tprintf("Games are built with Odin %s and the Crossfire Engine.", ODIN_VERSION), th.color.fg_muted, th.font.size_sm, max_width = 360),
			skald.row(
				link(ctx, "about-editor", "Editor on GitHub", EDITOR_REPOSITORY),
				link(ctx, "about-engine", "Engine on GitHub", ENGINE_REPOSITORY),
				link(ctx, "about-docs", "Engine docs", ENGINE_DOCS),
				spacing = th.spacing.xs,
			),
			skald.row(
				skald.flex(1, skald.spacer(0)),
				skald.button(ctx, "Close", Msg(About_Closed{}), id = skald.hash_id("about-close")),
			),
			spacing = th.spacing.sm,
			padding = th.spacing.lg,
			cross_align = .Center,
		),
		id = skald.hash_id("about-dialog"),
		width = 420,
	)
}

/*
The user manual (docs/manual in the editor's repository), where it's published: its contents, or
one of its pages ("tilemaps" for docs/manual/tilemaps.md). Help > User Manual (F1) and the panels'
Manual buttons open it in the system's browser. It's published on the website, crossfireengine.io,
where a page's address is its file name with dashes for underscores (`audio_effects_and_music.md`
is `/manual/audio-effects-and-music/`: the website's scripts/sync-manual.mjs).
*/
MANUAL_URL :: "https://crossfireengine.io/manual/"

// Opens the manual's contents ("") or a page of it in the browser
Manual_Open :: proc(page: string) {
	About_OpenLink(Manual_URL(page))
}

// The website's address of a manual page ("" for its contents; "scene_changes" for scene_changes.md)
Manual_URL :: proc(page: string) -> string {
	if page == "" do return MANUAL_URL
	slug, _ := strings.replace_all(page, "_", "-", context.temp_allocator)
	return fmt.tprintf("%s%s/", MANUAL_URL, slug)
}

// A panel's link to its manual page
Manual_Opened :: distinct string

// Opens a link from the About dialog (SDL hands it to the system's browser)
About_OpenLink :: proc(url: string) {
	_ = sdl.OpenURL(fmt.ctprintf("%s", url))
}

/*
Opens a link in the system's browser and remembers it (`State.lastLink`, owned). While a test
script runs nothing opens: the UI tests check the address instead (driver check `last_link`).
*/
Links_Open :: proc(state: ^State, url: string) {
	delete(state.lastLink)
	state.lastLink = strings.clone(url)
	logLine(state, .Info, fmt.aprintf("Opening %s", url))
	if ScriptDriver_Active() do return
	About_OpenLink(url)
}
