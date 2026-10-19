package editor

import "core:bytes"
import "core:compress/zlib"
import "core:encoding/endian"
import "core:fmt"
import "core:hash"
import "core:os"
import "core:strings"
import "core:time"

/*
Zip files, for project archives (project_archive.odin).

Writing stores files as they are (method 0, no compression): a project is mostly images and
sounds, already compressed, and Odin's core library has no deflate encoder. Reading takes stored
and deflated files (method 8, `core:compress/zlib`), so zips made by other tools open too. No
zip64: an archive holds at most 65535 files and 4 GB.

Layout (little-endian): per file a local header, its name and its bytes; then the central
directory (a header per file, with where its local header is); then the end record.

Example:
	files := []ZipSource{{name = "MyGame/project.xml", path = "my_game/project.xml"}}
	problem := Zip_Write("MyGame.odinsdl", files)
*/

// A file to put in a zip
ZipSource :: struct {
	// Its path in the zip, "/"-separated
	name: string,
	// Read from this file, unless `data` is given
	path: string,
	data: []byte,
	// Use `data` even when it's empty
	hasData: bool,
}

// A file in a zip (Zip_List)
ZipEntry :: struct {
	// Its path, "/"-separated; a folder's ends in "/"
	name: string,
	method: u16,
	crc: u32,
	compressedSize, size: u32,
	// Where its local header is
	headerOffset: u32,
}

@(private="file")
ZIP_LOCAL_SIGNATURE :: 0x04034b50
@(private="file")
ZIP_CENTRAL_SIGNATURE :: 0x02014b50
@(private="file")
ZIP_END_SIGNATURE :: 0x06054b50
// Version 2.0, the one store and deflate need; "made by" Unix (3), so permissions are read
@(private="file")
ZIP_VERSION :: 20
@(private="file")
ZIP_MADE_BY :: 3 << 8 | ZIP_VERSION
// Bit 11: names are UTF-8
@(private="file")
ZIP_UTF8 :: 1 << 11

/*
Writes a zip of files (stored, not compressed).

Inputs:
- path: The zip to write (replaced; written to a temporary file next to it, renamed when done)
- files: What goes in it

Returns:
- "" or what went wrong (temp allocated)
*/
Zip_Write :: proc(path: string, files: []ZipSource) -> string {
	if len(files) > 0xFFFF do return fmt.tprintf("too many files for a zip (%d, at most 65535)", len(files))
	partial := fmt.tprintf("%s.partial", path)
	out, err := os.create(partial)
	if err != nil do return fmt.tprintf("can't write %s: %v", partial, err)
	ok := false
	defer if !ok {
		os.close(out)
		os.remove(partial)
	}

	central := bytes.Buffer{}
	bytes.buffer_init_allocator(&central, 0, 4096, context.temp_allocator)
	at: u64 = 0
	dosTime, dosDate := dosDateTime(time.now())
	for file in files {
		data := file.data
		if !file.hasData && file.data == nil {
			read, readErr := os.read_entire_file(file.path, context.temp_allocator)
			if readErr != nil do return fmt.tprintf("can't read %s: %v", file.path, readErr)
			data = read
		}
		if u64(len(data)) >= 0xFFFFFFFF || at + u64(len(data)) + 30 + u64(len(file.name)) >= 0xFFFFFFFF {
			return "the archive would be over 4 GB, more than a zip holds"
		}
		crc := hash.crc32(data)
		header: [30]byte
		endian.put_u32(header[0:4], .Little, ZIP_LOCAL_SIGNATURE)
		endian.put_u16(header[4:6], .Little, ZIP_VERSION)
		endian.put_u16(header[6:8], .Little, ZIP_UTF8)
		endian.put_u16(header[8:10], .Little, 0)
		endian.put_u16(header[10:12], .Little, dosTime)
		endian.put_u16(header[12:14], .Little, dosDate)
		endian.put_u32(header[14:18], .Little, crc)
		endian.put_u32(header[18:22], .Little, u32(len(data)))
		endian.put_u32(header[22:26], .Little, u32(len(data)))
		endian.put_u16(header[26:28], .Little, u16(len(file.name)))
		endian.put_u16(header[28:30], .Little, 0)
		if !writeAll(out, header[:]) || !writeAll(out, transmute([]byte)file.name) || !writeAll(out, data) {
			return fmt.tprintf("can't write %s", partial)
		}

		entry: [46]byte
		endian.put_u32(entry[0:4], .Little, ZIP_CENTRAL_SIGNATURE)
		endian.put_u16(entry[4:6], .Little, ZIP_MADE_BY)
		endian.put_u16(entry[6:8], .Little, ZIP_VERSION)
		endian.put_u16(entry[8:10], .Little, ZIP_UTF8)
		endian.put_u16(entry[10:12], .Little, 0)
		endian.put_u16(entry[12:14], .Little, dosTime)
		endian.put_u16(entry[14:16], .Little, dosDate)
		endian.put_u32(entry[16:20], .Little, crc)
		endian.put_u32(entry[20:24], .Little, u32(len(data)))
		endian.put_u32(entry[24:28], .Little, u32(len(data)))
		endian.put_u16(entry[28:30], .Little, u16(len(file.name)))
		// Extra field, comment, disk: 0. Internal attributes 0; external: rw-r--r-- (Unix, high 16 bits)
		endian.put_u32(entry[38:42], .Little, u32(0o100644) << 16)
		endian.put_u32(entry[42:46], .Little, u32(at))
		bytes.buffer_write(&central, entry[:])
		bytes.buffer_write_string(&central, file.name)
		at += 30 + u64(len(file.name)) + u64(len(data))
	}

	centralBytes := bytes.buffer_to_bytes(&central)
	end: [22]byte
	endian.put_u32(end[0:4], .Little, ZIP_END_SIGNATURE)
	endian.put_u16(end[8:10], .Little, u16(len(files)))
	endian.put_u16(end[10:12], .Little, u16(len(files)))
	endian.put_u32(end[12:16], .Little, u32(len(centralBytes)))
	endian.put_u32(end[16:20], .Little, u32(at))
	if !writeAll(out, centralBytes) || !writeAll(out, end[:]) do return fmt.tprintf("can't write %s", partial)
	os.close(out)
	ok = true
	if renameErr := os.rename(partial, path); renameErr != nil {
		os.remove(partial)
		return fmt.tprintf("can't write %s: %v", path, renameErr)
	}
	return ""
}

/*
The files in a zip, from its central directory.

Inputs:
- data: The whole zip

Returns:
- Its entries (names point into `data`; the slice is temp allocated), or what's wrong with it
*/
Zip_List :: proc(data: []byte) -> ([]ZipEntry, string) {
	// The end record is the last 22 bytes, unless the zip has a comment (up to 64 KB)
	endAt := -1
	for i := len(data) - 22; i >= 0 && i >= len(data) - 22 - 0xFFFF; i -= 1 {
		if signature, _ := endian.get_u32(data[i:i + 4], .Little); signature == ZIP_END_SIGNATURE {
			endAt = i
			break
		}
	}
	if endAt < 0 do return nil, "not a zip file"
	count, _ := endian.get_u16(data[endAt + 10:endAt + 12], .Little)
	centralSize, _ := endian.get_u32(data[endAt + 12:endAt + 16], .Little)
	centralAt, _ := endian.get_u32(data[endAt + 16:endAt + 20], .Little)
	if count == 0xFFFF || centralAt == 0xFFFFFFFF do return nil, "zip64 archives aren't supported"
	if int(centralAt) + int(centralSize) > len(data) do return nil, "the zip is damaged (its directory is past its end)"

	entries := make([dynamic]ZipEntry, 0, int(count), context.temp_allocator)
	at := int(centralAt)
	for _ in 0 ..< int(count) {
		if at + 46 > len(data) do return nil, "the zip is damaged (its directory is cut short)"
		if signature, _ := endian.get_u32(data[at:at + 4], .Little); signature != ZIP_CENTRAL_SIGNATURE {
			return nil, "the zip is damaged (a bad directory entry)"
		}
		flags, _ := endian.get_u16(data[at + 8:at + 10], .Little)
		if flags & 1 != 0 do return nil, "encrypted zips aren't supported"
		entry: ZipEntry
		entry.method, _ = endian.get_u16(data[at + 10:at + 12], .Little)
		entry.crc, _ = endian.get_u32(data[at + 16:at + 20], .Little)
		entry.compressedSize, _ = endian.get_u32(data[at + 20:at + 24], .Little)
		entry.size, _ = endian.get_u32(data[at + 24:at + 28], .Little)
		nameLength, _ := endian.get_u16(data[at + 28:at + 30], .Little)
		extraLength, _ := endian.get_u16(data[at + 30:at + 32], .Little)
		commentLength, _ := endian.get_u16(data[at + 32:at + 34], .Little)
		entry.headerOffset, _ = endian.get_u32(data[at + 42:at + 46], .Little)
		if at + 46 + int(nameLength) > len(data) do return nil, "the zip is damaged (a name is cut short)"
		entry.name = string(data[at + 46:at + 46 + int(nameLength)])
		append(&entries, entry)
		at += 46 + int(nameLength) + int(extraLength) + int(commentLength)
	}
	return entries[:], ""
}

/*
A file's bytes from a zip (stored or deflated), checked against its CRC.

Inputs:
- data: The whole zip
- entry: One of Zip_List's entries

Returns:
- The bytes (stored: a slice of `data`; deflated: allocated with `allocator`), or what went wrong
*/
Zip_Read :: proc(data: []byte, entry: ZipEntry, allocator := context.temp_allocator) -> ([]byte, string) {
	at := int(entry.headerOffset)
	if at + 30 > len(data) do return nil, fmt.tprintf("%s: the zip is damaged", entry.name)
	if signature, _ := endian.get_u32(data[at:at + 4], .Little); signature != ZIP_LOCAL_SIGNATURE {
		return nil, fmt.tprintf("%s: the zip is damaged (a bad file header)", entry.name)
	}
	nameLength, _ := endian.get_u16(data[at + 26:at + 28], .Little)
	extraLength, _ := endian.get_u16(data[at + 28:at + 30], .Little)
	start := at + 30 + int(nameLength) + int(extraLength)
	if start + int(entry.compressedSize) > len(data) do return nil, fmt.tprintf("%s: the zip is cut short", entry.name)
	stored := data[start:start + int(entry.compressedSize)]
	result: []byte
	switch entry.method {
	case 0:
		result = stored
	case 8:
		buffer: bytes.Buffer
		bytes.buffer_init_allocator(&buffer, 0, int(entry.size), allocator)
		if err := zlib.inflate_from_byte_array_raw(stored, &buffer, expected_output_size = int(entry.size)); err != nil {
			return nil, fmt.tprintf("%s: can't decompress it (%v)", entry.name, err)
		}
		result = bytes.buffer_to_bytes(&buffer)
	case:
		return nil, fmt.tprintf("%s: compression method %d isn't supported (only stored and deflated)", entry.name, entry.method)
	}
	if len(result) != int(entry.size) || hash.crc32(result) != entry.crc {
		return nil, fmt.tprintf("%s: the zip is damaged (its checksum doesn't match)", entry.name)
	}
	return result, ""
}

/*
Whether a zip entry's name is safe to unpack: relative, no "..", no drive letters or backslashes
(a "zip slip" would write outside the folder it's unpacked into).
*/
Zip_SafeName :: proc(name: string) -> bool {
	if name == "" || strings.has_prefix(name, "/") || strings.contains_rune(name, '\\') || strings.contains_rune(name, ':') do return false
	for part in strings.split(name, "/", context.temp_allocator) {
		if part == ".." do return false
	}
	return true
}

// MS-DOS time and date (what zips store): local time, 2-second steps, years from 1980
@(private="file")
dosDateTime :: proc(t: time.Time) -> (dosTime, dosDate: u16) {
	year, month, day := time.date(t)
	hour, minute, second := time.clock(t)
	if year < 1980 do return 0, 1 << 5 | 1
	dosTime = u16(hour) << 11 | u16(minute) << 5 | u16(second / 2)
	dosDate = u16(year - 1980) << 9 | u16(month) << 5 | u16(day)
	return
}

@(private="file")
writeAll :: proc(out: ^os.File, data: []byte) -> bool {
	n, err := os.write(out, data)
	return err == nil && n == len(data)
}
