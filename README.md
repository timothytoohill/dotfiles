# dotfiles

Machine setup, reproducible from a clone.

```sh
git clone <this repo> ~/Development/dotfiles
cd ~/Development/dotfiles
./setup.sh
```

`setup.sh` reads `/etc/os-release`, resolves `<ID><major version>` to a
platform directory (Ubuntu 26.04 → `ubuntu26`), and hands off to that
platform's `setup.sh`. Pass a platform explicitly to override:
`./setup.sh ubuntu26`.

**Running it twice changes nothing the second time.** Every stage compares
desired state against actual state and acts only on the difference, so re-run
it freely after editing a config or adding a package.

Look before you leap:

```sh
./setup.sh --dry-run     # print every action, change nothing
./setup.sh --status      # report drift between the repo and $HOME
```

## Layout

```
setup.sh                      platform dispatcher
lib/setup-lib.sh              all the work, shared by every platform
common/
├── brew.txt                  formulae installed everywhere
└── apps/                     configs installed everywhere; mirror $HOME
    ├── bash/.bashrc.d/
    │   ├── 00-brew.sh        Homebrew environment
    │   └── 10-prompt.sh      three-line prompt with git status and timers
    └── tmux/
        ├── .tmux.conf        oh-my-tmux
        └── .tmux.conf.local  local overrides
ubuntu26/                     Ubuntu 26.04
├── setup.sh                  thin wrapper: sets EXPECTED_ID, sources the lib
├── apt.txt                   packages to install with apt
├── apt-remove.txt            packages to purge with apt
├── brew.txt                  formulae for this platform only
└── apps/                     optional; overrides common/apps per file
pop24/                        Pop!_OS 24.04, same shape
```

Every directory under an `apps/` tree is an app, and its contents mirror
`$HOME`:

| repo | installs to |
| --- | --- |
| `common/apps/tmux/.tmux.conf` | `~/.tmux.conf` |
| `common/apps/bash/.bashrc.d/10-prompt.sh` | `~/.bashrc.d/10-prompt.sh` |
| `pop24/apps/foo/.config/foo/x.toml` | `~/.config/foo/x.toml` |

Two `apps/` trees are read: `common/apps` first, then `<platform>/apps`. Where
both provide the same destination the platform wins, so a platform overrides a
shared config by simply placing its own copy at the same path.

Nesting works to any depth. Nothing outside `apps/` is ever installed, so the
package lists and `setup.sh` sit at the platform level without needing to be
excluded. `*.md` files inside app directories are skipped, so per-app notes are
free.

## Adding things

**A config file** — drop it in `<platform>/apps/<app>/` at the path it should
occupy relative to `$HOME`, creating `<app>/` if needed. Nothing to register.

**A package** — add a line to `apt.txt`, `brew.txt`, or `apt-remove.txt`. One
entry per line, `#` starts a comment. Fully-qualified brew names
(`user/tap/formula`) work; `brew install` taps automatically.

apt lists are per-platform, because package names and versions differ between
releases. Homebrew is not tied to the distro, so its list is shared in
`common/brew.txt`; a platform's own `brew.txt` is only for genuine additions,
and a formula in both is installed once.

Which list? **brew for anything that moves faster than the distro release
cycle, apt for anything the system integrates with.** The gap is not
theoretical — Ubuntu 26 ships `gh` 2.46 against Homebrew's 2.100, and does not
package `kubectl`, `helm`, `k9s`, `yq`, `uv` or `pnpm` at all. Conversely
`build-essential` must come from apt, because Homebrew on Linux compiles
against the system toolchain, and daemons like tailscale or the Docker engine
need apt's systemd integration rather than brew's CLI-only builds.

**A shell tweak** — add a numbered file to `apps/bash/.bashrc.d/`. It gets
sourced on shell start with no further wiring. Prefix controls order.

**A platform** — create a directory named `<ID><major VERSION_ID>` exactly as
`/etc/os-release` reports it, containing an executable `setup.sh` that sets
`PLATFORM_DIR`, `EXPECTED_ID` and `EXPECTED_NAME` then sources
`lib/setup-lib.sh`. Copy `pop24/setup.sh` as the template. The dispatcher finds
it automatically. Note the name comes from `ID`, not the marketing name:
Pop!_OS reports `ID=pop`, so the directory is `pop24`, not `popos24`.

## How `~/.bashrc` is handled

Ubuntu has no drop-in directory for bash, so setup appends one guarded block to
`~/.bashrc`:

```sh
# >>> dotfiles (ubuntu26) >>>
...sources ~/.bashrc.d/*.sh...
# <<< dotfiles (ubuntu26) <<<
```

That is the only edit ever made. Everything else lives in `~/.bashrc.d/`.

The block is rebuilt and appended at the end of the file on each run, which
matters because stock Ubuntu assigns `PS1` partway down and the prompt drop-in
has to load after it. The rebuild is diffed against the existing file, so an
already-correct `~/.bashrc` is not written at all — its mtime does not even
change. A duplicated block collapses back to one; a block with a missing end
marker is reported loudly rather than silently.

## Copies, not symlinks

Files are copied, so `$HOME` keeps working if this repo is moved or deleted.
The tradeoff is that the two can drift, which is what these are for:

```sh
./setup.sh --status   # what differs between the repo and $HOME
./setup.sh --adopt    # pull $HOME changes back into the repo, then commit
```

Anything about to be overwritten is first copied to
`~/.dotfiles-backup/<utc-timestamp>/`, preserving its path relative to `$HOME`.

## Options

```
-n, --dry-run     show what would happen, change nothing
    --only STAGE  run only STAGE (repeatable)
    --skip STAGE  skip STAGE (repeatable)
    --refresh     force 'apt-get update' even when the cache is fresh
    --status      report drift between the repo and $HOME, then exit
    --adopt       copy $HOME -> repo for tracked files, then exit
    --no-backup   overwrite without saving a backup
    --force       skip the Ubuntu check
-h, --help        show usage
```

Stages, in run order: `apt-remove apt brew brew-packages configs bashrc`.

## Notes

**Do not run as root.** Homebrew refuses to, and every config would land in
`/root`. Run as your normal user; you are prompted for a sudo password once,
only if a stage actually needs to touch packages, and the credential is held
open for the rest of the run. `./setup.sh --only configs` never prompts.

**`apt-remove` runs first, on purpose.** `needrestart` is what interrogates you
about restarting services during every apt transaction, so purging it before
the install stage keeps the rest of the run quiet. Packages are purged when
dpkg reports them `installed` *or* `config-files`, so a package previously
removed without `--purge` gets finished off.

**`apt-get update` is skipped when the package lists are under 24 hours old.**
Use `--refresh` to force it.

**opencode comes from `anomalyco/tap`, not homebrew-core.** The core formula is
maintained by the Homebrew team and lags — it was 1.18.20 while the tap was
already at 1.18.29. The tap is generated on every upstream release, and depends
on `ripgrep` alone where core also pulls in `node`.

**Hand-installed copies are removed once brew provides the tool.** Vendor
install scripts drop binaries into `~/.opencode`, `~/.local/bin` or
`/usr/local/bin`, all of which sit ahead of Homebrew on `PATH` — so the old
copy keeps winning and quietly goes stale, since nothing upgrades it. That is a
real failure mode, not a hypothetical: the hand-installed `bd` was two releases
behind the formula and shadowing it. The table is `SHADOWED` in
`ubuntu26/setup.sh`, currently covering opencode, uv, beads, helm, k3d and
kubectl.

Removal happens only after the brew-installed binary is present *and* executes,
so a failed install can never leave you with no copy at all. Only the exact
listed paths are touched. No application data is involved — opencode's sessions,
credentials and config live in `~/.local/share/opencode`,
`~/.local/state/opencode` and `~/.config/opencode`, none of which this goes
near.
