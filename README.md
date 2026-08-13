# amp-runner

`amp-runner` keeps one headless [Amp](https://ampcode.com/) runner alive per project. It uses launchd on macOS and the systemd user manager on Linux (including Omarchy/Arch).

## Install

Amp must already be executable at `~/.amp/bin/amp`. To use another executable, set `AMP_RUNNER_AMP_BIN` when installing and whenever running the CLI.

```sh
git clone https://github.com/yjsoon/amp-runner.git
cd amp-runner
./install.sh
./install.sh --allowed-root "$HOME/Developer" --allowed-root "/Volumes/Work Projects"
```

The installer writes the CLI to `${PREFIX:-$HOME/.local}/bin/amp-runner`, with mode `0700`. It never starts a runner. With no `--allowed-root`, a new installation allows `$HOME/Developer`; an existing configuration is preserved. Supplying one or more roots replaces the configuration with their canonical paths.

## Use

```sh
amp-runner ensure "$HOME/Developer/example" --repo https://github.com/example/example.git
amp-runner start                    # current directory
amp-runner start "/path/to/project"
amp-runner status
amp-runner list
amp-runner logs --follow
amp-runner stop
```

`start`, `status`, `stop`, and `logs` accept a project directory. Paths use their physical `pwd -P` identity, so a symlink and its target refer to the same runner.

`ensure` takes exactly one directory followed by `--repo` and one Git URL, in that order. It verifies a matching checkout or clones an absent destination through a private sibling temporary directory, then starts or reuses the runner:

```sh
amp-runner ensure "/path/to/project" --repo git@github.com:example/project.git
```

An existing checkout is accepted only when the destination is its exact worktree root and `remote.origin.url` matches. Comparison removes only trailing `/` characters and one trailing `.git`; SSH and HTTPS URLs remain distinct. `ensure` never fetches, pulls, checks out, resets, or changes a remote. It refuses symlink destinations, files, unrelated nonempty directories, mismatched origins, and paths outside the allowed roots. An existing empty destination may be replaced by the same temporary-clone-and-rename flow. Clone failure removes only that known temporary path and leaves the destination absent.

## Configuration

Allowed roots are stored at `${XDG_CONFIG_HOME:-$HOME/.config}/amp-runner/allowed-roots`. The file contains one absolute directory per nonblank, non-comment line:

```text
# Personal projects
/Users/example/Developer
/Volumes/Work Projects
```

Edit it directly or rerun `install.sh` with `--allowed-root`. Roots and requested projects are canonicalised before comparison; an exact root and its descendants are accepted. The file is data, never shell code.

## Platforms and behaviour

- Both platforms require `git`.
- macOS requires `launchctl`, `lockf`, `lsof`, `plutil`, and `shasum`.
- Linux requires systemd user services, `systemctl`, `flock`, `readlink`, and `sha256sum`. User lingering is optional; without it, runners begin with the user's login session.
- Service processes receive only `HOME`, a fixed `PATH`, and `LANG=en_US.UTF-8` through `/usr/bin/env -i`.
- Services restart after 10 seconds and return at the next user session until stopped.
- Runner identity is a SHA-256 hash of the canonical project path. Display IDs contain a host slug, project slug, and 12 hash characters, and never exceed 63 characters.
- State, logs, metadata, and generated service files are private (`0700` directories and `0600` files). macOS uses `~/Library/Application Support/AmpRunners` and `~/Library/Logs/AmpRunners`; Linux uses `${XDG_STATE_HOME:-$HOME/.local/state}/amp-runner`.
- Before starting, the CLI checks Amp PID files in `~/.cache/amp/pids` and verifies the process working directory. A matching runner that is not managed by this tool is reported and left untouched.
- Per-project locks serialise service changes; a global lock prevents ensure/start/stop/uninstall races.

## Uninstall

```sh
./uninstall.sh
./uninstall.sh --force
```

Uninstall refuses while managed services are active. `--force` stops only services recorded in amp-runner's validated private metadata. It then removes the installed CLI, its recorded services, state and logs, and the allowed-roots configuration. Unrecognised state is left in place. It does not remove Amp or touch unmanaged Amp runners.

## Test

Tests use temporary homes and a test-only metadata/service-generation mode. In this mode, `ensure` prepares and verifies real local Git repositories but skips launchd, systemd, and Amp.

```sh
bash -n amp-runner install.sh uninstall.sh tests/run.sh
bash tests/run.sh
```

## Licence

MIT © 2026 Yingjie Soon
