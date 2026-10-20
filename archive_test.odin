package crossfire_editor

import "core:os"
import "core:strings"
import "core:testing"

@(test)
zip_round_trip_and_safe_names :: proc(t: ^testing.T) {
	os.make_directory("build")
	dir := "build/test_zip"
	removeAll(dir)
	defer removeAll(dir)
	os.make_directory(dir)
	source := joinPath(dir, "source.bin", allocator = context.temp_allocator)
	payload := make([]byte, 70000, context.temp_allocator)
	for &b, i in payload do b = byte(i * 7)
	testing.expect(t, os.write_entire_file(source, payload) == nil)

	zip := joinPath(dir, "a.zip", allocator = context.temp_allocator)
	files := []ZipSource{
		{name = "Game/project.xml", data = transmute([]byte)string("<project/>")},
		{name = "Game/assets/big.bin", path = source},
		{name = "Game/empty.txt", hasData = true},
	}
	testing.expect_value(t, Zip_Write(zip, files), "")
	testing.expect(t, !os.exists(joinPath(dir, "a.zip.partial", allocator = context.temp_allocator)), "the partial file is renamed")

	data, err := os.read_entire_file(zip, context.temp_allocator)
	testing.expect(t, err == nil)
	entries, problem := Zip_List(data)
	testing.expect_value(t, problem, "")
	testing.expect_value(t, len(entries), 3)
	testing.expect_value(t, entries[1].name, "Game/assets/big.bin")
	big, readProblem := Zip_Read(data, entries[1])
	testing.expect_value(t, readProblem, "")
	testing.expect(t, string(big) == string(payload), "the file comes back as it was")
	text, _ := Zip_Read(data, entries[0])
	testing.expect_value(t, string(text), "<project/>")
	empty, emptyProblem := Zip_Read(data, entries[2])
	testing.expect_value(t, emptyProblem, "")
	testing.expect_value(t, len(empty), 0)

	// A damaged byte is caught by the checksum
	data[1000] ~= 0xFF
	_, damaged := Zip_Read(data, entries[1])
	testing.expect(t, damaged != "", "a changed byte fails the CRC")
	_, notZip := Zip_List(transmute([]byte)string("not a zip at all, just some text here"))
	testing.expect(t, notZip != "")

	// Made by Python's zipfile with deflate: other tools' zips open
	deflated, deflatedErr := os.read_entire_file("tests/fixtures/deflated.zip", context.temp_allocator)
	testing.expect(t, deflatedErr == nil)
	deflatedEntries, _ := Zip_List(deflated)
	testing.expect_value(t, len(deflatedEntries), 2)
	testing.expect_value(t, deflatedEntries[1].method, 8)
	notes, notesProblem := Zip_Read(deflated, deflatedEntries[1])
	testing.expect_value(t, notesProblem, "")
	testing.expect_value(t, len(notes), len("hello deflate ") * 50)
	testing.expect(t, strings.has_prefix(string(notes), "hello deflate hello"))

	testing.expect(t, Zip_SafeName("Game/assets/ship.png"))
	testing.expect(t, !Zip_SafeName("../evil.txt"))
	testing.expect(t, !Zip_SafeName("Game/../../evil.txt"))
	testing.expect(t, !Zip_SafeName("/etc/passwd"))
	testing.expect(t, !Zip_SafeName("C:/Windows/evil.dll"))
	testing.expect(t, !Zip_SafeName("Game\\..\\evil.txt"))
	free_all(context.temp_allocator)
}

@(test)
project_archive_brings_outside_assets_in :: proc(t: ^testing.T) {
	os.make_directory("build")
	dir := "build/test_archive"
	removeAll(dir)
	defer removeAll(dir)
	os.make_directory(dir)
	outside := joinPath(dir, "outside", allocator = context.temp_allocator)
	os.make_directory(outside)
	ship, _ := os.read_entire_file("tests/fixtures/ui_project/assets/ship.png", context.temp_allocator)
	_ = os.write_entire_file(joinPath(outside, "ship.png", allocator = context.temp_allocator), ship)

	// A project with an asset outside its folder, an exported game, a .git folder
	root := joinPath(dir, "Game", allocator = context.temp_allocator)
	project := Project_CreateEmpty(root, "My Game")
	defer Project_Destroy(&project)
	append(&project.assets, AssetDef{strings.clone("../outside/ship.png"), .Image})
	scene := &project.scenes[0]
	sprite := Scene_InsertNode(scene, "Ship", .Sprite, 0)
	scene.nodes[sprite].texture = strings.clone("../outside/ship.png")
	testing.expect_value(t, Project_Save(&project), "")
	_ = os.make_directory_all(joinPath(root, "export/linux_x64", allocator = context.temp_allocator))
	_ = os.write_entire_file(joinPath(root, "export/linux_x64/Game", allocator = context.temp_allocator), transmute([]byte)string("an exported game"))
	_ = os.make_directory_all(joinPath(root, ".git", allocator = context.temp_allocator))
	_ = os.write_entire_file(joinPath(root, ".git/HEAD", allocator = context.temp_allocator), transmute([]byte)string("ref: refs/heads/main"))
	_ = os.write_entire_file(joinPath(root, "notes.txt", allocator = context.temp_allocator), transmute([]byte)string("kept"))

	archive := joinPath(dir, "My Game.odinsdl", allocator = context.temp_allocator)
	result := ProjectArchive_Create({root = root, folder = "Game", archive = archive, assets = {"../outside/ship.png"}})
	testing.expect_value(t, result.problem, "")
	testing.expect_value(t, result.external, 1)

	data, _ := os.read_entire_file(archive, context.temp_allocator)
	entries, _ := Zip_List(data)
	names := make([dynamic]string, context.temp_allocator)
	for entry in entries do append(&names, entry.name)
	joined := strings.join(names[:], ",", context.temp_allocator)
	testing.expect(t, strings.contains(joined, "Game/project.xml"), joined)
	testing.expect(t, strings.contains(joined, "Game/notes.txt"), joined)
	testing.expect(t, strings.contains(joined, "Game/assets/external/ship.png"), joined)
	testing.expect(t, !strings.contains(joined, "export/"), "exported games are left out")
	testing.expect(t, !strings.contains(joined, ".git"), ".git is left out")

	// Unpacked, it opens with the asset inside it; the project on disk wasn't changed
	unpackTo := joinPath(dir, "unpacked", allocator = context.temp_allocator)
	os.make_directory(unpackTo)
	unpacked, files, problem := ProjectArchive_Extract(archive, unpackTo)
	testing.expect_value(t, problem, "")
	testing.expect_value(t, files, result.files)
	testing.expect(t, strings.has_suffix(unpacked, "Game"), unpacked)
	opened, message, _ := Project_Load(unpacked)
	defer Project_Destroy(&opened)
	testing.expect_value(t, message, "")
	testing.expect_value(t, opened.name, "My Game")
	testing.expect_value(t, opened.assets[0].path, "assets/external/ship.png")
	testing.expect_value(t, opened.scenes[0].nodes[sprite].texture, "assets/external/ship.png")
	testing.expect(t, os.exists(joinPath(unpacked, "assets/external/ship.png", allocator = context.temp_allocator)))
	original, _ := os.read_entire_file(joinPath(root, "project.xml", allocator = context.temp_allocator), context.temp_allocator)
	testing.expect(t, strings.contains(string(original), "../outside/ship.png"), "the project itself keeps its paths")

	// With its history: .git goes in too (exports still don't)
	withGit := joinPath(dir, "With Git.odinsdl", allocator = context.temp_allocator)
	gitResult := ProjectArchive_Create({root = root, folder = "Game", archive = withGit, assets = {"../outside/ship.png"}, includeGit = true})
	testing.expect_value(t, gitResult.problem, "")
	gitData, _ := os.read_entire_file(withGit, context.temp_allocator)
	gitEntries, _ := Zip_List(gitData)
	gitNames := make([dynamic]string, context.temp_allocator)
	for entry in gitEntries do append(&gitNames, entry.name)
	gitJoined := strings.join(gitNames[:], ",", context.temp_allocator)
	testing.expect(t, strings.contains(gitJoined, "Game/.git/HEAD"), gitJoined)
	testing.expect(t, !strings.contains(gitJoined, "export/"), "exported games are still left out")

	// Given on the command line: unpacked next to the archive (Game exists there: Game_2... here
	// the folder beside it is free)
	testing.expect(t, ProjectArchive_IsArchivePath("x/My Game.ODINSDL") && ProjectArchive_IsArchivePath("a.zip") && !ProjectArchive_IsArchivePath("Game"), "archive paths")
	beside, besideProblem := ProjectArchive_ExtractArgument(withGit)
	testing.expect_value(t, besideProblem, "")
	testing.expect(t, strings.has_prefix(beside, absolutePath(dir)) && os.exists(joinPath(beside, ".git/HEAD", allocator = context.temp_allocator)), beside)

	// Unpacking again doesn't overwrite: Game_2
	again, _, againProblem := ProjectArchive_Extract(archive, unpackTo)
	testing.expect_value(t, againProblem, "")
	testing.expect(t, strings.has_suffix(again, "Game_2"), again)

	// An archive with a name outside its folder is refused, and writes nothing
	evil := joinPath(dir, "evil.zip", allocator = context.temp_allocator)
	_ = Zip_Write(evil, {{name = "project.xml", data = transmute([]byte)string("<project/>")}, {name = "../escaped.txt", data = transmute([]byte)string("x")}})
	_, _, evilProblem := ProjectArchive_Extract(evil, unpackTo)
	testing.expect(t, evilProblem != "", "zip slip is refused")
	testing.expect(t, !os.exists(joinPath(dir, "escaped.txt", allocator = context.temp_allocator)))

	// A zip without a project
	empty := joinPath(dir, "empty.zip", allocator = context.temp_allocator)
	_ = Zip_Write(empty, {{name = "readme.txt", data = transmute([]byte)string("x")}})
	_, _, emptyProblem := ProjectArchive_Extract(empty, unpackTo)
	testing.expect(t, strings.contains(emptyProblem, "no project"), emptyProblem)
	free_all(context.temp_allocator)
}
