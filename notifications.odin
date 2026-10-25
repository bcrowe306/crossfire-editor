package crossfire_editor

import "core:fmt"
import "core:strings"
import "core:time"
import "gui:skald"
import sdl "vendor:sdl3"

/*
Notifications: toasts in the window's bottom-right corner (TODO.md's "UI and UX" round
"Feedback", 2026-10-25). The user's decision: no motion, so a toast appears and goes at once.

- **Toasts** (`Notify`): a line of text with its level's color (a stripe, the icon), stacked
  newest at the bottom, at most `TOAST_MAX` (the oldest one that isn't an error goes first). Info
  and success go after `TOAST_SECONDS`, warnings after `TOAST_WARNING_SECONDS`; **errors stay
  until dismissed**. A click on the card (or its ×) dismisses it; an optional action button
  (`ToastAction`: Show Output, Show Console, Show Problems, Open Folder) runs and dismisses it.
  Info and success toasts without a button are passive (`Toast_IsPassive`): while only they show,
  or while a dialog is open, the stack lets the pointer through to what's under it and has no ×.
  `Notifications_Expire` drops the old ones after every message; the view asks for a frame at the
  next deadline and sends `Toasts_Expired` then.
- **Jobs** (`ToastJob`): what runs in the background shows as a toast with a progress bar while
  it runs, above the others, without state of its own: `Notifications_Jobs` reads it from the
  state each frame (a Play or scripts build, exports, installing Odin or Emscripten, a plugin's
  build, a project archive). Exports know their steps; the others' bar is the time taken against
  how long the same job took last time (`Notifications_Follow` remembers it), or just the time
  taken the first time. Their end is a toast of its own where the job reports it (a failure is an
  error with its action).
- Every toast's text is also in the Console (the places that notify log too).

Keys: the stack `toasts`, a toast `toast-<i>` (by its place, oldest first), its × `toast-close-<i>`,
its action `toast-action-<i>`; a job's `toast-job-<Job>`. Driver checks `toasts <n>`,
`toast <i> <text>` (contains), `toast_jobs <n>`. Tests: `notifications_test.odin`;
tests/ui/feedback.script.
*/

// How long an info or success toast shows, and a warning
TOAST_SECONDS :: 4
TOAST_WARNING_SECONDS :: 8
// The most toasts shown at once (jobs aside)
TOAST_MAX :: 4

ToastLevel :: enum {
	Info,
	Success,
	Warning,
	// Stays until dismissed
	Error,
}

// A toast's button
ToastAction :: enum {
	None,
	Show_Output,
	Show_Console,
	Show_Problems,
	// `Toast.actionArg`: the folder, in the file manager
	Open_Folder,
}

// The button's label
TOAST_ACTION_LABELS := [ToastAction]string {
	.None          = "",
	.Show_Output   = "Show Output",
	.Show_Console  = "Show Console",
	.Show_Problems = "Show Problems",
	.Open_Folder   = "Open Folder",
}

Toast :: struct {
	// Unique while the editor runs (the messages name toasts by it)
	id: int,
	level: ToastLevel,
	// Owned
	text: string,
	action: ToastAction,
	// The action's argument (Open_Folder's folder; owned, "" none)
	actionArg: string,
	shown: time.Tick,
	// How long it shows; 0 until dismissed
	life: time.Duration,
}

// What runs in the background, shown as a toast with progress
ToastJob :: enum {
	Play_Build,
	Scripts_Build,
	Export,
	Install_Odin,
	Install_Emscripten,
	Plugin_Build,
	Archive,
}

// A job's toast this frame (`Notifications_Jobs`)
JobToast :: struct {
	job: ToastJob,
	// Temp allocated
	label: string,
	// 0..1, or -1 when it isn't known (the time taken shows alone)
	fraction: f32,
	elapsed: time.Duration,
}

// The toasts (part of State)
Notifications :: struct {
	toasts: [dynamic]Toast,
	nextId: int,
	// The jobs running after the last message, when each started, and how long each took last
	running: bit_set[ToastJob],
	started: [ToastJob]time.Tick,
	lastTook: [ToastJob]time.Duration,
}

// A click on a toast or its ×: it goes (by `Toast.id`)
Toast_Dismissed :: distinct int
// Its action button: runs it, and it goes
Toast_Action_Clicked :: distinct int
// A toast's time is up (the view sends it at the deadline)
Toasts_Expired :: struct {}
// Shows a toast (`Notify` from a message: the test driver's `send Notify_Requested`); the text
// lives for the frame (cloned)
Notify_Requested :: struct {
	level: ToastLevel,
	action: ToastAction,
	text: string,
}

/*
Adds a toast.

Inputs:
- n: The toasts
- level: Its level (errors stay until dismissed)
- text: What it says (cloned)
- action: Its button (`.None`: none)
- actionArg: The action's argument (cloned)
- now: The time it shows from

Returns:
- Its id
*/
Notifications_Push :: proc(n: ^Notifications, level: ToastLevel, text: string, action := ToastAction.None, actionArg := "", now := time.Tick{}) -> int {
	life: time.Duration
	switch level {
	case .Info, .Success: life = TOAST_SECONDS * time.Second
	case .Warning:        life = TOAST_WARNING_SECONDS * time.Second
	case .Error:          life = 0
	}
	n.nextId += 1
	append(&n.toasts, Toast{
		id = n.nextId, level = level, text = strings.clone(text), action = action,
		actionArg = strings.clone(actionArg), shown = now, life = life,
	})
	// Too many: the oldest that isn't an error goes (all errors: the oldest)
	for len(n.toasts) > TOAST_MAX {
		drop := 0
		for t, i in n.toasts do if t.level != .Error {
			drop = i
			break
		}
		toastFree(&n.toasts[drop])
		ordered_remove(&n.toasts, drop)
	}
	return n.nextId
}

/*
Adds a toast now (`Notifications_Push` with the time).

Inputs:
- state: The editor state
- level, text, action, actionArg: As `Notifications_Push`
*/
Notify :: proc(state: ^State, level: ToastLevel, text: string, action := ToastAction.None, actionArg := "") {
	Notifications_Push(&state.notifications, level, text, action, actionArg, time.tick_now())
}

/*
Whether a toast is a passive notice: info or success without a button. While every toast shown is
(and the jobs' are), the stack leaves the pointer to what's under it (Skald's `pass_through`): a
"Saved" after Ctrl+S never takes the click meant for the inspector under it. They go by
themselves and have no ×.
*/
Toast_IsPassive :: proc(t: Toast) -> bool {
	return (t.level == .Info || t.level == .Success) && t.action == .None
}

/*
Drops the toasts whose time is up.

Inputs:
- n: The toasts
- now: The time

Returns:
- Whether any went
*/
Notifications_Expire :: proc(n: ^Notifications, now: time.Tick) -> bool {
	gone := false
	for i := len(n.toasts) - 1; i >= 0; i -= 1 {
		t := &n.toasts[i]
		if t.life > 0 && time.tick_diff(t.shown, now) >= t.life {
			toastFree(t)
			ordered_remove(&n.toasts, i)
			gone = true
		}
	}
	return gone
}

/*
When the next toast's time is up, from now.

Returns:
- The time left, and whether a toast has a time at all
*/
Notifications_NextDeadline :: proc(n: ^Notifications, now: time.Tick) -> (time.Duration, bool) {
	best: time.Duration
	found := false
	for t in n.toasts do if t.life > 0 {
		left := t.life - time.tick_diff(t.shown, now)
		if !found || left < best do best = left
		found = true
	}
	return max(best, 0), found
}

/*
Dismisses a toast.

Inputs:
- n: The toasts
- id: Its `Toast.id`

Returns:
- Whether it was there
*/
Notifications_Dismiss :: proc(n: ^Notifications, id: int) -> bool {
	for &t, i in n.toasts do if t.id == id {
		toastFree(&t)
		ordered_remove(&n.toasts, i)
		return true
	}
	return false
}

// Frees the toasts
Notifications_Destroy :: proc(n: ^Notifications) {
	for &t in n.toasts do toastFree(&t)
	delete(n.toasts)
	n.toasts = nil
}

@(private="file")
toastFree :: proc(t: ^Toast) {
	delete(t.text)
	delete(t.actionArg)
	t^ = {}
}

// The jobs running now
Notifications_RunningJobs :: proc(state: ^State) -> bit_set[ToastJob] {
	jobs: bit_set[ToastJob]
	if state.play.stage == .Building || state.play.stage == .Describing {
		jobs += {state.play.purpose == .Play ? .Play_Build : .Scripts_Build}
	}
	if Export_Busy(state) do jobs += {.Export}
	if state.toolchainInstalling do jobs += {.Install_Odin}
	if state.emscriptenInstalling do jobs += {.Install_Emscripten}
	if _, building := Plugins_Building(); building do jobs += {.Plugin_Build}
	if state.archive.busy do jobs += {.Archive}
	return jobs
}

/*
Notes when jobs start and end, so the next run's bar knows how long one takes. Called by `update`
after every message.

Inputs:
- n: The toasts
- running: `Notifications_RunningJobs`
- now: The time

Returns:
- The jobs that ended since the last call
*/
Notifications_Follow :: proc(n: ^Notifications, running: bit_set[ToastJob], now: time.Tick) -> (ended: bit_set[ToastJob]) {
	for job in ToastJob {
		was, is := job in n.running, job in running
		if is && !was do n.started[job] = now
		if was && !is {
			n.lastTook[job] = time.tick_diff(n.started[job], now)
			ended += {job}
		}
	}
	n.running = running
	return
}

/*
The jobs' toasts this frame: what each is doing and how far it got.

Inputs:
- state: The editor state
- now: The time

Returns:
- The toasts (temp allocated), in `ToastJob` order
*/
Notifications_Jobs :: proc(state: ^State, now: time.Tick) -> []JobToast {
	n := &state.notifications
	out := make([dynamic]JobToast, context.temp_allocator)
	for job in Notifications_RunningJobs(state) {
		elapsed := job in n.running ? time.tick_diff(n.started[job], now) : 0
		fraction := f32(-1)
		if took := n.lastTook[job]; took > 0 do fraction = min(f32(f64(elapsed) / f64(took)), 0.95)
		label: string
		switch job {
		case .Play_Build:         label = "Building the game"
		case .Scripts_Build:      label = "Building the scripts"
		case .Install_Odin:       label = "Installing Odin"
		case .Install_Emscripten: label = "Installing Emscripten"
		case .Archive:            label = "Writing the project archive"
		case .Plugin_Build:
			label = "Building a plugin"
			if name, _ := Plugins_Building(); name != "" do label = fmt.tprintf("Building the plugin %s", name)
		case .Export:
			ex := &state.exporting
			done := ex.succeeded + ex.failed
			total := done + len(ex.jobs)
			label = "Exporting"
			if len(ex.jobs) > 0 {
				plan := &ex.jobs[0].plan
				label = fmt.tprintf("Exporting %s (%d of %d)", EXPORT_TARGETS[plan.target].label, done + 1, total)
				part := len(plan.steps) > 0 ? f32(ex.jobs[0].step) / f32(len(plan.steps)) : 0
				fraction = (f32(done) + part) / f32(max(total, 1))
			}
		}
		append(&out, JobToast{job = job, label = label, fraction = fraction, elapsed = elapsed})
	}
	return out[:]
}

/*
The toasts' messages.

Returns:
- The command, and whether the message was one of these
*/
Notifications_Update :: proc(state: ^State, m: Msg) -> (skald.Command(Msg), bool) {
	#partial switch v in m {
	case Toast_Dismissed:
		Notifications_Dismiss(&state.notifications, int(v))
		return {}, true
	case Notify_Requested:
		Notify(state, v.level, v.text, v.action)
		return {}, true
	case Toasts_Expired:
		// Notifications_Expire runs after every message (update)
		return {}, true
	case Toast_Action_Clicked:
		for t in state.notifications.toasts do if t.id == int(v) {
			command: skald.Command(Msg)
			switch t.action {
			case .None:
			case .Show_Output:   Mode_ShowBottomTab(state, .Output)
			case .Show_Console:  Mode_ShowBottomTab(state, .Console)
			case .Show_Problems:
				Problems_Gather(state)
				Mode_ShowBottomTab(state, .Problems)
			case .Open_Folder:
				if t.actionArg != "" do _ = sdl.OpenURL(fmt.ctprintf("file://%s", t.actionArg))
			}
			Notifications_Dismiss(&state.notifications, int(v))
			return command, true
		}
		return {}, true
	}
	return {}, false
}

/*
The toasts over the window's bottom-right corner, jobs first (nothing when there are none). A
frame is asked for at the next deadline (and every second while a job runs, for its time).
*/
notificationsView :: proc(s: ^State, ctx: ^skald.Ctx(Msg)) -> skald.View {
	th := ctx.theme
	tk := uiTokens(ctx)
	now := time.tick_now()
	jobs := Notifications_Jobs(s, now)
	n := &s.notifications
	if len(jobs) == 0 && len(n.toasts) == 0 do return skald.spacer(0)
	width := tk.dialogS
	cards := make([dynamic]skald.View, context.temp_allocator)
	for job in jobs {
		seconds := int(time.duration_seconds(job.elapsed))
		rows := make([dynamic]skald.View, context.temp_allocator)
		append(&rows, skald.row(
			uiText(th, .Value, job.label, max_width = width - tk.m * 2),
			skald.flex(1, skald.spacer(0)),
			uiText(th, .Muted, fmt.tprintf("%d s", seconds)),
			spacing = tk.s,
			cross_align = .Center,
		))
		if job.fraction >= 0 do append(&rows, skald.progress(ctx, job.fraction, height = tk.xs))
		append(&cards, toastCard(ctx, th.color.primary, skald.col(..rows[:], spacing = tk.xs, cross_align = .Stretch), width,
			fmt.tprintf("toast-job-%v", job.job)))
	}
	// A stack of passive notices lets the pointer through (Toast_IsPassive)
	// and so does every stack while a dialog is open: its buttons (an Apply, a Cancel in the corner)
	// stay clickable; the toasts take clicks again once it closes
	interactive := false
	for t in n.toasts do if !Toast_IsPassive(t) do interactive = true
	if ctx.widgets.modal_rect_prev.w > 0 do interactive = false
	for t, i in n.toasts {
		color := th.color.primary
		icon := ""
		switch t.level {
		case .Info:
		case .Success: color, icon = th.color.success, ICON_CHECK
		case .Warning: color, icon = th.color.warning, ACTION_ICONS[.Warning]
		case .Error:   color, icon = th.color.danger, ACTION_ICONS[.Warning]
		}
		parts := make([dynamic]skald.View, context.temp_allocator)
		if icon != "" do append(&parts, uiText(th, .Value, icon, color = color))
		textWidth := width - tk.m * 2 - (interactive ? tk.panelButtonWidth + tk.s : 0) - tk.s - (icon != "" ? tk.iconColumn : 0)
		body := make([dynamic]skald.View, context.temp_allocator)
		append(&body, uiText(th, .Value, t.text, max_width = textWidth))
		if t.action != .None {
			append(&body, skald.button(ctx, TOAST_ACTION_LABELS[t.action], Msg(Toast_Action_Clicked(t.id)),
				id = skald.hash_id(fmt.tprintf("toast-action-%d", i)), bg = th.color.surface, fg = th.color.fg,
				padding = tk.buttonPadding, font_size = th.font.size_sm))
		}
		append(&parts, skald.col(..body[:], spacing = tk.xs))
		append(&parts, skald.flex(1, skald.spacer(0)))
		if interactive do append(&parts, panelToolButton(ctx, fmt.tprintf("toast-close-%d", i), ACTION_ICONS[.Close], "Dismiss", Msg(Toast_Dismissed(t.id))))
		key := fmt.tprintf("toast-%d", i)
		card := toastCard(ctx, color, skald.row(..parts[:], spacing = tk.s, cross_align = .Start), width, key)
		// A click anywhere on the card dismisses it (its buttons do their own first)
		if interactive && skald.widget_clicked(ctx, skald.hash_id(key)) do skald.send(ctx, Msg(Toast_Dismissed(t.id)))
		append(&cards, card)
	}
	// The next frame: a toast's deadline, or the jobs' clock
	if left, ok := Notifications_NextDeadline(n, now); ok || len(jobs) > 0 {
		if len(jobs) > 0 && (!ok || left > time.Second) do left = time.Second
		if left <= 0 {
			skald.send(ctx, Msg(Toasts_Expired{}))
		} else {
			skald.widget_request_frame_at(ctx, time.now()._nsec + i64(left))
		}
	}
	stack := new(skald.View, context.temp_allocator)
	stack^ = skald.zone(ctx, skald.col(..cards[:], spacing = tk.s, cross_align = .Stretch), skald.hash_id(TOASTS_KEY))
	// Over the status bar, clear of the window's edge
	return skald.View_Toast{visible = true, child = stack, anchor = .Bottom_Right, margin = tk.l + tk.controlHeight, pass_through = !interactive}
}

/*
Whether a popup (a dropdown's list, a picker, a menu) was open last frame: Skald's overlay rects
besides the toasts' (which take the pointer over them, but leave the rest of the window alone).
Widgets that ignore the pointer while a popup is open ask this.
*/
Overlay_PopupOpen :: proc(ctx: ^skald.Ctx(Msg)) -> bool {
	toasts := lastRect(ctx, skald.hash_id(TOASTS_KEY))
	for r in ctx.widgets.overlay_rects_prev do if r != toasts do return true
	return false
}

// The toasts' stack (a zone: its rect is the one Skald's View_Toast stamps)
TOASTS_KEY :: "toasts"

// A toast's card: its level's stripe, then the content, on the popups' color
@(private="file")
toastCard :: proc(ctx: ^skald.Ctx(Msg), color: skald.Color, content: skald.View, width: f32, key: string) -> skald.View {
	th := ctx.theme
	tk := uiTokens(ctx)
	return skald.zone(ctx, skald.row(
		skald.rect({tk.xxs * 2, 0}, color, tk.hair),
		skald.flex(1, content),
		spacing = tk.s,
		padding = tk.m,
		bg = th.color.elevated,
		radius = th.radius.md,
		width = width,
		cross_align = .Stretch,
	), skald.hash_id(key))
}
