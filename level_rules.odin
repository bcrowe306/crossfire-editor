package crossfire_editor

import "core:fmt"
import "core:slice"
import "core:strings"

/*
The Auto-layer Rules tab's own state (phase 4 of TODO.md's "LDtk level editor"): which layer it
shows, which groups are open, the rule whose editor shows, the editor's value, the Assistant's and
Duplicate and Remap's choices, LDtk's clipboard, and what the pointer is over (the canvas shows a
rule's cells, the tab the rules of the cell under the pointer). None of it is in the file and none
of it is undone: the edits are `LDtk_Edit`s (ldtk_rule_ops.odin); this is `Rules_View`.

LDtk keeps the same things in its panel: groups start closed when a project opens but for a
layer's only group (unless the Assistant's), its RuleEditor smart-picks the value most used in the
pattern, its clipboard holds a rule's or group's JSON (across layers and projects).
*/

// What the tab shows
LevelRulesPage :: enum u8 {
	// The layer's groups and rules (LDtk's EditAllAutoLayerRules)
	List,
	// The rule `LevelRules.rule`'s editor (LDtk's RuleEditor and its option dialogs)
	Editor,
	// The Rule Assistant for a new group or `group` (LDtk's RulesWizard)
	Assistant,
	// Duplicate and Remap of `group` (LDtk's RuleGroupRemap)
	Remap,
	// Picking `group`'s icon on the tileset
	Icon,
	// Picking `group`'s color (LDtk's palette)
	Color,
}

// What LDtk's clipboard holds
LevelRulesClip :: enum u8 {
	None,
	Rule,
	Group,
}

// The tab's state (`LevelMode.rules`)
LevelRules :: struct {
	// The layer shown (a layer definition's uid; -1, as it is once the tab picks one: the selected
	// layer when it can have rules, else the first that can)
	layer: int,
	// Groups opened or closed by hand (uid: open); the others as LDtk starts them
	open: map[int]bool,
	page: LevelRulesPage,
	// The rule the editor shows, and LDtk's last rule (outlined in the list); uids, -1 none
	rule, last: int,
	// The editor's value: what the pattern's left button puts (an IntGrid value, a group's
	// `(uid + 1) * 1000`, or LDTK_ANYTHING)
	value: int,
	// The editor's help (LDtk's "Enable help")
	help: bool,
	// The random offsets' link turned off (the editor's link buttons; linked while min is -max)
	unlinkX, unlinkY: bool,
	// The stamp the tileset picks into (-1: a new one)
	stamp: int,
	// The Perlin noise of the shown rule drawn on the canvas (RulePerlinSettings' preview)
	perlinPreview: bool,
	// The group whose name is typed in its header (-1 none)
	renaming: int,
	// The page's group (the Assistant's: -1 a new one; the remap's, the icon's, the color's)
	group: int,
	// The Assistant's choices (tiles owned), the part picked, the group's name (owned)
	assistant: LDtkAssistant,
	part: LDtkWallFragment,
	name: string,
	// Duplicate and Remap: IntGrid values' new values, the tiles' offset in cells
	remap: map[int]int,
	offset: [2]int,
	// LDtk's clipboard: a rule's or group's JSON (owned)
	clip: string,
	clipKind: LevelRulesClip,
}

// What the tab does with a `Rules_View`
RulesViewOp :: enum u8 {
	// `uid` the layer shown
	Layer,
	// `uid` a group opened (`flag`) or closed
	Group_Open,
	// `uid` the rule whose editor shows (LDtk's click on a rule's pattern)
	Edit,
	// Back to the list
	Close,
	// `number` the editor's value
	Value,
	// `uid` a group whose name is typed (-1 done)
	Rename,
	// `uid` LDtk's last rule (a press on its row)
	Last,
	// `flag` the editor's help, the Perlin preview, a random offset's link
	Help,
	Perlin_Preview,
	Unlink_X,
	Unlink_Y,
	// `number` the stamp the tileset picks into
	Stamp,
	// `uid` the Assistant for a group (-1 a new one)
	Assistant,
	// The Assistant's main value, outer value (`number`), name (`text`), part (`number`), the
	// part's tiles (`ids`), its stacking option (`flag`: rules may stack, LDtk's inverted
	// breakOnMatch)
	Assistant_Main,
	Assistant_Other,
	Assistant_Name,
	Assistant_Part,
	Assistant_Tiles,
	Assistant_Stack,
	// `uid` Duplicate and Remap of a group; a value's new value (`number` the old, `uid` the new),
	// the tiles' offset (`ids`: dx, dy), the copy's name (`text`)
	Remap,
	Remap_Value,
	Remap_Offset,
	Remap_Name,
	// `uid` a group whose icon or color is picked
	Icon,
	Color,
	// `uid` a group, `number` a rule (-1: the group) copied into LDtk's clipboard
	Copy,
}

// The tab's view state changing (none of it is in the file, nothing is undone)
Rules_View :: struct {
	op: RulesViewOp,
	uid, number: int,
	flag: bool,
	// The frame's
	text: string,
	ids: []int,
}

// The tab's state at its start (`LevelMode.rules`)
LEVEL_RULES_DEFAULT :: LevelRules{layer = -1, rule = -1, last = -1, renaming = -1, group = -1, stamp = -1}

// Frees the tab's state (and leaves it at its start)
LevelRules_Destroy :: proc(r: ^LevelRules) {
	delete(r.open)
	delete(r.remap)
	delete(r.name)
	delete(r.clip)
	assistantClear(&r.assistant)
	r^ = LEVEL_RULES_DEFAULT
}

@(private="file")
assistantClear :: proc(a: ^LDtkAssistant) {
	for f in LDtkWallFragment do delete(a.tiles[f])
	a^ = {}
}

/*
The layer the tab shows: the one picked there while it's an IntGrid layer or an AutoLayer, else
the selected layer when it is one, else the first that is (-1 none; its node in `node`).
*/
LevelRules_Layer :: proc(s: ^State, doc: ^LDtkDoc) -> (uid, node: int) {
	if doc == nil || doc.problem != "" do return -1, -1
	main := LDtkDoc_Main(doc)
	ruleLayer :: proc(main: ^JsonDoc, d: int) -> bool {
		t := Json_String(main, Json_Get(main, d, "type"))
		return t == "IntGrid" || t == "AutoLayer"
	}
	for want in ([]int{s.level.rules.layer, LevelMode_LayerDefUid(s, doc)}) {
		if want < 0 do continue
		if d := LDtkDoc_DefByUid(doc, "layers", want); d >= 0 && ruleLayer(main, d) do return want, d
	}
	for d in Json_Items(main, LDtkDoc_Defs(doc, "layers")) do if ruleLayer(main, d) do return Json_Int(main, Json_Get(main, d, "uid")), d
	return -1, -1
}

// The selected layer's uid (-1 none)
LevelMode_LayerDefUid :: proc(s: ^State, doc: ^LDtkDoc) -> int {
	def := LevelMode_LayerDef(s, doc)
	if def < 0 do return -1
	main := LDtkDoc_Main(doc)
	return Json_Int(main, Json_Get(main, def, "uid"), -1)
}

/*
Whether a group shows its rules: as opened or closed in the tab, else as LDtk starts it (closed,
but a layer's only group that isn't the Assistant's: LayerDef.fromJson's "smart unfold").
*/
LevelRules_GroupOpen :: proc(s: ^State, groups: []LDtkGroupEdit, uid: int) -> bool {
	if open, set := s.level.rules.open[uid]; set do return open
	return len(groups) == 1 && groups[0].uid == uid && !groups[0].usesWizard
}

/*
The value LDtk's rule editor starts on (RuleEditor's smart pick): the value most used in the
pattern (anything not counted), else the source layer's first value, else "anything".
*/
LevelRules_SmartValue :: proc(r: ^LDtkRule, values: []int) -> int {
	counts := make(map[int]int, context.temp_allocator)
	best := -1
	for cy in 0 ..< r.size do for cx in 0 ..< r.size {
		v := abs(LDtkRule_Pattern(r, cx, cy))
		if v == 0 || v == LDTK_ANYTHING do continue
		counts[v] += 1
		if best < 0 || counts[best] < counts[v] do best = v
	}
	if best >= 0 do return best
	if len(values) > 0 do return values[0]
	return LDTK_ANYTHING
}

// The source layer's IntGrid values in their order (the rules' layer's own, or an AutoLayer's source's; temp)
LevelRules_Values :: proc(doc: ^LDtkDoc, layer: int) -> []int {
	_, _, source := LDtkRules_SourceValues(doc, layer)
	main := LDtkDoc_Main(doc)
	out := make([dynamic]int, context.temp_allocator)
	for v in Json_Items(main, Json_Get(main, source, "intGridValues")) do append(&out, Json_Int(main, Json_Get(main, v, "value")))
	return out[:]
}

// A rule of the tab's layer by uid (temp; ok false when it's gone)
LevelRules_Rule :: proc(doc: ^LDtkDoc, layer, uid: int) -> (r: LDtkRule, group: LDtkGroupEdit, ok: bool) {
	if doc == nil || layer < 0 do return {}, {}, false
	main := LDtkDoc_Main(doc)
	groups := LDtkRules_ReadGroups(main, layer)
	for g in groups do for x in g.rules do if x.uid == uid do return x, g, true
	return {}, {}, false
}

// The tab's view messages (none is undone)
LevelRules_Update :: proc(state: ^State, v: Rules_View) {
	r := &state.level.rules
	doc := LDtkDoc_Get(state.project.rootPath, LevelMode_File(state))
	switch v.op {
	case .Layer:
		// The tab follows the selected layer (LDtk's panel is the current layer's): picked here, it's selected
		state.level.layerDef = v.uid
		if !LevelTool_Available(state, state.level.tool) do state.level.tool = .Select
		r.layer = -1
		r.page, r.rule = .List, -1
	case .Group_Open:
		r.open[v.uid] = v.flag
	case .Edit:
		r.page, r.rule, r.last = .Editor, v.uid, v.uid
		r.unlinkX, r.unlinkY, r.stamp = false, false, -1
		_, layer := LevelRules_Layer(state, doc)
		if rule, _, ok := LevelRules_Rule(doc, layer, v.uid); ok {
			r.value = LevelRules_SmartValue(&rule, LevelRules_Values(doc, layer))
			// The offsets' link: on while min is -max (RuleRandomOffsets)
			r.unlinkX = rule.tileRandomXMin != -rule.tileRandomXMax
			r.unlinkY = rule.tileRandomYMin != -rule.tileRandomYMax
		}
	case .Close:
		r.page, r.rule, r.perlinPreview = .List, -1, false
	case .Value:
		r.value = v.number
	case .Rename:
		r.renaming = v.uid
	case .Last:
		r.last = v.uid
	case .Help:
		r.help = v.flag
	case .Perlin_Preview:
		r.perlinPreview = v.flag
	case .Unlink_X:
		r.unlinkX = v.flag
	case .Unlink_Y:
		r.unlinkY = v.flag
	case .Stamp:
		r.stamp = v.number
	case .Assistant:
		assistantClear(&r.assistant)
		r.page, r.group, r.part = .Assistant, v.uid, .Full
		setOwned(&r.name, "")
		r.assistant.breakOnMatch = true
		_, layer := LevelRules_Layer(state, doc)
		values := doc != nil && layer >= 0 ? LevelRules_Values(doc, layer) : nil
		if v.uid >= 0 && layer >= 0 {
			// A group the Assistant made: its choices read back (importRuleGroup)
			groups := LDtkRules_ReadGroups(LDtkDoc_Main(doc), layer)
			for &g in groups do if g.uid == v.uid {
				setOwned(&r.name, g.name)
				if a, ok := LDtkAssistant_Import(&g); ok {
					r.assistant.main, r.assistant.other, r.assistant.breakOnMatch = a.main, a.other, a.breakOnMatch
					for f in LDtkWallFragment do if len(a.tiles[f]) > 0 {
						r.assistant.tiles[f] = make([dynamic]int, len(a.tiles[f]))
						copy(r.assistant.tiles[f][:], a.tiles[f][:])
					}
				}
			}
		} else if len(values) == 1 {
			// The only value is picked, and names the group (onPickIntGridValue)
			assistantMain(state, doc, layer, values[0])
		}
	case .Assistant_Main:
		_, layer := LevelRules_Layer(state, doc)
		assistantMain(state, doc, layer, v.number)
	case .Assistant_Other:
		r.assistant.other = v.number
	case .Assistant_Name:
		setOwned(&r.name, v.text)
	case .Assistant_Part:
		r.part = LDtkWallFragment(clamp(v.number, 0, int(max(LDtkWallFragment))))
	case .Assistant_Tiles:
		f := LDtkWallFragment(clamp(v.number, 0, int(max(LDtkWallFragment))))
		delete(r.assistant.tiles[f])
		r.assistant.tiles[f] = nil
		if len(v.ids) > 0 {
			r.assistant.tiles[f] = make([dynamic]int, len(v.ids))
			copy(r.assistant.tiles[f][:], v.ids)
		}
	case .Assistant_Stack:
		r.assistant.breakOnMatch = !v.flag
	case .Remap:
		clear(&r.remap)
		r.page, r.group, r.offset = .Remap, v.uid, {}
		_, layer := LevelRules_Layer(state, doc)
		if doc != nil && layer >= 0 {
			for g in LDtkRules_ReadGroups(LDtkDoc_Main(doc), layer) do if g.uid == v.uid {
				setOwned(&r.name, strings.concatenate({g.name, " copy"}, context.temp_allocator))
				// Every value its patterns use, unchanged at first
				for x in g.rules do for raw in x.pattern {
					value := abs(raw)
					if value != 0 && value != LDTK_ANYTHING do r.remap[value] = value
				}
			}
		}
	case .Remap_Value:
		r.remap[v.number] = v.uid
	case .Remap_Offset:
		if len(v.ids) == 2 do r.offset = {v.ids[0], v.ids[1]}
	case .Remap_Name:
		setOwned(&r.name, v.text)
	case .Icon:
		r.page, r.group = .Icon, v.uid
	case .Color:
		r.page, r.group = .Color, v.uid
	case .Copy:
		_, layer := LevelRules_Layer(state, doc)
		layerUid := -1
		if layer >= 0 do layerUid = Json_Int(LDtkDoc_Main(doc), Json_Get(LDtkDoc_Main(doc), layer, "uid"))
		levelRulesCopy(state, doc, layerUid, v.uid, v.number)
	}
}

// The Assistant's main value picked: the outer one can't be it, and a new group takes its name
@(private="file")
assistantMain :: proc(state: ^State, doc: ^LDtkDoc, layer, value: int) {
	r := &state.level.rules
	if value == 0 do return
	r.assistant.main = value
	if r.assistant.other == value do r.assistant.other = 0
	if r.group >= 0 || doc == nil || layer < 0 do return
	_, _, source := LDtkRules_SourceValues(doc, layer)
	main := LDtkDoc_Main(doc)
	for v in Json_Items(main, Json_Get(main, source, "intGridValues")) do if Json_Int(main, Json_Get(main, v, "value")) == value {
		id := Json_Get(main, v, "identifier")
		setOwned(&r.name, Json_Kind(main, id) == .String ? Json_String(main, id) : fmt.tprintf("Rules for #%d", value))
	}
}

// A rule (`rule` >= 0) or a group copied into LDtk's clipboard
@(private="file")
levelRulesCopy :: proc(state: ^State, doc: ^LDtkDoc, layer, group, rule: int) {
	if doc == nil do return
	text := LDtkRules_CopyText(doc, layer, group, rule)
	if text == "" do return
	setOwned(&state.level.rules.clip, text)
	state.level.rules.clipKind = rule >= 0 ? .Rule : .Group
}

/*
What the tab does around a rule edit (`levelApplyEdit`): a cut copies first; after it, a new
rule's editor opens (LDtk's onCreateRule), a new empty group's name is typed, a copy becomes the
last rule, the Assistant's group shows open.

Inputs:
- before: the document's `nextUid` before the edit (the first uid it took)
*/
LevelRules_BeforeEdit :: proc(state: ^State, edit: LDtk_Edit) {
	if edit.key != "cut" do return
	doc := LDtkDoc_Get(state.project.rootPath, edit.file)
	#partial switch edit.op {
	case .Rule_Removed: levelRulesCopy(state, doc, edit.def, -1, edit.field)
	case .Rule_Group_Removed: levelRulesCopy(state, doc, edit.def, edit.index, -1)
	}
}

LevelRules_AfterEdit :: proc(state: ^State, edit: LDtk_Edit, before: int) {
	r := &state.level.rules
	#partial switch edit.op {
	case .Rule_Added:
		r.open[edit.index] = true
		LevelRules_Update(state, {op = .Edit, uid = before})
	case .Rule_Duplicated, .Rule_Pasted:
		if edit.key != "group" do r.last = before
	case .Rule_Group_Added:
		r.open[before] = true
		r.renaming = before
	case .Rule_Group_Assistant:
		r.open[edit.index >= 0 ? edit.index : before] = true
		r.page, r.group = .List, -1
	case .Rule_Group_Remapped:
		r.open[before] = true
		r.page, r.group = .List, -1
	case .Rule_Group_Set:
		if edit.key == "icon" || edit.key == "color" do r.page, r.group = .List, -1
	case .Rule_Removed:
		if edit.field == r.rule do r.page, r.rule = .List, -1
	}
	// The editor's rule went (a group removed, an undo): back to the list
	if r.page == .Editor {
		doc := LDtkDoc_Get(state.project.rootPath, edit.file)
		_, layer := LevelRules_Layer(state, doc)
		if _, _, ok := LevelRules_Rule(doc, layer, r.rule); !ok do r.page, r.rule = .List, -1
	}
}

// --- What the pointer is over -----------------------------------------------------------------

/*
The rule or group under the pointer in the tab (its cells are outlined on the canvas: LDtk's
showAffectedCells), and the cell under the pointer on the canvas (the tab outlines the rules that
put tiles there: onEditorMouseMove). View state kept by the views themselves, a frame behind.
*/
@(private="file", thread_local)
rulesHover: struct {
	layer, rule, group: int,
	// The canvas's cell (`ok` false: the pointer isn't on the focused level)
	cell: [2]int,
	cellLayer: int,
	cellOk: bool,
}

// What the tab's pointer is over (the canvas reads it)
LevelRules_Hovered :: proc() -> (layer, rule, group: int) {
	return rulesHover.layer, rulesHover.rule, rulesHover.group
}

// The tab says what its pointer is over (-1 nothing); true when that changed
LevelRules_SetHovered :: proc(layer, rule, group: int) -> bool {
	changed := rulesHover.layer != layer || rulesHover.rule != rule || rulesHover.group != group
	rulesHover.layer, rulesHover.rule, rulesHover.group = layer, rule, group
	return changed
}

// The canvas says which cell of a layer its pointer is over
LevelRules_SetCanvasCell :: proc(layer: int, cell: [2]int, ok: bool) -> bool {
	changed := rulesHover.cellOk != ok || (ok && (rulesHover.cell != cell || rulesHover.cellLayer != layer))
	rulesHover.cell, rulesHover.cellLayer, rulesHover.cellOk = cell, layer, ok
	return changed
}

// The canvas's cell (the tab reads it)
LevelRules_CanvasCell :: proc() -> (layer: int, cell: [2]int, ok: bool) {
	return rulesHover.cellLayer, rulesHover.cell, rulesHover.cellOk
}

/*
The rules under the canvas's pointer in the focused level's layer (LDtkRules_At; temp): what the
tab outlines.
*/
LevelRules_AtPointer :: proc(layer: int) -> []int {
	m := LevelPaint_Current()
	l, cell, ok := LevelRules_CanvasCell()
	if m == nil || !ok || l != layer do return nil
	data := LevelPaint_LayerByDef(m, layer)
	if data == nil do return nil
	return LDtkRules_At(m, data, cell.x, cell.y)
}

// Whether a rule is in a list (the tab's highlight)
LevelRules_Has :: proc(list: []int, uid: int) -> bool {
	return slice.contains(list, uid)
}
