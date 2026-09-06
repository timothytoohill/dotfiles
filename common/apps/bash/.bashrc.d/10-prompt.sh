# Three-line bash prompt. Sourced from ~/.bashrc via the ~/.bashrc.d loader.
#
# 2026-09-03 12:06:31.457 since 00:00:04.881 cmd 00:00:01.253
# tim@host:~/some/dir (branch +2 !1 ?3 ^1)
# $
#
# Line 1 is timing. Line 2 is Ubuntu's stock prompt unchanged -- same colours,
# same \u@\h:\w layout, same chroot prefix -- with a git segment appended.
# Line 3 is the input line, kept empty so long commands start at column 0.
#
# Git markers: +staged !unstaged ?untracked xconflict ^ahead vbehind, plus
# REBASE/MERGE/CHERRY/REVERT/BISECT when an operation is in flight. The
# segment turns red when the tree is unclean, and shows :<sha> when detached.

# DEBUG fires just before every command. The guard keeps the timestamp of the
# *first* command after a prompt, so pipelines/lists measure end-to-end.
__ccp_timer_start() {
    [[ -n ${__ccp_cmd_start:-} ]] || __ccp_cmd_start=$EPOCHREALTIME
}
trap '__ccp_timer_start' DEBUG

# $1 = destination variable, $2 = microseconds -> HH:MM:SS.sss
__ccp_hms() {
    local ms=$(( $2 / 1000 ))
    printf -v "$1" '%02d:%02d:%02d.%03d' \
        "$(( ms / 3600000 ))" "$(( ms / 60000 % 60 ))" \
        "$(( ms / 1000 % 60 ))" "$(( ms % 1000 ))"
}

__ccp_prompt() {
    local now=$EPOCHREALTIME
    # "1788436798.654028" -> integer microseconds. 10# stops the zero-padded
    # fraction being parsed as octal.
    local now_us=$(( ${now%.*} * 1000000 + 10#${now#*.} ))

    # --- palette -------------------------------------------------------
    # \[ \] marks every sequence zero-width for readline.
    #
    # Line 1 is truecolor "38;2;<fg rgb>;48;2;<bg rgb>" blocks. Hue lives in
    # the background, each held near L*=13 so the segments stay equally dark
    # yet separable. Channel values differ wildly per hue only because blue
    # carries 7% of luminance against yellow's 93%. Text is one dim grey
    # throughout: dim red on a visibly red background cannot reach a usable
    # contrast ratio at any intensity. Black clock, red timers, cmd lighter
    # than since.
    #
    # Line 2 reuses Ubuntu's stock codes exactly: 01;32 identity, 01;34 path.
    # Those are bold text on the default background, so git matches that
    # style rather than the blocks above.
    #
    # Git is supplementary, so it takes the normal-intensity yellow (#C4A000,
    # relative luminance 0.37) rather than the bright one (#FCE94F, 0.79).
    # Bright yellow is the most luminous slot in the palette -- 2.4x the path
    # blue it sits beside -- so it read as the loudest thing on the line while
    # carrying the least important information. Normal yellow lands next to
    # that blue (0.33), so the segment sits with the path rather than over it.
    #
    # Unclean keeps the bright red: at 0.20 it is already the dimmest colour
    # here, and it is the one state that has to catch the eye. Its weight
    # buys salience, not brightness.
    local r='\[\033[0m\]'
    local c_time='\[\033[38;2;199;199;199;48;2;0;0;0m\]'
    local c_wall='\[\033[38;2;199;199;199;48;2;61;0;0m\]'
    local c_cmd='\[\033[38;2;199;199;199;48;2;93;0;0m\]'
    local c_user='\[\033[01;32m\]'
    local c_dir='\[\033[01;34m\]'
    local c_git='\[\033[33m\]'
    local c_gitd='\[\033[01;31m\]'

    # --- segment: clock, YYYY-MM-DD HH:MM:SS.sss, US Eastern ------------
    # TZ must be a command prefix: a plain (or local) TZ= assignment is not
    # picked up by the printf builtin's strftime.
    local frac=${now#*.} stamp
    TZ=America/New_York \
        printf -v stamp '%(%Y-%m-%d %H:%M:%S)T.%s' "${now%.*}" "${frac:0:3}"

    # --- segment: runtime of the command that just finished -------------
    local start=${__ccp_cmd_start:-$now} cmd_time
    __ccp_hms cmd_time "$(( now_us - (${start%.*} * 1000000 + 10#${start#*.}) ))"
    unset __ccp_cmd_start

    # --- segment: wall time since the previous prompt was drawn ---------
    local wall_time
    __ccp_hms wall_time "$(( now_us - ${__ccp_last_prompt_us:-$now_us} ))"
    __ccp_last_prompt_us=$now_us

    # --- segment: git, omitted entirely outside a repo ------------------
    # One status call yields the branch, upstream tracking and every file
    # state. Parsing is pure bash, so this stays at one fork.
    local seg_git='' git_out
    git_out=$(git status --porcelain=v2 --branch 2>/dev/null)
    if [[ -n $git_out ]]; then
        local head='' oid='' ab='' line xy
        local staged=0 unstaged=0 untracked=0 conflict=0
        while IFS= read -r line; do
            case $line in
                '# branch.head '*) head=${line#\# branch.head } ;;
                '# branch.oid '*)  oid=${line#\# branch.oid } ;;
                '# branch.ab '*)   ab=${line#\# branch.ab } ;;
                # "1"/"2" = tracked change, XY at offset 2: X staged, Y not.
                [12]' '*) xy=${line:2:2}
                          [[ ${xy:0:1} != . ]] && (( ++staged ))
                          [[ ${xy:1:1} != . ]] && (( ++unstaged )) ;;
                'u '*)    (( ++conflict )) ;;
                '? '*)    (( ++untracked )) ;;
            esac
        done <<< "$git_out"

        # Porcelain v2 carries no in-progress marker, so merge/rebase has to
        # come from the git dir. Second fork, only inside a repo.
        local gd state=''
        gd=$(git rev-parse --git-dir 2>/dev/null)
        if   [[ -d $gd/rebase-merge || -d $gd/rebase-apply ]]; then state=' REBASE'
        elif [[ -f $gd/MERGE_HEAD ]];                          then state=' MERGE'
        elif [[ -f $gd/CHERRY_PICK_HEAD ]];                    then state=' CHERRY'
        elif [[ -f $gd/REVERT_HEAD ]];                         then state=' REVERT'
        elif [[ -f $gd/BISECT_LOG ]];                          then state=' BISECT'
        fi

        # +staged !unstaged ?untracked xconflict ^ahead vbehind
        local marks=''
        (( staged ))    && marks+=" +$staged"
        (( unstaged ))  && marks+=" !$unstaged"
        (( untracked )) && marks+=" ?$untracked"
        (( conflict ))  && marks+=" x$conflict"
        if [[ -n $ab ]]; then
            local a=${ab%% *} b=${ab##* }
            (( ${a#+} )) && marks+=" ^${a#+}"
            (( ${b#-} )) && marks+=" v${b#-}"
        fi

        local label=$head
        [[ $head == '(detached)' ]] && label=":${oid:0:7}"

        # Red text for an unclean tree or an operation in flight. Ahead or
        # behind alone stays yellow: nothing is uncommitted.
        local c=$c_git
        if (( staged + unstaged + untracked + conflict )) || [[ -n $state ]]; then
            c=$c_gitd
        fi
        seg_git=" ${c}(${label}${marks}${state})${r}"
    fi

    # --- segment: terminal / tmux pane title ----------------------------
    # PS1 is rebuilt from scratch every prompt, which drops the OSC 0 title
    # escape Ubuntu's stock .bashrc installs, so re-emit it here. The match
    # is wider than stock's xterm*|rxvt*: inside tmux TERM is screen-256color
    # (see .tmux.conf "default-terminal"), which stock never matches, leaving
    # titles dead. This sets the *pane* title, which tmux's "set-titles on"
    # forwards to the outer terminal. tmux window names are unaffected --
    # allow-rename is off by default and "automatic-rename on" owns those.
    local title=''
    case $TERM in
        xterm*|rxvt*|screen*|tmux*|alacritty|foot*|ghostty*)
            title='\[\033]0;\u@\h: \w\a\]' ;;
    esac

    # --- assembly -------------------------------------------------------
    # Line 2 is Ubuntu's stock PS1 with the trailing "\$ " moved to line 3:
    #   ${debian_chroot:+($debian_chroot)}\[01;32m\]\u@\h\[00m\]:\[01;34m\]\w
    # debian_chroot is expanded here rather than left as a literal for bash to
    # expand later, so the prompt does not depend on the promptvars option.
    #
    # On line 1 the separating space leads each block rather than trailing it,
    # so it picks up the incoming background colour. That leaves the line flush
    # at both ends -- no pad before the timestamp, no stray coloured cell after
    # the last timer -- with exactly one space between blocks.
    PS1="${title}${c_time}${stamp}${r}"
    PS1+="${c_wall} since ${wall_time}${r}"
    PS1+="${c_cmd} cmd ${cmd_time}${r}"
    PS1+="\n${debian_chroot:+($debian_chroot)}"
    PS1+="${c_user}\u@\h${r}:${c_dir}\w${r}${seg_git}"
    PS1+="\n\$ "
}
PROMPT_COMMAND=__ccp_prompt
