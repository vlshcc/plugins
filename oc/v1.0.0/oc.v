module main

import os

fn main() {
	op := if os.args.len > 1 { os.args[1] } else { '' }

	match op {
		'capabilities' {
			println('command oc')
			println('help')
		}
		'help' {
			cmd := if os.args.len > 2 { os.args[2] } else { '' }
			match cmd {
				'oc', '' {
					println('oc - wrapper for opencode (vlsh plugin)')
					println('')
					println('Usage:')
					println('  oc <args...>   Translates to: opencode run "<args as single string>"')
					println('')
					println('Example:')
					println('  oc write a small blog')
					println('  # Becomes: opencode run "write a small blog"')
				}
				else {}
			}
		}
		'run' {
			cmd := if os.args.len > 2 { os.args[2] } else { '' }
			match cmd {
				'oc' {
					if os.args.len > 3 {
						args := os.args[3..]
						combined := args.join(' ')
						opencode_cmd := 'opencode run "${combined}"'
						exit(os.system(opencode_cmd))
					} else {
						exit(os.system('opencode'))
					}
				}
				else {}
			}
		}
		else {}
	}
}
