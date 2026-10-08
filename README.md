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
    │   ├── 10-prompt.sh      two-line prompt with git status and timers
    │   ├── 11-editor.sh      EDITOR=nvim
    │   └── 90-proto.sh       proto shims ahead of Homebrew on PATH
    ├── git/
    │   └── .gitconfig        shared settings; includes ~/.gitconfig.local
    └── tmux/
        ├── .tmux.conf        oh-my-tmux
        └── .tmux.conf.local  local overrides
ubuntu26/                     Ubuntu 26.04
├── setup.sh                  thin wrapper: sets EXPECTED_ID, sources the lib
├── apt.txt                   packages to install with apt
├── apt-remove.txt            packages to purge with apt
├── brew.txt                  formulae for this platform only
└── apps/                     optional; overrides common/apps per file
ubuntu24/                     Ubuntu 24.04 LTS, same shape
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

A package also belongs in a platform list when the release it ships is too old
to be interchangeable. `neovim` comes from apt on 26.04, which has 0.11.6, and
from brew on 24.04, which has only 0.9.5 — old enough that plugin
configurations written against 0.10+ will not load.

One thing else belongs in a platform list rather than the shared one: anything a
version manager on that machine also provides. `node@22` and `pnpm` sit in
`ubuntu26/brew.txt` and `ubuntu24/brew.txt` because pop24 runs proto, whose
shims already supply `node`, `npm`, `npx`, `pnpm` and `pnpx`. Two sources for
one binary leaves the winner to `PATH` order, which is how a project pinned to
pnpm 10 came to run pnpm 11. `90-proto.sh` keeps the shims in front, but that
is a mitigation — not installing the duplicate is the fix.

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
# >>> dotfiles >>>
...sources ~/.bashrc.d/*.sh...
# <<< dotfiles <<<
```

That is the only edit ever made. Everything else lives in `~/.bashrc.d/`.

The block is rebuilt and appended at the end of the file on each run. The
rebuild is diffed against the existing file, so an already-correct `~/.bashrc`
is not written at all — its mtime does not even change. A duplicated block
collapses back to one; a block with a missing end marker is reported loudly
rather than silently.

Appending last is about `PATH`, not the prompt. The prompt is set inside
`PROMPT_COMMAND`, which runs before every prompt and overwrites `PS1` whatever
position the block occupies. `PATH` is the part that is order-sensitive, and
`brew shellenv` in particular is not idempotent — it prepends unconditionally,
so re-running it jumps ahead of anything already in front of Homebrew. That is
why anything which must outrank Homebrew asserts itself from a later-numbered
drop-in such as `90-proto.sh`, rather than relying on where the block sits.

## How `~/.gitconfig` is handled

`common/apps/git/.gitconfig` installs to `~/.gitconfig` like any other config,
so every machine gets the same identity and defaults. It ends by including
`~/.gitconfig.local`, which is not tracked: settings for one machine go there,
and because the include comes last they override the shared ones. Git skips a
missing include silently, so a machine with nothing of its own needs no file.

`git config --global` writes to `~/.gitconfig`, and so do tools such as
`gh auth setup-git` and `git lfs install`. Since files are copied rather than
linked, those writes are drift: `--status` reports the file as differing, and
the next run replaces it, keeping a backup. A setting every machine should have
belongs in the repo — `--adopt`, review, commit. One for this machine alone
belongs in the local file, which `git config --file ~/.gitconfig.local` writes
directly.

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
    --upgrade-opencode
                  replace opencode V1 with V2 without asking
-h, --help        show usage
```

Stages, in run order: `configs bashrc apt-remove apt guest-agent brew brew-packages`.
Configs go first because they need no privileges and no network, so the
dotfiles land even when a package stage fails.

## Notes

**Do not run as root.** Homebrew refuses to, and every config would land in
`/root`. Run as your normal user; you are prompted for a sudo password once,
only if a stage actually needs to touch packages, and the credential is held
open for the rest of the run. `./setup.sh --only configs` never prompts.

**`apt-remove` runs before `apt`, on purpose.** `needrestart` is what interrogates you
about restarting services during every apt transaction, so purging it before
the install stage keeps the rest of the run quiet. Packages are purged when
dpkg reports them `installed` *or* `config-files`, so a package previously
removed without `--purge` gets finished off.

**`apt-get update` is skipped when the package lists are under 24 hours old.**
Use `--refresh` to force it.

**VMs get their hypervisor's guest agent.** The host uses it to shut the VM down
cleanly and see its IP addresses; Proxmox also uses it to freeze the filesystem
so backups and snapshots are consistent. The `guest-agent` stage asks
`systemd-detect-virt --vm` which hypervisor this is:

| detected | installs | covers |
| --- | --- | --- |
| `kvm`, `qemu` | `qemu-guest-agent` | Proxmox, or any other QEMU host |
| `vmware` | `open-vm-tools` | VMware |

Bare metal, containers (LXC, Docker) and other hypervisors are left alone.
Adding a hypervisor is one line in `stage_guest_agent`.

`qemu-guest-agent` also needs switching on from the Proxmox side, which setup
cannot do from inside the VM. When the agent's channel is missing, setup says
so: turn on **Options → QEMU Guest Agent** for the VM (or
`qm set <vmid> --agent 1`), then shut the VM down and start it from Proxmox.
The channel is virtual hardware added when Proxmox starts the VM, so a reboot
from inside the guest is not enough. Installing the agent first is harmless —
its service is tied to that channel and simply never runs without it. Check it
from the Proxmox host with `qm agent <vmid> ping`.

**opencode is V2, from `anomalyco/tap/opencode-v2`.** It is a separate formula
from V1 (`opencode`), only available from the upstream tap — homebrew-core has
no `opencode-v2`. It declares `conflicts_with "opencode"` because both ship a
binary named `opencode`, so Homebrew refuses to install it while V1 is present.
`brew install --dry-run` does not check that and will claim it installs
cleanly; only a real install enforces it.

Where there is no opencode, V2 is installed. Where V1 is found — from brew, or
from the install script in `~/.opencode` — setup **asks** before replacing it:

```
found     opencode V1 1.18.33 from brew; V2 replaces it
Upgrade opencode to V2? V1 is uninstalled first, and V2 migrates the
session database on its first launch; a backup is taken beforehand. [y/N]
```

The default is no, and with no terminal to ask on, V1 is kept with a warning
unless `--upgrade-opencode` is passed. The upgrade is one-way for your session
history, which is why it is never done by default. Both versions use the same
database, `~/.local/share/opencode/opencode.db`, and V2 migrates it in place on
first launch: at 2.0.19 that is ten schema migrations, one of them
`clear_v1_session_permission`. Sessions and messages survive, and V1 can still
list them afterwards, but the data V2 clears is gone.

On yes, setup:

1. backs up the database to `~/.dotfiles-backup/<utc-timestamp>/`, using
   SQLite's online backup because the file is usually open — including by the
   opencode session you might be running setup from, which it warns about;
2. uninstalls V1 with `HOMEBREW_NO_AUTOREMOVE`, since plain `brew uninstall`
   sweeps every orphaned dependency on the machine — fifteen formulae in
   testing — including `ripgrep`, which V2 needs;
3. installs V2, and if that fails, reinstalls V1 so the machine is never left
   without opencode.

An install-script copy of either version in `~/.opencode` is removed once
brew's V2 is installed and runs, as below.

**Hand-installed copies are removed once brew provides the tool.** Vendor
install scripts drop binaries into `~/.opencode`, `~/.local/bin` or
`/usr/local/bin`, all of which sit ahead of Homebrew on `PATH` — so the old
copy keeps winning and quietly goes stale, since nothing upgrades it. That is a
real failure mode, not a hypothetical: the hand-installed `bd` was two releases
behind the formula and shadowing it. The table is `SHADOWED` in
`lib/setup-lib.sh`, currently covering opencode (both major versions), uv,
beads, helm, k3d and kubectl.

Removal happens only after the brew-installed binary is present *and* executes,
so a failed install can never leave you with no copy at all. Only the exact
listed paths are touched. No application data is involved — opencode's sessions,
credentials and config live in `~/.local/share/opencode`,
`~/.local/state/opencode` and `~/.config/opencode`, none of which this goes
near.
