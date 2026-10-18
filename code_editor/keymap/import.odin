// Importing key bindings from VSCode (keybindings.json) and Zed
// (keymap.json). Both files are JSON with comments/trailing commas
// (parsed as JSON5). Commands are mapped onto this editor's actions by the
// tables below; anything else is counted and reported, as are multi-key
// sequences ("cmd+k cmd+s"), which this keymap doesn't support.
//
// VSCode: [{"key", "command", "when"?}]; a "-command" entry removes that
//   binding; entries whose `when` targets non-editor UI are skipped.
// Zed: [{"context"?, "bindings": {key: action | [action, args] | null},
//   "unbind": {key: action}}]; only editor/workspace contexts apply
//   (vim modes, terminal, panels are skipped); null or "unbind" removes.
package keymap

import "core:encoding/json"
import "core:strings"

Import_Report :: struct {
	bound:     int,
	unbound:   int,
	unknown:   int, // commands with no equivalent here
	sequences: int, // multi-key chords (unsupported)
	skipped:   int, // entries for other contexts (terminal, vim, panels ...)
	unknown_names: [dynamic]string, // first few unknown commands (temp)
}

Name_Action :: struct {
	name:   string,
	action: Action,
}

@(private)
lookup_command :: proc(table: []Name_Action, name: string) -> (Action, bool) {
	for e in table {
		if e.name == name {
			return e.action, true
		}
	}
	return .None, false
}

@(private)
VSCODE_COMMANDS := [?]Name_Action{
	{"cursorLeft", .MoveLeft}, {"cursorRight", .MoveRight}, {"cursorUp", .MoveUp}, {"cursorDown", .MoveDown},
	{"cursorWordLeft", .MoveWordLeft}, {"cursorWordRight", .MoveWordRight},
	{"cursorHome", .MoveLineStart}, {"cursorEnd", .MoveLineEnd}, {"cursorTop", .MoveDocStart}, {"cursorBottom", .MoveDocEnd},
	{"cursorPageUp", .MovePageUp}, {"cursorPageDown", .MovePageDown},
	{"cursorLeftSelect", .ExtendLeft}, {"cursorRightSelect", .ExtendRight}, {"cursorUpSelect", .ExtendUp}, {"cursorDownSelect", .ExtendDown},
	{"cursorWordLeftSelect", .ExtendWordLeft}, {"cursorWordRightSelect", .ExtendWordRight},
	{"cursorHomeSelect", .ExtendLineStart}, {"cursorEndSelect", .ExtendLineEnd},
	{"cursorTopSelect", .ExtendDocStart}, {"cursorBottomSelect", .ExtendDocEnd},
	{"cursorPageUpSelect", .ExtendPageUp}, {"cursorPageDownSelect", .ExtendPageDown},
	{"editor.action.selectAll", .SelectAll}, {"expandLineSelection", .SelectLine},
	{"deleteLeft", .Backspace}, {"deleteRight", .DeleteForward}, {"deleteWordLeft", .BackspaceWord}, {"deleteWordRight", .DeleteForwardWord},
	{"tab", .IndentOrTab}, {"outdent", .Outdent}, {"editor.action.outdentLines", .Outdent}, {"editor.action.indentLines", .IndentOrTab},
	{"editor.action.copyLinesUpAction", .DuplicateLineUp}, {"editor.action.copyLinesDownAction", .DuplicateLineDown},
	{"editor.action.moveLinesUpAction", .MoveLineUp}, {"editor.action.moveLinesDownAction", .MoveLineDown},
	{"editor.action.commentLine", .ToggleLineComment}, {"editor.action.deleteLines", .DeleteLine},
	{"editor.action.insertLineAfter", .InsertLineBelow}, {"editor.action.insertLineBefore", .InsertLineAbove},
	{"editor.action.clipboardCutAction", .Cut}, {"editor.action.clipboardCopyAction", .Copy}, {"editor.action.clipboardPasteAction", .Paste},
	{"undo", .Undo}, {"redo", .Redo},
	{"workbench.action.files.save", .Save}, {"workbench.action.files.saveAs", .SaveAs}, {"workbench.action.files.openFile", .Open},
	{"editor.action.insertCursorAbove", .AddCursorAbove}, {"editor.action.insertCursorBelow", .AddCursorBelow},
	{"editor.action.triggerSuggest", .TriggerCompletion}, {"editor.action.triggerParameterHints", .TriggerSignatureHelp},
	{"editor.action.marker.next", .NextDiagnostic}, {"editor.action.marker.nextInFiles", .NextDiagnostic},
	{"editor.action.marker.prev", .PrevDiagnostic}, {"editor.action.marker.prevInFiles", .PrevDiagnostic},
	{"editor.action.quickFix", .QuickFix}, {"workbench.actions.view.problems", .ToggleProblems},
	{"editor.action.revealDefinition", .GotoDefinition}, {"editor.action.goToDeclaration", .GotoDefinition},
	{"editor.action.peekDefinition", .PeekDefinition}, {"editor.action.goToReferences", .FindReferences},
	{"references-view.findReferences", .FindReferences},
	{"goToNextReference", .NextReference}, {"goToPreviousReference", .PrevReference},
	{"workbench.action.navigateBack", .NavigateBack}, {"workbench.action.navigateForward", .NavigateForward},
	{"actions.find", .Find}, {"editor.action.startFindReplaceAction", .Replace},
	{"editor.action.nextMatchFindAction", .FindNext}, {"editor.action.previousMatchFindAction", .FindPrev},
	{"editor.action.addSelectionToNextFindMatch", .SelectNextOccurrence}, {"editor.action.selectHighlights", .SelectAllOccurrences},
	{"workbench.action.zoomIn", .ZoomIn}, {"workbench.action.zoomOut", .ZoomOut}, {"workbench.action.zoomReset", .ZoomReset},
	{"editor.action.fontZoomIn", .ZoomIn}, {"editor.action.fontZoomOut", .ZoomOut}, {"editor.action.fontZoomReset", .ZoomReset},
	{"workbench.action.showCommands", .CommandPalette}, {"workbench.action.quickOpen", .CommandPalette},
	{"workbench.action.openGlobalKeybindings", .OpenKeymapEditor},
}

@(private)
ZED_ACTIONS := [?]Name_Action{
	{"editor::MoveLeft", .MoveLeft}, {"editor::MoveRight", .MoveRight}, {"editor::MoveUp", .MoveUp}, {"editor::MoveDown", .MoveDown},
	{"editor::MoveToPreviousWordStart", .MoveWordLeft}, {"editor::MoveToNextWordEnd", .MoveWordRight},
	{"editor::MoveToBeginningOfLine", .MoveLineStart}, {"editor::MoveToEndOfLine", .MoveLineEnd},
	{"editor::MoveToBeginning", .MoveDocStart}, {"editor::MoveToEnd", .MoveDocEnd},
	{"editor::MovePageUp", .MovePageUp}, {"editor::MovePageDown", .MovePageDown},
	{"editor::SelectLeft", .ExtendLeft}, {"editor::SelectRight", .ExtendRight}, {"editor::SelectUp", .ExtendUp}, {"editor::SelectDown", .ExtendDown},
	{"editor::SelectToPreviousWordStart", .ExtendWordLeft}, {"editor::SelectToNextWordEnd", .ExtendWordRight},
	{"editor::SelectToBeginningOfLine", .ExtendLineStart}, {"editor::SelectToEndOfLine", .ExtendLineEnd},
	{"editor::SelectToBeginning", .ExtendDocStart}, {"editor::SelectToEnd", .ExtendDocEnd},
	{"editor::SelectAll", .SelectAll}, {"editor::SelectLine", .SelectLine},
	{"editor::Backspace", .Backspace}, {"editor::Delete", .DeleteForward},
	{"editor::DeleteToPreviousWordStart", .BackspaceWord}, {"editor::DeleteToNextWordEnd", .DeleteForwardWord},
	{"editor::Tab", .IndentOrTab}, {"editor::Backtab", .Outdent}, {"editor::Indent", .IndentOrTab}, {"editor::Outdent", .Outdent},
	{"editor::DuplicateLineUp", .DuplicateLineUp}, {"editor::DuplicateLineDown", .DuplicateLineDown},
	{"editor::MoveLineUp", .MoveLineUp}, {"editor::MoveLineDown", .MoveLineDown},
	{"editor::ToggleComments", .ToggleLineComment}, {"editor::DeleteLine", .DeleteLine},
	{"editor::NewlineBelow", .InsertLineBelow}, {"editor::NewlineAbove", .InsertLineAbove},
	{"editor::Cut", .Cut}, {"editor::Copy", .Copy}, {"editor::Paste", .Paste}, {"editor::Undo", .Undo}, {"editor::Redo", .Redo},
	{"workspace::Save", .Save}, {"workspace::SaveAs", .SaveAs}, {"workspace::Open", .Open},
	{"editor::AddSelectionAbove", .AddCursorAbove}, {"editor::AddSelectionBelow", .AddCursorBelow},
	{"editor::ShowCompletions", .TriggerCompletion}, {"editor::ShowSignatureHelp", .TriggerSignatureHelp},
	{"editor::GoToDiagnostic", .NextDiagnostic}, {"editor::GoToPreviousDiagnostic", .PrevDiagnostic}, {"editor::GoToPrevDiagnostic", .PrevDiagnostic},
	{"editor::ToggleCodeActions", .QuickFix}, {"diagnostics::Deploy", .ToggleProblems},
	{"editor::GoToDefinition", .GotoDefinition}, {"editor::GoToDeclaration", .GotoDefinition},
	{"editor::FindAllReferences", .FindReferences},
	{"pane::GoBack", .NavigateBack}, {"pane::GoForward", .NavigateForward},
	{"buffer_search::Deploy", .Find}, {"buffer_search::DeployReplace", .Replace},
	{"search::SelectNextMatch", .FindNext}, {"search::SelectPrevMatch", .FindPrev},
	{"editor::SelectNext", .SelectNextOccurrence}, {"editor::SelectAllMatches", .SelectAllOccurrences},
	{"zed::IncreaseBufferFontSize", .ZoomIn}, {"zed::DecreaseBufferFontSize", .ZoomOut}, {"zed::ResetBufferFontSize", .ZoomReset},
	{"command_palette::Toggle", .CommandPalette}, {"zed::OpenKeymap", .OpenKeymapEditor}, {"zed::OpenKeymapEditor", .OpenKeymapEditor},
}

@(private)
note_unknown :: proc(r: ^Import_Report, name: string) {
	r.unknown += 1
	if len(r.unknown_names) < 8 {
		append(&r.unknown_names, strings.clone(name, context.temp_allocator))
	}
}

// keymap_import_vscode applies a VSCode keybindings.json on top of km.
keymap_import_vscode :: proc(km: ^Keymap, text: string) -> (r: Import_Report, ok: bool) {
	r.unknown_names = make([dynamic]string, context.temp_allocator)
	v, err := json.parse_string(text, json.Specification.JSON5, allocator = context.temp_allocator)
	if err != nil {
		return r, false
	}
	arr, is_arr := v.(json.Array)
	if !is_arr {
		return r, false
	}
	for e in arr {
		obj, is_obj := e.(json.Object)
		if !is_obj {
			continue
		}
		key, _ := obj["key"].(json.String)
		command, _ := obj["command"].(json.String)
		when_, _ := obj["when"].(json.String)
		if len(when_) > 0 && !strings.contains(when_, "editor") && !strings.contains(when_, "textInput") {
			r.skipped += 1
			continue
		}
		if strings.contains(strings.trim_space(key), " ") {
			r.sequences += 1
			continue
		}
		chord, chord_ok := chord_parse(key)
		removal := strings.has_prefix(command, "-")
		name := command[1:] if removal else command
		action, known := lookup_command(VSCODE_COMMANDS[:], name)
		if !known {
			note_unknown(&r, name)
			continue
		}
		if !chord_ok {
			r.unknown += 1
			continue
		}
		if removal {
			if cur, bound := km.bindings[chord]; bound && cur == action {
				keymap_unbind(km, chord)
				r.unbound += 1
			}
		} else {
			keymap_bind(km, chord, action)
			r.bound += 1
		}
	}
	return r, true
}

@(private)
zed_context_applies :: proc(ctx: string) -> bool {
	if len(ctx) == 0 {
		return true
	}
	for skip in ([]string{"vim", "Terminal", "ProjectPanel", "Pane >", "menu", "Picker", "Dock", "OutlinePanel", "GitPanel", "Search"}) {
		if strings.contains(ctx, skip) {
			return false
		}
	}
	return strings.contains(ctx, "Editor") || strings.contains(ctx, "Workspace")
}

// keymap_import_zed applies a Zed keymap.json on top of km.
keymap_import_zed :: proc(km: ^Keymap, text: string) -> (r: Import_Report, ok: bool) {
	r.unknown_names = make([dynamic]string, context.temp_allocator)
	v, err := json.parse_string(text, json.Specification.JSON5, allocator = context.temp_allocator)
	if err != nil {
		return r, false
	}
	arr, is_arr := v.(json.Array)
	if !is_arr {
		return r, false
	}
	for e in arr {
		section, is_obj := e.(json.Object)
		if !is_obj {
			continue
		}
		ctx, _ := section["context"].(json.String)
		if !zed_context_applies(ctx) {
			if b, has := section["bindings"].(json.Object); has {
				r.skipped += len(b)
			}
			continue
		}
		if b, has := section["bindings"].(json.Object); has {
			for key, val in b {
				if strings.contains(strings.trim_space(key), " ") {
					r.sequences += 1
					continue
				}
				chord, chord_ok := chord_parse(key)
				if !chord_ok {
					r.unknown += 1
					continue
				}
				name: string
				#partial switch x in val {
				case json.Null:
					keymap_unbind(km, chord)
					r.unbound += 1
					continue
				case json.String:
					name = x
				case json.Array:
					if len(x) > 0 {
						name, _ = x[0].(json.String)
					}
				}
				action, known := lookup_command(ZED_ACTIONS[:], name)
				if !known {
					note_unknown(&r, name)
					continue
				}
				keymap_bind(km, chord, action)
				r.bound += 1
			}
		}
		if u, has := section["unbind"].(json.Object); has {
			for key, _ in u {
				if chord, chord_ok := chord_parse(key); chord_ok {
					if _, bound := km.bindings[chord]; bound {
						keymap_unbind(km, chord)
						r.unbound += 1
					}
				}
			}
		}
	}
	return r, true
}
