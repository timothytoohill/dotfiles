#!/usr/bin/env bash
#
# Ubuntu 26.04 machine setup.
#
# Idempotent by construction: every stage compares desired state against actual
# state and acts only on the difference. A second run reports "ok" for
# everything and writes nothing -- not even an mtime.
#
#   apt         installs only packages dpkg does not report as installed
#   apt-remove  purges only packages dpkg reports as installed/config-files
#   brew        skipped entirely when the binary is already present
#   configs     cmp(1) per file; identical files are not rewritten
#   bashrc      managed block is diffed before the file is touched at all
#
# Layout: each directory under apps/ is an "app" whose contents mirror $HOME.
# apps/tmux/.tmux.conf becomes ~/.tmux.conf. Nesting works, so
# apps/foo/.config/foo/x.toml becomes ~/.config/foo/x.toml. Everything outside
# apps/ -- this script, the package lists -- is never installed.

set -Eeuo pipefail

#==============================================================================
# Globals
#==============================================================================

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PLATFORM=$(basename "$SCRIPT_DIR")
APPS_DIR="$SCRIPT_DIR/apps"

BACKUP_ROOT="$HOME/.dotfiles-backup"
BACKUP_DIR=""                       # created lazily, one per run
LAST_BACKUP=""                      # set by backup_of()

BREW_FALLBACK="/home/linuxbrew/.linuxbrew"

BEGIN_MARK="# >>> dotfiles ($PLATFORM) >>>"
END_MARK="# <<< dotfiles ($PLATFORM) <<<"

ALL_STAGES=(apt-remove apt brew brew-packages configs bashrc)

# Options
DRY_RUN=false
DO_BACKUP=true
FORCE=false
REFRESH=false
MODE=install                        # install | status | adopt
declare -a ONLY=() SKIP=()

# Run state
SUDO_OK=false
SUDO_PID=""
declare -a WARNINGS=() FAILURES=()
declare -i N_OK=0 N_CREATED=0 N_UPDATED=0

#==============================================================================
# Output
#==============================================================================

if [[ -t 1 ]]; then
    C_RESET=$'\033[0m'; C_BOLD=$'\033[1m';   C_DIM=$'\033[2m'
    C_RED=$'\033[31m';  C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'
    C_BLUE=$'\033[34m'
else
    C_RESET=''; C_BOLD=''; C_DIM=''; C_RED=''; C_GREEN=''; C_YELLOW=''; C_BLUE=''
fi

hdr()  { printf '\n%s==>%s %s%s%s\n' "$C_BLUE" "$C_RESET" "$C_BOLD" "$*" "$C_RESET"; }
info() { printf '    %s%s%s\n' "$C_DIM" "$*" "$C_RESET"; }
ok()   { printf '    %sok%s        %s\n' "$C_DIM" "$C_RESET" "$*"; }
act()  { printf '    %s%-9s%s %s\n' "$C_GREEN" "$1" "$C_RESET" "${*:2}"; }
note() { printf '    %s%-9s%s %s\n' "$C_YELLOW" "$1" "$C_RESET" "${*:2}"; }
bad()  { printf '    %s%-9s%s %s\n' "$C_RED" "$1" "$C_RESET" "${*:2}"; }

warn() { note warn "$*"; WARNINGS+=("$*"); }
die()  { printf '\n%serror%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; exit 1; }

# Shorten $HOME to ~ for display.
tilde() { printf '%s' "${1/#$HOME/\~}"; }

# Execute unless --dry-run. Callers always emit their own act/note line first,
# so this stays silent and the output reads the same either way.
run() { $DRY_RUN && return 0; "$@"; }

#==============================================================================
# Arguments
#==============================================================================

usage() {
    cat <<EOF
Usage: ${0##*/} [options]

Set up this machine from the dotfiles repo. Safe to run repeatedly; a second
run makes no changes.

Options:
  -n, --dry-run     show what would happen, change nothing
      --only STAGE  run only STAGE (repeatable)
      --skip STAGE  skip STAGE (repeatable)
      --refresh     force 'apt-get update' even when the cache is fresh
      --status      report drift between the repo and \$HOME, then exit
      --adopt       copy \$HOME -> repo for tracked files, then exit
      --no-backup   overwrite without saving a backup
      --force       skip the Ubuntu check
  -h, --help        show this text

Stages: ${ALL_STAGES[*]}

Backups are written to $(tilde "$BACKUP_ROOT")/<utc-timestamp>/.
EOF
}

valid_stage() {
    local s
    for s in "${ALL_STAGES[@]}"; do [[ $s == "$1" ]] && return 0; done
    return 1
}

parse_args() {
    while (($#)); do
        case $1 in
            -n|--dry-run) DRY_RUN=true ;;
            --no-backup)  DO_BACKUP=false ;;
            --force)      FORCE=true ;;
            --refresh)    REFRESH=true ;;
            --status)     MODE=status ;;
            --adopt)      MODE=adopt ;;
            --only)
                [[ ${2:-} ]] || die "--only needs a stage name"
                valid_stage "$2" || die "unknown stage '$2'. Valid: ${ALL_STAGES[*]}"
                ONLY+=("$2"); shift ;;
            --skip)
                [[ ${2:-} ]] || die "--skip needs a stage name"
                valid_stage "$2" || die "unknown stage '$2'. Valid: ${ALL_STAGES[*]}"
                SKIP+=("$2"); shift ;;
            -h|--help)    usage; exit 0 ;;
            *)            usage >&2; die "unknown argument '$1'" ;;
        esac
        shift
    done
}

stage_enabled() {
    local s
    if ((${#ONLY[@]})); then
        for s in "${ONLY[@]}"; do [[ $s == "$1" ]] && return 0; done
        return 1
    fi
    for s in "${SKIP[@]}"; do [[ $s == "$1" ]] && return 1; done
    return 0
}

#==============================================================================
# Preflight and sudo
#==============================================================================

preflight() {
    if [[ $(id -u) -eq 0 ]]; then
        die "do not run as root.
    Homebrew refuses to run as root, and every config would be written to
    /root instead of your home directory. Run as your normal user; you will
    be prompted for a sudo password only when package management needs it."
    fi

    if [[ -r /etc/os-release ]]; then
        local id=''
        # shellcheck source=/dev/null
        id=$(. /etc/os-release && printf '%s' "${ID:-}")
        if [[ $id != ubuntu ]] && ! $FORCE; then
            die "expected Ubuntu but found '${id:-unknown}'. Use --force to override."
        fi
    fi
}

# Acquire sudo once, then hold the timestamp open for the rest of the run so
# later apt calls -- and Homebrew's own internal sudo -- do not re-prompt. The
# keepalive is tied to this PID and reaped by the EXIT trap.
need_sudo() {
    $SUDO_OK && return 0
    if $DRY_RUN; then SUDO_OK=true; return 0; fi

    if ! sudo -n true 2>/dev/null; then
        printf '    %sAdministrator privileges are required for package management.%s\n' \
            "$C_BOLD" "$C_RESET"
    fi
    # Returns non-zero rather than dying: a stage that cannot get sudo should
    # fail on its own terms and let the stages that need no privileges run.
    sudo -v || { warn "sudo authentication failed"; return 1; }

    ( while kill -0 "$$" 2>/dev/null; do sudo -n true 2>/dev/null; sleep 50; done ) &
    SUDO_PID=$!
    SUDO_OK=true
}

cleanup() {
    [[ -n $SUDO_PID ]] && kill "$SUDO_PID" 2>/dev/null
    return 0
}
trap cleanup EXIT

#==============================================================================
# Helpers
#==============================================================================

# Strip comments, trailing whitespace and blank lines from a package list.
read_list() {
    [[ -f $1 ]] || return 0
    sed -e 's/#.*//' -e 's/[[:space:]]*$//' -e '/^$/d' "$1"
}

pkg_status() { dpkg-query -W -f='${db:Status-Status}' "$1" 2>/dev/null || true; }

apt_get() {
    need_sudo || return 1
    run sudo env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a apt-get "$@"
}

# Copy a path into this run's backup directory, preserving its position
# relative to $HOME. Sets LAST_BACKUP.
backup_of() {
    LAST_BACKUP=""
    $DO_BACKUP || return 0
    [[ -e $1 ]] || return 0

    [[ -n $BACKUP_DIR ]] || BACKUP_DIR="$BACKUP_ROOT/$(date -u +%Y%m%dT%H%M%SZ)"
    local to="$BACKUP_DIR/${1#"$HOME"/}"
    run mkdir -p "${to%/*}"
    run cp -a "$1" "$to"
    LAST_BACKUP=$to
}

# Every directory under apps/ is an app.
app_dirs() {
    [[ -d $APPS_DIR ]] || return 0
    local d
    for d in "$APPS_DIR"/*/; do
        [[ -d $d ]] && printf '%s\n' "${d%/}"
    done
}

# Emit "<repo path>\t<home path>" for every tracked file.
tracked_files() {
    local app src
    while IFS= read -r app; do
        while IFS= read -r -d '' src; do
            printf '%s\t%s\n' "$src" "$HOME/${src#"$app"/}"
        done < <(find "$app" -type f ! -name '*.md' -print0 | sort -z)
    done < <(app_dirs)
}

#==============================================================================
# Stage: apt-remove
#==============================================================================

stage_apt_remove() {
    hdr "apt: remove"
    local -a want=() victims=()
    mapfile -t want < <(read_list "$SCRIPT_DIR/apt-remove.txt")
    ((${#want[@]})) || { info "nothing listed"; return 0; }

    local p
    for p in "${want[@]}"; do
        # "config-files" means removed but not purged: finish the job.
        case $(pkg_status "$p") in
            installed|config-files) victims+=("$p") ;;
            *)                      ok "$p (absent)" ;;
        esac
    done
    ((${#victims[@]})) || return 0

    act purge "${victims[*]}"
    apt_get purge -y "${victims[@]}" || { bad failed "apt-get purge"; return 1; }
    apt_get autoremove --purge -y    || warn "apt-get autoremove failed"
    return 0
}

#==============================================================================
# Stage: apt
#==============================================================================

# Treat lists newer than 24h as current so repeat runs stay fast.
apt_cache_fresh() {
    $REFRESH && return 1
    [[ -d /var/lib/apt/lists ]] || return 1
    [[ -n $(find /var/lib/apt/lists -maxdepth 0 -mmin -1440 2>/dev/null) ]]
}

stage_apt() {
    hdr "apt: install"
    local -a want=() missing=()
    mapfile -t want < <(read_list "$SCRIPT_DIR/apt.txt")
    ((${#want[@]})) || { info "nothing listed"; return 0; }

    local p
    for p in "${want[@]}"; do
        if [[ $(pkg_status "$p") == installed ]]; then ok "$p"; else missing+=("$p"); fi
    done
    ((${#missing[@]})) || return 0

    if apt_cache_fresh; then
        info "package lists are fresh; skipping update (--refresh to force)"
    else
        act update "apt-get update"
        apt_get update -qq || warn "apt-get update failed; using the cached lists"
    fi
    act install "${missing[*]}"
    apt_get install -y "${missing[@]}" || { bad failed "apt-get install"; return 1; }
    return 0
}

#==============================================================================
# Stage: brew
#==============================================================================

brew_bin() {
    if command -v brew >/dev/null 2>&1; then command -v brew
    elif [[ -x $BREW_FALLBACK/bin/brew ]]; then printf '%s\n' "$BREW_FALLBACK/bin/brew"
    else return 1
    fi
}

# Put brew on PATH inside *this* process so the next stage can use it during
# the same run that installed it.
load_brew() {
    local b
    b=$(brew_bin) || return 1
    eval "$("$b" shellenv bash)"
}

stage_brew() {
    hdr "homebrew"
    if brew_bin >/dev/null; then
        load_brew
        ok "installed ($(brew --version | head -1))"
        return 0
    fi

    local -a deps=(build-essential procps curl file git) missing=()
    local d
    for d in "${deps[@]}"; do
        [[ $(pkg_status "$d") == installed ]] || missing+=("$d")
    done
    if ((${#missing[@]})); then
        act deps "${missing[*]}"
        apt_get install -y "${missing[@]}"
    fi

    act install "Homebrew"
    $DRY_RUN && return 0

    need_sudo || return 1
    NONINTERACTIVE=1 /bin/bash -c \
        "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" \
        || { bad failed "Homebrew installer"; return 1; }
    load_brew || { bad failed "Homebrew installed but 'brew' is not on PATH"; return 1; }
    return 0
}

#==============================================================================
# Stage: brew-packages
#==============================================================================

# Hand-installed copies that Homebrew now provides. Installer scripts drop
# these into ~/.local/bin, /usr/local/bin or a private prefix, all of which sit
# ahead of Homebrew on PATH -- so the old binary keeps winning and silently
# goes stale. They are never upgraded by anything.
#
#   <formula>|<binary>|<path to remove>...
#
# The binary name is listed separately because it does not always match the
# formula (kubernetes-cli ships kubectl, beads ships bd). Only these exact
# paths are ever removed; user data is not involved. opencode is the clearest
# case -- its 239M private prefix holds no state at all, since sessions live
# in ~/.local/share/opencode and config in ~/.config/opencode.
SHADOWED=(
    "opencode|opencode|$HOME/.opencode"
    "uv|uv|$HOME/.local/bin/uv|$HOME/.local/bin/uvx"
    "beads|bd|$HOME/.local/bin/bd|$HOME/.local/bin/beads"
    "helm|helm|/usr/local/bin/helm"
    "k3d|k3d|/usr/local/bin/k3d"
    "kubernetes-cli|kubectl|/usr/local/bin/kubectl"
)

# Remove a shadowing copy only once brew's replacement is installed AND runs,
# so a failed install can never leave the tool missing altogether.
prune_shadowed() {
    local -n installed=$1
    local entry formula binary bin rc p
    local -a fields=() paths=()
    local prefix="${HOMEBREW_PREFIX:-$BREW_FALLBACK}"

    for entry in "${SHADOWED[@]}"; do
        IFS='|' read -r -a fields <<< "$entry"
        formula=${fields[0]}
        binary=${fields[1]}
        paths=("${fields[@]:2}")
        [[ -n ${installed[$formula]:-} ]] || continue

        bin="$prefix/bin/$binary"
        [[ -x $bin ]] || continue

        # 126/127 are "cannot execute" and "not found". Any other status means
        # the binary loaded fine, whatever it made of the argument -- which
        # matters because version flags are not consistent (helm wants
        # "version", kubectl wants "version --client").
        "$bin" --version >/dev/null 2>&1
        rc=$?
        if ((rc == 126 || rc == 127)); then
            warn "brew $formula is not runnable; leaving its old copy in place"
            continue
        fi

        # Every path for the entry, so a partially cleaned install finishes.
        #
        # -L as well as -e: these tables list a binary and the symlinks beside
        # it, and removing the binary first leaves those links dangling. -e
        # follows a symlink, so a dangling one tests false and would be skipped
        # forever -- which is exactly what stranded ~/.local/bin/beads once
        # ~/.local/bin/bd was gone.
        for p in "${paths[@]}"; do
            [[ -e $p || -L $p ]] || continue

            if [[ -w ${p%/*} ]]; then
                act removed "$(tilde "$p") (superseded by brew $formula)"
                run rm -rf "$p"
            elif need_sudo; then
                act removed "$(tilde "$p") (superseded by brew $formula)"
                run sudo rm -rf "$p"
            else
                warn "cannot remove $(tilde "$p") without sudo; it still shadows brew $formula"
            fi
        done
    done
}

stage_brew_packages() {
    hdr "brew packages"
    local -a want=()
    mapfile -t want < <(read_list "$SCRIPT_DIR/brew.txt")
    ((${#want[@]})) || { info "nothing listed"; return 0; }

    if ! load_brew 2>/dev/null; then
        warn "brew unavailable; skipping"
        return 0
    fi

    # "brew list" prints short names, so compare on the last path segment.
    local -A have=()
    local n
    while read -r n; do
        [[ -n $n ]] && have[$n]=1
    done < <(brew list --formula -1 2>/dev/null; brew list --cask -1 2>/dev/null)

    local spec
    for spec in "${want[@]}"; do
        if [[ -n ${have[${spec##*/}]:-} ]]; then
            ok "$spec"
            continue
        fi
        act install "$spec"
        if $DRY_RUN; then
            have[${spec##*/}]=1      # so prune_shadowed reports realistically
            continue
        fi
        if brew install "$spec"; then
            have[${spec##*/}]=1
        else
            FAILURES+=("brew install $spec")
            bad failed "brew install $spec"
        fi
    done

    prune_shadowed have
}

#==============================================================================
# Stage: configs
#==============================================================================

stage_configs() {
    hdr "configs"
    local src dest
    while IFS=$'\t' read -r src dest; do
        if [[ -f $dest ]] && cmp -s "$src" "$dest"; then
            ok "$(tilde "$dest")"
            N_OK+=1
            continue
        fi
        local existed=false
        [[ -e $dest ]] && { existed=true; backup_of "$dest"; }

        # Copy before reporting, so one unwritable destination is a warning
        # about that file rather than an abort that strands every file after
        # it -- and so the counters describe what actually happened.
        if ! { run mkdir -p "${dest%/*}" && run cp -a "$src" "$dest"; }; then
            warn "could not write $(tilde "$dest")"
            continue
        fi

        if $existed; then
            act updated "$(tilde "$dest")${LAST_BACKUP:+   backup: $(tilde "$LAST_BACKUP")}"
            N_UPDATED+=1
        else
            act created "$(tilde "$dest")"
            N_CREATED+=1
        fi
    done < <(tracked_files)

    if ((N_OK + N_CREATED + N_UPDATED == 0)); then
        info "no tracked files in $(tilde "$APPS_DIR")"
    fi
}

#==============================================================================
# Stage: bashrc
#==============================================================================

bashrc_block() {
    cat <<EOF
$BEGIN_MARK
# Managed by dotfiles. Do not edit between these markers -- the block is
# rewritten on every setup run. Add or change files in ~/.bashrc.d/ instead.
if [ -d "\$HOME/.bashrc.d" ]; then
  for __rc in "\$HOME"/.bashrc.d/*.sh; do
    [ -r "\$__rc" ] && . "\$__rc"
  done
  unset __rc
fi
$END_MARK
EOF
}

# Rebuild ~/.bashrc: drop any previous managed block and the legacy opencode
# PATH export, then append a fresh block at the end. Appending last matters --
# stock Ubuntu assigns PS1 partway down the file, and the prompt drop-in has to
# win. The result is diffed against the original, so an already-correct .bashrc
# is not written at all.
stage_bashrc() {
    hdr "bashrc"
    local rc="$HOME/.bashrc"
    local fresh=false

    if [[ ! -f $rc ]]; then
        fresh=true
        act created "$(tilde "$rc")"
        run touch "$rc"
        [[ -f $rc ]] || return 0
    fi

    local -a src=() out=()
    mapfile -t src < "$rc"

    local line i had_block=false in_block=false
    local -i dropped=0
    for ((i = 0; i < ${#src[@]}; i++)); do
        line=${src[i]}

        if [[ $line == "$BEGIN_MARK" ]]; then in_block=true; had_block=true; continue; fi
        if [[ $line == "$END_MARK" ]];   then in_block=false; continue; fi
        $in_block && continue

        # Legacy: "export PATH=~/.opencode/bin:$PATH" plus the "# opencode"
        # comment above it. opencode now comes from brew, whose bin directory
        # is already on PATH via ~/.bashrc.d/00-brew.sh.
        if [[ $line == *.opencode/bin* && $line == *PATH=* ]]; then
            dropped+=1
            if ((${#out[@]})) && [[ ${out[-1]} == '# opencode' ]]; then
                unset 'out[-1]'
            fi
            while ((${#out[@]})) && [[ -z ${out[-1]} ]]; do unset 'out[-1]'; done
            continue
        fi

        out+=("$line")
    done

    # A begin marker with no matching end means the file was hand-edited. We
    # cannot tell what was ours, so everything after it is dropped -- say so
    # loudly, since the backup is the only way back.
    if $in_block; then
        warn "unterminated managed block in $(tilde "$rc"): content after the
             begin marker was discarded. Recover it from the backup below."
    fi

    # One blank line separating the block from whatever precedes it, but not a
    # leading blank line when the file was empty.
    while ((${#out[@]})) && [[ -z ${out[-1]} ]]; do unset 'out[-1]'; done
    if ((${#out[@]})); then out+=(''); fi
    while IFS= read -r line; do out+=("$line"); done < <(bashrc_block)

    local tmp
    tmp=$(mktemp)
    printf '%s\n' "${out[@]}" >"$tmp"

    if cmp -s "$rc" "$tmp"; then
        rm -f "$tmp"
        ok "$(tilde "$rc") (loader current)"
        return 0
    fi

    if $DRY_RUN; then
        rm -f "$tmp"
        if $had_block; then act updated "$(tilde "$rc") loader block"
        else                act added   "$(tilde "$rc") loader block"; fi
        ((dropped)) && act removed "$dropped legacy opencode line(s)"
        return 0
    fi

    # Nothing worth preserving in a file this run just created.
    $fresh || backup_of "$rc"
    # Redirect, not mv: keeps the inode and permissions.
    if ! cat "$tmp" >"$rc"; then
        rm -f "$tmp"
        bad failed "could not write $(tilde "$rc")"
        return 1
    fi
    rm -f "$tmp"

    if $had_block; then act updated "$(tilde "$rc") loader block refreshed"
    else                act added   "$(tilde "$rc") loader block appended"; fi
    ((dropped)) && act removed "$dropped legacy opencode line(s) from $(tilde "$rc")"
    [[ -n $LAST_BACKUP ]] && info "backup: $(tilde "$LAST_BACKUP")"
    return 0
}

#==============================================================================
# Modes: status and adopt
#==============================================================================

mode_status() {
    hdr "configs: repo vs \$HOME"
    local src dest
    local -i same=0 diff=0 miss=0
    while IFS=$'\t' read -r src dest; do
        if [[ ! -e $dest ]];        then note missing "$(tilde "$dest")"; miss+=1
        elif cmp -s "$src" "$dest"; then ok "$(tilde "$dest")";           same+=1
        else                             bad differs "$(tilde "$dest")";  diff+=1
        fi
    done < <(tracked_files)
    printf '\n    %d same, %d differ, %d missing\n' "$same" "$diff" "$miss"

    hdr "bashrc"
    if grep -qxF "$BEGIN_MARK" "$HOME/.bashrc" 2>/dev/null; then
        ok "loader block present"
    else
        note missing "loader block absent from $(tilde "$HOME/.bashrc")"
    fi

    ((diff)) && info "run with --adopt to pull \$HOME changes back into the repo"
    return 0
}

mode_adopt() {
    hdr "adopt: \$HOME -> repo"
    local src dest
    while IFS=$'\t' read -r src dest; do
        if [[ ! -e $dest ]];        then note missing "$(tilde "$dest")"; continue; fi
        if cmp -s "$src" "$dest";   then ok "$(tilde "$dest")";           continue; fi
        act adopted "${src#"$SCRIPT_DIR"/}  <-  $(tilde "$dest")"
        run cp -a "$dest" "$src"
    done < <(tracked_files)
    info "review with: git -C ${SCRIPT_DIR%/*} diff"
    return 0
}

#==============================================================================
# Main
#==============================================================================

summary() {
    hdr "done"
    info "configs: $N_OK unchanged, $N_CREATED created, $N_UPDATED updated"
    [[ -n $BACKUP_DIR ]] && info "backups: $(tilde "$BACKUP_DIR")"

    if ((${#WARNINGS[@]})); then
        printf '\n'
        local w
        for w in "${WARNINGS[@]}"; do note warn "$w"; done
    fi

    if ((${#FAILURES[@]})); then
        printf '\n'
        local f
        for f in "${FAILURES[@]}"; do bad failed "$f"; done
        die "${#FAILURES[@]} step(s) failed"
    fi

    printf '\n'
    if $DRY_RUN; then
        info "dry run: nothing was changed"
    else
        info "start a new shell, or run: exec bash"
    fi
}

# Run one stage, recording rather than propagating a failure. Stages are
# independent -- deploying configs needs neither apt nor brew -- so one going
# wrong must not take the others down with it. Without this, a sudo timeout
# during package installs silently skipped every dotfile on the machine.
#
# Stages signal failure by returning non-zero explicitly, never by relying on
# errexit: bash disables errexit inside a function invoked from a && or ||
# list, so a bare failing command here would neither abort its stage nor be
# reported. Every fallible command in a stage is checked at its call site.
run_stage() {
    local name=$1 rc=0
    stage_enabled "$name" || return 0
    "stage_${name//-/_}" || rc=$?
    if ((rc)); then
        FAILURES+=("stage '$name' exited $rc")
        bad failed "stage '$name' exited $rc; continuing with the rest"
    fi
    return 0
}

main() {
    parse_args "$@"
    preflight

    case $MODE in
        status) mode_status; exit 0 ;;
        adopt)  mode_adopt;  exit 0 ;;
    esac

    $DRY_RUN && hdr "dry run: no changes will be made"

    # Configs first: they are fast, need no privileges and cannot fail for
    # reasons outside this repo, so the dotfiles land even if a package
    # source is unreachable. apt-remove still precedes apt, which is what
    # actually matters -- purging needrestart keeps the installs quiet.
    run_stage configs
    run_stage bashrc
    run_stage apt-remove
    run_stage apt
    run_stage brew
    run_stage brew-packages

    summary
}

main "$@"
