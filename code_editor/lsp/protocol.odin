// LSP protocol data structures (the subset this editor needs). Field names
// use `json` tags to match the protocol's camelCase wire format.
package lsp

import "core:encoding/json"

Position :: struct {
	line:      int `json:"line"`,
	character: int `json:"character"`,
}

Range :: struct {
	start: Position `json:"start"`,
	end:   Position `json:"end"`,
}

TextDocumentIdentifier :: struct {
	uri: string `json:"uri"`,
}

VersionedTextDocumentIdentifier :: struct {
	uri:     string `json:"uri"`,
	version: int    `json:"version"`,
}

TextDocumentItem :: struct {
	uri:         string `json:"uri"`,
	languageId:  string `json:"languageId"`,
	version:     int    `json:"version"`,
	text:        string `json:"text"`,
}

TextDocumentPositionParams :: struct {
	textDocument: TextDocumentIdentifier `json:"textDocument"`,
	position:     Position               `json:"position"`,
}

// --- initialize ---

InitializeParams :: struct {
	processId:             Maybe(int)   `json:"processId"`,
	rootUri:               Maybe(string) `json:"rootUri"`,
	capabilities:          ClientCapabilities `json:"capabilities"`,
	// Server-specific settings (OLS reads its ols.json options from here).
	initializationOptions: json.Value `json:"initializationOptions"`,
}

// ClientCapabilities advertises what this client can render, which changes
// what servers send (e.g. diagnostic tags, code-action literals).
ClientCapabilities :: struct {
	textDocument: TextDocumentClientCapabilities `json:"textDocument"`,
}

TextDocumentClientCapabilities :: struct {
	completion: struct {
		completionItem: struct {
			snippetSupport:      bool     `json:"snippetSupport"`,
			documentationFormat: []string `json:"documentationFormat"`,
		} `json:"completionItem"`,
	} `json:"completion"`,
	publishDiagnostics: struct {
		tagSupport: struct {
			valueSet: []int `json:"valueSet"`,
		} `json:"tagSupport"`,
	} `json:"publishDiagnostics"`,
	codeAction: struct {
		codeActionLiteralSupport: struct {
			codeActionKind: struct {
				valueSet: []string `json:"valueSet"`,
			} `json:"codeActionKind"`,
		} `json:"codeActionLiteralSupport"`,
	} `json:"codeAction"`,
}

default_client_capabilities :: proc() -> ClientCapabilities {
	caps: ClientCapabilities
	caps.textDocument.publishDiagnostics.tagSupport.valueSet = DIAGNOSTIC_TAGS[:]
	caps.textDocument.codeAction.codeActionLiteralSupport.codeActionKind.valueSet = CODE_ACTION_KINDS[:]
	caps.textDocument.completion.completionItem.snippetSupport = true
	caps.textDocument.completion.completionItem.documentationFormat = DOC_FORMATS[:]
	return caps
}

@(private)
DIAGNOSTIC_TAGS := [2]int{1, 2}
@(private)
DOC_FORMATS := [2]string{"markdown", "plaintext"}
@(private)
CODE_ACTION_KINDS := [6]string{"", "quickfix", "refactor", "refactor.rewrite", "source", "source.organizeImports"}

// --- textDocument/didOpen, didChange, didClose, didSave ---

DidOpenTextDocumentParams :: struct {
	textDocument: TextDocumentItem `json:"textDocument"`,
}

TextDocumentContentChangeEvent :: struct {
	text: string `json:"text"`,
}

// Incremental_Change replaces [range.start, range.end) (UTF-16 columns,
// in the document as left by the previous change) with `text`.
Incremental_Change :: struct {
	range: Range  `json:"range"`,
	text:  string `json:"text"`,
}

DidChangeIncrementalParams :: struct {
	textDocument:   VersionedTextDocumentIdentifier `json:"textDocument"`,
	contentChanges: []Incremental_Change             `json:"contentChanges"`,
}

DidChangeTextDocumentParams :: struct {
	textDocument:   VersionedTextDocumentIdentifier    `json:"textDocument"`,
	contentChanges: []TextDocumentContentChangeEvent    `json:"contentChanges"`,
}

DidCloseTextDocumentParams :: struct {
	textDocument: TextDocumentIdentifier `json:"textDocument"`,
}

DidSaveTextDocumentParams :: struct {
	textDocument: TextDocumentIdentifier `json:"textDocument"`,
	// Servers that register `save: {includeText: true}` (OLS does) re-index
	// the file from this; omitting it makes OLS index an empty file.
	text:         string                 `json:"text"`,
}

// --- completion ---

CompletionParams :: struct {
	textDocument: TextDocumentIdentifier `json:"textDocument"`,
	position:     Position               `json:"position"`,
}

CompletionItem :: struct {
	label:       string `json:"label"`,
	kind:        int    `json:"kind"`,
	detail:      string `json:"detail"`,
	// Text to insert on accept (falls back to `label` when empty).
	insert_text: string `json:"insertText"`,
	// Text to match the typed prefix against (falls back to `label`).
	filter_text: string `json:"filterText"`,
	// If the server supplied a `textEdit`, its replacement range; the
	// editor replaces [text_edit_range.start, cursor) with insert_text.
	has_text_edit:   bool  `json:"-"`,
	text_edit_range: Range `json:"-"`,
	// insertTextFormat 2: insert_text is a snippet ($1, ${1:x}, $0).
	is_snippet:      bool   `json:"-"`,
	// Documentation (plain text or markdown; see doc_markdown).
	documentation:   string `json:"-"`,
	doc_markdown:    bool   `json:"-"`,
	// command.command to run after accepting (e.g. OLS asks for
	// "editor.action.triggerParameterHints" after inserting `name($0)`).
	command:         string `json:"-"`,
}

// CompletionItemKind values from the LSP spec (the subset worth labeling).
CompletionKind :: enum int {
	Text = 1, Method = 2, Function = 3, Constructor = 4, Field = 5,
	Variable = 6, Class = 7, Interface = 8, Module = 9, Property = 10,
	Unit = 11, Value = 12, Enum = 13, Keyword = 14, Snippet = 15,
	Color = 16, File = 17, Reference = 18, Folder = 19, EnumMember = 20,
	Constant = 21, Struct = 22, Event = 23, Operator = 24, TypeParameter = 25,
}

// --- signatureHelp ---

SignatureHelpParams :: struct {
	textDocument: TextDocumentIdentifier `json:"textDocument"`,
	position:     Position               `json:"position"`,
}

ParameterInformation :: struct {
	label: string `json:"label"`,
}

SignatureInformation :: struct {
	label:      string                  `json:"label"`,
	parameters: []ParameterInformation  `json:"parameters"`,
	// Per-signature active parameter (LSP 3.16+); -1 when the server
	// didn't send one, in which case the response-level value applies.
	active_parameter: int `json:"-"`,
}

// --- diagnostics ---

Diagnostic :: struct {
	range:    Range  `json:"range"`,
	// 1 error, 2 warning, 3 information, 4 hint (0/absent -> error).
	severity: int    `json:"severity"`,
	message:  string `json:"message"`,
	source:   string `json:"source"`,
	// From `tags`: 1 = Unnecessary (render faded), 2 = Deprecated
	// (render struck through).
	unnecessary: bool `json:"-"`,
	deprecated:  bool `json:"-"`,
}

// --- definition / references ---

// Location is a range in a document; `key` is its uri_key (path).
Location :: struct {
	uri:   string,
	key:   string,
	range: Range,
}

ReferenceParams :: struct {
	textDocument: TextDocumentIdentifier `json:"textDocument"`,
	position:     Position               `json:"position"`,
	context_:     struct {
		includeDeclaration: bool `json:"includeDeclaration"`,
	} `json:"context"`,
}

// --- codeAction ---

CodeActionContext :: struct {
	diagnostics: []Diagnostic `json:"diagnostics"`,
}

CodeActionParams :: struct {
	textDocument: TextDocumentIdentifier `json:"textDocument"`,
	range:        Range                  `json:"range"`,
	context_:     CodeActionContext      `json:"context"`,
}

// Code_Action_Edit is one TextEdit of a code action's WorkspaceEdit.
// `key` is the target document's uri_key; ranges are in UTF-16 columns.
Code_Action_Edit :: struct {
	key:      string,
	range:    Range,
	new_text: string,
}

Code_Action :: struct {
	title:     string,
	kind:      string,
	preferred: bool,
	edits:     []Code_Action_Edit,
}

// --- hover ---

HoverParams :: struct {
	textDocument: TextDocumentIdentifier `json:"textDocument"`,
	position:     Position               `json:"position"`,
}
