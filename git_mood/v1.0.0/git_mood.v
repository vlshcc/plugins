// Git working-tree mood plugin for vlsh.
//
// Copy this file to ~/.vlsh/plugins/git_mood.v
// vlsh will compile it automatically on the next start (requires `v` in PATH).
//
// Shows 😡 above the prompt when the current git repo has uncommitted changes,
// or ✅ when the working tree is clean.
// Nothing is shown outside of a git repository.

module main

import os

fn git_mood_line() string {
	result := os.execute('git status --porcelain 2>/dev/null')
	// Non-zero exit code means we are not inside a git repository.
	if result.exit_code != 0 {
		return ''
	}
	if result.output.trim_space() == '' {
		return '✅'
	}
	return '😡'
}

fn main() {
	op := if os.args.len > 1 { os.args[1] } else { '' }
	match op {
		'capabilities' {
			println('prompt')
			println('help')
		}
		'help' {
			println('git_mood — shows an emoji above the prompt reflecting the git working-tree state')
			println('')
			println('  ✅   working tree is clean')
			println('  😡   uncommitted changes present')
			println('')
			println('Nothing is shown outside a git repository.')
		}
		'prompt' {
			line := git_mood_line()
			if line != '' {
				println(line)
			}
		}
		else {}
	}
}
