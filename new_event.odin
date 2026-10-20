package crossfire_editor

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"

/*
New Event (the inspector's Events section): a script publishes an event of its own, an
EventSubject field tagged with what it means and how to read its data (the engine's
node_events.odin). The dialog asks for a name, a description and what data it carries;
`NewEvent_Insert` adds the field to the script's struct (in the code tab, or the file with the
external editor), with a comment showing how to fire it. Saved and built, it's listed in the
Events section of nodes running the script (or under Globals for a global) to listen to.
*/

// What an event carries (the field's `data` tag: how a handler reads it)
EventDataKind :: enum {
	None,
	Int,
	Float,
	Bool,
	String,
	Node,
}

EVENT_DATA_LABELS := [EventDataKind]string{
	.None   = "Nothing",
	.Int    = "A whole number (int)",
	.Float  = "A number (f32)",
	.Bool   = "True or false (bool)",
	.String = "Text (string)",
	.Node   = "A node (^e.Node)",
}

// The New Event dialog, part of `State` (strings owned)
NewEventDialog :: struct {
	open: bool,
	// The script that will publish it
	script: string,
	name: string,
	description: string,
	kind: EventDataKind,
}

// Frees the dialog's strings
NewEventDialog_Destroy :: proc(d: ^NewEventDialog) {
	delete(d.script)
	delete(d.name)
	delete(d.description)
	d^ = {}
}

// Why the dialog's event can't be made ("" when it can)
NewEvent_Problem :: proc(state: ^State) -> string {
	name := state.newEvent.name
	if name == "" do return "Name the event: what happened, as onSomething (onCoinCollected)."
	for r, i in name {
		ok := r == '_' || (r >= 'a' && r <= 'z') || (r >= 'A' && r <= 'Z') || (i > 0 && r >= '0' && r <= '9')
		if !ok do return "A name is letters, digits and _, not starting with a digit."
	}
	for ev in Script_Events(state, state.newEvent.script) do if Event_ShortName(ev.name) == name do return fmt.tprintf("%s already has %s.", state.newEvent.script, name)
	if Script_FileOf(state, state.newEvent.script) == "" do return fmt.tprintf("No file in scripts/ registers %s.", state.newEvent.script)
	return ""
}

/*
The field line for an event, with the comment showing how to fire it.

Inputs:
- name, description: The event's
- kind: Its data
- alias: The engine's import name in the file ("e")
- global: The script is a global (it fires with no node)
*/
NewEvent_Source :: proc(name, description: string, kind: EventDataKind, alias: string, global: bool) -> string {
	// Tags can't hold quotes or backquotes
	clean, _ := strings.replace_all(description, "\"", "'", context.temp_allocator)
	clean, _ = strings.replace_all(clean, "`", "'", context.temp_allocator)
	hint, example: string
	switch kind {
	case .None:   example = "nil"
	case .Int:    hint, example = "value := data.(int)", "42"
	case .Float:  hint, example = "value := data.(f32)", "1.5"
	case .Bool:   hint, example = "value := data.(bool)", "true"
	case .String: hint, example = "text := data.(string)", "\"text\""
	case .Node:   hint, example = fmt.tprintf("node := cast(^%s.Node)data.(rawptr)", alias), "rawptr(node)"
	}
	tag := hint != "" ? fmt.tprintf("event:\"%s\" data:\"%s\"", clean, hint) : fmt.tprintf("event:\"%s\"", clean)
	return fmt.tprintf("\t// %s. Fire it: %s.Event_Notify(&self.%s, %s, %s)\n\t%s: %s.EventSubject `%s`,\n",
		clean, alias, name, global ? "nil" : "self.node", example, name, alias, tag)
}

/*
Adds the dialog's event to its script's struct: before the struct's closing brace, in the code
tab (an undo step there) or, with the external editor, in the file.

Returns:
- What happened, for the Console, and false when nothing was added
*/
NewEvent_Insert :: proc(state: ^State) -> (message: string, ok: bool) {
	d := &state.newEvent
	if problem := NewEvent_Problem(state); problem != "" do return problem, false
	file := Script_FileOf(state, d.script)
	absolute := absolutePath(joinPath(state.project.rootPath, file, allocator = context.temp_allocator))
	builtIn := state.settings.builtInCodeEditor
	if builtIn do CodeTabs_Open(state, absolute, 0)
	path := builtIn && state.codeTab > 0 ? state.codeTabs[state.codeTab - 1] : absolute
	text := builtIn ? CodeEditor_Text(path) : ""
	if !builtIn {
		data, err := os.read_entire_file(absolute, context.temp_allocator)
		if err != nil do return fmt.tprintf("Couldn't read %s", file), false
		text = string(data)
	}
	st, found := NodeField_FindStruct(text, d.script)
	if !found do return fmt.tprintf("%s has no struct %s with `using script:`", file, d.script), false
	global := false
	for g in state.project.globals do if g.script == d.script do global = true
	line := NewEvent_Source(d.name, strings.trim_space(d.description), d.kind, st.engineAlias, global)
	commaLine, commaColumn, needsComma := Struct_MissingComma(text, st.closeLine)
	if builtIn {
		// The field above needs a comma now that another follows it
		if needsComma do CodeEditor_InsertAt(path, commaLine, commaColumn, ",")
		if !CodeEditor_InsertAtLine(path, st.closeLine, line) do return "The code editor couldn't take the event", false
		CodeEditor_GotoLine(path, st.closeLine + 2)
	} else {
		lines := strings.split_lines(text, context.temp_allocator)
		if needsComma do lines[commaLine] = strings.concatenate({lines[commaLine][:commaColumn], ",", lines[commaLine][commaColumn:]}, context.temp_allocator)
		before := strings.join(lines[:st.closeLine], "\n", context.temp_allocator)
		after := strings.join(lines[st.closeLine:], "\n", context.temp_allocator)
		if err := os.write_entire_file(absolute, transmute([]u8)strings.concatenate({before, "\n", line, after}, context.temp_allocator)); err != nil {
			return fmt.tprintf("Couldn't write %s", file), false
		}
	}
	return fmt.tprintf("Added the event %s to %s in %s (save to build it, then listen to it in the Events section)", d.name, d.script, filepath.base(file)), true
}
