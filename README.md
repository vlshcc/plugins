# vlsh plugins

This is the official plugin repository for [vlsh](https://github.com/vlshcc/vlsh) — a fast, hackable Unix shell written in V.

## What is this?

vlsh has a built-in plugin system that lets anyone extend the shell without touching the core binary. Plugins are plain V source files (`.v`) that vlsh compiles automatically on startup (requires `v` in PATH). The compiled binaries are cached in `~/.vlsh/plugins/.bin/` and reused on subsequent launches.

This repository is the central collection of community plugins that can be browsed and installed directly from within vlsh using the built-in `plugins` command.

## Managing plugins

vlsh's `plugins` built-in command integrates with this repository:

```
plugins remote          # browse plugins available in this repository
plugins search <query>  # search plugins by name or description
plugins install <name>  # download a plugin from this repository
plugins update [name]   # update one or all installed plugins to the latest version
plugins list            # list locally installed plugins with their versions
plugins enable <name>   # activate a plugin
plugins disable <name>  # deactivate a plugin without deleting it
plugins reload          # recompile all plugins
plugins delete <name>   # remove a plugin
```

When you run `plugins install`, vlsh fetches the plugin source from this repository into `~/.vlsh/plugins/<name>/<version>/`, then compiles and activates it. The `~/.vlsh/plugins/` and `~/.vlsh/plugins/.bin/` directories are created automatically on startup if they do not exist.

## Plugin capabilities

Each plugin is a self-contained V program that responds to arguments passed by vlsh. A plugin declares its capabilities by printing one token per line when called with `capabilities`. It can provide any combination of the following:

| Capability | Argument vlsh calls | Description |
|---|---|---|
| `command <name>` | `run <command> [args…]` | Registers a new shell command |
| `prompt` | `prompt` | Contributes a line of text displayed above the `- ` prompt |
| `pre_hook` | `pre_hook <cmdline>` | Called before every command runs |
| `post_hook` | `post_hook <cmdline> <exit_code>` | Called after every command finishes |
| `output_hook` | `output_hook <cmdline> <exit_code> <output>` | Called after every command with its captured stdout |
| `completion` | `complete <input_line>` | Provides tab-completion candidates for the current input |
| `mux_status` | `mux_status` | Contributes text to the multiplexer status bar |

### Hook details

**`pre_hook`** — vlsh calls `<binary> pre_hook <cmdline>` before executing any command. The full input line is passed as the third argument. Output from the plugin is ignored.

**`post_hook`** — vlsh calls `<binary> post_hook <cmdline> <exit_code>` after a command finishes. The exit code is passed as the fourth argument. Output from the plugin is ignored.

**`output_hook`** — vlsh calls `<binary> output_hook <cmdline> <exit_code> <output>` after a command finishes, passing the command's captured stdout as the fifth argument. Stdout is captured for pipe-chain commands and the built-in `echo` command; interactive programs that require a TTY are not captured.

**`complete`** — vlsh calls `<binary> complete <input_line>` when the user presses Tab. The plugin should print replacement candidates one per line (each being the full replacement for the input, not just the suffix). Plugin completions are consulted before the built-in file/directory fallback.

**`mux_status`** — vlsh calls `<binary> mux_status` roughly once per second and displays the output as centered text in the multiplexer status bar. Keep the output short and avoid trailing newlines.

**`prompt`** — vlsh calls `<binary> prompt` before each prompt is drawn and prints the returned line above the `- ` prompt line. Return an empty string (or print nothing) when the plugin has nothing to show.

## Repository layout

Each plugin lives in its own directory. The directory name is the plugin name:

```
<plugin-name>/
├── DESC          # plugin metadata (TOML)
└── v1.0.0/
    └── <plugin-name>.v   # source for version 1.0.0
```

The `DESC` file contains the following TOML fields:

| Field | Description |
|---|---|
| `name` | Plugin name (matches the directory name) |
| `author` | Author's full name |
| `email` | Author's e-mail address |
| `description` | Short description of what the plugin does |

Version directories follow [Semantic Versioning](https://semver.org/) with a `v` prefix (e.g. `v1.0.0`, `v1.2.3`). When multiple version directories are present, `plugins install` picks the highest semver automatically.

## Plugins in this repository

| Plugin | Description |
|---|---|
| `hello_plugin` | A minimal example plugin demonstrating all capabilities — a good starting point for writing your own |
| `git` | Shows the current git branch and short commit hash above the prompt, with configurable colours via `~/.vlshrc` |
| `git_mood` | Shows an emoji above the prompt indicating whether the git working tree is clean |
| `ssh_hosts` | Provides tab-completion for `ssh` commands using hostnames from `~/.ssh/config` and `~/.ssh/known_hosts` |
| `v_man` | Adds a `vman <module>` command that fetches and displays V module documentation from [modules.vlang.io](https://modules.vlang.io/) |
| `hist` | Captures terminal output after every command via tmux and stores it in `~/.vlsh/hist_output.txt` |
| `share` | Uploads any text file to dpaste.com and prints the resulting URL |

## Writing a plugin

Copy `hello_plugin/v1.0.0/hello_plugin.v` as a starting point. A plugin must handle at minimum the `capabilities` argument and whichever capability arguments it declares.

### Full protocol reference

```
your_plugin capabilities
```
Print one capability token per line. vlsh reads this on startup to know what to call.

```
your_plugin run <command> [args…]
```
Execute a registered command. Only called if the plugin declared `command <name>`.

```
your_plugin prompt
```
Print a single line shown above the `- ` prompt. Print nothing to show no line.

```
your_plugin pre_hook <cmdline>
```
Notification before a command runs. `cmdline` is `os.args[2]`.

```
your_plugin post_hook <cmdline> <exit_code>
```
Notification after a command finishes. `cmdline` is `os.args[2]`, `exit_code` is `os.args[3]`.

```
your_plugin output_hook <cmdline> <exit_code> <output>
```
Called after a command with its captured stdout. `output` is `os.args[4]`.

```
your_plugin complete <input_line>
```
Print full replacement candidates one per line. `input_line` is `os.args[2]`.

```
your_plugin mux_status
```
Print a short string to display in the mux status bar. Called roughly once per second.

### Minimal example

```v
module main

import os

fn main() {
    op := if os.args.len > 1 { os.args[1] } else { '' }
    match op {
        'capabilities' {
            println('command hello')
            println('prompt')
            println('pre_hook')
            println('post_hook')
            println('output_hook')
            println('completion')
            println('mux_status')
        }
        'run' {
            cmd := if os.args.len > 2 { os.args[2] } else { '' }
            if cmd == 'hello' {
                name := if os.args.len > 3 { os.args[3] } else { 'world' }
                println('Hello, ${name}!')
            }
        }
        'prompt' {
            println('[ my plugin ]')
        }
        'pre_hook' {
            // os.args[2] is the full command line
        }
        'post_hook' {
            // os.args[2] = cmdline, os.args[3] = exit code
        }
        'output_hook' {
            // os.args[2] = cmdline, os.args[3] = exit code, os.args[4] = stdout
        }
        'complete' {
            input := if os.args.len > 2 { os.args[2] } else { '' }
            if input.starts_with('hello ') {
                println('hello world')
                println('hello vlsh')
            }
        }
        'mux_status' {
            println('my status')
        }
        else {}
    }
}
```

### Tips

- Only declare capabilities you actually use. vlsh calls every declared hook on every command, so unused hooks add overhead.
- `mux_status` is polled frequently — keep the implementation fast and avoid blocking I/O.
- `output_hook` does not fire for interactive programs (editors, pagers, etc.) that require a TTY.
- `complete` receives the full input line, not just the last word. Return full replacement strings, not suffixes.
- Colours in `prompt` output can be emitted as ANSI escape codes; vlsh passes them through as-is.
- Style colours for `~/.vlshrc` follow the pattern `key=R,G,B` (e.g. `style_git_bg=44,59,71`).

## Contributing

Pull requests are welcome! To add your plugin to this repository:

1. Fork this repository
2. Create a new directory named after your plugin (e.g. `my_plugin/`)
3. Add a `DESC` file with the required TOML fields (see layout above)
4. Add a `v1.0.0/` subdirectory containing your `.v` source file
5. Open a pull request with a short description of what your plugin does

Please keep plugins self-contained (a single `.v` file per version) and make sure they compile cleanly with a recent version of V.
