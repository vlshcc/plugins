// fm — fast file manager (ported from bash to V / vsh).
module main

import os
import strings

#pkgconfig ncurses

#include <ncurses.h>

fn C.initscr() voidptr
fn C.endwin() int
fn C.refresh() int
fn C.getch() int
fn C.wmove(voidptr, int, int) int
fn C.mvwaddstr(voidptr, int, int, &char) int
fn C.wclrtoeol(voidptr) int
fn C.wclear(voidptr) int
fn C.werase(voidptr) int
fn C.wattroff(voidptr, int) int
fn C.wattron(voidptr, int) int
fn C.wattrset(voidptr, int) int
fn C.cbreak() int
fn C.noecho() int
fn C.keypad(voidptr, bool) int
fn C.nonl() int
fn C.curs_set(int) int
fn C.flushinp() int
fn C.def_prog_mode() int
fn C.reset_prog_mode() int
fn C.reset_shell_mode() int
fn C.COLOR_PAIR(int) int
fn C.getmaxy(voidptr) int
fn C.getmaxx(voidptr) int
fn C.start_color() int
fn C.use_default_colors() int
fn C.has_colors() bool
fn C.init_pair(int, int, int) int
fn C.intrflush(voidptr, bool) int
fn C.dup(int) int
fn C.dup2(int, int) int
fn C.close(int) int
fn C.getchar() int

pub const nc_a_reverse = 262144 // A_REVERSE
pub const nc_a_bold = 2097152 // A_BOLD

// KEY_* from ncurses.h (octal constants)
pub const nc_key_down = 258 // 0402
pub const nc_key_up = 259 // 0403
pub const nc_key_left = 260 // 0404
pub const nc_key_right = 261 // 0405
pub const nc_key_resize = 410 // 0632 KEY_RESIZE

pub fn nc_suspend_for_shell() {
	C.def_prog_mode()
	C.endwin()
	C.flushinp()
}

pub fn nc_resume_after_shell() {
	C.reset_prog_mode()
	C.refresh()
}

pub const nc_key_backspace = 263
pub const nc_key_enter = 343

const version = '2.2-v'

fn main() {
	if os.args.len >= 2 {
		match os.args[1] {
			'capabilities' {
				println('command fm')
				println('help')
				return
			}
			'run' {
				if os.args.len >= 3 && os.args[2] == 'fm' {
					mut args := []string{}
					if os.args.len > 3 {
						args = os.args[3..].clone()
					}
					fm_main(args)
					return
				}
			}
			'help' {
				println('fm — terminal file manager')
				println('Usage: fm [-v|-h|-p] [directory]')
				return
			}
			else {}
		}
	}
	fm_main(os.args[1..])
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
	fm_trash         string
	hidden           bool
	fav              [9]string
	last_cols        int
	last_lines       int
	nc_win           voidptr
	stdin_saved      int = -1
	ext_pair_cache   map[string]int
	next_ext_pair    int = 20
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
	ff := getenv_def('FM_FILE_FORMAT', '%f')
	if ff.contains('%f') {
		parts := ff.split('%f')
		a.file_pre = parts[0]
		a.file_post = if parts.len > 1 { parts[1..].join('%f') } else { '' }
	}
	mf := getenv_def('FM_MARK_FORMAT', ' %f*')
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
		a.fav[i] = getenv_def('FM_FAV${i + 1}', '')
	}
}

fn (mut a App) get_os_defaults() {
	a.opener = getenv_def('FM_OPENER', 'xdg-open')
	ost := getenv_def('OSTYPE', '')
	if ost.starts_with('darwin') {
		a.opener = 'open'
	}
}

fn parse_ls_sgr_fg(s string) int {
	if s == '' {
		return -1
	}
	parts := s.split(';')
	for p in parts {
		if p.len == 2 && (p[0] == `3` || p[0] == `4`) && p[1] >= `0` && p[1] <= `7` {
			return int(p[1] - `0`)
		}
	}
	for i := 0; i < parts.len; i++ {
		if parts[i] == '38' && i + 2 < parts.len && parts[i + 1] == '5' {
			n := parts[i + 2].int()
			return n % 8
		}
	}
	return -1
}

fn (mut a App) nc_init_color_pairs() {
	c1 := getenv_int('FM_COL1', 2) % 8
	c2 := getenv_int('FM_COL2', 1) % 8
	c3 := getenv_int('FM_COL3', 1) % 8
	c5 := getenv_int('FM_COL5', 0) % 8
	C.init_pair(1, c1, -1)
	C.init_pair(2, 6, -1)
	C.init_pair(3, 1, -1)
	C.init_pair(4, 2, -1)
	C.init_pair(5, 7, -1)
	C.init_pair(6, c3, -1)
	C.init_pair(7, c5, c2)
}

fn (mut a App) pair_for_ext(ext string) int {
	if ext in a.ext_pair_cache {
		return a.ext_pair_cache[ext]
	}
	if a.next_ext_pair >= 256 {
		return 5
	}
	code := a.ls_ext_map[ext] or { return 5 }
	mut fg := parse_ls_sgr_fg(code)
	if fg < 0 {
		fg = 7
	}
	pid := a.next_ext_pair
	a.next_ext_pair++
	C.init_pair(pid, fg, -1)
	a.ext_pair_cache[ext] = pid
	return pid
}

fn (mut a App) get_term_size() {
	if a.nc_win == 0 {
		return
	}
	a.columns = C.getmaxx(a.nc_win) + 1
	a.lines = C.getmaxy(a.nc_win) + 1
	a.last_cols = a.columns
	a.last_lines = a.lines
	a.max_items = if a.lines > 3 { a.lines - 3 } else { 1 }
}

fn (mut a App) check_resize() {
	oc := a.columns
	ol := a.lines
	a.get_term_size()
	if a.columns != oc || a.lines != ol {
		a.redraw(false)
	}
}

fn (mut a App) setup_terminal() {
	if os.is_atty(0) <= 0 {
		mut tty := os.open_file('/dev/tty', 'r') or {
			eprintln('fm: need a terminal (stdin is not a tty and /dev/tty could not be opened)')
			exit(1)
		}
		a.stdin_saved = C.dup(0)
		if a.stdin_saved < 0 {
			eprintln('fm: dup stdin failed')
			exit(1)
		}
		unsafe {
			C.dup2(tty.fd, 0)
		}
		os.fd_close(tty.fd)
	}
	w := C.initscr()
	if w == 0 {
		eprintln('fm: initscr failed')
		exit(1)
	}
	a.nc_win = w
	C.cbreak()
	C.noecho()
	C.keypad(a.nc_win, true)
	C.nonl()
	C.curs_set(0)
	C.intrflush(a.nc_win, false)
	if C.has_colors() {
		C.start_color()
		C.use_default_colors()
		a.nc_init_color_pairs()
	}
	a.get_term_size()
}

fn (mut a App) reset_terminal() {
	C.endwin()
	if a.stdin_saved >= 0 {
		C.dup2(a.stdin_saved, 0)
		C.close(a.stdin_saved)
		a.stdin_saved = -1
	}
}

fn (mut a App) nc_clear_list_area() {
	for y := 0; y < a.max_items; y++ {
		C.wmove(a.nc_win, y, 0)
		C.wclrtoeol(a.nc_win)
	}
}

fn (mut a App) clear_screen() {
	a.nc_clear_list_area()
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

fn (mut a App) nc_print_line(screen_y int, idx int) {
	if idx < 0 || idx >= a.list.len {
		return
	}
	item := a.list[idx]
	C.wmove(a.nc_win, screen_y, 0)
	C.wclrtoeol(a.nc_win)
	if item == 'empty' && a.list.len == 1 {
		C.wattrset(a.nc_win, C.COLOR_PAIR(5))
		C.mvwaddstr(a.nc_win, screen_y, 0, c'empty')
		C.wattrset(a.nc_win, 0)
		return
	}
	if item == '' {
		return
	}
	base := os.base(item)
	mut ext := if base.contains('.') && base != '.' && base != '..' {
		base.all_after_last('.')
	} else {
		''
	}
	mut pair := 5
	mut suf := ''
	if os.is_dir(item) {
		pair = 1
		suf = '/'
	} else if os.is_link(item) {
		target := os.real_path(item)
		if target == '' || !os.exists(target) {
			pair = 3
		} else {
			pair = 2
		}
	} else if os.is_file(item) {
		if os.is_executable(item) {
			pair = 4
		} else if a.ls_colors_on && ext != '' && ext != base {
			pair = a.pair_for_ext(ext)
		} else {
			pair = 5
		}
	}
	marked := a.marked_files[idx] == item
	mut attrs := int(0)
	if marked {
		attrs = C.COLOR_PAIR(6)
	} else {
		attrs = C.COLOR_PAIR(pair)
		if os.is_file(item) && os.is_executable(item) {
			attrs |= nc_a_bold
		}
	}
	if idx == a.scroll {
		attrs |= nc_a_reverse
	}
	C.wattrset(a.nc_win, attrs)
	disp := esc_name(base)
	if marked {
		line := '${a.file_pre}${a.mark_pre}${disp}${suf}${a.mark_post}${a.file_post}'
		C.mvwaddstr(a.nc_win, screen_y, 0, line.str)
	} else {
		line := '${a.file_pre}${disp}${suf}${a.file_post}'
		C.mvwaddstr(a.nc_win, screen_y, 0, line.str)
	}
	C.wattrset(a.nc_win, 0)
}

fn (mut a App) read_dir() {
	pwd := os.getwd()
	a.pwd = pwd
	print('\x1b]2;fm: ${pwd}\x07')
	os.flush()
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
	for i in scroll_start .. scroll_end {
		line_y := i - scroll_start
		a.nc_print_line(line_y, i)
	}
	a.y = scroll_new_pos
	C.refresh()
}

fn (mut a App) status_line(extra string) {
	row := a.lines - 2
	pwd_show := a.pwd
	mut mark_ui := ''
	if a.marked_files.len > 0 {
		mark_ui = '[${a.marked_files.len}] selected (${a.file_program.join(' ')}) [p] -> '
	}
	mut body := '(${a.scroll + 1}/${a.list_total + 1}) ${mark_ui}'
	if extra != '' {
		body += extra
	} else {
		body += pwd_show
	}
	if body.len > a.columns {
		body = body[..a.columns]
	}
	pad := ' '.repeat(a.columns)
	C.wattrset(a.nc_win, C.COLOR_PAIR(7))
	C.mvwaddstr(a.nc_win, row, 0, pad.str)
	C.mvwaddstr(a.nc_win, row, 0, body.str)
	C.wattrset(a.nc_win, 0)
	C.wmove(a.nc_win, a.lines - 1, 0)
	C.wclrtoeol(a.nc_win)
	C.refresh()
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

fn (mut a App) cmd_line(prompt string, mode string) string {
	mut reply := ''
	row := a.lines - 1
	C.curs_set(1)
	for {
		line := '${prompt}${reply}'
		C.wmove(a.nc_win, row, 0)
		C.wclrtoeol(a.nc_win)
		C.mvwaddstr(a.nc_win, row, 0, line.str)
		C.refresh()
		ch := C.getch()
		if ch == nc_key_resize {
			a.check_resize()
			continue
		}
		if ch == nc_key_backspace || ch == 127 || ch == 8 {
			if reply.len > 0 {
				reply = reply[..reply.len - 1]
			}
			continue
		}
		if ch == 27 {
			reply = ''
			break
		}
		if ch == `\n` || ch == `\r` || ch == nc_key_enter {
			break
		}
		if ch < 0 || ch > 255 {
			continue
		}
		reply += u8(ch).ascii_str()
		if mode == 'search' {
			a.do_search(reply)
		}
	}
	C.curs_set(0)
	C.wmove(a.nc_win, row, 0)
	C.wclrtoeol(a.nc_win)
	C.refresh()
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
				cache := '${getenv_def('XDG_CACHE_HOME', os.join_path(os.home_dir(), '.cache'))}/fm/opened_file'
				os.mkdir_all(os.dir(cache)) or {}
				os.write_file(cache, path) or {}
				a.reset_terminal()
				exit(0)
			}
			ed := getenv_def('VISUAL', getenv_def('EDITOR', 'vi'))
			nc_suspend_for_shell()
			os.system('${ed} "${path}"')
			nc_resume_after_shell()
			a.redraw(false)
			return
		}
		op := getenv_def('FM_OPENER', a.opener)
		nc_suspend_for_shell()
		os.system('nohup "${op}" "${path}" >/dev/null 2>&1 &')
		nc_resume_after_shell()
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
			cmd := getenv_def('FM_TRASH_CMD', '')
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
		a.redraw(false)
	}
	a.status_line('')
}

fn (mut a App) paste() {
	if a.marked_files.len == 0 {
		return
	}
	nc_suspend_for_shell()
	print('fm: Running ${a.file_program[0]}\n')
	if a.file_program[0] == 'bulk_rename' {
		a.bulk_rename()
		nc_resume_after_shell()
		a.marked_files.clear()
		a.redraw(true)
		return
	}
	if a.file_program[0] == 'trash' {
		a.do_trash()
		nc_resume_after_shell()
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
	nc_resume_after_shell()
	a.marked_files.clear()
	a.redraw(true)
}

fn (mut a App) do_trash() {
	print('Trash [y/n]? ')
	os.flush()
	b := C.getchar()
	print('\n')
	if b != `y` && b != `Y` {
		return
	}
	cmd := getenv_def('FM_TRASH_CMD', '')
	if cmd != '' {
		mut parts := [cmd]
		for _, p in a.marked_files {
			parts << p
		}
		os.system(parts.join(' '))
		return
	}
	tr := a.fm_trash
	os.mkdir_all(tr) or {}
	for _, p in a.marked_files {
		dest := os.join_path(tr, os.base(p))
		os.system('mv -f "${p}" "${dest}"')
	}
}

fn (mut a App) bulk_rename() {
	cache_root := getenv_def('XDG_CACHE_HOME', os.join_path(os.home_dir(), '.cache'))
	rf := os.join_path(cache_root, 'fm/bulk_rename')
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
	lvl := getenv_int('FM_LEVEL', 0)
	os.setenv('FM_LEVEL', '${lvl + 1}', true)
	nc_suspend_for_shell()
	os.system('cd "${a.pwd}" && "${sh}"')
	nc_resume_after_shell()
	a.redraw(true)
}

fn fm_main(user_args []string) {
	mut a := App{}
	mut start_dir := ''
	mut i := 0
	for i < user_args.len {
		arg := user_args[i]
		match arg {
			'-v' {
				println('fm ${version}')
				return
			}
			'-h' {
				println('fm ${version}')
				println('Usage: fm [-v|-h|-p] [directory]')
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
	a.fm_trash = getenv_def('FM_TRASH', os.join_path(data_home, 'fm/trash'))
	cache := getenv_def('XDG_CACHE_HOME', os.join_path(os.home_dir(), '.cache'))
	os.mkdir_all(os.join_path(cache, 'fm')) or {}
	os.mkdir_all(a.fm_trash) or {}
	if getenv_int('FM_LS_COLORS', 1) == 1 {
		a.parse_ls_colors()
	}
	a.hidden = getenv_int('FM_HIDDEN', 0) == 1
	defer {
		a.reset_terminal()
	}
	a.setup_terminal()
	a.redraw(true)
	for {
		ch := C.getch()
		if ch == nc_key_resize {
			a.check_resize()
			continue
		}
		if ch == nc_key_up {
			a.handle_key(`k`)
			continue
		}
		if ch == nc_key_down {
			a.handle_key(`j`)
			continue
		}
		if ch == nc_key_left {
			a.key_left()
			continue
		}
		if ch == nc_key_right {
			a.key_right()
			continue
		}
		if ch >= 0 && ch <= 255 {
			a.handle_key(u8(ch))
		}
	}
}

fn (mut a App) key_left() {
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

fn (mut a App) key_right() {
	if a.scroll < a.list.len {
		a.open_path(a.list[a.scroll])
	}
}

fn (mut a App) handle_key(ch u8) {
	match ch {
		`q` {
			cdfile := getenv_def('FM_CD_FILE', os.join_path(getenv_def('XDG_CACHE_HOME',
				os.join_path(os.home_dir(), '.cache')), 'fm/.fm_d'))
			if getenv_int('FM_CD_ON_EXIT', 1) == 1 {
				os.mkdir_all(os.dir(cdfile)) or {}
				os.write_file(cdfile, a.pwd) or {}
			}
			a.reset_terminal()
			exit(0)
		}
		`j` {
			if a.scroll < a.list_total {
				a.scroll++
				a.redraw(false)
			}
		}
		`k` {
			if a.scroll > 0 {
				a.scroll--
				a.redraw(false)
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
				st := getenv_def('FM_STAT_CMD', 'stat')
				nc_suspend_for_shell()
				os.system('${st} "${p}"')
				C.getchar()
				nc_resume_after_shell()
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
			a.open_path(a.fm_trash)
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

// csi_final_byte_from_tail returns the CSI/SS3 final byte (e.g. C in "1;5C"). Used by tests.
fn csi_final_byte_from_tail(tail []u8) u8 {
	for b in tail {
		if b >= 0x40 && b <= 0x7e {
			return b
		}
	}
	return 0
}
