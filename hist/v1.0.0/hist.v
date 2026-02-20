// hist — terminal output history plugin for vlsh.
//
// Copy this file to ~/.vlsh/plugins/hist.v
// vlsh will compile it automatically on the next start (requires `v` in PATH).
//
// Uses tmux capture-pane to snapshot the last 5000 lines of terminal output
// after every command, storing them in ~/.vlsh/hist_output.txt.
//
// Usage:
//   hist        — print the path to the history file
//   hist ed     — open a copy of the history file in $EDITOR

module main

import os

const max_lines = 5000

fn hist_path() string {
	return os.join_path(os.home_dir(), '.vlsh', 'hist_output.txt')
}

fn capture_and_save() {
	if os.getenv('TMUX') == '' {
		return // not inside a tmux session
	}
	result := os.execute('tmux capture-pane -p -S -${max_lines}')
	if result.exit_code != 0 {
		return
	}
	path := hist_path()
	os.mkdir_all(os.dir(path)) or {}
	os.write_file(path, result.output) or {}
}

fn main() {
	op := if os.args.len > 1 { os.args[1] } else { '' }

	match op {
		'capabilities' {
			println('command hist')
			println('post_hook')
		}
		'run' {
			cmd := if os.args.len > 2 { os.args[2] } else { '' }
			match cmd {
				'hist' {
					sub := if os.args.len > 3 { os.args[3] } else { '' }
					match sub {
						'' {
							println(hist_path())
						}
						'ed' {
							path := hist_path()
							if !os.exists(path) {
								eprintln('hist: no history captured yet — run a command first')
								exit(1)
							}
							editor := os.getenv('EDITOR')
							if editor == '' {
								eprintln('hist: $EDITOR is not set')
								exit(1)
							}
							content := os.read_file(path) or {
								eprintln('hist: could not read history file: ${err}')
								exit(1)
							}
							tmp := os.join_path(os.temp_dir(), 'vlsh_hist_view.txt')
							os.write_file(tmp, content) or {
								eprintln('hist: could not write temp file: ${err}')
								exit(1)
							}
							os.system('${editor} "${tmp}"')
						}
						else {
							eprintln('usage: hist [ed]')
							exit(1)
						}
					}
				}
				else {}
			}
		}
		'post_hook' {
			capture_and_save()
		}
		else {}
	}
}
