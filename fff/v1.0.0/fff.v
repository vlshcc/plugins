// fff — fast file manager (ported from bash to V / vsh).
module main

import os
import strings
import term

const version = '2.2-v'

fn main() {
	if os.args.len >= 2 {
		match os.args[1] {
			'capabilities' {
				println('command fff')
				println('help')
				return
			}
			'run' {
				if os.args.len >= 3 && os.args[2] == 'fff' {
					mut args := []string{}
					if os.args.len > 3 {
						args = os.args[3..].clone()
					}
					fff_main(args)
					return
				}
			}
			'help' {
				println('fff — terminal file manager')
				println('Usage: fff [-v|-h|-p] [directory]')
				return
			}
			else {}
		}
	}
	fff_main(os.args[1..])
}

struct App {
mut:
	pwd              string
	oldpwd           string
	list             []string
	cur_list         []string
	scroll           int
	y                int
	list_total       int
	max_items        int
	lines            int
	columns          int
	find_previous    int
	search           int
	search_end_early int
	marked_files     map[int]string
	mark_dir         string
	file_program     []string
	ls_ext_map       map[string]string
	ls_colors_on     bool
	file_pre         string
	file_post        string
	mark_pre         string
	mark_post        string
	mime_type        string
	file_picker      int
	opener           string
	fff_trash        string
	hidden           bool
	fav              [9]string
	last_cols        int
	last_lines       int
}

fn getenv_def(name string, def string) string {
	s := os.getenv(name)
	if s == '' {
		return def
	}
	return s
}

fn getenv_int(name string, def int) int {
	s := os.getenv(name)
	if s == '' {
		return def
	}
	return s.int()
}

fn (mut a App) setup_options() {
	ff := getenv_def('FFF_FILE_FORMAT', '%f')
	if ff.contains('%f') {
		parts := ff.split('%f')
		a.file_pre = parts[0]
		a.file_post = if parts.len > 1 { parts[1..].join('%f') } else { '' }
	}
	mf := getenv_def('FFF_MARK_FORMAT', ' %f*')
	if mf.contains('%f') {
		parts := mf.split('%f')
		a.mark_pre = parts[0]
		a.mark_post = if parts.len > 1 { parts[1..].join('%f') } else { '' }
	} else {
		a.mark_pre = ' '
		a.mark_post = '*'
	}
}

fn (mut a App) parse_ls_colors() {
	a.ls_colors_on = false
	a.ls_ext_map = map[string]string{}
	lc := getenv_def('LS_COLORS', '')
	if lc == '' {
		return
	}
	a.ls_colors_on = true
	for p in lc.split(':') {
		if p == '' {
			continue
		}
		kv := p.split('=')
		if kv.len < 2 {
			continue
		}
		key := kv[0]
		val := kv[1..].join('=')
		if key.starts_with('*.') {
			a.ls_ext_map[key[2..]] = val
		}
	}
}

fn (mut a App) load_favorites() {
	for i in 0 .. 9 {
		a.fav[i] = getenv_def('FFF_FAV${i + 1}', '')
	}
}

fn (mut a App) get_os_defaults() {
	a.opener = getenv_def('FFF_OPENER', 'xdg-open')
	ost := getenv_def('OSTYPE', '')
	if ost.starts_with('darwin') {
		a.opener = 'open'
	}
}

fn (mut a App) get_term_size() {
	w, h := term.get_terminal_size()
	a.columns = w
	a.lines = h
	a.last_cols = w
	a.last_lines = h
	a.max_items = if a.lines > 3 { a.lines - 3 } else { 1 }
}

fn (mut a App) check_resize() {
	w, h := term.get_terminal_size()
	if w != a.last_cols || h != a.last_lines {
		a.get_term_size()
		a.redraw(false)
	}
}

fn (mut a App) setup_terminal() {
	print('\x1b[?1049h\x1b[?7l\x1b[?25l\x1b[2J\x1b[1;${a.max_items}r')
	os.execute('stty -echo -icanon min 0 time 1 2>/dev/null')
}

fn (mut a App) reset_terminal() {
	print('\x1b[?7h\x1b[?25h\x1b[2J\x1b[;r\x1b[?1049l')
	os.execute('stty echo icanon 2>/dev/null')
}

fn (mut a App) clear_screen() {
	tmux_fix := if getenv_def('TMUX', '') != '' { '\x1b[2J' } else { '' }
	print('\x1b[${a.lines - 2}H\x1b[9999C\x1b[1J${tmux_fix}\x1b[1;${a.max_items}r')
}

fn (mut a App) get_mime(path string) {
	res := os.execute("file -biL '${path}' 2>/dev/null")
	if res.exit_code != 0 {
		res2 := os.execute("file -b --mime-type -- '${path}' 2>/dev/null")
		if res2.exit_code == 0 {
			a.mime_type = res2.output.trim_space()
			return
		}
		a.mime_type = ''
		return
	}
	ln := res.output.trim_space()
	if ln.contains(': ') {
		a.mime_type = ln.all_after_last(': ').trim_space()
	} else {
		a.mime_type = ln
	}
}

fn esc_name(name string) string {
	mut b := strings.new_builder(name.len)
	for ch in name {
		if ch >= 32 && ch != 127 {
			b.write_u8(ch)
		} else {
			b.write_string('^[')
		}
	}
	return b.str()
}

fn (mut a App) sgr_ls(key string, fallback string) string {
	return getenv_def(key, fallback)
}

fn (mut a App) print_line(idx int) {
	if idx < 0 || idx >= a.list.len {
		return
	}
	item := a.list[idx]
	if item == 'empty' && a.list.len == 1 {
		print('\r\x1b[2mempty\x1b[m\r')
		return
	}
	if item == '' {
		return
	}
	mut seq := ''
	mut suf := ''
	base := os.base(item)
	mut ext := if base.contains('.') && base != '.' && base != '..' {
		base.all_after_last('.')
	} else {
		''
	}

	if os.is_dir(item) {
		di := a.sgr_ls('DI', '1;34')
		c1 := getenv_int('FFF_COL1', 2)
		seq = '\x1b[${di};3${c1}m'
		suf = '/'
	} else if os.is_link(item) {
		target := os.real_path(item)
		if target == '' || !os.exists(target) {
			seq = '\x1b[${a.sgr_ls('MI', '01;31;7')}m'
		} else {
			seq = '\x1b[${a.sgr_ls('LN', '01;36')}m'
		}
	} else if os.is_file(item) {
		if os.is_executable(item) {
			seq = '\x1b[${a.sgr_ls('EX', '01;32')}m'
		} else if a.ls_colors_on && ext != '' && ext != base {
			if code := a.ls_ext_map[ext] {
				seq = '\x1b[${code}m'
			} else {
				seq = '\x1b[${a.sgr_ls('FI', '37')}m'
			}
		} else {
			seq = '\x1b[${a.sgr_ls('FI', '37')}m'
		}
	} else {
		seq = '\x1b[37m'
	}
	if idx == a.scroll {
		c4 := getenv_int('FFF_COL4', 6)
		seq += '\x1b[1;3${c4};7m'
	}
	if a.marked_files[idx] == item {
		c3 := getenv_int('FFF_COL3', 1)
		seq += '\x1b[3${c3}m${a.mark_pre}'
		suf += a.mark_post
	}
	disp := esc_name(base)
	print('\r${a.file_pre}${seq}${disp}${suf}${a.file_post}\x1b[m\r')
}

fn (mut a App) read_dir() {
	pwd := os.getwd()
	a.pwd = pwd
	print('\x1b]2;fff: ${pwd}\x07')
	mut entries := os.ls(pwd) or { []string{} }
	mut dirs := []string{}
	mut files := []string{}
	for name in entries {
		if !a.hidden && name.starts_with('.') && name != '.' && name != '..' {
			continue
		}
		full := os.join_path(pwd, name)
		if os.is_dir(full) {
			dirs << full
		} else {
			files << full
		}
	}
	dirs.sort()
	files.sort()
	a.list = dirs
	a.list << files
	if a.list.len == 0 {
		a.list = ['empty']
	}
	a.list_total = a.list.len - 1
	a.cur_list = a.list.clone()
	if a.find_previous == 1 {
		for i, p in a.list {
			if p == a.oldpwd {
				a.scroll = i
				break
			}
		}
		a.find_previous = 0
	}
}

fn (mut a App) draw_dir() {
	mut scroll_start := a.scroll
	mut scroll_end := 0
	mut scroll_new_pos := 1
	if a.list_total < a.max_items || a.scroll < a.max_items / 2 {
		scroll_start = 0
		scroll_end = a.max_items
		scroll_new_pos = a.scroll + 1
	} else if a.list_total - a.scroll < a.max_items / 2 {
		scroll_start = a.list_total - a.max_items + 1
		scroll_new_pos = a.max_items - (a.list_total - a.scroll)
		scroll_end = a.list_total + 1
	} else {
		scroll_start = a.scroll - a.max_items / 2
		scroll_end = scroll_start + a.max_items
		scroll_new_pos = a.max_items / 2 + 1
	}
	if scroll_end > a.list.len {
		scroll_end = a.list.len
	}
	print('\x1b[H')
	for i in scroll_start .. scroll_end {
		if i > scroll_start {
			print('\n')
		}
		a.print_line(i)
	}
	print('\x1b[${scroll_new_pos}H')
	a.y = scroll_new_pos
}

fn (mut a App) status_line(extra string) {
	c5 := getenv_int('FFF_COL5', 0)
	c2 := getenv_int('FFF_COL2', 1)
	pwd_show := a.pwd
	mut mark_ui := ''
	if a.marked_files.len > 0 {
		mark_ui = '[${a.marked_files.len}] selected (${a.file_program.join(' ')}) [p] -> '
	}
	print('\x1b7\x1b[${a.lines - 1}H\x1b[3${c5};4${c2}m${' '.repeat(a.columns)}\r')
	print('(${a.scroll + 1}/${a.list_total + 1}) ${mark_ui}')
	if extra != '' {
		print(extra)
	} else {
		print(pwd_show)
	}
	print('\x1b[m\x1b[${a.lines}H\x1b[K\x1b8')
}

fn (mut a App) redraw(full bool) {
	if full {
		a.read_dir()
		a.scroll = 0
	}
	a.clear_screen()
	a.draw_dir()
	a.status_line('')
}

fn read_byte_timeout() u8 {
	mut stdin := os.stdin()
	mut b := []u8{len: 1}
	n := stdin.read(mut b) or { return 0 }
	if n <= 0 {
		return 0
	}
	return b[0]
}

fn (mut a App) cmd_line(prompt string, mode string) string {
	mut reply := ''
	print('\x1b7\x1b[${a.lines}H\x1b[?25h')
	for {
		print('\r\x1b[K${prompt}${reply}')
		os.flush()
		ch := read_byte_timeout()
		if ch == 0 {
			a.check_resize()
			print('\x1b[${a.lines}H\x1b[?25h')
			continue
		}
		if ch == 127 || ch == 8 {
			if reply.len > 0 {
				reply = reply[..reply.len - 1]
			}
			continue
		}
		if ch == 27 {
			reply = ''
			break
		}
		if ch == `\n` || ch == `\r` {
			break
		}
		reply += ch.ascii_str()
		if mode == 'search' {
			a.do_search(reply)
		}
	}
	print('\x1b[2K\x1b[?25l\x1b8')
	return reply
}

fn (mut a App) do_search(q string) {
	if q == '' {
		a.list = a.cur_list.clone()
		a.list_total = a.list.len - 1
		a.scroll = 0
		a.clear_screen()
		a.draw_dir()
		a.status_line('')
		return
	}
	mut out := []string{}
	pat := '*${q}*'
	glob_pat := os.join_path(a.pwd, pat)
	entries := os.glob(glob_pat) or {
		a.list = ['empty']
		a.list_total = 0
		a.scroll = 0
		a.clear_screen()
		a.draw_dir()
		a.status_line('')
		return
	}
	for e in entries {
		base := os.base(e)
		if !a.hidden && base.starts_with('.') {
			continue
		}
		out << e
	}
	if out.len == 0 {
		a.list = ['empty']
		a.list_total = 0
	} else {
		out.sort()
		a.list = out
		a.list_total = a.list.len - 1
	}
	a.scroll = 0
	a.clear_screen()
	a.draw_dir()
	a.status_line('')
}

fn (mut a App) open_path(path string) {
	if os.is_dir(path) {
		prev := a.pwd
		os.chdir(path) or { return }
		a.oldpwd = prev
		a.search = 0
		a.search_end_early = 0
		a.redraw(true)
		return
	}
	if os.is_file(path) {
		a.get_mime(path)
		if a.mime_type.starts_with('text/') || a.mime_type.contains('json')
			|| a.mime_type.contains('empty') || a.mime_type.contains('x-empty') {
			if a.file_picker == 1 {
				cache := '${getenv_def('XDG_CACHE_HOME', os.join_path(os.home_dir(), '.cache'))}/fff/opened_file'
				os.mkdir_all(os.dir(cache)) or {}
				os.write_file(cache, path) or {}
				a.reset_terminal()
				exit(0)
			}
			ed := getenv_def('VISUAL', getenv_def('EDITOR', 'vi'))
			a.reset_terminal()
			os.system('${ed} "${path}"')
			a.setup_terminal()
			a.redraw(false)
			return
		}
		op := getenv_def('FFF_OPENER', a.opener)
		a.reset_terminal()
		os.system('nohup "${op}" "${path}" >/dev/null 2>&1 &')
		a.setup_terminal()
		a.redraw(false)
	}
}

fn (mut a App) mark_key(op u8) {
	if a.mark_dir != a.pwd {
		a.marked_files.clear()
	}
	if a.list.len == 0 || (a.list[0] == 'empty' && a.list.len == 1) {
		return
	}
	match op {
		`y`, `Y` {
			a.file_program = ['cp', '-iR']
		}
		`m`, `M` {
			a.file_program = ['mv', '-i']
		}
		`s`, `S` {
			a.file_program = ['ln', '-s']
		}
		`d`, `D` {
			cmd := getenv_def('FFF_TRASH_CMD', '')
			if cmd != '' {
				a.file_program = [cmd]
			} else {
				a.file_program = ['trash']
			}
		}
		`b`, `B` {
			a.file_program = ['bulk_rename']
		}
		else {}
	}
	if op >= `A` && op <= `Z` {
		if a.marked_files.len != a.list.len {
			for i, p in a.list {
				if p != 'empty' {
					a.marked_files[i] = p
				}
			}
			a.mark_dir = a.pwd
		} else {
			a.marked_files.clear()
		}
		a.redraw(false)
	} else {
		i := a.scroll
		if a.marked_files[i] == a.list[i] {
			a.marked_files.delete(i)
		} else {
			a.marked_files[i] = a.list[i]
			a.mark_dir = a.pwd
		}
		print('\x1b[K')
		a.print_line(i)
	}
	a.status_line('')
}

fn (mut a App) paste() {
	if a.marked_files.len == 0 {
		return
	}
	a.reset_terminal()
	print('fff: Running ${a.file_program[0]}\n')
	if a.file_program[0] == 'bulk_rename' {
		a.bulk_rename()
		a.setup_terminal()
		a.marked_files.clear()
		a.redraw(true)
		return
	}
	if a.file_program[0] == 'trash' {
		a.do_trash()
		a.setup_terminal()
		a.marked_files.clear()
		a.redraw(true)
		return
	}
	mut args := a.file_program.clone()
	for _, p in a.marked_files {
		args << p
	}
	args << '.'
	os.system(args.join(' '))
	a.setup_terminal()
	a.marked_files.clear()
	a.redraw(true)
}

fn (mut a App) do_trash() {
	print('Trash [y/n]? ')
	os.flush()
	b := read_byte_timeout()
	print('\n')
	if b != `y` && b != `Y` {
		return
	}
	cmd := getenv_def('FFF_TRASH_CMD', '')
	if cmd != '' {
		mut parts := [cmd]
		for _, p in a.marked_files {
			parts << p
		}
		os.system(parts.join(' '))
		return
	}
	tr := a.fff_trash
	os.mkdir_all(tr) or {}
	for _, p in a.marked_files {
		dest := os.join_path(tr, os.base(p))
		os.system('mv -f "${p}" "${dest}"')
	}
}

fn (mut a App) bulk_rename() {
	cache_root := getenv_def('XDG_CACHE_HOME', os.join_path(os.home_dir(), '.cache'))
	rf := os.join_path(cache_root, 'fff/bulk_rename')
	os.mkdir_all(os.dir(rf)) or {}
	mut lines := []string{}
	for _, p in a.marked_files {
		lines << os.base(p)
	}
	os.write_file(rf, lines.join('\n')) or {}
	ed := getenv_def('EDITOR', 'vi')
	os.system('${ed} "${rf}"')
	new_lines := os.read_lines(rf) or { return }
	mut old_paths := []string{}
	for _, p in a.marked_files {
		old_paths << p
	}
	if new_lines.len != old_paths.len {
		os.rm(rf) or {}
		print('error: line mismatch\n')
		return
	}
	mut script := '#!/bin/sh\n'
	for i := 0; i < old_paths.len; i++ {
		new_name := new_lines[i]
		old := old_paths[i]
		if os.base(old) == new_name {
			continue
		}
		dest := os.join_path(a.pwd, new_name)
		script += 'mv -i -- "${old}" "${dest}"\n'
	}
	shf := rf + '.sh'
	os.write_file(shf, script) or {}
	os.system('sh "${shf}"')
	os.rm(rf) or {}
	os.rm(shf) or {}
}

fn expand_tilde(s string) string {
	if s.starts_with('~') {
		return os.join_path(os.home_dir(), s[1..])
	}
	return s
}

fn (mut a App) spawn_shell() {
	sh := getenv_def('SHELL', '/bin/sh')
	lvl := getenv_int('FFF_LEVEL', 0)
	os.setenv('FFF_LEVEL', '${lvl + 1}', true)
	a.reset_terminal()
	os.system('cd "${a.pwd}" && "${sh}"')
	a.setup_terminal()
	a.redraw(true)
}

fn fff_main(user_args []string) {
	mut a := App{}
	mut start_dir := ''
	mut i := 0
	for i < user_args.len {
		arg := user_args[i]
		match arg {
			'-v' {
				println('fff ${version}')
				return
			}
			'-h' {
				println('fff ${version}')
				println('Usage: fff [-v|-h|-p] [directory]')
				return
			}
			'-p' {
				a.file_picker = 1
				if i + 1 < user_args.len && !user_args[i + 1].starts_with('-') {
					start_dir = user_args[i + 1]
					i += 2
					continue
				}
				i++
				continue
			}
			else {
				if !arg.starts_with('-') {
					start_dir = arg
				}
				i++
				continue
			}
		}
		i++
	}
	if start_dir != '' {
		os.chdir(start_dir) or {}
	}
	a.setup_options()
	a.parse_ls_colors()
	a.load_favorites()
	a.get_os_defaults()
	data_home := getenv_def('XDG_DATA_HOME', os.join_path(os.home_dir(), '.local/share'))
	a.fff_trash = getenv_def('FFF_TRASH', os.join_path(data_home, 'fff/trash'))
	cache := getenv_def('XDG_CACHE_HOME', os.join_path(os.home_dir(), '.cache'))
	os.mkdir_all(os.join_path(cache, 'fff')) or {}
	os.mkdir_all(a.fff_trash) or {}
	if getenv_int('FFF_LS_COLORS', 1) == 1 {
		a.parse_ls_colors()
	}
	a.hidden = getenv_int('FFF_HIDDEN', 0) == 1
	a.get_term_size()
	defer {
		a.reset_terminal()
	}
	a.setup_terminal()
	a.redraw(true)
	for {
		if os.is_atty(1) <= 0 {
			exit(1)
		}
		ch := read_byte_timeout()
		if ch == 0 {
			a.check_resize()
			continue
		}
		a.handle_key(ch)
	}
}

fn (mut a App) handle_key(ch u8) {
	if ch == 27 {
		a.handle_escape()
		return
	}
	match ch {
		`q` {
			cdfile := getenv_def('FFF_CD_FILE', os.join_path(getenv_def('XDG_CACHE_HOME',
				os.join_path(os.home_dir(), '.cache')), 'fff/.fff_d'))
			if getenv_int('FFF_CD_ON_EXIT', 1) == 1 {
				os.mkdir_all(os.dir(cdfile)) or {}
				os.write_file(cdfile, a.pwd) or {}
			}
			a.reset_terminal()
			exit(0)
		}
		`j` {
			if a.scroll < a.list_total {
				a.scroll++
				if a.y < a.max_items {
					a.y++
				}
				a.print_line(a.scroll - 1)
				print('\n')
				a.print_line(a.scroll)
				a.status_line('')
			}
		}
		`k` {
			if a.scroll > 0 {
				a.scroll--
				a.print_line(a.scroll + 1)
				if a.y < 2 {
					print('\x1b[L')
				} else {
					print('\x1b[A')
					a.y--
				}
				a.print_line(a.scroll)
				a.status_line('')
			}
		}
		`h` {
			if a.search == 1 && a.search_end_early != 1 {
				a.open_path(a.pwd)
				a.search = 0
				return
			}
			if a.pwd != '/' && a.pwd != '' {
				parent := os.dir(a.pwd)
				a.oldpwd = a.pwd
				a.find_previous = 1
				a.open_path(parent)
			}
		}
		`l` {
			if a.scroll < a.list.len {
				a.open_path(a.list[a.scroll])
			}
		}
		`\n`, `\r` {
			if a.scroll < a.list.len {
				a.open_path(a.list[a.scroll])
			}
		}
		`.` {
			a.hidden = !a.hidden
			a.redraw(true)
		}
		`/` {
			a.cmd_line('/', 'search')
			if a.list.len == 0 {
				a.list = a.cur_list.clone()
				a.list_total = a.list.len - 1
				a.redraw(false)
				a.search = 0
			} else {
				a.search = 1
			}
		}
		`!` {
			a.spawn_shell()
		}
		`p` {
			a.paste()
		}
		`c` {
			a.marked_files.clear()
			a.redraw(false)
		}
		`r` {
			if a.scroll >= a.list.len {
				return
			}
			p := a.list[a.scroll]
			if p == 'empty' {
				return
			}
			n := a.cmd_line('rename ${os.base(p)}: ', '')
			if n != '' && !os.exists(os.join_path(a.pwd, n)) {
				os.system('mv "${p}" "${os.join_path(a.pwd, n)}"')
				a.redraw(true)
			}
		}
		`n` {
			n := a.cmd_line('mkdir: ', 'dirs')
			if n != '' {
				os.mkdir_all(os.join_path(a.pwd, n), os.MkdirParams{}) or {}
				a.redraw(true)
			}
		}
		`f` {
			n := a.cmd_line('mkfile: ', '')
			if n != '' {
				os.write_file(os.join_path(a.pwd, n), '') or {}
				a.redraw(true)
			}
		}
		`e` {
			a.redraw(true)
		}
		`g` {
			if a.scroll != 0 {
				a.scroll = 0
				a.redraw(false)
			}
		}
		`G` {
			if a.scroll != a.list_total {
				a.scroll = a.list_total
				a.redraw(false)
			}
		}
		`y`, `m`, `d`, `s`, `b` {
			a.mark_key(ch)
		}
		`Y`, `M`, `D`, `S`, `B` {
			a.mark_key(ch)
		}
		`x` {
			if a.scroll < a.list.len {
				p := a.list[a.scroll]
				st := getenv_def('FFF_STAT_CMD', 'stat')
				a.reset_terminal()
				os.system('${st} "${p}"')
				read_byte_timeout()
				a.setup_terminal()
				a.redraw(false)
			}
		}
		`X` {
			p := a.list[a.scroll]
			if os.is_file(p) {
				if os.is_executable(p) {
					os.system('chmod -x "${p}"')
				} else {
					os.system('chmod +x "${p}"')
				}
				a.status_line('')
			}
		}
		`i` {
			a.status_line('image preview not implemented in V port')
		}
		`:` {
			d := a.cmd_line('go: ', 'dirs')
			if d != '' {
				t := expand_tilde(d)
				if os.is_dir(t) {
					os.chdir(t) or {}
					a.redraw(true)
				}
			}
		}
		`~` {
			a.open_path(os.home_dir())
		}
		`t` {
			a.open_path(a.fff_trash)
		}
		`-` {
			if a.oldpwd != '' {
				a.open_path(a.oldpwd)
			}
		}
		else {
			if ch >= `1` && ch <= `9` {
				idx := ch - `1`
				if a.fav[idx] != '' {
					a.open_path(expand_tilde(a.fav[idx]))
				}
			}
		}
	}
}

fn (mut a App) handle_escape() {
	b1 := read_byte_timeout()
	if b1 == 0 {
		return
	}
	if b1 != `[` && b1 != `O` {
		return
	}
	b2 := read_byte_timeout()
	if b2 == 0 {
		return
	}
	if b2 == `A` {
		a.handle_key(`k`)
		return
	}
	if b2 == `B` {
		a.handle_key(`j`)
		return
	}
	if b2 == `C` {
		if a.scroll < a.list.len {
			a.open_path(a.list[a.scroll])
		}
		return
	}
	if b2 == `D` {
		if a.search == 1 {
			a.open_path(a.pwd)
			a.search = 0
			return
		}
		if a.pwd != '/' {
			a.oldpwd = a.pwd
			a.find_previous = 1
			a.open_path(os.dir(a.pwd))
		}
		return
	}
}
