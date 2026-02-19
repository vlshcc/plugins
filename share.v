// share — vlsh plugin
//
// Uploads a file to dpaste.com and prints the resulting URL.
//
// Install: copy this file to ~/.vlsh/plugins/share.v
// Then run "plugins reload" inside vlsh to activate it.
//
// Usage: share <file>

module main

import os
import net.http

fn main() {
	op := if os.args.len > 1 { os.args[1] } else { '' }

	match op {
		'capabilities' {
			println('command share')
		}
		'run' {
			cmd := if os.args.len > 2 { os.args[2] } else { '' }
			match cmd {
				'share' {
					args := os.args[3..]
					if args.len != 1 {
						eprintln('usage: share <file>')
						exit(1)
					}
					file := args[0]
					if !os.exists(file) {
						eprintln('share: could not find ${file}')
						exit(1)
					}
					content := os.read_file(file) or {
						eprintln('share: could not read ${file}')
						exit(1)
					}
					mut data := map[string]string{}
					data['content'] = content
					resp := http.post_form('https://dpaste.com/api/', data) or {
						eprintln('share: could not post file: ${err.msg()}')
						exit(1)
					}
					if resp.status_code == 200 || resp.status_code == 201 {
						println(resp.bytestr())
					} else {
						eprintln('share: status_code: ${resp.status_code}')
						exit(1)
					}
				}
				else {}
			}
		}
		else {}
	}
}
