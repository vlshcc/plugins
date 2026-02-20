// hist — vlsh plugin that keeps a rolling 5000-line terminal output history.
//
// Install:
//   mkdir -p ~/.vlsh/plugins/hist/v1.0.0
//   cp hist.v ~/.vlsh/plugins/hist/v1.0.0/hist.v
//   Then inside vlsh: plugins reload
//
// Two-hook design:
//   output_hook fires first (for ls, echo, and external commands) and saves
//   any captured output to a temp buffer file.
//   post_hook fires after every command unconditionally. It writes
//   "$ cmdline" plus the buffered output (if any) to the history file,
//   then clears the buffer. The history file is trimmed to 5000 lines.
//
// Usage:
//   hist        — print the path to the history file
//   hist ed     — open a copy of the history file in $EDITOR

module main

import os

const hist_file    = os.home_dir() + '/.vlsh/hist_output.txt'
const pending_file = os.home_dir() + '/.vlsh/.hist_pending'
const max_lines    = 5000

fn trim_to_max(path string) {
	content := os.read_file(path) or { return }
	lines := content.split('\n')
	if lines.len <= max_lines {
		return
	}
	trimmed := lines[lines.len - max_lines..].join('\n')
	os.write_file(path, trimmed) or {}
}

fn main() {
	op := if os.args.len > 1 { os.args[1] } else { '' }

	match op {
		'capabilities' {
			println('output_hook')
			println('post_hook')
			println('command hist')
		}

		// output_hook fires before post_hook for ls, echo, and external commands.
		// Save non-empty output to the pending buffer so post_hook can pick it up.
		// output_hook <cmdline> <exit_code> <output>
		'output_hook' {
			output := if os.args.len > 4 { os.args[4] } else { '' }
			if output == '' {
				return
			}
			os.mkdir_all(os.dir(pending_file)) or {}
			os.write_file(pending_file, output) or {}
		}

		// post_hook fires after every command. Write the command line plus any
		// buffered output from output_hook, then clear the buffer.
		// post_hook <cmdline> <exit_code>
		'post_hook' {
			cmdline := if os.args.len > 2 { os.args[2] } else { '' }
			if cmdline == '' || cmdline.starts_with('plugins ') {
				return
			}

			mut entry := '$ ${cmdline}\n'
			if os.exists(pending_file) {
				pending := os.read_file(pending_file) or { '' }
				if pending != '' {
					entry += pending
					if !pending.ends_with('\n') {
						entry += '\n'
					}
				}
				os.rm(pending_file) or {}
			}
			entry += '\n'

			os.mkdir_all(os.dir(hist_file)) or {}
			mut f := os.open_file(hist_file, 'a') or { return }
			f.write_string(entry) or {}
			f.close()
			trim_to_max(hist_file)
		}

		'run' {
			cmd := if os.args.len > 2 { os.args[2] } else { '' }
			match cmd {
				'hist' {
					sub := if os.args.len > 3 { os.args[3] } else { '' }
					match sub {
						'' {
							println(hist_file)
						}
						'ed' {
							if !os.exists(hist_file) {
								eprintln('hist: no history captured yet — run a command first')
								exit(1)
							}
							editor := os.getenv('EDITOR')
							if editor == '' {
								eprintln('hist: \$EDITOR is not set')
								exit(1)
							}
							content := os.read_file(hist_file) or {
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

		else {}
	}
}
