// Current-directory prompt plugin for vlsh.
//
// Copy this file to ~/.vlsh/plugins/mux_status_path.v
// vlsh will compile it automatically on the next start (requires `v` in PATH).
//
// Shows the current working directory above the prompt, with the home directory
// abbreviated to '~'. Colours are configurable via ~/.vlshrc:
//   style_path_bg=R,G,B
//   style_path_fg=R,G,B

module main

import os

// read_style_color reads an R,G,B colour value from ~/.vlshrc.
// Returns default_rgb if the key is not found or the file cannot be read.
fn read_style_color(config_file string, key string, default_rgb []int) []int {
	lines := os.read_lines(config_file) or { return default_rgb }
	prefix := '${key}='
	for line in lines {
		trimmed := line.trim_space()
		if trimmed.starts_with(prefix) {
			parts := trimmed[prefix.len..].split(',')
			if parts.len == 3 {
				return [parts[0].int(), parts[1].int(), parts[2].int()]
			}
		}
	}
	return default_rgb
}

fn path_prompt_line() string {
	cwd := os.getwd()
	home := os.home_dir()
	display := if cwd.starts_with(home) {
		'~' + cwd[home.len..]
	} else {
		cwd
	}

	config_file := home + '/.vlshrc'
	bg := read_style_color(config_file, 'style_path_bg', [52, 73, 94])
	fg := read_style_color(config_file, 'style_path_fg', [236, 240, 241])

	label := ' ${display} '
	return '\x1b[48;2;${bg[0]};${bg[1]};${bg[2]}m\x1b[38;2;${fg[0]};${fg[1]};${fg[2]}m${label}\x1b[0m'
}

fn main() {
	op := if os.args.len > 1 { os.args[1] } else { '' }
	match op {
		'capabilities' {
			println('prompt')
		}
		'prompt' {
			println(path_prompt_line())
		}
		else {}
	}
}
