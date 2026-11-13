# cmux shell integration for bash

# Cache which send tool is available to avoid repeated PATH lookups.
_CMUX_SEND_TOOL=""
_cmux_detect_send_tool() {
    if command -v ncat >/dev/null 2>&1; then
        _CMUX_SEND_TOOL=ncat
    elif command -v socat >/dev/null 2>&1; then
        _CMUX_SEND_TOOL=socat
    elif command -v nc >/dev/null 2>&1; then
        _CMUX_SEND_TOOL=nc
    fi
}
# Detection deferred to after _cmux_fix_path (end of file).

# Present the signed capability inherited by every cmux-created terminal. This
# keeps detached reporters authorized after launchd or tmux reparents them.
_cmux_write_socket_payload() {
    local payload="$1"
    case "${CMUX_SOCKET_CAPABILITY:-}" in
        ""|*[[:space:]]*)
            printf '%s\n' "$payload"
            ;;
        *)
            printf '_cmux_capability_v1 %s %s\n' "$CMUX_SOCKET_CAPABILITY" "$payload"
            ;;
    esac
}

_cmux_send() {
    local payload="$1"
    if [[ -x /usr/bin/nc ]]; then
        # Apple's nc defines -N as a value-taking adaptive write timeout, not
        # OpenBSD's no-argument shutdown-after-EOF flag. Use the bounded form
        # directly and wait for cmux's response so ordered batches stay ordered.
        _cmux_write_socket_payload "$payload" | /usr/bin/nc -w 1 -U "$CMUX_SOCKET_PATH" >/dev/null 2>&1 || true
        return 0
    fi
    case "$_CMUX_SEND_TOOL" in
        ncat)
            _cmux_write_socket_payload "$payload" | ncat -w 1 -U "$CMUX_SOCKET_PATH" --send-only
            ;;
        socat)
            _cmux_write_socket_payload "$payload" | socat -T 1 - "UNIX-CONNECT:$CMUX_SOCKET_PATH" >/dev/null 2>&1
            ;;
        nc)
            if _cmux_write_socket_payload "$payload" | nc -N -U "$CMUX_SOCKET_PATH" >/dev/null 2>&1; then
                :
            else
                _cmux_write_socket_payload "$payload" | nc -w 1 -U "$CMUX_SOCKET_PATH" >/dev/null 2>&1 || true
            fi
            ;;
    esac
}

_cmux_detach_bg() {
    ( "$@" >/dev/null 2>&1 & ) >/dev/null 2>&1
}

_cmux_send_bg() {
    local payload="$1"
    if [[ "${_CMUX_IN_PREEXEC:-}" == "1" ]]; then
        {
            _cmux_send "$payload"
        } >/dev/null 2>&1 &
        disown
        return 0
    fi
    _cmux_detach_bg _cmux_send "$payload"
}

_cmux_start_tracked_bg() {
    local __pid_var="$1"
    shift
    local __pid_file="${TMPDIR:-/tmp}/cmux-bg-pid-$$-${RANDOM:-0}"
    local __pid=""
    (
        "$@" >/dev/null 2>&1 &
        printf '%s\n' "$!" >| "$__pid_file"
    )
    if [[ -r "$__pid_file" ]]; then
        IFS= read -r __pid < "$__pid_file" || __pid=""
        /bin/rm -f -- "$__pid_file" >/dev/null 2>&1 || true
    fi
    printf -v "$__pid_var" '%s' "$__pid"
}

_cmux_socket_is_unix() {
    [[ -n "$CMUX_SOCKET_PATH" && -S "$CMUX_SOCKET_PATH" ]]
}

_cmux_has_port_scan_transport() {
    _cmux_socket_is_unix
}

_cmux_restore_scrollback_once() {
    local path="${CMUX_RESTORE_SCROLLBACK_FILE:-}"
    [[ -n "$path" ]] || return 0
    unset CMUX_RESTORE_SCROLLBACK_FILE
    local token="${path##*/}"

    builtin printf '\033]1337;CurrentDir=kitty-shell-cwd://%s/.cmux/session-scrollback-replay/%s/start\007' "$HOSTNAME" "$token"

    if [[ -r "$path" ]]; then
        /bin/cat -- "$path" 2>/dev/null || true
        /bin/rm -f -- "$path" >/dev/null 2>&1 || true
    fi

    # Valid kitty-shell-cwd URIs reach Ghostty's PWD action in PTY order. The
    # following real cwd report keeps the private boundary out of title state.
    builtin printf '\033]1337;CurrentDir=kitty-shell-cwd://%s/.cmux/session-scrollback-replay/%s/end\007' "$HOSTNAME" "$token"
    builtin printf '\033]1337;CurrentDir=kitty-shell-cwd://%s%s\007' "$HOSTNAME" "$PWD"
}
_cmux_restore_scrollback_once
_CMUX_CLAUDE_WRAPPER="${_CMUX_CLAUDE_WRAPPER:-}"
_CMUX_GROK_WRAPPER="${_CMUX_GROK_WRAPPER:-}"
_cmux_path_prepend_unique_directory() {
    local directory="$1"
    local current_path="${2-}"
    local skipped_directory="${3-}"
    local result="$directory"
    local rest="$current_path"
    local entry=""
    local has_more=false

    [[ -n "$directory" ]] || {
        printf '%s' "$current_path"
        return 0
    }
    [[ -n "$current_path" ]] || {
        printf '%s' "$directory"
        return 0
    }

    while true; do
        if [[ "$rest" == *:* ]]; then
            entry="${rest%%:*}"
            rest="${rest#*:}"
            has_more=true
        else
            entry="$rest"
            rest=""
            has_more=false
        fi

        if [[ "$entry" != "$directory" && ( -z "$skipped_directory" || "$entry" != "$skipped_directory" ) ]]; then
            result="$result:$entry"
        fi
        [[ "$has_more" == true ]] || break
    done

    printf '%s' "$result"
}
_cmux_install_cli_command_shim() {
    local command_name="$1"
    local wrapper_path="$2"
    local surface_component="${CMUX_SURFACE_ID:-$$}"
    local shim_root="${CMUX_CLAUDE_WRAPPER_SHIM_ROOT:-}"
    local shim_parent="${shim_root%/*}"
    if [[ -z "$shim_root" || "${shim_root##*/}" != "$surface_component" || "${shim_parent##*/}" != "cmux-cli-shims" ]]; then
        shim_root="${TMPDIR:-/tmp}/cmux-cli-shims/$surface_component"
    fi
    local shim_path="$shim_root/$command_name"
    local escaped_wrapper="$wrapper_path"

    escaped_wrapper="${escaped_wrapper//\\/\\\\}"
    escaped_wrapper="${escaped_wrapper//\"/\\\"}"
    escaped_wrapper="${escaped_wrapper//\$/\\\$}"
    escaped_wrapper="${escaped_wrapper//\`/\\\`}"

    /bin/mkdir -p "$shim_root" >/dev/null 2>&1 || return 0
    {
        printf '%s\n' '#!/usr/bin/env bash'
        if [[ "$command_name" == "claude" ]]; then
            printf 'cmux_wrapper="%s"\n' "$escaped_wrapper"
            printf '%s\n' 'if [[ ! -x "$cmux_wrapper" && -n "${CMUX_BUNDLED_CLI_PATH:-}" ]]; then'
            printf '%s\n' '    cmux_candidate="$(dirname "$CMUX_BUNDLED_CLI_PATH")/cmux-claude-wrapper"'
            printf '%s\n' '    if [[ -x "$cmux_candidate" ]]; then'
            printf '%s\n' '        cmux_wrapper="$cmux_candidate"'
            printf '%s\n' '    fi'
            printf '%s\n' 'fi'
            printf '%s\n' 'if [[ ! -x "$cmux_wrapper" ]]; then'
            printf '%s\n' '    cmux_cli="$(command -v cmux 2>/dev/null || true)"'
            printf '%s\n' '    if [[ -n "$cmux_cli" ]]; then'
            printf '%s\n' '        cmux_candidate="$(dirname "$cmux_cli")/cmux-claude-wrapper"'
            printf '%s\n' '        if [[ -x "$cmux_candidate" ]]; then'
            printf '%s\n' '            cmux_wrapper="$cmux_candidate"'
            printf '%s\n' '        fi'
            printf '%s\n' '    fi'
            printf '%s\n' 'fi'
            printf 'export CMUX_CLAUDE_WRAPPER_SHIM="%s"\n' "$shim_path"
            printf 'export CMUX_CLAUDE_WRAPPER_SHIM_ROOT="%s"\n' "$shim_root"
            printf '%s\n' 'if [[ -x "$cmux_wrapper" ]]; then'
            printf '%s\n' '    exec "$cmux_wrapper" "$@"'
            printf '%s\n' 'fi'
            printf '%s\n' 'cmux_path_without_shim=""'
            printf '%s\n' 'cmux_old_ifs="$IFS"'
            printf '%s\n' 'IFS=:'
            printf '%s\n' 'for cmux_entry in ${PATH:-}; do'
            printf '%s\n' '    if [[ "$cmux_entry" == "$CMUX_CLAUDE_WRAPPER_SHIM_ROOT" || "$cmux_entry" == */cmux-cli-shims/* || "$cmux_entry" == */cmux-cli-shims ]]; then'
            printf '%s\n' '        continue'
            printf '%s\n' '    fi'
            printf '%s\n' '    if [[ -z "$cmux_path_without_shim" ]]; then'
            printf '%s\n' '        cmux_path_without_shim="$cmux_entry"'
            printf '%s\n' '    else'
            printf '%s\n' '        cmux_path_without_shim="$cmux_path_without_shim:$cmux_entry"'
            printf '%s\n' '    fi'
            printf '%s\n' 'done'
            printf '%s\n' 'IFS="$cmux_old_ifs"'
            printf '%s\n' 'export PATH="$cmux_path_without_shim"'
            printf '%s\n' 'exec claude "$@"'
        else
            printf 'exec "%s" "$@"\n' "$escaped_wrapper"
        fi
    # `>|` forces the truncate so cmux can always refresh its own generated
    # shim, even when the user's interactive bash has `noclobber` set. A plain
    # `>` is refused under noclobber and prints `cannot overwrite existing file`
    # on every prompt (the redirect failure is reported by the shell, so the
    # `2>/dev/null` on the compound command does not suppress it).
    } >|"$shim_path" 2>/dev/null || return 0
    /bin/chmod 0700 "$shim_path" >/dev/null 2>&1 || return 0

    if [[ "$command_name" == "claude" ]]; then
        export CMUX_CLAUDE_WRAPPER_SHIM="$shim_path"
        export CMUX_CLAUDE_WRAPPER_SHIM_ROOT="$shim_root"
    fi

    PATH="$(_cmux_path_prepend_unique_directory "$shim_root" "${PATH-}")"
    hash -r >/dev/null 2>&1 || true
}
_cmux_claude_wrapper_command() {
    if [[ -x "${CMUX_CLAUDE_WRAPPER_SHIM:-}" ]]; then
        "$CMUX_CLAUDE_WRAPPER_SHIM" "$@"
    elif [[ -x "${_CMUX_CLAUDE_WRAPPER:-}" ]]; then
        "$_CMUX_CLAUDE_WRAPPER" "$@"
    else
        command claude "$@"
    fi
}
_cmux_install_cli_wrapper() {
    local command_name="$1"
    local wrapper_variable="$2"
    local wrapper_file="${3:-$command_name}"
    local integration_dir="${CMUX_SHELL_INTEGRATION_DIR:-}"
    local existing_type=""
    [[ -n "$integration_dir" ]] || return 0

    integration_dir="${integration_dir%/}"
    local bundle_dir="${integration_dir%/shell-integration}"
    local wrapper_path="$bundle_dir/bin/$wrapper_file"
    [[ -x "$wrapper_path" ]] || return 0

    existing_type="$(type -t "$command_name" 2>/dev/null || true)"
    printf -v "$wrapper_variable" '%s' "$wrapper_path"
    if [[ "$command_name" == "claude" ]]; then
        _cmux_install_cli_command_shim "$command_name" "$wrapper_path"
    fi
    case "$existing_type" in
        alias|function)
            return 0
            ;;
    esac

    # Keep the bundled wrapper ahead of later PATH mutations. Install it
    # via eval so an existing alias cannot break parsing.
    unalias "$command_name" >/dev/null 2>&1 || true
    if [[ "$command_name" == "claude" ]]; then
        eval "$command_name() { _cmux_claude_wrapper_command \"\$@\"; }"
    else
        eval "$command_name() { \"\${$wrapper_variable}\" \"\$@\"; }"
    fi
}
_cmux_install_cli_wrapper claude _CMUX_CLAUDE_WRAPPER cmux-claude-wrapper
_cmux_install_cli_wrapper grok _CMUX_GROK_WRAPPER
_cmux_now() {
    printf '%s\n' "${EPOCHSECONDS:-$SECONDS}"
}

# Throttle heavy work to avoid prompt latency.
_CMUX_PWD_LAST_PWD="${_CMUX_PWD_LAST_PWD:-}"
_CMUX_GIT_LAST_PWD="${_CMUX_GIT_LAST_PWD:-}"
_CMUX_GIT_LAST_RUN="${_CMUX_GIT_LAST_RUN:-0}"
_CMUX_GIT_JOB_PID="${_CMUX_GIT_JOB_PID:-}"
_CMUX_GIT_JOB_STARTED_AT="${_CMUX_GIT_JOB_STARTED_AT:-0}"
_CMUX_GIT_HEAD_LAST_PWD="${_CMUX_GIT_HEAD_LAST_PWD:-}"
_CMUX_GIT_HEAD_PATH="${_CMUX_GIT_HEAD_PATH:-}"
_CMUX_GIT_HEAD_SIGNATURE="${_CMUX_GIT_HEAD_SIGNATURE:-}"
_CMUX_GIT_ACTIVE_PWD_FILE="${_CMUX_GIT_ACTIVE_PWD_FILE:-$(/usr/bin/mktemp "${TMPDIR:-/tmp}/cmux-git-active-pwd.XXXXXX" 2>/dev/null || true)}"
_CMUX_ASYNC_JOB_TIMEOUT="${_CMUX_ASYNC_JOB_TIMEOUT:-20}"
_CMUX_BASH_HISTORY_LAST_FILE="${_CMUX_BASH_HISTORY_LAST_FILE:-${TMPDIR:-/tmp}/cmux-history-last-$$}"

_CMUX_PORTS_LAST_RUN="${_CMUX_PORTS_LAST_RUN:-0}"
_CMUX_SHELL_ACTIVITY_LAST="${_CMUX_SHELL_ACTIVITY_LAST:-}"
_CMUX_TTY_NAME="${_CMUX_TTY_NAME:-}"
_CMUX_TTY_REPORTED="${_CMUX_TTY_REPORTED:-0}"
_CMUX_TMUX_PUSH_SIGNATURE="${_CMUX_TMUX_PUSH_SIGNATURE:-}"
_CMUX_TMUX_PULL_SIGNATURE="${_CMUX_TMUX_PULL_SIGNATURE:-}"
# Keep CMUX_SOCKET_CAPABILITY inherited; tmux's global environment is readable
# by clients that were not started inside cmux.
_CMUX_TMUX_SYNC_KEYS=(
    CMUX_BUNDLED_CLI_PATH
    CMUX_BUNDLE_ID
    CMUXD_UNIX_PATH
    CMUXTERM_REPO_ROOT
    CMUX_DEBUG_LOG
    CMUX_LOAD_GHOSTTY_ZSH_INTEGRATION
    CMUX_PORT
    CMUX_PORT_END
    CMUX_PORT_RANGE
    CMUX_SHELL_INTEGRATION
    CMUX_SHELL_INTEGRATION_DIR
    CMUX_SOCKET_ENABLE
    CMUX_SOCKET_MODE
    CMUX_SOCKET_PATH
    CMUX_TAB_ID
    CMUX_TAG
    CMUX_TERMINAL_LIFECYCLE_ID
    CMUX_WORKSPACE_ID
)
_CMUX_TMUX_SURFACE_SCOPED_KEYS=(
    CMUX_PANEL_ID
    CMUX_SURFACE_ID
)

_cmux_tmux_sync_key_is_managed() {
    local candidate="$1"
    local key
    for key in "${_CMUX_TMUX_SYNC_KEYS[@]}"; do
        [[ "$key" == "$candidate" ]] && return 0
    done
    return 1
}

_cmux_tmux_shell_env_signature() {
    local key value first=1
    for key in "${_CMUX_TMUX_SYNC_KEYS[@]}"; do
        value="${!key}"
        [[ -n "$value" ]] || continue
        if (( first )); then
            printf '%s=%s' "$key" "$value"
            first=0
        else
            printf '\037%s=%s' "$key" "$value"
        fi
    done
}

_cmux_tmux_publish_cmux_environment() {
    [[ -z "$TMUX" ]] || return 0
    command -v tmux >/dev/null 2>&1 || return 0

    local signature
    signature="$(_cmux_tmux_shell_env_signature)"
    [[ -n "$signature" ]] || return 0
    [[ "$signature" == "$_CMUX_TMUX_PUSH_SIGNATURE" ]] && return 0

    local key value
    for key in "${_CMUX_TMUX_SYNC_KEYS[@]}"; do
        value="${!key}"
        [[ -n "$value" ]] || continue
        tmux set-environment -g "$key" "$value" >/dev/null 2>&1 || return 0
    done

    for key in "${_CMUX_TMUX_SURFACE_SCOPED_KEYS[@]}"; do
        tmux set-environment -gu "$key" >/dev/null 2>&1 || return 0
    done

    _CMUX_TMUX_PUSH_SIGNATURE="$signature"
}

_cmux_tmux_refresh_cmux_environment() {
    [[ -n "$TMUX" ]] || return 0
    command -v tmux >/dev/null 2>&1 || return 0

    local output filtered line key value did_change=0
    for key in "${_CMUX_TMUX_SURFACE_SCOPED_KEYS[@]}"; do
        if [[ -n "${!key}" ]]; then
            unset "$key"
            did_change=1
        fi
    done

    output="$(tmux show-environment 2>/dev/null)" || return 0

    while IFS= read -r line; do
        [[ "$line" == CMUX_* ]] || continue
        key="${line%%=*}"
        _cmux_tmux_sync_key_is_managed "$key" || continue
        filtered+="${line}"$'\n'
    done <<< "$output"

    [[ -n "$filtered" ]] || return 0
    [[ "$filtered" == "$_CMUX_TMUX_PULL_SIGNATURE" ]] && (( ! did_change )) && return 0

    while IFS= read -r line; do
        [[ "$line" == CMUX_* ]] || continue
        key="${line%%=*}"
        _cmux_tmux_sync_key_is_managed "$key" || continue
        value="${line#*=}"
        if [[ "${!key}" != "$value" ]]; then
            printf -v "$key" '%s' "$value"
            export "$key"
            did_change=1
        fi
    done <<< "$filtered"

    _CMUX_TMUX_PULL_SIGNATURE="$filtered"
    if (( did_change )); then
        _CMUX_TTY_REPORTED=0
        _CMUX_SHELL_ACTIVITY_LAST=""
        _CMUX_PWD_LAST_PWD=""
        _CMUX_GIT_LAST_PWD=""
        _CMUX_GIT_HEAD_LAST_PWD=""
        _CMUX_GIT_HEAD_PATH=""
        _CMUX_GIT_HEAD_SIGNATURE=""
    fi
}

_cmux_tmux_sync_cmux_environment() {
    if [[ -n "$TMUX" ]]; then
        _cmux_tmux_refresh_cmux_environment
    else
        _cmux_tmux_publish_cmux_environment
    fi
}

_cmux_git_resolve_head_path() {
    # Resolve the HEAD file path without invoking git (fast; works for worktrees).
    local dir="${1:-$PWD}"
    while :; do
        if [[ -d "$dir/.git" ]]; then
            printf '%s\n' "$dir/.git/HEAD"
            return 0
        fi
        if [[ -f "$dir/.git" ]]; then
            local line gitdir
            IFS= read -r line < "$dir/.git" || line=""
            if [[ "$line" == gitdir:* ]]; then
                gitdir="${line#gitdir:}"
                gitdir="${gitdir## }"
                gitdir="${gitdir%% }"
                [[ -n "$gitdir" ]] || return 1
                [[ "$gitdir" != /* ]] && gitdir="$dir/$gitdir"
                printf '%s\n' "$gitdir/HEAD"
                return 0
            fi
        fi
        [[ "$dir" == "/" || -z "$dir" ]] && break
        dir="$(dirname "$dir")"
    done
    return 1
}

_cmux_git_head_signature() {
    local head_path="$1"
    [[ -n "$head_path" && -r "$head_path" ]] || return 1
    local line
    IFS= read -r line < "$head_path" || return 1
    printf '%s\n' "$line"
}

_cmux_git_branch_for_path() {
    local repo_path="$1"
    local head_path="" head_line="" prefix="ref: refs/heads/"
    head_path="$(_cmux_git_resolve_head_path "$repo_path" 2>/dev/null || true)"
    [[ -n "$head_path" && -r "$head_path" ]] || return 1
    IFS= read -r head_line < "$head_path" || return 1
    [[ "$head_line" == "$prefix"* ]] || return 1
    printf '%s\n' "${head_line#$prefix}"
}

_cmux_set_git_active_pwd() {
    local active_pwd="$1"
    [[ -n "$active_pwd" ]] || return 0
    [[ -n "${_CMUX_GIT_ACTIVE_PWD_FILE:-}" ]] || return 0
    printf '%s\n' "$active_pwd" >| "$_CMUX_GIT_ACTIVE_PWD_FILE" 2>/dev/null || true
}

_cmux_git_report_path_is_active() {
    local repo_path="$1"
    [[ -n "$repo_path" ]] || return 1
    [[ -n "${_CMUX_GIT_ACTIVE_PWD_FILE:-}" ]] || return 0
    [[ -r "$_CMUX_GIT_ACTIVE_PWD_FILE" ]] || return 0

    local active_pwd=""
    IFS= read -r active_pwd < "$_CMUX_GIT_ACTIVE_PWD_FILE" || active_pwd=""
    # No recorded cwd yet, or the report targets the current cwd exactly: allow.
    [[ -z "$active_pwd" || "$repo_path" == "$active_pwd" ]] && return 0

    # Otherwise the report is valid only when the current cwd is in the SAME
    # repository as repo_path. This keeps live branch updates flowing after an
    # in-repo `cd pkg` while still dropping a report once the shell has left the
    # repo entirely (the stale-branch case). Resolve both HEAD paths without
    # invoking git and compare.
    local repo_head active_head
    repo_head="$(_cmux_git_resolve_head_path "$repo_path" 2>/dev/null || true)"
    active_head="$(_cmux_git_resolve_head_path "$active_pwd" 2>/dev/null || true)"
    [[ -n "$repo_head" && "$repo_head" == "$active_head" ]]
}

_cmux_report_git_branch_for_path() {
    local repo_path="$1"
    [[ "${CMUX_NO_GIT_WATCH:-}" == "1" ]] && return 0
    [[ -n "$repo_path" ]] || return 0
    [[ -n "$CMUX_TAB_ID" ]] || return 0
    if _cmux_socket_is_unix; then
        [[ -n "$CMUX_PANEL_ID" ]] || return 0
    fi
    _cmux_git_report_path_is_active "$repo_path" || return 0
    local branch dirty_opt="--status=unknown"
    branch="$(_cmux_git_branch_for_path "$repo_path" 2>/dev/null || true)"
    _cmux_git_report_path_is_active "$repo_path" || return 0
    if [[ -n "$branch" ]]; then
        if _cmux_socket_is_unix; then
            _cmux_send "report_git_branch $branch $dirty_opt --tab=$CMUX_TAB_ID --panel=$CMUX_PANEL_ID"
        fi
    else
        if _cmux_socket_is_unix; then
            _cmux_send "clear_git_branch --tab=$CMUX_TAB_ID --panel=$CMUX_PANEL_ID"
        fi
    fi
}

_cmux_report_tty_payload() {
    [[ -n "$CMUX_TAB_ID" ]] || return 0
    [[ -n "$_CMUX_TTY_NAME" ]] || return 0

    local payload="report_tty $_CMUX_TTY_NAME --tab=$CMUX_TAB_ID"
    if [[ -z "$TMUX" ]]; then
        [[ -n "$CMUX_PANEL_ID" ]] || return 0
        payload+=" --panel=$CMUX_PANEL_ID"
    fi

    printf '%s\n' "$payload"
}

_cmux_report_tty_once() {
    # Send the TTY name to the app once per session so the batched port scanner
    # knows which TTY belongs to this panel.
    (( _CMUX_TTY_REPORTED )) && return 0
    _cmux_has_port_scan_transport || return 0

    if _cmux_socket_is_unix; then
        local payload=""
        payload="$(_cmux_report_tty_payload)"
        [[ -n "$payload" ]] || return 0
        _CMUX_TTY_REPORTED=1
        _cmux_send_bg "$payload"
    fi
}

_cmux_report_shell_activity_state() {
    local state="$1"
    [[ -n "$state" ]] || return 0
    [[ -n "$CMUX_TAB_ID" ]] || return 0
    if _cmux_socket_is_unix; then
        [[ -n "$CMUX_PANEL_ID" ]] || return 0
    fi
    [[ "$_CMUX_SHELL_ACTIVITY_LAST" == "$state" ]] && return 0
    _CMUX_SHELL_ACTIVITY_LAST="$state"
    if _cmux_socket_is_unix; then
        local payload="report_shell_state $state --tab=$CMUX_TAB_ID --panel=$CMUX_PANEL_ID"
        if [[ -n "${CMUX_TERMINAL_LIFECYCLE_ID:-}" ]]; then
            payload+=" --terminal-lifecycle-id=$CMUX_TERMINAL_LIFECYCLE_ID"
        fi
        _cmux_send_bg "$payload"
    fi
}

_cmux_reset_terminal_keyboard_protocols() {
    [[ -t 1 || -n "${CMUX_TEST_FORCE_KEYBOARD_RESET:-}${CMUX_TEST_FORCE_KITTY_RESET:-}" ]] || return 0
    # A crashed TUI may leave keyboard protocol state pushed. At a fresh shell
    # prompt, return terminal input encoding to plain readline bytes.
    printf '\033[>m\033[<8u'
}

_cmux_ports_kick() {
    local reason="${1:-command}"
    # Lightweight: just tell the app to run a batched scan for this panel.
    # The app coalesces kicks across all panels and runs a single ps+lsof.
    _cmux_has_port_scan_transport || return 0
    [[ -n "$CMUX_TAB_ID" ]] || return 0
    if _cmux_socket_is_unix; then
        [[ -n "$CMUX_PANEL_ID" ]] || return 0
    fi
    _CMUX_PORTS_LAST_RUN="$(_cmux_now)"
    if _cmux_socket_is_unix; then
        _cmux_send_bg "ports_kick --tab=$CMUX_TAB_ID --panel=$CMUX_PANEL_ID --reason=$reason"
    fi
}

_cmux_bash_cleanup() {
    [[ -n "${_CMUX_GIT_ACTIVE_PWD_FILE:-}" ]] && /bin/rm -f -- "$_CMUX_GIT_ACTIVE_PWD_FILE" >/dev/null 2>&1 || true
}

_cmux_command_starts_nested_shell() {
    local cmd="$1"
    local -a words=()
    read -r -a words <<< "$cmd"

    local index=0
    local word base
    while (( index < ${#words[@]} )); do
        word="${words[index]}"

        case "$word" in
            *=*)
                index=$(( index + 1 ))
                continue ;;
            exec|command|builtin|noglob|time)
                index=$(( index + 1 ))
                continue ;;
            env)
                index=$(( index + 1 ))
                while (( index < ${#words[@]} )); do
                    word="${words[index]}"
                    case "$word" in
                        -*|*=*)
                            index=$(( index + 1 ))
                            continue ;;
                    esac
                    break
                done
                continue ;;
        esac

        base="${word##*/}"
        case "$base" in
            bash|zsh|sh|fish|nu|nix-shell)
                return 0 ;;
            nix)
                local next_index=$(( index + 1 ))
                local next_word="${words[next_index]:-}"
                case "$next_word" in
                    develop|shell)
                        return 0 ;;
                esac ;;
        esac

        return 1
    done

    return 1
}

_cmux_preexec_command() {
    local cmd="${1:-${BASH_COMMAND:-}}"
    _cmux_tmux_sync_cmux_environment

    local cmux_has_unix_socket=0
    _cmux_socket_is_unix && cmux_has_unix_socket=1
    (( cmux_has_unix_socket )) || _cmux_has_port_scan_transport || return 0
    [[ -n "$CMUX_TAB_ID" ]] || return 0

    if [[ -z "$_CMUX_TTY_NAME" ]]; then
        local t
        t="$(tty 2>/dev/null || true)"
        t="${t##*/}"
        [[ -n "$t" && "$t" != "not a tty" ]] && _CMUX_TTY_NAME="$t"
    fi

    _cmux_report_shell_activity_state running
    _cmux_report_tty_once
    _cmux_ports_kick command
    if _cmux_command_starts_nested_shell "$cmd"; then
        return 0
    fi
}

_cmux_bash_history_command() {
    local HISTTIMEFORMAT=
    local history_file="${TMPDIR:-/tmp}/cmux-history-$$-${RANDOM:-0}"
    local line="" history_number="" last_number=""
    builtin history 1 >| "$history_file" 2>/dev/null || {
        /bin/rm -f -- "$history_file" >/dev/null 2>&1 || true
        return 1
    }
    IFS= read -r line < "$history_file" || line=""
    /bin/rm -f -- "$history_file" >/dev/null 2>&1 || true
    if [[ "$line" =~ ^[[:space:]]*([0-9]+)[[:space:]]+(.*)$ ]]; then
        history_number="${BASH_REMATCH[1]}"
        if [[ -n "${_CMUX_BASH_HISTORY_LAST_FILE:-}" && -r "$_CMUX_BASH_HISTORY_LAST_FILE" ]]; then
            IFS= read -r last_number < "$_CMUX_BASH_HISTORY_LAST_FILE" || last_number=""
        fi
        [[ "$history_number" == "$last_number" ]] && return 1
        if [[ -n "${_CMUX_BASH_HISTORY_LAST_FILE:-}" ]]; then
            printf '%s\n' "$history_number" >| "$_CMUX_BASH_HISTORY_LAST_FILE" 2>/dev/null || true
        fi
        printf '%s\n' "${BASH_REMATCH[2]}"
        return 0
    fi
    return 1
}

_cmux_bash_preexec_hook() {
    local cmd="${1:-}"
    local history_cmd=""
    history_cmd="$(_cmux_bash_history_command 2>/dev/null || true)"
    if [[ -n "$history_cmd" ]]; then
        cmd="$history_cmd"
    fi
    _cmux_preexec_command "$cmd"
}

_cmux_bash_preexec_hook_subshell() {
    local _CMUX_IN_PREEXEC=1
    _cmux_bash_preexec_hook "$@"
}

_cmux_prompt_command() {
    _cmux_tmux_sync_cmux_environment

    local cmux_has_unix_socket=0
    _cmux_socket_is_unix && cmux_has_unix_socket=1
    (( cmux_has_unix_socket )) || _cmux_has_port_scan_transport || return 0
    [[ -n "$CMUX_TAB_ID" ]] || return 0

    if [[ -z "$_CMUX_TTY_NAME" ]]; then
        local t
        t="$(tty 2>/dev/null || true)"
        t="${t##*/}"
        [[ "$t" != "not a tty" ]] && _CMUX_TTY_NAME="$t"
    fi

    if [[ -n "$CMUX_PANEL_ID" ]]; then
        _cmux_reset_terminal_keyboard_protocols
    fi
    if [[ -n "$CMUX_PANEL_ID" ]] || (( ! cmux_has_unix_socket )); then
        _cmux_report_shell_activity_state prompt
    fi
    _cmux_report_tty_once

    local now
    now="$(_cmux_now)"
    local pwd="$PWD"
    if (( cmux_has_unix_socket )); then
        [[ -n "$CMUX_PANEL_ID" ]] || return 0
    fi

    _cmux_set_git_active_pwd "$pwd"

    # Post-wake socket writes can occasionally leave a probe process wedged.
    # If one probe is stale, clear the guard so fresh async probes can resume.
    if [[ -n "$_CMUX_GIT_JOB_PID" ]]; then
        if ! kill -0 "$_CMUX_GIT_JOB_PID" 2>/dev/null; then
            _CMUX_GIT_JOB_PID=""
            _CMUX_GIT_JOB_STARTED_AT=0
        elif (( _CMUX_GIT_JOB_STARTED_AT > 0 )) && (( now - _CMUX_GIT_JOB_STARTED_AT >= _CMUX_ASYNC_JOB_TIMEOUT )); then
            _CMUX_GIT_JOB_PID=""
            _CMUX_GIT_JOB_STARTED_AT=0
        fi
    fi

    # Resolve TTY name once.
    if [[ -z "$_CMUX_TTY_NAME" ]]; then
        local t
        t="$(tty 2>/dev/null || true)"
        t="${t##*/}"
        [[ "$t" != "not a tty" ]] && _CMUX_TTY_NAME="$t"
    fi

    _cmux_report_tty_once

    # CWD: keep the app in sync with the actual shell directory.
    if (( cmux_has_unix_socket )) && [[ "$pwd" != "$_CMUX_PWD_LAST_PWD" ]]; then
        _CMUX_PWD_LAST_PWD="$pwd"
        local qpwd="${pwd//\"/\\\"}"
        _cmux_send_bg "report_pwd \"${qpwd}\" --tab=$CMUX_TAB_ID --panel=$CMUX_PANEL_ID"
    fi

    # Branch can change via aliases/tools while an older probe is still in flight.
    # Track .git/HEAD content so we can restart stale probes immediately.
    local git_head_changed=0
    if [[ "${CMUX_NO_GIT_WATCH:-}" == "1" ]]; then
        if [[ -n "$_CMUX_GIT_JOB_PID" ]] && kill -0 "$_CMUX_GIT_JOB_PID" 2>/dev/null; then
            kill "$_CMUX_GIT_JOB_PID" >/dev/null 2>&1 || true
        fi
        _CMUX_GIT_JOB_PID=""
        _CMUX_GIT_JOB_STARTED_AT=0
        _CMUX_GIT_HEAD_LAST_PWD=""
        _CMUX_GIT_HEAD_PATH=""
        _CMUX_GIT_HEAD_SIGNATURE=""
        _CMUX_GIT_LAST_PWD=""
    else
        if [[ "$pwd" != "$_CMUX_GIT_HEAD_LAST_PWD" ]]; then
            _CMUX_GIT_HEAD_LAST_PWD="$pwd"
            _CMUX_GIT_HEAD_PATH="$(_cmux_git_resolve_head_path "$pwd" 2>/dev/null || true)"
            _CMUX_GIT_HEAD_SIGNATURE=""
        fi
        if [[ -n "$_CMUX_GIT_HEAD_PATH" ]]; then
            local head_signature
            head_signature="$(_cmux_git_head_signature "$_CMUX_GIT_HEAD_PATH" 2>/dev/null || true)"
            if [[ -n "$head_signature" ]]; then
                if [[ -z "$_CMUX_GIT_HEAD_SIGNATURE" ]]; then
                    # The first observed HEAD value is just the session baseline.
                    _CMUX_GIT_HEAD_SIGNATURE="$head_signature"
                elif [[ "$head_signature" != "$_CMUX_GIT_HEAD_SIGNATURE" ]]; then
                    _CMUX_GIT_HEAD_SIGNATURE="$head_signature"
                    git_head_changed=1
                fi
            fi
        fi
    fi

    # Git branch/dirty can change without a directory change (e.g. `git checkout`),
    # so update on every prompt (still async + de-duped by the running-job check).
    # When pwd changes (cd into a different repo), kill the old probe and start fresh
    # so the sidebar picks up the new branch immediately.
    if [[ "${CMUX_NO_GIT_WATCH:-}" != "1" && -n "$_CMUX_GIT_JOB_PID" ]] && kill -0 "$_CMUX_GIT_JOB_PID" 2>/dev/null; then
        if [[ "$pwd" != "$_CMUX_GIT_LAST_PWD" || "$git_head_changed" == "1" ]]; then
            kill "$_CMUX_GIT_JOB_PID" >/dev/null 2>&1 || true
            _CMUX_GIT_JOB_PID=""
            _CMUX_GIT_JOB_STARTED_AT=0
        fi
    fi

    if [[ "${CMUX_NO_GIT_WATCH:-}" != "1" ]] && { [[ -z "$_CMUX_GIT_JOB_PID" ]] || ! kill -0 "$_CMUX_GIT_JOB_PID" 2>/dev/null; }; then
        _CMUX_GIT_LAST_PWD="$pwd"
        _CMUX_GIT_LAST_RUN=$now
        _cmux_start_tracked_bg _CMUX_GIT_JOB_PID _cmux_report_git_branch_for_path "$pwd"
        _CMUX_GIT_JOB_STARTED_AT=$now
    fi

    # Ports: lightweight kick to the app's batched scanner every ~10s.
    if (( now - _CMUX_PORTS_LAST_RUN >= 10 )); then
        _cmux_ports_kick refresh
    fi
}

_cmux_install_prompt_command() {
    [[ -n "${_CMUX_PROMPT_INSTALLED:-}" ]] && return 0
    _CMUX_PROMPT_INSTALLED=1

    local decl
    decl="$(declare -p PROMPT_COMMAND 2>/dev/null || true)"
    if [[ "$decl" == "declare -a"* ]]; then
        local existing=0
        local item
        for item in "${PROMPT_COMMAND[@]}"; do
            [[ "$item" == "_cmux_prompt_command" ]] && existing=1 && break
        done
        if (( existing == 0 )); then
            PROMPT_COMMAND=("_cmux_prompt_command" "${PROMPT_COMMAND[@]}")
        fi
    else
        case ";$PROMPT_COMMAND;" in
            *";_cmux_prompt_command;"*) ;;
            *)
                if [[ -n "$PROMPT_COMMAND" ]]; then
                    PROMPT_COMMAND="_cmux_prompt_command;$PROMPT_COMMAND"
                else
                    PROMPT_COMMAND="_cmux_prompt_command"
                fi
                ;;
        esac
    fi

        if (( BASH_VERSINFO[0] > 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 4) )); then
        if (( BASH_VERSINFO[0] > 5 || (BASH_VERSINFO[0] == 5 && BASH_VERSINFO[1] >= 3) )); then
            builtin readonly _CMUX_BASH_PS0='${ _cmux_bash_preexec_hook; }'
        else
            builtin readonly _CMUX_BASH_PS0='$(_cmux_bash_preexec_hook_subshell >/dev/null)'
        fi
        if [[ "$PS0" != *"${_CMUX_BASH_PS0}"* ]]; then
            PS0=$PS0"${_CMUX_BASH_PS0}"
        fi
    fi
}

# Ensure Resources/bin is at the front of PATH, and remove the app's
# Contents/MacOS entry so the GUI cmux binary cannot shadow the CLI cmux.
# Shell init (.bashrc/.bash_profile) may prepend other dirs after launch.
_cmux_fix_path() {
    local integration_dir="${CMUX_SHELL_INTEGRATION_DIR:-}"
    integration_dir="${integration_dir%/}"
    if [[ "$integration_dir" == */Resources/shell-integration ]]; then
        local resources_dir="${integration_dir%/shell-integration}"
        local gui_dir="${resources_dir%/Resources}/MacOS"
        local bin_dir="$resources_dir/bin"
        if [[ -d "$bin_dir" ]]; then
            PATH="$(_cmux_path_prepend_unique_directory "$bin_dir" "${PATH-}" "$gui_dir")"
        fi
    fi
}
_cmux_fix_path
unset -f _cmux_fix_path

_cmux_detect_send_tool

_cmux_install_prompt_command
