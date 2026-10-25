package crossfire_editor

import "core:fmt"
import "core:log"
import "core:os"
import "core:slice"
import "core:strings"
import "core:testing"

// LDtk's auto-layer rules (ldtk_rules.odin) and its JSON writer (ldtk_json_pretty.odin) against
// files LDtk saved itself

// LDtk's samples, saved by LDtk 1.5.3 (when the workspace has LDtk's source)
@(private="file")
LDTK_SAMPLES :: "../ldtk/app/extraFiles/samples"

// Where two texts first differ, with some context (temp)
@(private="file")
firstDifference :: proc(a, b: string) -> string {
	i := 0
	for i < len(a) && i < len(b) && a[i] == b[i] do i += 1
	from := max(0, i - 80)
	return fmt.tprintf("at byte %d of %d / %d:\n  ours:   %q\n  theirs: %q", i, len(a), len(b), a[from:min(len(a), i + 80)], b[from:min(len(b), i + 80)])
}

/*
Every auto layer of every level of LDtk's samples: the tiles the file has, written again, are the
file's text (the writer); then cleared and made again from the rules, they're still the file's
text (the rules, with LDtk's randomness and Perlin masks).
*/
@(test)
ldtk_rules_match_ldtk_samples :: proc(t: ^testing.T) {
	defer LDtkDoc_DestroyAll()
	entries, err := os.read_all_directory_by_path(LDTK_SAMPLES, context.allocator)
	defer os.file_info_slice_delete(entries, context.allocator)
	if err != nil {
		log.infof("LDtk's samples aren't here (%s): skipped", LDTK_SAMPLES)
		return
	}
	layers, tiles := 0, 0
	for entry in entries {
		if !strings.has_suffix(entry.name, ".ldtk") do continue
		doc := LDtkDoc_Get(LDTK_SAMPLES, entry.name)
		if !testing.expectf(t, doc != nil && doc.problem == "", "%s reads", entry.name) do continue
		for _, level in doc.levels {
			m, ok := LDtkLevel_Read(doc, entry.name, level)
			if !testing.expectf(t, ok, "%s level %d decodes", entry.name, level) do continue
			defer LDtkLevel_Destroy(&m)
			file, array := LDtkDoc_LayerInstances(doc, level)
			json := LDtkDoc_Json(doc, file)
			for &l in m.layers {
				d := &m.defs[l.def]
				if !LDtkLayerInfo_IsAuto(d) do continue
				li := -1
				for item in Json_Items(json, array) do if Json_String(json, Json_Get(json, item, "iid")) == l.iid do li = item
				node := Json_Get(json, li, "autoLayerTiles")
				theirs := Json_Text(json, node)
				indent := LDtk_IndentAt(json.text, int(json.nodes[node].start))
				written := LDtk_PrettyJson(LDtkLayer_AutoTilesJson(&m, &l), m.minified, indent)
				testing.expectf(t, written == theirs, "%s %s %s: the file's tiles written again are its text, %s", entry.name, m.identifier, d.identifier, firstDifference(written, theirs))
				// The fast writer (what painting commits) writes the same
				fast := LDtkLayer_AutoTilesText(&m, &l, m.minified, indent)
				testing.expectf(t, fast == theirs, "%s %s %s: the text writer, %s", entry.name, m.identifier, d.identifier, firstDifference(fast, theirs))
				LDtkRules_ApplyAll(&m, &l)
				made := LDtk_PrettyJson(LDtkLayer_AutoTilesJson(&m, &l), m.minified, indent)
				testing.expectf(t, made == theirs, "%s %s %s: the rules make the file's tiles, %s", entry.name, m.identifier, d.identifier, firstDifference(made, theirs))
				layers += 1
				tiles += Json_Count(json, node)
			}
			// Every layer's IntGrid and tiles, written again by the text writers: the file's text
			for &l in m.layers {
				li := -1
				for item in Json_Items(json, array) do if Json_String(json, Json_Get(json, item, "iid")) == l.iid do li = item
				for key in ([]string{"intGridCsv", "gridTiles"}) {
					node := Json_Get(json, li, key)
					if node < 0 do continue
					indent := LDtk_IndentAt(json.text, int(json.nodes[node].start))
					theirs := Json_Text(json, node)
					switch m.defs[l.def].kind {
					case .IntGrid:
						if key != "intGridCsv" do continue
						ours := LDtkLayer_IntGridText(&l, m.minified, indent)
						testing.expectf(t, ours == theirs, "%s %s %s: intGridCsv, %s", entry.name, m.identifier, m.defs[l.def].identifier, firstDifference(ours, theirs))
					case .Tiles:
						if key != "gridTiles" do continue
						ours := LDtkLayer_GridTilesText(&m, &l, m.minified, indent)
						testing.expectf(t, ours == theirs, "%s %s %s: gridTiles, %s", entry.name, m.identifier, m.defs[l.def].identifier, firstDifference(ours, theirs))
					case .Entities, .AutoLayer:
					}
				}
			}
		}
		free_all(context.temp_allocator)
	}
	log.infof("%d auto layers of LDtk's samples, %d tiles, made as LDtk made them", layers, tiles)
}

// Numbers as JavaScript writes them, and JsonPretty's layouts
@(test)
ldtk_json_pretty_writes_as_ldtk :: proc(t: ^testing.T) {
	testing.expect_value(t, LDtk_JsNumber(0.35), "0.35")
	testing.expect_value(t, LDtk_JsNumber(1e-7), "1e-7")
	testing.expect_value(t, LDtk_JsNumber(123456789.125), "123456789.125")
	testing.expect_value(t, LDtk_JsNumber(1e21), "1e+21")
	testing.expect_value(t, LDtk_JsNumber(-0.5), "-0.5")
	testing.expect_value(t, LDtk_JsNumber(100), "100")
	k := f64(2.12)
	g := f64(0.396055)
	testing.expect_value(t, LDtk_JsNumber(g * k), "0.8396366000000001")
	// A number grid: 35 a line, a tab deeper
	grid := make([]LDtkJV, 40, context.temp_allocator)
	for &v in grid do v = i64(0)
	small := LDtk_PrettyJson(LDtkJArray(grid), false, 1)
	testing.expect_value(t, small, "[0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0]")
	big := make([]LDtkJV, 90, context.temp_allocator)
	for &v in big do v = i64(1)
	text := LDtk_PrettyJson(LDtkJArray(big), false, 2)
	lines := strings.split(text, "\n", context.temp_allocator)
	testing.expect_value(t, len(lines), 5)
	testing.expect_value(t, lines[0], "[")
	testing.expect(t, strings.has_prefix(lines[1], "\t\t\t1,1,"), "rows a tab deeper")
	testing.expect_value(t, lines[4], "\t\t]")
	// 50 to 85 numbers: an item per line (JsonPretty's estimate)
	mid := make([]LDtkJV, 60, context.temp_allocator)
	for &v in mid do v = i64(2)
	testing.expect_value(t, len(strings.split(LDtk_PrettyJson(LDtkJArray(mid), false, 0), "\n", context.temp_allocator)), 62)
	// One small object on a line, an array of one without spaces
	pair := []LDtkJPair{{"a", i64(1)}, {"b", "x"}}
	one := []LDtkJV{LDtkJObject(pair)}
	testing.expect_value(t, LDtk_PrettyJson(LDtkJArray(one), false, 0), `[{ "a": 1, "b": "x" }]`)
	testing.expect_value(t, LDtk_PrettyJson(LDtkJArray(one), true, 0), `[{"a":1,"b":"x"}]`)
	// Strings: line breaks escaped (LDtk's escapeString), tabs spaces, quotes escaped; a float-hinted string becomes a number
	testing.expect_value(t, LDtk_PrettyJson("a\nb\"c\td", false), `"a\nb\"c d"`)
	testing.expect_value(t, LDtk_PrettyJson("5f", false), "5.0")
}

// The demo's levels (generated LDtk-style by tools/demo/make_demo.py, written by Python with its
// own key order and number forms, and random tiles picked by Python's `random.choice`, not LDtk's
// seeded hash): the rules match the same cells with the same flips and alphas, each tile one of
// its rule's choices
@(test)
ldtk_rules_match_the_demo :: proc(t: ^testing.T) {
	defer LDtkDoc_DestroyAll()
	folder := "examples/demo_project/assets/levels"
	doc := LDtkDoc_Get(folder, "legacy.ldtk")
	if !testing.expect(t, doc != nil && doc.problem == "", "the demo reads") do return
	// A layer's tiles as sorted lines, without which of the rule's tiles it is (temp)
	tileSet :: proc(m: ^LDtkLevelModel, l: ^LDtkLayerData) -> []string {
		out := make([dynamic]string, context.temp_allocator)
		for cell, coord in l.auto do for a in cell do append(&out, fmt.tprintf("%d %d %d %d %d %v", a.rule, coord, a.x, a.y, a.flips, a.alpha))
		slice.sort(out[:])
		return out[:]
	}
	for _, level in doc.levels {
		m, ok := LDtkLevel_Read(doc, "legacy.ldtk", level)
		if !testing.expect(t, ok) do continue
		defer LDtkLevel_Destroy(&m)
		for &l in m.layers {
			d := &m.defs[l.def]
			if !LDtkLayerInfo_IsAuto(d) do continue
			theirs := tileSet(&m, &l)
			LDtkRules_ApplyAll(&m, &l)
			made := tileSet(&m, &l)
			first := ""
			for v, i in made do if i >= len(theirs) || v != theirs[i] {
				first = fmt.tprintf("%s vs %s", v, i < len(theirs) ? theirs[i] : "none")
				break
			}
			testing.expectf(t, len(made) == len(theirs) && first == "", "%s %s: the rules match the file's %d tiles (made %d; %s)", m.identifier, d.identifier, len(theirs), len(made), first)
			// Each tile is one of its rule's
			for cell in l.auto do for a in cell {
				found := false
				for &g in d.groups do for &r in g.rules do if r.uid == int(a.rule) do for ids in r.tileRectsIds do for id in ids do if id == int(a.tile) do found = true
				if !testing.expectf(t, found, "%s %s: tile %d is one of rule %d's", m.identifier, d.identifier, a.tile, a.rule) do return
			}
		}
	}
}
