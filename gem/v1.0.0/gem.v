// gem — vlsh plugin: minimal Gemini protocol browser.
//
// Install:
//   mkdir -p ~/.vlsh/plugins/gem/v1.0.0
//   cp gem.v ~/.vlsh/plugins/gem/v1.0.0/gem.v
//   Then inside vlsh: plugins reload
//
// Usage:
//   gem <gemini-url>        fetch and render a Gemini page
//   gem <n>                 follow link n from the last visited page
//   gem search <query>      search Kennedy, GUS, and Geminispace simultaneously
//
// Gemini protocol overview:
//   1. Open a TLS connection to host:1965
//   2. Send "<URL>\r\n"
//   3. Read response: first line is "<STATUS> <META>\r\n", then optional body
//   Status classes: 1x=input, 2x=success, 3x=redirect, 4x/5x/6x=error
//
// State: link list for the current page (or search results) is saved to
// ~/.vlsh/gem_links.txt so that "gem <n>" can follow any numbered link
// across invocations.

module main

import os
import net.ssl

const links_file    = os.home_dir() + '/.vlsh/gem_links.txt'
const state_dir     = os.home_dir() + '/.vlsh'
const max_redirects = 5

// ANSI escape sequences
const r_reset  = '\x1b[0m'
const r_bold   = '\x1b[1m'
const r_dim    = '\x1b[2m'
const r_yellow = '\x1b[33m'
const r_cyan   = '\x1b[36m'

// ── Search engines ────────────────────────────────────────────────────────────

struct SearchEngine {
	name string
	// Base URL for search. The percent-encoded query is appended as ?<query>.
	url string
}

// Adjust these if a capsule changes its search endpoint.
const search_engines = [
	SearchEngine{ name: 'Kennedy',     url: 'gemini://kennedy.gemi.dev/' },
	SearchEngine{ name: 'GUS',         url: 'gemini://gus.guru/' },
	SearchEngine{ name: 'Geminispace', url: 'gemini://geminispace.info/search' },
]

// ── URL ───────────────────────────────────────────────────────────────────────

struct GemUrl {
	host string
	port int
	path string
}

// find_last_byte returns the index of the last occurrence of b in s, or -1.
fn find_last_byte(s string, b u8) int {
	mut i := s.len - 1
	for i >= 0 {
		if s[i] == b {
			return i
		}
		i--
	}
	return -1
}

fn parse_gem_url(raw string) !GemUrl {
	mut s := raw
	if s.starts_with('gemini://') {
		s = s[9..]
	} else {
		return error('not a gemini:// URL: "${raw}"')
	}

	slash_pos := s.index('/') or { s.len }
	host_part := s[..slash_pos]
	path_part := if slash_pos < s.len { s[slash_pos..] } else { '/' }

	colon_pos := find_last_byte(host_part, u8(`:`))
	mut host  := ''
	mut port  := 1965
	if colon_pos > 0 {
		p := host_part[colon_pos + 1..].int()
		if p > 0 {
			host = host_part[..colon_pos]
			port = p
		} else {
			host = host_part
		}
	} else {
		host = host_part
	}

	if host == '' {
		return error('empty host in URL: "${raw}"')
	}
	return GemUrl{ host: host, port: port, path: path_part }
}

fn gem_url_str(u GemUrl) string {
	port_str := if u.port != 1965 { ':${u.port}' } else { '' }
	return 'gemini://${u.host}${port_str}${u.path}'
}

// resolve_url turns a potentially-relative link into an absolute gemini:// URL.
fn resolve_url(base GemUrl, link string) string {
	if link.contains('://') {
		return link
	}
	port_str := if base.port != 1965 { ':${base.port}' } else { '' }
	if link.starts_with('/') {
		return 'gemini://${base.host}${port_str}${link}'
	}
	// Relative: resolve against the directory part of the current path.
	slash_pos := find_last_byte(base.path, u8(`/`))
	base_dir  := if slash_pos >= 0 { base.path[..slash_pos + 1] } else { '/' }
	return 'gemini://${base.host}${port_str}${base_dir}${link}'
}

// url_encode percent-encodes a string for use as a Gemini query string.
// Unreserved characters (RFC 3986) pass through; everything else is %XX.
fn url_encode(s string) string {
	digits   := '0123456789ABCDEF'
	mut out  := ''
	for b in s.bytes() {
		if (b >= 65 && b <= 90)  ||  // A-Z
		   (b >= 97 && b <= 122) ||  // a-z
		   (b >= 48 && b <= 57)  ||  // 0-9
		   b == 45 || b == 95 || b == 46 || b == 126 { // - _ . ~
			out += b.ascii_str()
		} else {
			out += '%' + digits[b >> 4].ascii_str() + digits[b & 15].ascii_str()
		}
	}
	return out
}

// ── Network ───────────────────────────────────────────────────────────────────

// gemini_fetch opens a TLS connection, sends the request, and returns the
// response header line and body as separate strings.
fn gemini_fetch(url GemUrl) !(string, string) {
	mut conn := ssl.new_ssl_conn(ssl.SSLConnectConfig{
		validate: false // many Gemini capsules use self-signed certificates
	})!
	conn.dial(url.host, url.port)!

	request := gem_url_str(url) + '\r\n'
	conn.write(request.bytes())!

	mut buf      := []u8{len: 4096}
	mut response := []u8{}
	for {
		n := conn.read(mut buf) or { break }
		if n <= 0 { break }
		response << buf[..n]
	}
	conn.shutdown() or {}

	full     := response.bytestr()
	crlf_pos := full.index('\r\n') or {
		return error('invalid response: no CRLF after header')
	}
	return full[..crlf_pos], full[crlf_pos + 2..]
}

// ── Gemtext renderer ─────────────────────────────────────────────────────────

// first_whitespace returns the index of the first space or tab in s, or s.len.
fn first_whitespace(s string) int {
	bytes := s.bytes()
	for i, b in bytes {
		if b == 32 || b == 9 { // space or tab
			return i
		}
	}
	return s.len
}

// render_gemtext prints body to stdout with ANSI formatting and returns the
// absolute link URLs found on the page, in order.
//
// link_offset is added to the displayed link number so that results from
// multiple sources (e.g. several search engines) share a single global
// numbering sequence that lines up with the saved links file.
fn render_gemtext(body string, page_url GemUrl, link_offset int) []string {
	mut links        := []string{}
	mut preformatted := false

	for raw_line in body.split('\n') {
		// Strip trailing CR so we don't print it
		line := if raw_line.ends_with('\r') { raw_line[..raw_line.len - 1] } else { raw_line }

		// Preformatted toggle (``` fence)
		if line.starts_with('```') {
			preformatted = !preformatted
			if preformatted {
				alt := line[3..].trim_space()
				if alt.len > 0 {
					println('${r_dim}[${alt}]${r_reset}')
				}
			}
			continue
		}

		if preformatted {
			println('${r_dim}${line}${r_reset}')
			continue
		}

		if line.starts_with('=> ') {
			// Link line: => URL [optional label]
			rest     := line[3..].trim_space()
			sp       := first_whitespace(rest)
			link     := rest[..sp]
			label    := if sp < rest.len { rest[sp..].trim_space() } else { link }
			full_url := resolve_url(page_url, link)
			n        := link_offset + links.len + 1
			links << full_url
			// Show scheme tag for non-gemini links
			scheme_tag := if !full_url.starts_with('gemini://') {
				scheme_end := full_url.index(':') or { 0 }
				' ${r_dim}[${full_url[..scheme_end]}]${r_reset}'
			} else {
				''
			}
			println('${r_cyan}[${n}]${r_reset} ${label}${scheme_tag}')
		} else if line.starts_with('# ') {
			println('\n${r_bold}${r_yellow}${line[2..]}${r_reset}')
		} else if line.starts_with('## ') {
			println('\n${r_bold}${line[3..]}${r_reset}')
		} else if line.starts_with('### ') {
			println('  ${r_bold}${line[4..]}${r_reset}')
		} else if line.starts_with('* ') {
			println('  • ${line[2..]}')
		} else if line.starts_with('> ') {
			println('${r_dim}│ ${line[2..]}${r_reset}')
		} else {
			println(line)
		}
	}
	return links
}

// ── Visit ─────────────────────────────────────────────────────────────────────

fn gem_visit(raw string) {
	mut url_str := if raw.starts_with('gemini://') { raw } else { 'gemini://${raw}' }

	for redir := 0; redir <= max_redirects; redir++ {
		url := parse_gem_url(url_str) or {
			eprintln('gem: ${err}')
			exit(1)
		}

		header, body := gemini_fetch(url) or {
			eprintln('gem: ${err}')
			exit(1)
		}

		if header.len < 2 {
			eprintln('gem: malformed response header')
			exit(1)
		}

		status := header[..2].int()
		meta   := if header.len > 3 { header[3..].trim_space() } else { '' }
		class  := status / 10

		if class == 1 {
			// Input required — show the prompt, let the user construct the URL
			println('${r_bold}Input required:${r_reset} ${meta}')
			println('Append your answer as a query string:')
			println('  gem ${url_str}?<answer>')
		} else if class == 2 {
			// Success
			mime := meta.split(';')[0].trim_space().to_lower()
			if mime == '' || mime == 'text/gemini' {
				println('${r_dim}── ${url_str} ──${r_reset}')
				links := render_gemtext(body, url, 0)
				// Persist link list so "gem <n>" works next invocation
				os.mkdir_all(state_dir) or {}
				mut saved := url_str + '\n'
				for l in links {
					saved += l + '\n'
				}
				os.write_file(links_file, saved) or {}
			} else if mime.starts_with('text/') {
				println(body)
			} else {
				eprintln('gem: cannot display binary content type "${mime}"')
				exit(1)
			}
		} else if class == 3 {
			// Redirect
			if redir == max_redirects {
				eprintln('gem: too many redirects')
				exit(1)
			}
			target := resolve_url(url, meta)
			eprintln('${r_dim}→ ${target}${r_reset}')
			url_str = target
			continue
		} else if class == 4 {
			eprintln('gem: temporary failure (${status}): ${meta}')
			exit(1)
		} else if class == 5 {
			eprintln('gem: permanent failure (${status}): ${meta}')
			exit(1)
		} else if class == 6 {
			eprintln('gem: client certificate required (${status}): ${meta}')
			exit(1)
		} else {
			eprintln('gem: unexpected status ${status}: ${meta}')
			exit(1)
		}
		break
	}
}

// ── Search ────────────────────────────────────────────────────────────────────

// gem_search queries all search_engines for query and renders combined results.
// Links are numbered globally across all engines so "gem <n>" works uniformly.
fn gem_search(query string) {
	encoded   := url_encode(query)
	mut all_links := []string{}

	for engine in search_engines {
		search_url := engine.url + '?' + encoded
		url := parse_gem_url(search_url) or {
			eprintln('gem: search: bad URL for ${engine.name}: ${err}')
			continue
		}

		eprint('${r_dim}Querying ${engine.name}…${r_reset} ')
		mut header := ''
		mut body   := ''
		mut fetch_url := url
		header, body = gemini_fetch(fetch_url) or {
			eprintln('(failed: ${err})')
			continue
		}
		eprintln('')

		// Follow a single redirect if needed (e.g. http→https normalisation)
		if header.len >= 2 && header[..2].int() / 10 == 3 {
			meta   := if header.len > 3 { header[3..].trim_space() } else { '' }
			target := resolve_url(url, meta)
			eprintln('${r_dim}  → ${target}${r_reset}')
			redir_url := parse_gem_url(target) or {
				eprintln('gem: search: bad redirect URL from ${engine.name}')
				continue
			}
			header, body = gemini_fetch(redir_url) or {
				eprintln('gem: search: redirect fetch failed for ${engine.name}: ${err}')
				continue
			}
			fetch_url = redir_url
		}

		if header.len < 2 {
			eprintln('${r_dim}  (${engine.name}: malformed response)${r_reset}')
			continue
		}

		status := header[..2].int()
		meta   := if header.len > 3 { header[3..].trim_space() } else { '' }
		class  := status / 10

		println('${r_bold}── ${engine.name} ──${r_reset}')

		if class == 2 {
			mime := meta.split(';')[0].trim_space().to_lower()
			if mime == '' || mime == 'text/gemini' {
				links := render_gemtext(body, fetch_url, all_links.len)
				all_links << links
			} else {
				eprintln('  (unexpected MIME type: ${mime})')
			}
		} else if class == 1 {
			// The engine returned INPUT — our ?query wasn't accepted at this path
			eprintln('  (search endpoint did not accept the query — URL may need updating)')
			eprintln('  (current URL: ${search_url})')
		} else {
			eprintln('  (${status}: ${meta})')
		}
	}

	if all_links.len == 0 {
		eprintln('gem: no results')
		return
	}

	// Save the combined link list so "gem <n>" can follow any result
	os.mkdir_all(state_dir) or {}
	mut saved := 'gem:search:${query}\n'
	for l in all_links {
		saved += l + '\n'
	}
	os.write_file(links_file, saved) or {}
}

// ── Follow link ───────────────────────────────────────────────────────────────

fn follow_link(n int) {
	if !os.exists(links_file) {
		eprintln('gem: no page visited yet — use "gem <url>" first')
		exit(1)
	}
	content := os.read_file(links_file) or {
		eprintln('gem: cannot read state file')
		exit(1)
	}
	lines := content.split('\n').filter(it.len > 0)
	// lines[0] = page URL (or search sentinel), lines[1..] = link 1, link 2, …
	if n < 1 || n >= lines.len {
		total := lines.len - 1
		eprintln('gem: link ${n} out of range (${total} link(s) available)')
		exit(1)
	}
	gem_visit(lines[n])
}

// ── Entry point ───────────────────────────────────────────────────────────────

fn main() {
	op := if os.args.len > 1 { os.args[1] } else { '' }
	match op {
		'capabilities' {
			println('command gem')
			println('help')
		}
		'help' {
			cmd := if os.args.len > 2 { os.args[2] } else { '' }
			match cmd {
				'gem', '' {
					println('gem — Gemini protocol browser')
					println('')
					println('Usage:')
					println('  gem <url>            fetch and display a gemini:// page')
					println('  gem <n>              follow link n from the last visited page or search')
					println('  gem search <query>   search Kennedy, GUS, and Geminispace')
					println('')
					println('Examples:')
					println('  gem gemini://geminiprotocol.net/')
					println('  gem 3')
					println('  gem search gemini software')
					println('  gem gemini://geminiprotocol.net/docs/faq.gmi')
					println('')
					println('Gemini is a lightweight internet protocol (port 1965, TLS).')
					println('Pages are written in gemtext, a simple line-oriented format.')
					println('Link numbers persist between invocations; after a search,')
					println('"gem <n>" follows result n regardless of which engine found it.')
				}
				else {}
			}
		}
		'run' {
			cmd := if os.args.len > 2 { os.args[2] } else { '' }
			if cmd == 'gem' {
				sub := if os.args.len > 3 { os.args[3] } else { '' }
				if sub == '' {
					eprintln('gem: usage: gem <url>  |  gem <n>  |  gem search <query>')
					exit(1)
				} else if sub == 'search' {
					if os.args.len < 5 {
						eprintln('gem: usage: gem search <query>')
						exit(1)
					}
					gem_search(os.args[4..].join(' '))
				} else {
					// Pure decimal integer → follow a numbered link
					is_num := sub.bytes().all(it >= 48 && it <= 57)
					if is_num {
						follow_link(sub.int())
					} else {
						gem_visit(sub)
					}
				}
			}
		}
		else {}
	}
}
