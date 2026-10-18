// edctl — command-line client for the editor's remote control hook
// (package `control`). Sends commands to a running editor_demo started
// with `--control <port>` and prints one reply per command.
//
// Usage:
//   edctl [--port N] [--retry SECONDS] [-q] "<command>" ["<command>" ...]
//   edctl [--port N] [--retry SECONDS] [-q] < script.txt
//
// With no command arguments, commands are read from stdin (one per line;
// blank lines and lines starting with '#' are skipped). Exit status is 0
// if every reply starts with "ok" (or is JSON from `state`), 1 if any
// command failed (`err`/`fail`/`timeout`), 2 if the editor couldn't be
// reached. With -q only failing commands and a summary are printed.
package main

import "core:fmt"
import "core:net"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"

DEFAULT_PORT :: 7777

main :: proc() {
	port := DEFAULT_PORT
	retry_seconds := 0.0
	quiet := false
	commands := make([dynamic]string)

	args := os.args[1:]
	for i := 0; i < len(args); i += 1 {
		switch args[i] {
		case "--port":
			i += 1
			if i < len(args) {
				port, _ = strconv.parse_int(args[i])
			}
		case "--retry":
			i += 1
			if i < len(args) {
				retry_seconds, _ = strconv.parse_f64(args[i])
			}
		case "-q":
			quiet = true
		case:
			append(&commands, args[i])
		}
	}

	if len(commands) == 0 {
		data, err := os.read_entire_file(os.stdin, context.allocator)
		if err != nil {
			fmt.eprintln("edctl: cannot read stdin:", err)
			os.exit(2)
		}
		text := string(data)
		for line in strings.split_lines_iterator(&text) {
			append(&commands, line)
		}
	}

	// Drop blank lines/comments locally: the server sends no reply for
	// them, and we count replies to know when we're done. Commands are
	// otherwise sent verbatim — trailing spaces in `type`/`text` payloads
	// are meaningful.
	to_send := make([dynamic]string)
	for c in commands {
		t := strings.trim_space(c)
		if len(t) > 0 && t[0] != '#' {
			append(&to_send, strings.trim_right(c, "\r\n"))
		}
	}
	if len(to_send) == 0 {
		return
	}

	ep := net.Endpoint{address = net.IP4_Loopback, port = port}
	sock: net.TCP_Socket
	deadline := time.tick_now()
	for {
		s, err := net.dial_tcp(ep)
		if err == nil {
			sock = s
			break
		}
		if time.duration_seconds(time.tick_since(deadline)) >= retry_seconds {
			fmt.eprintfln("edctl: cannot connect to 127.0.0.1:%d: %v", port, err)
			os.exit(2)
		}
		time.sleep(100 * time.Millisecond)
	}

	failed := 0
	pending := make([dynamic]u8)
	for cmd in to_send {
		line := strings.concatenate({cmd, "\n"})
		if _, err := net.send_tcp(sock, transmute([]u8)line); err != nil {
			fmt.eprintln("edctl: send failed:", err)
			os.exit(2)
		}
		reply, ok := read_line(sock, &pending)
		if !ok {
			fmt.eprintln("edctl: connection closed before reply to:", cmd)
			os.exit(2)
		}
		bad := !(strings.has_prefix(reply, "ok") || strings.has_prefix(reply, "{"))
		if bad {
			failed += 1
		}
		if !quiet || bad {
			fmt.printfln("> %s", cmd)
			fmt.println(reply)
		}
	}
	net.close(sock)
	if quiet {
		fmt.printfln("edctl: %d/%d commands ok", len(to_send) - failed, len(to_send))
	}
	os.exit(failed > 0 ? 1 : 0)
}

// read_line blocks until one full '\n'-terminated reply has arrived.
read_line :: proc(sock: net.TCP_Socket, pending: ^[dynamic]u8) -> (string, bool) {
	for {
		for b, i in pending {
			if b == '\n' {
				line := strings.clone(string(pending[:i]))
				remove_range(pending, 0, i + 1)
				return line, true
			}
		}
		chunk: [8192]u8
		n, err := net.recv_tcp(sock, chunk[:])
		if err != nil || n == 0 {
			return "", false
		}
		append(pending, ..chunk[:n])
	}
}

remove_range :: proc(b: ^[dynamic]u8, lo, hi: int) {
	copy(b[lo:], b[hi:])
	resize(b, len(b) - (hi - lo))
}
