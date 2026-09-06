# Multi-line bash prompt. Sourced from ~/.bashrc via the ~/.bashrc.d loader.
#
#  2026-09-03 12:06:31.457  since 00:00:04.881  cmd 00:00:01.253  tim@host  ~/some/dir  branch +2 !1 ?3 ^1
# $
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
    # Truecolor "38;2;<fg rgb>;48;2;<bg rgb>". \[ \] marks them zero-width
    # for readline. Hue lives in the background, each held near L*=13 so the
    # segments stay equally dark yet separable. Channel values differ wildly
    # per hue only because blue carries 7% of luminance against yellow's 93%.
    # Text is one dim grey throughout: dim red on a visibly red background
    # cannot reach a usable contrast ratio at any intensity.
    # Black clock, red timers (cmd lighter than since), grey identity,
    # blue path, yellow git. Red text is reserved for an unclean tree.
    local r='\[\033[0m\]'
    local c_time='\[\033[38;2;199;199;199;48;2;0;0;0m\]'
    local c_wall='\[\033[38;2;199;199;199;48;2;61;0;0m\]'
    local c_user='\[\033[38;2;199;199;199;48;2;34;34;34m\]'
    local c_dir='\[\033[38;2;199;199;199;48;2;0;0;128m\]'
    local c_git='\[\033[38;2;199;199;199;48;2;35;35;0m\]'
    local c_gitd='\[\033[38;2;246;91;91;48;2;35;35;0m\]'
    local c_cmd='\[\033[38;2;199;199;199;48;2;93;0;0m\]'

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
        seg_git="${c} ${label}${marks}${state} ${r}"
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
    PS1="${title}${c_time} ${stamp} ${r}"
    PS1+="${c_wall} since ${wall_time} ${r}"
    PS1+="${c_cmd} cmd ${cmd_time} ${r}"
    PS1+="${c_user} \u@\h ${r}"
    PS1+="${c_dir} \w ${r}"
    PS1+="${seg_git}"
    PS1+="\n\$ "
}
PROMPT_COMMAND=__ccp_prompt
