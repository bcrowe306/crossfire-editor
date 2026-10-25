package crossfire_editor

import "core:fmt"
import "core:log"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"
import e "engine:."

// The Auto-layer Rules tab's edits (ldtk_rule_ops.odin, ldtk_rule_assistant.odin): every group
// and rule edit, what's written (LDtk's toJson: its keys, its tidy), the rules applied again in
// every level (LDtk's evaluation, ported), undo, the schema and the engine; checked against
// LDtk's samples (saved by LDtk 1.5.3) where they have the case

@(private="file")
RULES_SAMPLES :: "../ldtk/app/extraFiles/samples"

@(private="file")
RULES_FIXTURE :: "tests/fixtures/ldtk_paint"

// Where two texts first differ (temp)
@(private="file")
rulesDifference :: proc(a, b: string) -> string {
	i := 0
	for i < len(a) && i < len(b) && a[i] == b[i] do i += 1
	from := max(0, i - 100)
	return fmt.tprintf("at byte %d of %d / %d:\n  ours:   %q\n  theirs: %q", i, len(a), len(b), a[from:min(len(a), i + 100)], b[from:min(len(b), i + 100)])
}

// A fresh copy of a folder for one test
@(private="file")
rulesCopy :: proc(from, name: string) -> string {
	dir := tempDir(name)
	_ = removeAll(dir)
	problem := Folder_Copy(from, dir)
	assert(problem == "", problem)
	return dir
}

// A copy of one of LDtk's samples (with its images) in a fresh folder; "" without the samples
@(private="file")
sampleCopy :: proc(name, sample: string) -> string {
	if !os.exists(joinPath(RULES_SAMPLES, sample, allocator = context.temp_allocator)) do return ""
	dir := tempDir(name)
	_ = removeAll(dir)
	_ = os.make_directory(dir)
	entries, err := os.read_all_directory_by_path(RULES_SAMPLES, context.temp_allocator)
	if err != nil do return ""
	for entry in entries {
		if entry.type == .Directory {
			if entry.name == "atlas" do Folder_Copy(joinPath(RULES_SAMPLES, entry.name, allocator = context.temp_allocator), joinPath(dir, entry.name, allocator = context.temp_allocator))
			continue
		}
		if entry.name != sample && strings.has_suffix(entry.name, ".ldtk") do continue
		data, _ := os.read_entire_file(joinPath(RULES_SAMPLES, entry.name, allocator = context.temp_allocator), context.temp_allocator)
		_ = os.write_entire_file(joinPath(dir, entry.name, allocator = context.temp_allocator), data)
	}
	return dir
}

// A layer definition's uid by its name
@(private="file")
layerUid :: proc(doc: ^LDtkDoc, name: string) -> int {
	main := LDtkDoc_Main(doc)
	for d in Json_Items(main, LDtkDoc_Defs(doc, "layers")) do if Json_String(main, Json_Get(main, d, "identifier")) == name do return Json_Int(main, Json_Get(main, d, "uid"))
	return -1
}

// An edit of a document (why not, "" when made)
@(private="file")
ruleApply :: proc(dir, file: string, edit: LDtk_Edit) -> string {
	x := edit
	x.file = file
	problem, _ := LDtkOps_Apply(dir, x)
	return problem
}

/*
An edit made, then the document checked: every file against LDtk's schema, read by the engine,
already tidy (LDtk's tidy changes nothing), and every auto-layer's tiles what LDtk's rules make
of its IntGrid (applied again from scratch, they're the file's).
*/
@(private="file")
ruleMust :: proc(t: ^testing.T, dir, file: string, edit: LDtk_Edit, loc := #caller_location) {
	problem := ruleApply(dir, file, edit)
	testing.expectf(t, problem == "", "%v %q: %s", edit.op, edit.key, problem, loc = loc)
	rulesCheck(t, dir, file, loc)
}

@(private="file")
rulesCheck :: proc(t: ^testing.T, dir, file: string, loc := #caller_location) {
	doc := LDtkDoc_Get(dir, file)
	if !testing.expect(t, doc != nil && doc.problem == "", "the document reads", loc = loc) do return
	for f, i in doc.files {
		for p in LDtk_SchemaProblems(f.json.text, i == 0 ? "" : "Level") do testing.expectf(t, false, "schema: %s", p, loc = loc)
	}
	project, problem := e.LDtk_Parse(LDtkDoc_GameText(doc), doc.files[0].path)
	testing.expectf(t, project != nil, "the engine reads it: %s", problem, loc = loc)
	if project != nil do e.LDtk_Destroy(project)
	s := stagesMake(doc)
	testing.expect_value(t, LDtkTidy_Run(&s), "", loc = loc)
	for text, i in s.texts do if text != doc.files[i].json.text do testing.expectf(t, false, "not tidy after the edit (file %d): %s", i, rulesDifference(text, doc.files[i].json.text), loc = loc)
	for m in s.made do LDtkDoc_Free(m)
	// The auto-layers are what the rules make
	for _, level in doc.levels {
		m, ok := LDtkLevel_Read(doc, file, level)
		if !ok do continue
		defer LDtkLevel_Destroy(&m)
		lf, array := LDtkDoc_LayerInstances(doc, level)
		json := LDtkDoc_Json(doc, lf)
		for &l in m.layers {
			if !LDtkLayerInfo_IsAuto(&m.defs[l.def]) do continue
			li := -1
			for item in Json_Items(json, array) do if Json_String(json, Json_Get(json, item, "iid")) == l.iid do li = item
			node := Json_Get(json, li, "autoLayerTiles")
			// A layer the file gives no tiles (the fixture's Hall, never evaluated: LDtk keeps it so
			// until one of its rules changes)
			if Json_Count(json, node) == 0 do continue
			LDtkRules_ApplyAll(&m, &l)
			made := LDtk_PrettyJson(LDtkLayer_AutoTilesJson(&m, &l), m.minified, LDtk_IndentAt(json.text, int(json.nodes[node].start)))
			theirs := Json_Text(json, node)
			testing.expectf(t, made == theirs, "%s %s: the tiles are the rules', %s", m.identifier, m.defs[l.def].identifier, rulesDifference(made, theirs), loc = loc)
		}
	}
}

// A value of the document as the editor has it
@(private="file")
rulesValue :: proc(dir, file, at: string) -> string {
	return valueAt(joinPath(dir, file, allocator = context.temp_allocator), at)
}

// The keys of an object of the document, in order ("a,b,c")
@(private="file")
rulesKeys :: proc(dir, file, at: string) -> string {
	text, _ := LDtkDoc_CachedText(joinPath(dir, file, allocator = context.temp_allocator))
	doc, _ := Json_Parse(text, context.temp_allocator)
	keys := make([dynamic]string, context.temp_allocator)
	for c in Json_Items(&doc, Json_Path(&doc, at)) do append(&keys, Json_Key(&doc, c))
	return strings.join(keys[:], ",", context.temp_allocator)
}

/*
Every rule group of LDtk's samples, read and written back as LDtk's toJson writes it, is its text
byte for byte; and LDtk's tidy of each rule (trim, mirrors, checkers, out-of-bounds values)
changes nothing in them (LDtk tidied them when it saved them).
*/
@(test)
ldtk_rule_groups_write_back_as_ldtk_wrote_them :: proc(t: ^testing.T) {
	defer LDtkDoc_DestroyAll()
	entries, err := os.read_all_directory_by_path(RULES_SAMPLES, context.temp_allocator)
	// Kept past the temp memory each file is read in
	files := make([dynamic]string)
	defer {
		for f in files do delete(f)
		delete(files)
	}
	append(&files, joinPath(RULES_FIXTURE, "paint.ldtk"))
	if err == nil {
		for entry in entries do if strings.has_suffix(entry.name, ".ldtk") do append(&files, joinPath(RULES_SAMPLES, entry.name))
	} else {
		log.infof("LDtk's samples aren't here (%s): the fixture only", RULES_SAMPLES)
	}
	groups, rules := 0, 0
	for path in files {
		data, _ := os.read_entire_file(path, context.temp_allocator)
		json, problem := Json_Parse(string(data), context.temp_allocator)
		if !testing.expectf(t, problem == "", "%s parses", path) do continue
		for ld in Json_Items(&json, Json_Path(&json, "defs.layers")) {
			node := Json_Get(&json, ld, "autoRuleGroups")
			if Json_Count(&json, node) == 0 do continue
			read := LDtkRules_ReadGroups(&json, ld)
			// The source layer's values (the tidy's out-of-bounds check)
			values := make(map[int]bool, context.temp_allocator)
			source := ld
			if src := nodeUid(&json, Json_Get(&json, ld, "autoSourceLayerDefUid")); src >= 0 {
				for d in Json_Items(&json, Json_Path(&json, "defs.layers")) do if Json_Int(&json, Json_Get(&json, d, "uid")) == src do source = d
			}
			for v in Json_Items(&json, Json_Get(&json, source, "intGridValues")) do values[Json_Int(&json, Json_Get(&json, v, "value"))] = true
			items := Json_Items(&json, node)
			for &g, gi in read {
				for &r in g.rules {
					size := r.size
					fixed := LDtkRule_Tidy(&r, values)
					testing.expectf(t, !fixed && r.size == size, "%s rule %d: LDtk's tidy changes nothing", path, r.uid)
					rules += 1
				}
				ours := writeAt(&json, items[gi], ldtkGroupJV(&g), Json_Minified(&json))
				theirs := Json_Text(&json, items[gi])
				testing.expectf(t, ours == theirs, "%s group %q: written back %s", path, g.name, rulesDifference(ours, theirs))
				groups += 1
			}
		}
		free_all(context.temp_allocator)
	}
	log.infof("%d rule groups, %d rules written back as LDtk wrote them", groups, rules)
}

/*
Edits undone by the opposite edit leave LDtk's samples byte for byte as LDtk saved them (but for
`nextUid` where uids were taken): the rules written as LDtk writes them and their tiles made again
in every level as LDtk made them. Each step in between is schema-checked, read by the engine, tidy,
and its tiles the rules'.
*/
@(test)
ldtk_rule_edits_give_ldtks_own_files_back :: proc(t: ^testing.T) {
	defer LDtkDoc_DestroyAll()
	Case :: struct { sample, layer: string }
	cases := []Case{{"AutoLayers_1_basic.ldtk", ""}, {"AutoLayers_2_stamps.ldtk", ""}, {"AutoLayers_5_Advanced.ldtk", ""}, {"AutoLayers_7_Biomes.ldtk", ""}}
	ran := 0
	for c, ci in cases {
		dir := sampleCopy(fmt.tprintf("ldtk_rules_sample_%d", ci), c.sample)
		if dir == "" {
			log.infof("LDtk's samples aren't here: skipped")
			return
		}
		defer removeAll(dir)
		doc := LDtkDoc_Get(dir, c.sample)
		if !testing.expectf(t, doc != nil && doc.problem == "", "%s reads", c.sample) do continue
		original := strings.clone(LDtkDoc_Main(doc).text, context.temp_allocator)
		main := LDtkDoc_Main(doc)
		// The first layer with rules
		uid := -1
		for d in Json_Items(main, LDtkDoc_Defs(doc, "layers")) do if uid < 0 && Json_Count(main, Json_Get(main, d, "autoRuleGroups")) > 0 do uid = Json_Int(main, Json_Get(main, d, "uid"))
		if c.layer != "" do uid = layerUid(doc, c.layer)
		groups := LDtkRules_ReadGroups(main, LDtkDoc_DefByUid(doc, "layers", uid))
		if !testing.expectf(t, len(groups) > 0 && len(groups[0].rules) > 0, "%s has rules", c.sample) do continue
		g0 := groups[0].uid
		r0 := groups[0].rules[0]
		back :: proc(t: ^testing.T, dir, file, original: string, what: string, nextUid := false) {
			doc := LDtkDoc_Get(dir, file)
			text := LDtkDoc_Main(doc).text
			if nextUid {
				// Uids aren't given back (LDtk's either): the rest is
				a, _ := Json_Parse(text, context.temp_allocator)
				b, _ := Json_Parse(original, context.temp_allocator)
				na, nb := Json_Get(&a, Json_Root(&a), "nextUid"), Json_Get(&b, Json_Root(&b), "nextUid")
				text = fmt.tprintf("%s%s%s", text[:a.nodes[na].start], Json_Text(&b, nb), text[a.nodes[na].end:])
			}
			testing.expectf(t, text == original, "%s %s: the file as LDtk saved it %s", file, what, rulesDifference(text, original))
		}
		base := LDtk_Edit{def = uid, field = r0.uid, index = g0}
		// A rule's chance changed, then back
		e1 := base
		e1.op, e1.key, e1.number = .Rule_Set, "chance", r0.chance == 1 ? 0.5 : 1
		ruleMust(t, dir, c.sample, e1)
		testing.expect(t, LDtkDoc_Main(LDtkDoc_Get(dir, c.sample)).text != original, "the chance changed the file")
		e1.number = r0.chance
		ruleMust(t, dir, c.sample, e1)
		back(t, dir, c.sample, original, "chance back")
		// Off and on again
		e2 := base
		e2.op, e2.key, e2.flag = .Rule_Set, "active", !r0.active
		ruleMust(t, dir, c.sample, e2)
		e2.flag = r0.active
		ruleMust(t, dir, c.sample, e2)
		back(t, dir, c.sample, original, "rule off and on")
		// The group off and on
		if !groups[0].isOptional {
			e3 := base
			e3.op, e3.key, e3.flag = .Rule_Group_Set, "active", false
			ruleMust(t, dir, c.sample, e3)
			e3.flag = true
			ruleMust(t, dir, c.sample, e3)
			back(t, dir, c.sample, original, "group off and on")
		}
		// Its pattern changed and put back (the 9 x 9 grid the editor edits, trimmed again)
		{
			grid := make([]int, 81, context.temp_allocator)
			pad := (9 - r0.size) / 2
			for cy in 0 ..< r0.size do for cx in 0 ..< r0.size do grid[cx + pad + (cy + pad) * 9] = r0.pattern[cx + cy * r0.size]
			e4 := base
			e4.op, e4.number = .Rule_Pattern, 9
			changed := make([]int, 81, context.temp_allocator)
			copy(changed, grid)
			changed[40] = changed[40] == LDTK_ANYTHING ? 0 : LDTK_ANYTHING
			e4.ids = changed
			ruleMust(t, dir, c.sample, e4)
			e4.ids = grid
			ruleMust(t, dir, c.sample, e4)
			back(t, dir, c.sample, original, "pattern back")
		}
		// The second group moved up and back, when there's one
		if len(groups) > 1 {
			e5 := base
			e5.op, e5.index, e5.number = .Rule_Group_Moved, groups[1].uid, -1
			ruleMust(t, dir, c.sample, e5)
			e5.number = 1
			ruleMust(t, dir, c.sample, e5)
			back(t, dir, c.sample, original, "group moved and back")
		}
		// A rule copied, then the copy removed (uids aren't reused)
		{
			e6 := base
			e6.op = .Rule_Duplicated
			ruleMust(t, dir, c.sample, e6)
			after := LDtkRules_ReadGroups(LDtkDoc_Main(LDtkDoc_Get(dir, c.sample)), LDtkDoc_DefByUid(LDtkDoc_Get(dir, c.sample), "layers", uid))
			testing.expect_value(t, len(after[0].rules), len(groups[0].rules) + 1)
			e7 := base
			e7.op, e7.field = .Rule_Removed, after[0].rules[1].uid
			ruleMust(t, dir, c.sample, e7)
			back(t, dir, c.sample, original, "rule copied and removed", nextUid = true)
		}
		ran += 1
	}
	log.infof("%d of LDtk's samples edited and given back", ran)
}

// Optional groups (LDtk's sample of them): on and off in a level, as LDtk's levels have them
@(test)
ldtk_optional_rule_groups_per_level :: proc(t: ^testing.T) {
	defer LDtkDoc_DestroyAll()
	sample := "AutoLayers_6_OptionalRules.ldtk"
	dir := sampleCopy("ldtk_rules_optional", sample)
	if dir == "" {
		log.infof("LDtk's samples aren't here: skipped")
		return
	}
	defer removeAll(dir)
	doc := LDtkDoc_Get(dir, sample)
	original := strings.clone(LDtkDoc_Main(doc).text, context.temp_allocator)
	// A level with an optional group on, and the layer
	level, layer, group := "", -1, -1
	for _, l in doc.levels {
		_, iid := LDtkDoc_LevelNames(doc, l)
		file, array := LDtkDoc_LayerInstances(doc, l)
		json := LDtkDoc_Json(doc, file)
		for li in Json_Items(json, array) do if opt := Json_Get(json, li, "optionalRules"); Json_Count(json, opt) > 0 && level == "" {
			level = strings.clone(iid, context.temp_allocator)
			layer = Json_Int(json, Json_Get(json, li, "layerDefUid"))
			group = Json_Int(json, Json_At(json, opt, 0))
		}
	}
	if !testing.expect(t, level != "", "the sample has a level with an optional group on") do return
	// Off in that level: its rules' tiles go there, the others' levels stay as they were
	off := LDtk_Edit{op = .Rule_Group_Here, def = layer, index = group, level = level, flag = false}
	ruleMust(t, dir, sample, off)
	testing.expect(t, LDtkDoc_Main(LDtkDoc_Get(dir, sample)).text != original, "turned off")
	on := off
	on.flag = true
	ruleMust(t, dir, sample, on)
	testing.expect(t, LDtkDoc_Main(LDtkDoc_Get(dir, sample)).text == original, "on again: the file as LDtk saved it")
	// Not optional: "active" can't turn it off, the levels' states go with LDtk's tidy
	act := LDtk_Edit{op = .Rule_Group_Set, def = layer, index = group, key = "active", flag = false}
	testing.expect_value(t, ruleApply(dir, sample, act), "an optional group is turned on or off per level")
	notOptional := LDtk_Edit{op = .Rule_Group_Set, def = layer, index = group, key = "isOptional", flag = false}
	ruleMust(t, dir, sample, notOptional)
	text, _ := LDtkDoc_CachedText(joinPath(dir, sample, allocator = context.temp_allocator))
	json, _ := Json_Parse(text, context.temp_allocator)
	for lv in Json_Items(&json, Json_Get(&json, Json_Root(&json), "levels")) do for li in Json_Items(&json, Json_Get(&json, lv, "layerInstances")) {
		for u in Json_Items(&json, Json_Get(&json, li, "optionalRules")) do testing.expect(t, Json_Int(&json, u) != group, "the levels lost its on / off state (LDtk's tidy)")
	}
}

// Biomes (LDtk's sample of them): a group's required values, sorted as LDtk sorts them, its AND / OR
@(test)
ldtk_rule_group_biomes :: proc(t: ^testing.T) {
	defer LDtkDoc_DestroyAll()
	sample := "AutoLayers_7_Biomes.ldtk"
	dir := sampleCopy("ldtk_rules_biomes", sample)
	if dir == "" {
		log.infof("LDtk's samples aren't here: skipped")
		return
	}
	defer removeAll(dir)
	doc := LDtkDoc_Get(dir, sample)
	original := strings.clone(LDtkDoc_Main(doc).text, context.temp_allocator)
	layer := layerUid(doc, "IntGrid")
	at :: "defs.layers.identifier=IntGrid.autoRuleGroups.uid=84"
	set := LDtk_Edit{op = .Rule_Group_Set, def = layer, index = 84, key = "requiredBiomeValues", text = "Snow, rocky"}
	// "rocky" isn't one of the enum's values (LDtk's picker lists them only)
	testing.expect(t, strings.contains(ruleApply(dir, sample, set), "isn't a value"), "an unknown value")
	set.text = "Snow, Rocky, Snow"
	ruleMust(t, dir, sample, set)
	testing.expect_value(t, rulesValue(dir, sample, at + ".requiredBiomeValues"), `["Rocky","Snow"]`)
	mode := LDtk_Edit{op = .Rule_Group_Set, def = layer, index = 84, key = "biomeRequirementMode", number = 1}
	ruleMust(t, dir, sample, mode)
	testing.expect_value(t, rulesValue(dir, sample, at + ".biomeRequirementMode"), "1")
	bad := mode
	bad.number = 3
	testing.expect(t, ruleApply(dir, sample, bad) != "", "only 0 or 1")
	// One value again: the mode goes back to OR (LDtk's tidy), the file as LDtk saved it
	set.text = "Snow"
	ruleMust(t, dir, sample, set)
	testing.expect_value(t, rulesValue(dir, sample, at + ".biomeRequirementMode"), "0")
	testing.expect(t, LDtkDoc_Main(LDtkDoc_Get(dir, sample)).text == original, "the file as LDtk saved it")
}

// The keys LDtk's sample writes a rule group and a rule with (its toJson order)
@(private="file")
sampleRuleKeys :: proc() -> (group, rule: string) {
	data, err := os.read_entire_file(joinPath(RULES_SAMPLES, "AutoLayers_1_basic.ldtk", allocator = context.temp_allocator), context.temp_allocator)
	if err != nil do return "uid,name,color,icon,active,isOptional,rules,usesWizard,requiredBiomeValues,biomeRequirementMode",
		"uid,active,size,tileRectsIds,alpha,chance,breakOnMatch,pattern,flipX,flipY,xModulo,yModulo,xOffset,yOffset,tileXOffset,tileYOffset,tileRandomXMin,tileRandomXMax,tileRandomYMin,tileRandomYMax,checker,tileMode,pivotX,pivotY,outOfBoundsValue,invalidated,perlinActive,perlinSeed,perlinScale,perlinOctaves"
	doc, _ := Json_Parse(string(data), context.temp_allocator)
	keys :: proc(doc: ^JsonDoc, node: int) -> string {
		out := make([dynamic]string, context.temp_allocator)
		for c in Json_Items(doc, node) do append(&out, Json_Key(doc, c))
		return strings.join(out[:], ",", context.temp_allocator)
	}
	g := Json_Path(&doc, "defs.layers.0.autoRuleGroups.0")
	return keys(&doc, g), keys(&doc, Json_At(&doc, Json_Get(&doc, g, "rules"), 0))
}

/*
A layer's rule groups edited as LDtk's panel edits them (on the painting fixture's Ground layer:
groups Surface (50) and Flowers (60, optional, on in Room)): made in LDtk's key order with its
defaults, renamed, colored, given an icon, copied with new uids, moved, made optional and turned on
in a level, every rule's out-of-bounds policy, removed; refusals.
*/
@(test)
ldtk_rule_groups_are_edited_as_ldtk_edits_them :: proc(t: ^testing.T) {
	dir := rulesCopy(RULES_FIXTURE, "ldtk_rule_groups")
	defer removeAll(dir)
	defer LDtkDoc_DestroyAll()
	file := "paint.ldtk"
	groupKeys, _ := sampleRuleKeys()
	g :: "defs.layers.uid=3.autoRuleGroups"
	add := LDtk_Edit{op = .Rule_Group_Added, def = 3}
	ruleMust(t, dir, file, add)
	testing.expect_value(t, rulesValue(dir, file, g + ".0.uid"), "200")
	testing.expect_value(t, rulesValue(dir, file, g + ".0.name"), "New group")
	testing.expect_value(t, rulesValue(dir, file, g + ".0.rules"), "[]")
	testing.expect_value(t, rulesKeys(dir, file, g + ".0"), groupKeys)
	testing.expect_value(t, rulesValue(dir, file, "nextUid"), "201")
	set :: proc(key, text: string, number: f64 = 0, flag := false, group := 200) -> LDtk_Edit {
		return {op = .Rule_Group_Set, def = 3, index = group, key = key, text = text, number = number, flag = flag}
	}
	ruleMust(t, dir, file, set("name", "Edges"))
	testing.expect_value(t, rulesValue(dir, file, g + ".0.name"), "Edges")
	ruleMust(t, dir, file, set("color", "#ff0044"))
	testing.expect_value(t, rulesValue(dir, file, g + ".0.color"), "#FF0044")
	testing.expect(t, ruleApply(dir, file, set("color", "red")) != "", "not a color")
	ruleMust(t, dir, file, set("icon", "16,0,16,16", 10))
	testing.expect_value(t, rulesValue(dir, file, g + ".0.icon"), `{"tilesetUid":10,"x":16,"y":0,"w":16,"h":16}`)
	ruleMust(t, dir, file, set("icon", ""))
	testing.expect_value(t, rulesValue(dir, file, g + ".0.icon"), "null")
	// Biomes need the layer's biome field
	testing.expect(t, strings.contains(ruleApply(dir, file, set("requiredBiomeValues", "Snow")), "biome"), "no biome field")
	// Moved down past Surface, back up
	move := LDtk_Edit{op = .Rule_Group_Moved, def = 3, index = 200, number = 1}
	ruleMust(t, dir, file, move)
	testing.expect_value(t, rulesValue(dir, file, g + ".1.uid"), "200")
	move.number = -5
	ruleMust(t, dir, file, move)
	testing.expect_value(t, rulesValue(dir, file, g + ".0.uid"), "200")
	// Surface copied after itself: new uids for it and its rules, the same name (LDtk's paste)
	dup := LDtk_Edit{op = .Rule_Group_Duplicated, def = 3, index = 50}
	ruleMust(t, dir, file, dup)
	testing.expect_value(t, rulesValue(dir, file, g + ".2.uid"), "201")
	testing.expect_value(t, rulesValue(dir, file, g + ".2.name"), "Surface")
	testing.expect_value(t, rulesValue(dir, file, g + ".2.rules.0.uid"), "202")
	testing.expect_value(t, rulesValue(dir, file, g + ".2.rules.5.uid"), "207")
	testing.expect_value(t, rulesValue(dir, file, "nextUid"), "208")
	// Every rule's out-of-bounds policy at once
	ruleMust(t, dir, file, set("outOfBoundsValue", "2", group = 201))
	testing.expect_value(t, rulesValue(dir, file, g + ".2.rules.0.outOfBoundsValue"), "2")
	testing.expect_value(t, rulesValue(dir, file, g + ".2.rules.4.outOfBoundsValue"), "2")
	testing.expect(t, strings.contains(ruleApply(dir, file, set("outOfBoundsValue", "9", group = 201)), "no value 9"), "a value the layer lacks")
	ruleMust(t, dir, file, set("outOfBoundsValue", "", group = 201))
	testing.expect_value(t, rulesValue(dir, file, g + ".2.rules.4.outOfBoundsValue"), "null")
	// Off: its tiles go (the copy's: Surface's still make the same)
	ruleMust(t, dir, file, set("active", "", flag = false, group = 201))
	testing.expect_value(t, rulesValue(dir, file, g + ".2.active"), "false")
	// Optional (active again), turned on in Hall only
	ruleMust(t, dir, file, set("isOptional", "", flag = true, group = 201))
	testing.expect_value(t, rulesValue(dir, file, g + ".2.isOptional"), "true")
	testing.expect_value(t, rulesValue(dir, file, g + ".2.active"), "true")
	hall := rulesValue(dir, file, "levels.identifier=Hall.iid")
	here := LDtk_Edit{op = .Rule_Group_Here, def = 3, index = 201, level = hall, flag = true}
	ruleMust(t, dir, file, here)
	testing.expect_value(t, rulesValue(dir, file, "levels.identifier=Hall.layerInstances.__identifier=Ground.optionalRules"), "[201]")
	notHere := here
	notHere.index = 50
	testing.expect(t, ruleApply(dir, file, notHere) != "", "Surface isn't optional")
	// No longer optional: Hall's state goes (LDtk's tidy)
	ruleMust(t, dir, file, set("isOptional", "", flag = false, group = 201))
	testing.expect_value(t, rulesValue(dir, file, "levels.identifier=Hall.layerInstances.__identifier=Ground.optionalRules"), "[]")
	// Removed
	ruleMust(t, dir, file, LDtk_Edit{op = .Rule_Group_Removed, def = 3, index = 201})
	testing.expect_value(t, rulesValue(dir, file, g + ".2.uid"), "60")
	// A layer whose rules can't work takes no groups
	testing.expect(t, strings.contains(ruleApply(dir, file, LDtk_Edit{op = .Rule_Group_Added, def = 2}), "prevent"), "a Tiles layer")
}

/*
Rules edited as LDtk's panel, rule editor and option dialogs edit them: a new rule in LDtk's key
order (trimmed to 1 x 1 as its toJson writes an empty one), its pattern from the editor's 9 x 9
grid (trimmed), tiles one by one and as stamps, every option with LDtk's bounds and fixes, the
tidy's fixes (a mirror of a symmetric pattern, a checker without its modulo), copies, moves
between groups, LDtk's clipboard, the level's seed and tileset.
*/
@(test)
ldtk_rules_are_edited_as_ldtk_edits_them :: proc(t: ^testing.T) {
	dir := rulesCopy(RULES_FIXTURE, "ldtk_rules_edits")
	defer removeAll(dir)
	defer LDtkDoc_DestroyAll()
	file := "paint.ldtk"
	_, ruleKeys := sampleRuleKeys()
	r :: "defs.layers.uid=3.autoRuleGroups.uid=50.rules.0"
	ruleMust(t, dir, file, LDtk_Edit{op = .Rule_Added, def = 3, index = 50, number = 0})
	testing.expect_value(t, rulesValue(dir, file, r + ".uid"), "200")
	testing.expect_value(t, rulesKeys(dir, file, r), ruleKeys)
	testing.expect_value(t, rulesValue(dir, file, r + ".size"), "1")
	testing.expect_value(t, rulesValue(dir, file, r + ".pattern"), "[0]")
	testing.expect_value(t, rulesValue(dir, file, r + ".breakOnMatch"), "true")
	testing.expect_value(t, rulesValue(dir, file, r + ".chance"), "1")
	testing.expect_value(t, rulesValue(dir, file, r + ".tileRectsIds"), "[]")
	testing.expect_value(t, rulesValue(dir, file, r + ".perlinScale"), "0.2")
	set :: proc(key: string, number: f64 = 0, text := "", flag := false, number2: f64 = 0) -> LDtk_Edit {
		return {op = .Rule_Set, def = 3, field = 200, key = key, number = number, number2 = number2, text = text, flag = flag}
	}
	// The pattern: grass at the center, not grass above it (the 9 x 9 grid, trimmed to 3 x 3)
	grid := make([]int, 81, context.temp_allocator)
	grid[40], grid[31] = 1, -1
	ruleMust(t, dir, file, LDtk_Edit{op = .Rule_Pattern, def = 3, field = 200, number = 9, ids = grid})
	testing.expect_value(t, rulesValue(dir, file, r + ".size"), "3")
	testing.expect_value(t, rulesValue(dir, file, r + ".pattern"), "[0,-1,0,0,1,0,0,0,0]")
	testing.expect(t, ruleApply(dir, file, LDtk_Edit{op = .Rule_Pattern, def = 3, field = 200, number = 4, ids = grid[:16]}) != "", "an even size")
	// Tiles: individual ones, then the mode changes (they go), stamps added, replaced, removed
	tiles := LDtk_Edit{op = .Rule_Tiles, def = 3, field = 200, key = "single", ids = []int{12, 13}}
	ruleMust(t, dir, file, tiles)
	testing.expect_value(t, rulesValue(dir, file, r + ".tileRectsIds"), "[[12],[13]]")
	ruleMust(t, dir, file, set("tileMode", text = "Stamp"))
	testing.expect_value(t, rulesValue(dir, file, r + ".tileRectsIds"), "[]")
	stamp := LDtk_Edit{op = .Rule_Tiles, def = 3, field = 200, key = "stamp", number = -1, ids = []int{8, 16, 9, 17}}
	ruleMust(t, dir, file, stamp)
	stamp.ids = []int{10, 18}
	ruleMust(t, dir, file, stamp)
	testing.expect_value(t, rulesValue(dir, file, r + ".tileRectsIds"), "[[8,16,9,17],[10,18]]")
	stamp.number, stamp.ids = 0, []int{12}
	ruleMust(t, dir, file, stamp)
	ruleMust(t, dir, file, LDtk_Edit{op = .Rule_Tiles, def = 3, field = 200, key = "remove", number = 1})
	testing.expect_value(t, rulesValue(dir, file, r + ".tileRectsIds"), "[[12]]")
	ruleMust(t, dir, file, set("pivot", 0.5, number2 = 1))
	testing.expect_value(t, rulesValue(dir, file, r + ".pivotX"), "0.5")
	testing.expect_value(t, rulesValue(dir, file, r + ".pivotY"), "1")
	// Chance, opacity: LDtk's bounds and precision
	ruleMust(t, dir, file, set("chance", 0.25))
	testing.expect_value(t, rulesValue(dir, file, r + ".chance"), "0.25")
	ruleMust(t, dir, file, set("chance", 5))
	testing.expect_value(t, rulesValue(dir, file, r + ".chance"), "1")
	ruleMust(t, dir, file, set("alpha", 0.555))
	testing.expect_value(t, rulesValue(dir, file, r + ".alpha"), "0.56")
	ruleMust(t, dir, file, set("breakOnMatch", flag = false))
	testing.expect_value(t, rulesValue(dir, file, r + ".breakOnMatch"), "false")
	// Mirrors: X is symmetric (refused), Y isn't
	testing.expect(t, strings.contains(ruleApply(dir, file, set("flipX", flag = true)), "symmetric"), "X mirror of a symmetric pattern")
	ruleMust(t, dir, file, set("flipY", flag = true))
	testing.expect_value(t, rulesValue(dir, file, r + ".flipY"), "true")
	// Modulos, offsets, the checker
	ruleMust(t, dir, file, set("xModulo", 3))
	ruleMust(t, dir, file, set("xOffset", 5))
	testing.expect_value(t, rulesValue(dir, file, r + ".xOffset"), "2")
	ruleMust(t, dir, file, set("xModulo", 99))
	testing.expect_value(t, rulesValue(dir, file, r + ".xModulo"), "40")
	ruleMust(t, dir, file, set("checker", text = "Horizontal"))
	testing.expect_value(t, rulesValue(dir, file, r + ".checker"), "Horizontal")
	testing.expect(t, strings.contains(ruleApply(dir, file, set("checker", text = "Vertical")), "Y modulo"), "a vertical checker without a Y modulo")
	// The X modulo back to 1: the tidy turns the checker off
	ruleMust(t, dir, file, set("xModulo", 1))
	testing.expect_value(t, rulesValue(dir, file, r + ".checker"), "None")
	ruleMust(t, dir, file, set("yModulo", 2))
	ruleMust(t, dir, file, set("yOffset", 1))
	ruleMust(t, dir, file, set("moduloReset"))
	testing.expect_value(t, rulesValue(dir, file, r + ".yModulo"), "1")
	testing.expect_value(t, rulesValue(dir, file, r + ".yOffset"), "0")
	// Tile offsets: fixed, random (linked: -max to max), min never past max
	ruleMust(t, dir, file, set("tileXOffset", 3))
	ruleMust(t, dir, file, set("tileRandomX", 4))
	testing.expect_value(t, rulesValue(dir, file, r + ".tileRandomXMin"), "-4")
	testing.expect_value(t, rulesValue(dir, file, r + ".tileRandomXMax"), "4")
	ruleMust(t, dir, file, set("tileRandomXMin", 6))
	testing.expect_value(t, rulesValue(dir, file, r + ".tileRandomXMin"), "4")
	ruleMust(t, dir, file, set("tileRandomYMax", -2))
	testing.expect_value(t, rulesValue(dir, file, r + ".tileRandomYMax"), "0")
	ruleMust(t, dir, file, set("tileRandomYMin", -3))
	ruleMust(t, dir, file, set("tileRandomYLink"))
	testing.expect_value(t, rulesValue(dir, file, r + ".tileRandomYMax"), "0")
	testing.expect_value(t, rulesValue(dir, file, r + ".tileRandomYMin"), "0")
	ruleMust(t, dir, file, set("offsetsReset"))
	testing.expect_value(t, rulesValue(dir, file, r + ".tileXOffset"), "0")
	testing.expect_value(t, rulesValue(dir, file, r + ".tileRandomXMax"), "0")
	// Perlin
	ruleMust(t, dir, file, set("perlinActive", flag = true))
	ruleMust(t, dir, file, set("perlinSeed", 123))
	ruleMust(t, dir, file, set("perlinScale", 2))
	ruleMust(t, dir, file, set("perlinOctaves", 9))
	testing.expect_value(t, rulesValue(dir, file, r + ".perlinActive"), "true")
	testing.expect_value(t, rulesValue(dir, file, r + ".perlinSeed"), "123")
	testing.expect_value(t, rulesValue(dir, file, r + ".perlinScale"), "0.99")
	testing.expect_value(t, rulesValue(dir, file, r + ".perlinOctaves"), "4")
	// The out-of-bounds policy
	ruleMust(t, dir, file, set("outOfBoundsValue", text = "0"))
	testing.expect_value(t, rulesValue(dir, file, r + ".outOfBoundsValue"), "0")
	testing.expect(t, ruleApply(dir, file, set("outOfBoundsValue", text = "7")) != "", "a value the layer lacks")
	ruleMust(t, dir, file, set("outOfBoundsValue", text = ""))
	testing.expect_value(t, rulesValue(dir, file, r + ".outOfBoundsValue"), "null")
	// A mirror the pattern makes useless is turned off when it's written (LDtk's tidy)
	symmetric := make([]int, 81, context.temp_allocator)
	symmetric[40] = 1
	ruleMust(t, dir, file, LDtk_Edit{op = .Rule_Pattern, def = 3, field = 200, number = 9, ids = symmetric})
	testing.expect_value(t, rulesValue(dir, file, r + ".flipY"), "false")
	testing.expect_value(t, rulesValue(dir, file, r + ".size"), "1")
	// Off and on
	ruleMust(t, dir, file, set("active", flag = false))
	testing.expect_value(t, rulesValue(dir, file, r + ".active"), "false")
	ruleMust(t, dir, file, set("active", flag = true))
	// Copied after itself, moved into Flowers, removed
	ruleMust(t, dir, file, LDtk_Edit{op = .Rule_Duplicated, def = 3, field = 200})
	testing.expect_value(t, rulesValue(dir, file, "defs.layers.uid=3.autoRuleGroups.uid=50.rules.1.uid"), "201")
	ruleMust(t, dir, file, LDtk_Edit{op = .Rule_Moved, def = 3, field = 201, index = 60, number = 1})
	testing.expect_value(t, rulesValue(dir, file, "defs.layers.uid=3.autoRuleGroups.uid=60.rules.1.uid"), "201")
	testing.expect(t, ruleApply(dir, file, LDtk_Edit{op = .Rule_Moved, def = 3, field = 201, index = 60, number = 5}) != "", "past the group's end")
	ruleMust(t, dir, file, LDtk_Edit{op = .Rule_Moved, def = 3, field = 201, index = 60, number = 0})
	testing.expect_value(t, rulesValue(dir, file, "defs.layers.uid=3.autoRuleGroups.uid=60.rules.0.uid"), "201")
	ruleMust(t, dir, file, LDtk_Edit{op = .Rule_Removed, def = 3, field = 201})
	testing.expect_value(t, rulesValue(dir, file, "defs.layers.uid=3.autoRuleGroups.uid=60.rules.0.uid"), "61")
	// LDtk's clipboard: a rule pasted after another (a new uid, the rest the same), a group at the end
	doc := LDtkDoc_Get(dir, file)
	text := strings.clone(LDtkRules_CopyText(doc, 3, -1, 51), context.temp_allocator)
	testing.expect(t, strings.contains(text, `"uid":51`), text)
	ruleMust(t, dir, file, LDtk_Edit{op = .Rule_Pasted, def = 3, key = "rule", text = text, index = 60, field = 61})
	pasted :: "defs.layers.uid=3.autoRuleGroups.uid=60.rules.1"
	testing.expect_value(t, rulesValue(dir, file, pasted + ".uid"), "202")
	testing.expect_value(t, rulesValue(dir, file, pasted + ".chance"), "0.3")
	testing.expect_value(t, rulesValue(dir, file, pasted + ".tileRectsIds"), "[[0],[1],[2]]")
	groupText := strings.clone(LDtkRules_CopyText(LDtkDoc_Get(dir, file), 3, 60, -1), context.temp_allocator)
	ruleMust(t, dir, file, LDtk_Edit{op = .Rule_Pasted, def = 3, key = "group", text = groupText, index = -1})
	testing.expect_value(t, rulesValue(dir, file, "defs.layers.uid=3.autoRuleGroups.2.uid"), "203")
	testing.expect_value(t, rulesValue(dir, file, "defs.layers.uid=3.autoRuleGroups.2.rules.1.uid"), "205")
	testing.expect(t, ruleApply(dir, file, LDtk_Edit{op = .Rule_Pasted, def = 3, key = "rule", text = "nope", index = 60}) != "", "not a rule")
	// The level's layer: its seed (Randomize), its tileset (one of the same size)
	room := rulesValue(dir, file, "levels.identifier=Room.iid")
	ruleMust(t, dir, file, LDtk_Edit{op = .Rule_Seed, def = 3, level = room, number = 42})
	testing.expect_value(t, rulesValue(dir, file, "levels.identifier=Room.layerInstances.__identifier=Ground.seed"), "42")
	ruleMust(t, dir, file, LDtk_Edit{op = .Rule_Seed, def = 3, level = room, number = -1})
	testing.expect(t, rulesValue(dir, file, "levels.identifier=Room.layerInstances.__identifier=Ground.seed") != "42", "a new random seed")
	ruleMust(t, dir, file, LDtk_Edit{op = .Rule_Tileset_Here, def = 3, level = room, number = 10})
	testing.expect_value(t, rulesValue(dir, file, "levels.identifier=Room.layerInstances.__identifier=Ground.overrideTilesetUid"), "10")
	ruleMust(t, dir, file, LDtk_Edit{op = .Rule_Tileset_Here, def = 3, level = room, number = -1})
	testing.expect_value(t, rulesValue(dir, file, "levels.identifier=Room.layerInstances.__identifier=Ground.overrideTilesetUid"), "null")
	testing.expect(t, ruleApply(dir, file, LDtk_Edit{op = .Rule_Tileset_Here, def = 3, level = room, number = 99}) != "", "no such tileset")
}

/*
LDtk's Rule Assistant: its sample's group, read back into the Assistant's choices and made again,
gives LDtk's rules (the same patterns, tiles, mirrors, policies, in the same order: only uids and
Perlin seeds are new); a new group from a value and a few parts' tiles, mirrored parts flipping;
the group's rules refused to the other edits until Advanced mode.
*/
@(test)
ldtk_rule_assistant_makes_ldtks_rules :: proc(t: ^testing.T) {
	defer LDtkDoc_DestroyAll()
	sample := "AutoLayers_4_Assistant.ldtk"
	if dir := sampleCopy("ldtk_rules_assistant_sample", sample); dir != "" {
		defer removeAll(dir)
		doc := LDtkDoc_Get(dir, sample)
		layer := layerUid(doc, "Walls")
		main := LDtkDoc_Main(doc)
		before := LDtkRules_ReadGroups(main, LDtkDoc_DefByUid(doc, "layers", layer))
		g := &before[0]
		testing.expect(t, g.usesWizard, "the sample's group is the Assistant's")
		a, ok := LDtkAssistant_Import(g)
		testing.expect(t, ok, "read back")
		edit := LDtk_Edit{op = .Rule_Group_Assistant, def = layer, index = g.uid, text = g.name, ids = LDtkAssistant_Encode(&a)}
		ruleMust(t, dir, sample, edit)
		doc = LDtkDoc_Get(dir, sample)
		after := LDtkRules_ReadGroups(LDtkDoc_Main(doc), LDtkDoc_DefByUid(doc, "layers", layer))
		testing.expect_value(t, len(after[0].rules), len(g.rules))
		for i in 0 ..< min(len(g.rules), len(after[0].rules)) {
			x, y := g.rules[i], after[0].rules[i]
			describe :: proc(r: LDtkRule) -> string {
				return fmt.tprint(r.size, r.pattern[:], r.tileRectsIds[:], r.flipX, r.flipY, r.outOfBounds, r.hasOutOfBounds, r.breakOnMatch, r.chance, r.alpha)
			}
			testing.expectf(t, describe(x) == describe(y), "rule %d: LDtk's %s, ours %s", i, describe(x), describe(y))
		}
		testing.expect(t, after[0].usesWizard && after[0].name == g.name, "still the Assistant's")
		rulesCheck(t, dir, sample)
	} else {
		log.infof("LDtk's samples aren't here: the sample's part skipped")
	}

	// A new group on the fixture: stone (2) blocks with a top wall, its bottom mirrored
	dir := rulesCopy(RULES_FIXTURE, "ldtk_rules_assistant")
	defer removeAll(dir)
	file := "paint.ldtk"
	a: LDtkAssistant
	a.main, a.breakOnMatch = 2, true
	a.tiles[.Full] = make([dynamic]int, context.temp_allocator)
	append(&a.tiles[.Full], 4)
	a.tiles[.Wall_N] = make([dynamic]int, context.temp_allocator)
	append(&a.tiles[.Wall_N], 0, 1)
	edit := LDtk_Edit{op = .Rule_Group_Assistant, def = 3, index = -1, text = "Stone", ids = LDtkAssistant_Encode(&a)}
	ruleMust(t, dir, file, edit)
	g :: "defs.layers.uid=3.autoRuleGroups.0"
	testing.expect_value(t, rulesValue(dir, file, g + ".name"), "Stone")
	testing.expect_value(t, rulesValue(dir, file, g + ".uid"), "200")
	testing.expect_value(t, rulesValue(dir, file, g + ".usesWizard"), "true")
	// The parts in LDtk's order: the top wall (Wall_N) before the block (Full)
	testing.expect_value(t, rulesValue(dir, file, g + ".rules.0.pattern"), "[0,-2,0,0,2,0,0,0,0]")
	testing.expect_value(t, rulesValue(dir, file, g + ".rules.0.tileRectsIds"), "[[0],[1]]")
	// Wall_S has no tiles: the top wall's rule mirrors vertically for it
	testing.expect_value(t, rulesValue(dir, file, g + ".rules.0.flipY"), "true")
	testing.expect_value(t, rulesValue(dir, file, g + ".rules.0.flipX"), "false")
	testing.expect_value(t, rulesValue(dir, file, g + ".rules.0.outOfBoundsValue"), "2")
	testing.expect_value(t, rulesValue(dir, file, g + ".rules.1.pattern"), "[2]")
	testing.expect_value(t, rulesValue(dir, file, g + ".rules.1.size"), "1")
	testing.expect_value(t, rulesValue(dir, file, g + ".rules.1.uid"), "202")
	// Its rules are the Assistant's: refused elsewhere, until Advanced mode
	testing.expect(t, strings.contains(ruleApply(dir, file, LDtk_Edit{op = .Rule_Set, def = 3, field = 201, key = "chance", number = 0.5}), "Assistant"), "refused")
	testing.expect(t, strings.contains(ruleApply(dir, file, LDtk_Edit{op = .Rule_Added, def = 3, index = 200}), "Assistant"), "refused")
	ruleMust(t, dir, file, LDtk_Edit{op = .Rule_Group_Set, def = 3, index = 200, key = "usesWizard", flag = false})
	ruleMust(t, dir, file, LDtk_Edit{op = .Rule_Set, def = 3, field = 201, key = "chance", number = 0.5})
	// Edited again with the outer value dirt (3): its rules made again in the group
	testing.expect(t, ruleApply(dir, file, LDtk_Edit{op = .Rule_Group_Assistant, def = 3, index = 200, text = "", ids = edit.ids}) != "", "a name")
	a.other = 3
	again := LDtk_Edit{op = .Rule_Group_Assistant, def = 3, index = 200, text = "Stone on dirt", ids = LDtkAssistant_Encode(&a)}
	ruleMust(t, dir, file, again)
	testing.expect_value(t, rulesValue(dir, file, g + ".rules.0.pattern"), "[0,3,0,0,2,0,0,0,0]")
	testing.expect_value(t, rulesValue(dir, file, g + ".rules.0.uid"), "203")
	testing.expect_value(t, rulesValue(dir, file, g + ".name"), "Stone on dirt")
	testing.expect_value(t, rulesValue(dir, file, g + ".usesWizard"), "true")
	read := LDtkRules_ReadGroups(LDtkDoc_Main(LDtkDoc_Get(dir, file)), LDtkDoc_DefByUid(LDtkDoc_Get(dir, file), "layers", 3))
	back, ok := LDtkAssistant_Import(&read[0])
	testing.expect(t, ok && back.main == 2 && back.other == 3 && len(back.tiles[.Wall_N]) == 2 && len(back.tiles[.Full]) == 1, "read back")
}

// LDtk's Duplicate and Remap: values remapped (their "not" too), tiles moved on the tileset
@(test)
ldtk_rule_groups_duplicate_and_remap :: proc(t: ^testing.T) {
	dir := rulesCopy(RULES_FIXTURE, "ldtk_rules_remap")
	defer removeAll(dir)
	defer LDtkDoc_DestroyAll()
	file := "paint.ldtk"
	edit := LDtk_Edit{op = .Rule_Group_Remapped, def = 3, index = 50, text = "Surface copy", ids = []int{1, 3, 2, 4}, number = 0, number2 = 1}
	ruleMust(t, dir, file, edit)
	g :: "defs.layers.uid=3.autoRuleGroups.1"
	testing.expect_value(t, rulesValue(dir, file, g + ".name"), "Surface copy")
	testing.expect_value(t, rulesValue(dir, file, g + ".uid"), "200")
	testing.expect_value(t, rulesValue(dir, file, g + ".rules.0.pattern"), "[0,-3,0,0,3,0,0,0,0]")
	// A row down (the tileset is 8 tiles across)
	testing.expect_value(t, rulesValue(dir, file, g + ".rules.0.tileRectsIds"), "[[8],[9],[10]]")
	// The wall's out-of-bounds stone became water
	testing.expect_value(t, rulesValue(dir, file, g + ".rules.4.outOfBoundsValue"), "4")
	edit.number = 1
	testing.expect(t, strings.contains(ruleApply(dir, file, edit), "edge"), "tile 7 moved past the tileset's right edge")
	edit.number, edit.text = 0, " "
	testing.expect(t, ruleApply(dir, file, edit) != "", "a name")
}

// Rule edits through the editor: one undo step each, labelled; undo puts the text back byte for byte
@(test)
ldtk_rule_edits_undo_in_the_editor :: proc(t: ^testing.T) {
	dir := rulesCopy(RULES_FIXTURE, "ldtk_rules_undo")
	defer removeAll(dir)
	defer LDtkDoc_DestroyAll()
	defer LevelCanvas_Destroy()
	state := new(State)
	state^ = State{project = Project_CreateEmpty(dir, "Rules"), browserSelection = {kind = .None}, selectedNode = -1, layout = {bottomOpen = true}, settings = Settings_Default()}
	defer {
		State_Destroy(state)
		free(state)
	}
	state.settings.builtInCodeEditor = false
	state.mode = .Level
	state.level = {layout = LEVEL_LAYOUT_DEFAULT, bottomTab = .Auto_Layer_Rules, layerDef = 3, entityDef = -1, enumDef = -1, fieldDef = -1, levelField = -1, tilesetDef = -1, dataTile = -1, paint = {entityDef = -1}}
	append(&state.project.assets, AssetDef{path = strings.clone("paint.ldtk"), kind = .LDtk})
	before := strings.clone(LDtkDoc_Main(LDtkDoc_Get(dir, "paint.ldtk")).text, context.temp_allocator)
	ruleSend(state, LDtk_Edit{op = .Rule_Set, file = "paint.ldtk", def = 3, field = 51, key = "chance", number = 0.6})
	testing.expect_value(t, state.level.problem, "")
	testing.expect_value(t, len(state.history.undo), 1)
	if len(state.history.undo) > 0 do testing.expect_value(t, state.history.undo[0].label, "Change a rule's chance in paint.ldtk")
	ruleSend(state, LDtk_Edit{op = .Rule_Set, file = "paint.ldtk", def = 3, field = 51, key = "flipY", flag = true})
	ruleSend(state, LDtk_Edit{op = .Rule_Added, file = "paint.ldtk", def = 3, index = 60})
	testing.expect_value(t, len(state.history.undo), 3)
	testing.expect(t, LDtkDoc_IsUnsaved(dir, "paint.ldtk"), "unsaved")
	for _ in 0 ..< 3 do ruleSend(state, Msg(Action.Undo))
	testing.expect(t, LDtkDoc_Main(LDtkDoc_Get(dir, "paint.ldtk")).text == before, "undone byte for byte")
	testing.expect(t, !LDtkDoc_IsUnsaved(dir, "paint.ldtk"), "nothing to save")
	ruleSend(state, Msg(Action.Redo))
	testing.expect_value(t, rulesValue(dir, "paint.ldtk", "defs.layers.uid=3.autoRuleGroups.uid=50.rules.uid=51.chance"), "0.6")
	// Nothing was written
	data, _ := os.read_entire_file(joinPath(dir, "paint.ldtk", allocator = context.temp_allocator), context.temp_allocator)
	testing.expect(t, string(data) == before, "the file waits for Save")
}

@(private="file")
ruleSend :: proc(state: ^State, m: Msg) {
	state^, _ = update(state^, m)
}

/*
The tab's own state (level_rules.odin): the editor opening on LDtk's smart-picked value, a new rule
opening its editor and a new group its name, LDtk's clipboard (copy, cut), the Assistant (a new
group named from its value, an existing one read back), Duplicate and Remap's values, the layer
picked (it's selected).
*/
@(test)
level_rules_tab_state :: proc(t: ^testing.T) {
	dir := rulesCopy(RULES_FIXTURE, "level_rules_tab")
	defer removeAll(dir)
	defer LDtkDoc_DestroyAll()
	defer LevelCanvas_Destroy()
	state := new(State)
	state^ = State{project = Project_CreateEmpty(dir, "Rules"), browserSelection = {kind = .None}, selectedNode = -1, layout = {bottomOpen = true}, settings = Settings_Default()}
	defer {
		State_Destroy(state)
		free(state)
	}
	state.settings.builtInCodeEditor = false
	state.mode = .Level
	state.level = {layout = LEVEL_LAYOUT_DEFAULT, bottomTab = .Auto_Layer_Rules, layerDef = 1, entityDef = -1, enumDef = -1, fieldDef = -1, levelField = -1, tilesetDef = -1, dataTile = -1, paint = {entityDef = -1}, rules = LEVEL_RULES_DEFAULT}
	append(&state.project.assets, AssetDef{path = strings.clone("paint.ldtk"), kind = .LDtk})
	doc := LDtkDoc_Get(dir, "paint.ldtk")
	// The Entities layer is selected: the tab shows the first layer that can have rules (Ground)
	uid, _ := LevelRules_Layer(state, doc)
	testing.expect_value(t, uid, 3)
	ruleSend(state, Rules_View{op = .Layer, uid = 4})
	testing.expect_value(t, state.level.layerDef, 4)
	uid, _ = LevelRules_Layer(state, doc)
	testing.expect_value(t, uid, 4)
	ruleSend(state, Rules_View{op = .Layer, uid = 3})
	// The editor: LDtk's smart pick (the value most used in the pattern)
	ruleSend(state, Rules_View{op = .Edit, uid = 51})
	testing.expect_value(t, state.level.rules.page, LevelRulesPage.Editor)
	testing.expect_value(t, state.level.rules.value, 1)
	testing.expect_value(t, state.level.rules.last, 51)
	ruleSend(state, Rules_View{op = .Edit, uid = 53})
	testing.expect_value(t, state.level.rules.value, 2000)
	ruleSend(state, Rules_View{op = .Close})
	testing.expect_value(t, state.level.rules.page, LevelRulesPage.List)
	// A new rule opens its editor (its group open), a new group its name
	ruleSend(state, LDtk_Edit{op = .Rule_Added, file = "paint.ldtk", def = 3, index = 60})
	testing.expect_value(t, state.level.rules.page, LevelRulesPage.Editor)
	testing.expect_value(t, state.level.rules.rule, 200)
	testing.expect(t, state.level.rules.open[60], "its group opens")
	// An empty rule: the source layer's first value
	testing.expect_value(t, state.level.rules.value, 1)
	ruleSend(state, LDtk_Edit{op = .Rule_Group_Added, file = "paint.ldtk", def = 3})
	testing.expect_value(t, state.level.rules.renaming, 201)
	// Removing the edited rule (an undo too) goes back to the list
	ruleSend(state, LDtk_Edit{op = .Rule_Removed, file = "paint.ldtk", def = 3, field = 200})
	testing.expect_value(t, state.level.rules.page, LevelRulesPage.List)
	// LDtk's clipboard: a rule copied, a group cut
	ruleSend(state, Rules_View{op = .Copy, uid = 50, number = 51})
	testing.expect_value(t, state.level.rules.clipKind, LevelRulesClip.Rule)
	testing.expect(t, strings.contains(state.level.rules.clip, `"uid":51`), state.level.rules.clip)
	ruleSend(state, LDtk_Edit{op = .Rule_Group_Removed, file = "paint.ldtk", def = 3, index = 60, key = "cut"})
	testing.expect_value(t, state.level.rules.clipKind, LevelRulesClip.Group)
	testing.expect(t, strings.contains(state.level.rules.clip, `"name":"Flowers"`), state.level.rules.clip)
	testing.expect_value(t, rulesValue(dir, "paint.ldtk", "defs.layers.uid=3.autoRuleGroups.uid=60"), "")
	// The Assistant: a new group named after its value, made, then read back to edit
	ruleSend(state, Rules_View{op = .Assistant, uid = -1})
	testing.expect_value(t, state.level.rules.page, LevelRulesPage.Assistant)
	ruleSend(state, Rules_View{op = .Assistant_Main, number = 2})
	testing.expect_value(t, state.level.rules.name, "stone")
	tiles := []int{4}
	ruleSend(state, Rules_View{op = .Assistant_Tiles, number = int(LDtkWallFragment.Full), ids = tiles})
	ruleSend(state, Rules_View{op = .Assistant_Stack, flag = true})
	testing.expect(t, !state.level.rules.assistant.breakOnMatch, "rules may stack")
	ruleSend(state, LDtk_Edit{op = .Rule_Group_Assistant, file = "paint.ldtk", def = 3, index = -1, text = state.level.rules.name, ids = LDtkAssistant_Encode(&state.level.rules.assistant)})
	testing.expect_value(t, state.level.problem, "")
	testing.expect_value(t, state.level.rules.page, LevelRulesPage.List)
	made := Json_Int(LDtkDoc_Main(LDtkDoc_Get(dir, "paint.ldtk")), Json_Path(LDtkDoc_Main(LDtkDoc_Get(dir, "paint.ldtk")), "defs.layers.uid=3.autoRuleGroups.0.uid"))
	ruleSend(state, Rules_View{op = .Assistant, uid = made})
	testing.expect_value(t, state.level.rules.assistant.main, 2)
	testing.expect_value(t, len(state.level.rules.assistant.tiles[.Full]), 1)
	testing.expect_value(t, state.level.rules.name, "stone")
	// Duplicate and Remap: every value Surface uses, unchanged at first
	ruleSend(state, Rules_View{op = .Remap, uid = 50})
	testing.expect_value(t, state.level.rules.page, LevelRulesPage.Remap)
	testing.expect_value(t, state.level.rules.name, "Surface copy")
	testing.expect_value(t, state.level.rules.remap[1], 1)
	testing.expect_value(t, state.level.rules.remap[2000], 2000)
	// 1, 2 (the wall's), 3 (the corner's), 4 and the Solid group (2000)
	testing.expect_value(t, len(state.level.rules.remap), 5)
	ruleSend(state, Rules_View{op = .Remap_Value, number = 1, uid = 3})
	testing.expect_value(t, state.level.rules.remap[1], 3)
	// None of it is undone
	steps := len(state.history.undo)
	ruleSend(state, Rules_View{op = .Help, flag = true})
	testing.expect_value(t, len(state.history.undo), steps)
}

/*
How long a rule edit takes on LDtk's biggest sample (WorldMap_GridVania_layout: 2.4 MB, 21 levels,
30 rules): the layer's groups written, the tidy, the rules applied again in every level. Best of
TIMING_RUNS; logged (CLAUDE.md has the numbers), with a generous limit.
*/
@(test)
ldtk_rule_edits_timing :: proc(t: ^testing.T) {
	defer LDtkDoc_DestroyAll()
	sample := "WorldMap_GridVania_layout.ldtk"
	// Kept past the temp memory each run frees
	dir := strings.clone(sampleCopy("ldtk_rules_timing", sample))
	defer delete(dir)
	if dir == "" {
		log.infof("LDtk's samples aren't here: skipped")
		return
	}
	defer removeAll(dir)
	doc := LDtkDoc_Get(dir, sample)
	main := LDtkDoc_Main(doc)
	uid, rule := -1, -1
	for d in Json_Items(main, LDtkDoc_Defs(doc, "layers")) do if uid < 0 {
		groups := LDtkRules_ReadGroups(main, d)
		if len(groups) > 0 && len(groups[0].rules) > 0 do uid, rule = Json_Int(main, Json_Get(main, d, "uid")), groups[0].rules[0].uid
	}
	if !testing.expect(t, uid >= 0, "the sample has rules") do return
	best := time.Duration(max(i64))
	for i in 0 ..< TIMING_RUNS {
		start := time.tick_now()
		problem := strings.clone(ruleApply(dir, sample, LDtk_Edit{op = .Rule_Set, def = uid, field = rule, key = "chance", number = i % 2 == 0 ? 0.5 : 1}), context.allocator)
		defer delete(problem)
		took := time.tick_since(start)
		testing.expect_value(t, problem, "")
		best = min(best, took)
		free_all(context.temp_allocator)
	}
	log.infof("a rule edit on %s (21 levels): %.1f ms", sample, time.duration_milliseconds(best))
	testing.expectf(t, time.duration_seconds(best) < 5, "a rule edit took %v", best)
}
