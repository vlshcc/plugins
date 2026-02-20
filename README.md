# vlsh plugins

This is the official plugin repository for [vlsh](https://github.com/vlshcc/vlsh) — a fast, hackable Unix shell written in V.

## What is this?

vlsh has a built-in plugin system that lets anyone extend the shell without touching the core binary. Plugins are plain V source files (`.v`) that vlsh compiles automatically on startup (requires `v` in PATH). The compiled binaries are cached next to the source files and reused on subsequent launches.

This repository is the central collection of community plugins that can be browsed and installed directly from within vlsh using the built-in `plugins remote` command.

## How vlsh uses this repository

vlsh's `plugins` built-in command integrates with this repository:

```
plugins remote          # browse plugins available in this repository
plugins install <name>  # download a plugin from this repository
plugins list            # list locally installed plugins
plugins enable <name>   # activate a plugin
plugins disable <name>  # deactivate a plugin
plugins reload          # recompile all plugins
plugins delete <name>   # remove a plugin
```

When you run `plugins install`, vlsh fetches the plugin source from this repository into `~/.vlsh/plugins/`, then compiles and activates it.

## Plugin capabilities

Each plugin is a self-contained V program that responds to arguments passed by vlsh. A plugin can provide any combination of the following capabilities:

| Capability | Description |
|---|---|
| `command <name>` | Registers a new shell command, invoked via `run <command> [args]` |
| `prompt` | Contributes a line of text displayed above the `- ` prompt |
| `pre_hook` | Called before every command runs, receives the full command line |
| `post_hook` | Called after every command finishes, receives the command line and exit code |
| `completion` | Provides tab-completion candidates for a given input line |

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

Version directories follow [Semantic Versioning](https://semver.org/) with a `v` prefix (e.g. `v1.0.0`, `v1.2.3`).

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

Copy `hello_plugin.v` as a starting point. A plugin must handle at minimum the `capabilities` argument and whichever capability arguments it declares. The protocol is:

```
your_plugin capabilities            # print one capability per line
your_plugin run <command> [args]    # run a registered command
your_plugin prompt                  # print a single line for the prompt area
your_plugin pre_hook  <cmdline>     # called before a command runs
your_plugin post_hook <cmdline> <exit_code>  # called after a command finishes
your_plugin complete  <input_line>  # print completion candidates, one per line
```

## Contributing

Pull requests are welcome! To add your plugin to this repository:

1. Fork this repository
2. Create a new directory named after your plugin (e.g. `my_plugin/`)
3. Add a `DESC` file with the required TOML fields (see layout above)
4. Add a `v1.0.0/` subdirectory containing your `.v` source file
5. Open a pull request with a short description of what your plugin does

Please keep plugins self-contained (a single `.v` file per version) and make sure they compile cleanly with a recent version of V.
