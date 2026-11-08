#!/usr/bin/env bash
# drain.sh — maintenance mode (`mother drain` / `undrain`) and the ordered `mother upgrade`.
#
# The flag is $RUNNER_DIR/drain.json {since, by, reason} (0600). mother-runner's
# `_dispatch_drained` makes dispatch start nothing while it exists. It survives a runner restart; only
# `undrain` (or the end of a successful `mother upgrade`) removes it. Running jobs are never touched.
# Everything the CLI does for it lives here so the runner file stays untouched beyond the gate.
# Relies on helpers from bin/mother: _die, _owner_only_refusal, _iso_now.
#
# The owner-only guard (`_drain_guard`) is ACCIDENT PREVENTION, not a security boundary: it stops a Mother
# worker (ancestor walk, MOTHER_JOB_ID), an agent session (CLAUDECODE / CLAUDE_CODE_ENTRYPOINT) and a
# non-TTY caller from draining or upgrading by mistake. `env -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT`, a pty
# wrapper, or editing drain.json by hand all bypass it. A real Mother worker is still caught by the walk.

mother_drain_file() { printf '%s' "$RUNNER_DIR/drain.json"; }
mother_drain_active() { [ -f "$(mother_drain_file)" ]; }

# mother_drain_set <reason> — write the flag atomically (0600). An existing flag keeps its `since`.
mother_drain_set() {
    local f since by
    f=$(mother_drain_file)
    mkdir -p "$RUNNER_DIR"
    since=$(jq -r '.since // empty' "$f" 2>/dev/null) || since=""
    [ -n "$since" ] || since=$(_iso_now)
    by="${USER:-unknown}@$(hostname -s 2>/dev/null || echo host)"
    ( umask 077
      jq -nc --arg s "$since" --arg b "$by" --arg r "$1" '{since: $s, by: $b, reason: $r}' > "$f.tmp.$$" ) \
        && chmod 600 "$f.tmp.$$" && mv "$f.tmp.$$" "$f" || { rm -f "$f.tmp.$$"; return 1; }
}

mother_drain_clear() { rm -f "$(mother_drain_file)"; }

# _drain_update <jq filter> [jq args...] — atomically rewrite the flag (0600); a no-op when it is missing/unreadable.
_drain_update() {
    local f filter="$1"; shift
    f=$(mother_drain_file)
    [ -f "$f" ] || return 1
    ( umask 077; jq -c "$filter" "$@" "$f" > "$f.tmp.$$" ) 2>/dev/null \
        && chmod 600 "$f.tmp.$$" && mv "$f.tmp.$$" "$f" || { rm -f "$f.tmp.$$"; return 1; }
}

# _drain_flag_readable — true when the flag parses and carries a `since`.
_drain_flag_readable() { jq -e '(.since // "") | strings | length > 0' "$(mother_drain_file)" >/dev/null 2>&1; }

# mother_drain_running — one line per piece of in-flight work: "<job_id> (supervisor pid N)" per live supervisor
# (the pid's command line must be a mother-run-job; a reused pid does not count), plus the adherence-review and
# pipeline-driver work the runner holds a lockdir for. None are ever signalled.
mother_drain_running() {
    local f pid jid cmd tok is_run lock
    for f in "$RUNNER_DIR/children"/*.json; do
        [ -f "$f" ] || continue
        pid=$(basename "$f" .json)
        kill -0 "$pid" 2>/dev/null || continue
        # When `ps` cannot say what the pid is, the entry is trusted (alive), like the runner's own check.
        if cmd=$(ps -o command= -p "$pid" 2>/dev/null) && [ -n "$cmd" ]; then
            is_run=0
            set -f; for tok in $cmd; do [ "${tok##*/}" = "mother-run-job" ] && is_run=1; done; set +f
            [ "$is_run" -eq 1 ] || continue
        fi
        jid=$(jq -r '.job_id // "?"' "$f" 2>/dev/null)
        echo "$jid (supervisor pid $pid)"
    done
    for lock in adherence-review pipeline-driver; do
        [ -d "$RUNNER_DIR/$lock.lockdir" ] && echo "$lock (in flight, $lock.lockdir)"
    done
    return 0
}

mother_drain_waiting_count() {
    local f n=0
    for f in "$JOBS_DIR"/*.json; do
        [ -f "$f" ] || continue
        [ "$(jq -r '.state // ""' "$f" 2>/dev/null)" = "ready" ] && n=$((n + 1))
    done
    echo "$n"
}

# mother_drain_status_line — "dispatch: DRAINING since ..." or nothing when not draining.
mother_drain_status_line() {
    mother_drain_active || return 0
    local f running waiting
    f=$(mother_drain_file)
    running=$(mother_drain_running | grep -c . || true)
    waiting=$(mother_drain_waiting_count)
    if ! _drain_flag_readable; then
        echo "dispatch: DRAINING (drain flag unreadable: $f; \`mother undrain\` removes it), ${running:-0} running, $waiting waiting"
        return 0
    fi
    jq -r --arg r "${running:-0}" --arg w "$waiting" \
        '"dispatch: DRAINING since \(.since)\(if (.reason // "") != "" then " (\(.reason))" else "" end), \($r) running, \($w) waiting"' "$f"
}

_drain_guard() {
    if _owner_only_refusal; then
        _die "$1: refused ($_OWNER_ONLY_WHY): only the owner, at a terminal, can change dispatch"
    fi
}

# _drain_wait_idle <timeout_s> — 0 idle, 3 timeout. Prints what is running every 30s. Never signals a job.
_drain_wait_idle() {
    local timeout="$1" start now last=0 poll="${MOTHER_DRAIN_POLL_S:-1}" every="${MOTHER_DRAIN_PRINT_S:-30}" r
    start=$(date +%s)
    while :; do
        r=$(mother_drain_running)
        if [ -z "$r" ]; then echo "drain: idle (no job running)"; return 0; fi
        now=$(date +%s)
        if [ $((now - start)) -ge "$timeout" ]; then
            echo "drain: timed out after ${timeout}s; still running:" >&2
            printf '%s\n' "$r" | sed 's/^/  /' >&2
            return 3
        fi
        if [ $((now - last)) -ge "$every" ]; then
            echo "drain: waiting for $(printf '%s\n' "$r" | grep -c .) running job(s):"
            printf '%s\n' "$r" | sed 's/^/  /'
            last=$now
        fi
        sleep "$poll"
    done
}

# mother drain [--reason TEXT] [--wait [--timeout SECS]] | --status
cmd_drain() {
    local reason="" wait=0 timeout=900 status=0
    while [ $# -gt 0 ]; do
        case "$1" in
            --reason) [ $# -ge 2 ] || _die "drain: --reason needs a value"; reason="$2"; shift 2 ;;
            --wait) wait=1; shift ;;
            --timeout) [ $# -ge 2 ] || _die "drain: --timeout needs a value"; timeout="$2"; shift 2 ;;
            --status) status=1; shift ;;
            *) _die "usage: mother drain [--reason TEXT] [--wait [--timeout SECS]] | --status" ;;
        esac
    done
    case "$timeout" in ''|*[!0-9]*) _die "drain: --timeout must be a whole number of seconds" ;; esac
    if [ "$status" -eq 1 ]; then
        if mother_drain_active; then mother_drain_status_line; else echo "dispatch: normal (not draining)"; fi
        return 0
    fi
    _drain_guard drain
    mother_drain_set "$reason" || _die "drain: could not write $(mother_drain_file)"
    echo "drain: ON — no new job will start; running jobs are untouched ($(mother_drain_file))"
    [ "$wait" -eq 1 ] || return 0
    _drain_wait_idle "$timeout"
}

cmd_undrain() {
    _drain_guard undrain
    if mother_drain_active; then mother_drain_clear; echo "drain: OFF — dispatch resumes"; else echo "drain: not draining"; fi
}

# ---------- upgrade ----------
#
# Order: drain, wait idle, land origin/main (fetch + merge --ff-only of the exact commit listed), rebuild the
# broker if Go/broker files changed, stop + start the daemon, verify, undrain. The drain flag records
# `upgrade: {old_sha, step}` so `mother upgrade --resume` (or a plain re-run) continues after a failure at any
# step: it compares old_sha..HEAD for the broker rebuild instead of concluding "nothing new". One upgrade at a
# time ($RUNNER_DIR/upgrade.lockdir via _switch_with_lock). INT/TERM name the step and leave the drain ON.

_UPGRADE_STEP=""
_UPGRADE_OUT=""
_UPGRADE_DAEMON_STOPPED=0
_UPGRADE_LOCKDIR=""

# _upgrade_record_step — remember the current step in the drain flag (only when an upgrade owns it).
_upgrade_record_step() {
    mother_drain_active || return 0
    _drain_update 'if .upgrade then .upgrade.step = $s else . end' --arg s "$_UPGRADE_STEP" || true
}

_upgrade_hint() {
    if [ "$_UPGRADE_DAEMON_STOPPED" = "1" ]; then
        echo "  !! the mother daemon is STOPPED: nothing is dispatching or reaping. Run \`mother daemon start\` now," >&2
        echo "     then \`mother upgrade --resume\` (or \`mother undrain\` once it is up)." >&2
    fi
    if mother_drain_active; then
        echo "  dispatch is still DRAINING. Fix the problem and run \`mother upgrade --resume\`, or \`mother undrain\`." >&2
    fi
}

_upgrade_fail() {
    echo "mother upgrade: FAILED at step '$_UPGRADE_STEP': $*" >&2
    [ -z "$_UPGRADE_OUT" ] || printf '%s\n' "$_UPGRADE_OUT" | tail -n 8 | sed 's/^/    /' >&2
    _upgrade_record_step
    _upgrade_hint
    exit 1
}

_upgrade_on_signal() {
    trap '' INT TERM
    echo "mother upgrade: interrupted ($1) at step '$_UPGRADE_STEP'; drain stays ON" >&2
    _upgrade_record_step
    _upgrade_hint
    exit 130
}

# Release the upgrade lock only if it is still ours (the lock helper also releases on a normal return).
_upgrade_on_exit() {
    [ -n "$_UPGRADE_LOCKDIR" ] || return 0
    [ "$(cat "$_UPGRADE_LOCKDIR/owner" 2>/dev/null)" = "$$" ] || return 0
    rm -f "$_UPGRADE_LOCKDIR/owner"; rmdir "$_UPGRADE_LOCKDIR" 2>/dev/null || true
}

# _upgrade_cmd <cmd...> — run in the background and `wait`, so a trapped signal is handled at once instead of
# after the command. Output lands in _UPGRADE_OUT (shown by _upgrade_fail). A command already running is not killed.
_upgrade_cmd() {
    local out="$RUNNER_DIR/upgrade-out.tmp.$$" rc cpid
    _UPGRADE_OUT=""
    "$@" > "$out" 2>&1 < /dev/null &
    cpid=$!
    wait "$cpid"; rc=$?
    _UPGRADE_OUT=$(cat "$out" 2>/dev/null); rm -f "$out"
    return "$rc"
}

# _upgrade_runner_started <runner.log> <size before restart> — a "mother-runner started" line appended since.
_upgrade_runner_started() {
    local size cur
    size="$2"; cur=$(wc -c < "$1" 2>/dev/null | tr -d ' ')
    [ -n "$cur" ] || return 1
    [ "$cur" -ge "$size" ] || size=0
    tail -c +$((size + 1)) "$1" 2>/dev/null | grep -q 'mother-runner started'
}

# mother upgrade [--timeout SECS] [--dry-run] [--resume] [--restart-with-running]
cmd_upgrade() {
    local timeout=900 dry=0 force_running=0 resume=0 holder
    while [ $# -gt 0 ]; do
        case "$1" in
            --timeout) [ $# -ge 2 ] || _die "upgrade: --timeout needs a value"; timeout="$2"; shift 2 ;;
            --dry-run) dry=1; shift ;;
            --resume) resume=1; shift ;;
            --restart-with-running) force_running=1; shift ;;
            *) _die "usage: mother upgrade [--timeout SECS] [--dry-run] [--resume] [--restart-with-running]" ;;
        esac
    done
    case "$timeout" in ''|*[!0-9]*) _die "upgrade: --timeout must be a whole number of seconds" ;; esac
    _drain_guard upgrade

    _UPGRADE_LOCKDIR="$RUNNER_DIR/upgrade.lockdir"
    mkdir -p "$RUNNER_DIR"
    holder=$(cat "$_UPGRADE_LOCKDIR/owner" 2>/dev/null || true)
    if [ -d "$_UPGRADE_LOCKDIR" ] && [ -n "$holder" ] && kill -0 "$holder" 2>/dev/null; then
        _die "upgrade: another mother upgrade is already running (pid $holder, $_UPGRADE_LOCKDIR)"
    fi
    _switch_with_lock "$_UPGRADE_LOCKDIR" upgrade 20 _upgrade_locked "$dry" "$force_running" "$timeout" \
        || _die "upgrade: could not take $_UPGRADE_LOCKDIR (another upgrade is starting?)"
}

_upgrade_locked() {
    local dry="$1" force_running="$2" timeout="$3"
    trap '_upgrade_on_signal INT' INT
    trap '_upgrade_on_signal TERM' TERM
    trap '_upgrade_on_exit' EXIT

    local root cli bin_dir rtop btop branch old_full head_full target pending new new_full resuming=0 prev_step=""
    root="$(mother_code_root)/mother"
    bin_dir="${MOTHER_BIN_DIR:-$(cd "$(dirname "$0")" && pwd)}"
    cli="${MOTHER_UPGRADE_CLI:-$bin_dir/mother}"

    _UPGRADE_STEP="preflight"
    [ -e "$root/.git" ] || _die "upgrade: $root is not a git checkout"
    # The runner runs from MOTHER_BIN_DIR; pulling any other checkout would restart the same old code.
    rtop=$(git -C "$root" rev-parse --show-toplevel 2>/dev/null)
    btop=$(git -C "$bin_dir" rev-parse --show-toplevel 2>/dev/null)
    if [ -z "$btop" ]; then
        _die "upgrade: the runner's bin dir $bin_dir is not inside a git checkout (a plugin cache?); upgrade would pull the checkout $rtop, which the runner does not run from"
    elif [ "$rtop" != "$btop" ]; then
        _die "upgrade: checkout mismatch: the runner runs from the checkout $btop (bin dir $bin_dir) but upgrade would pull the checkout $rtop; refusing"
    fi
    branch=$(git -C "$root" rev-parse --abbrev-ref HEAD 2>/dev/null)
    [ "$branch" = "main" ] || _die "upgrade: $root is not on main (found: ${branch:-unknown})"
    [ -z "$(git -C "$root" status --porcelain --untracked-files=no 2>/dev/null)" ] \
        || _die "upgrade: $root has uncommitted changes to tracked files (untracked files are ignored)"
    if [ "$dry" -eq 0 ]; then
        _upgrade_cmd git -C "$root" fetch || _die "upgrade: git fetch failed in $root: $_UPGRADE_OUT"
    fi
    head_full=$(git -C "$root" rev-parse HEAD 2>/dev/null)
    target=$(git -C "$root" rev-parse origin/main 2>/dev/null) || _die "upgrade: no origin/main in $root"

    # A drain set by an earlier upgrade carries the commit it started from: continue that upgrade.
    old_full=""
    if mother_drain_active; then
        old_full=$(jq -r '.upgrade.old_sha // empty' "$(mother_drain_file)" 2>/dev/null)
        prev_step=$(jq -r '.upgrade.step // empty' "$(mother_drain_file)" 2>/dev/null)
    fi
    if [ -n "$old_full" ]; then
        git -C "$root" cat-file -e "$old_full^{commit}" 2>/dev/null \
            || _die "upgrade: recorded starting commit $old_full is not in $root; \`mother undrain\` and start over"
        resuming=1
    else
        old_full="$head_full"
    fi
    pending=$(git -C "$root" log --oneline HEAD..origin/main 2>/dev/null)
    if [ -z "$pending" ] && [ "$resuming" -eq 0 ]; then
        echo "upgrade: nothing new on origin/main ($(git -C "$root" rev-parse --short HEAD)); nothing to do"
        return 0
    fi
    if [ "$resuming" -eq 1 ]; then
        echo "upgrade: resuming an upgrade from ${old_full:0:7} that stopped at step '${prev_step:-unknown}'"
    fi
    if [ -n "$pending" ]; then
        echo "upgrade: new commits on origin/main:"; printf '%s\n' "$pending" | sed 's/^/  /'
    fi

    if [ "$dry" -eq 1 ]; then
        echo "upgrade (dry run; fetch skipped, nothing changed). Would:"
        echo "  1. drain (dispatch stops; running jobs untouched)"
        echo "  2. wait up to ${timeout}s for no running job (abort with exit 3, drain stays on)"
        echo "  3. git merge --ff-only origin/main in $root"
        echo "  4. rebuild the broker if Go/broker files changed since ${old_full:0:7}"
        echo "  5. mother daemon stop, then start; verify a new live runner pid, a 'mother-runner started' log line and that mother status answers"
        echo "  6. undrain"
        echo "  7. print old/new commit and the limiter line"
        return 0
    fi

    _UPGRADE_STEP="drain"
    if [ "$resuming" -eq 0 ]; then
        mother_drain_set "mother upgrade" || _upgrade_fail "could not write drain flag"
        _drain_update '.upgrade = {old_sha: $o, step: "drain"}' --arg o "$old_full" || _upgrade_fail "could not record the upgrade in the drain flag"
    fi
    echo "upgrade: drain ON"

    _UPGRADE_STEP="wait"
    _upgrade_record_step
    if ! _drain_wait_idle "$timeout"; then
        if [ "$force_running" -ne 1 ]; then
            echo "mother upgrade: aborted (work still running); drain stays ON, nothing pulled." >&2
            echo "  Wait and run \`mother upgrade --resume\`, \`mother undrain\` to cancel, or pass --restart-with-running" >&2
            echo "  to pull and restart anyway (running jobs survive a restart; scripts are replaced under them)." >&2
            exit 3
        fi
        echo "upgrade: proceeding with work running (--restart-with-running)"
    fi

    _UPGRADE_STEP="pull"
    _upgrade_record_step
    if [ -n "$pending" ]; then
        _upgrade_cmd git -C "$root" merge --ff-only "$target" || _upgrade_fail "git merge --ff-only failed in $root"
    fi
    new=$(git -C "$root" rev-parse --short HEAD); new_full=$(git -C "$root" rev-parse HEAD)

    _UPGRADE_STEP="build"
    _upgrade_record_step
    if git -C "$root" diff --name-only "$old_full" "$new_full" 2>/dev/null | grep -Eq '(^|/)broker/|\.go$|go\.(mod|sum)$'; then
        _upgrade_cmd "$root/plugins/mother/scripts/build-broker.sh" || _upgrade_fail "broker rebuild failed"
        echo "upgrade: broker rebuilt"
    else
        echo "upgrade: no Go/broker changes; broker not rebuilt"
    fi

    _UPGRADE_STEP="restart"
    _upgrade_record_step
    local oldpid="" newpid="" tries=0 logf="$RUNNER_DIR/runner.log" logsize
    [ -f "$RUNNER_DIR/runner.pid" ] && oldpid=$(cat "$RUNNER_DIR/runner.pid" 2>/dev/null)
    logsize=$(wc -c < "$logf" 2>/dev/null | tr -d ' '); logsize="${logsize:-0}"
    _upgrade_cmd "$cli" daemon stop || _upgrade_fail "mother daemon stop failed"
    _UPGRADE_DAEMON_STOPPED=1
    _upgrade_cmd "$cli" daemon start || _upgrade_fail "mother daemon start failed"
    _UPGRADE_DAEMON_STOPPED=0
    while [ "$tries" -lt 20 ]; do
        newpid=$(cat "$RUNNER_DIR/runner.pid" 2>/dev/null)
        if [ -n "$newpid" ] && [ "$newpid" != "$oldpid" ] && kill -0 "$newpid" 2>/dev/null \
            && _upgrade_runner_started "$logf" "$logsize"; then break; fi
        newpid=""; sleep 0.5; tries=$((tries + 1))
    done
    [ -n "$newpid" ] || _upgrade_fail "no new live runner after restart (needs a pid different from ${oldpid:-none} and a 'mother-runner started' line in $logf)"
    sleep "${MOTHER_UPGRADE_SETTLE_S:-3}"
    { kill -0 "$newpid" 2>/dev/null && [ "$(cat "$RUNNER_DIR/runner.pid" 2>/dev/null)" = "$newpid" ]; } \
        || _upgrade_fail "runner pid $newpid did not stay alive after the restart (see $logf)"

    _UPGRADE_STEP="verify"
    _upgrade_record_step
    _upgrade_cmd "$cli" status || _upgrade_fail "mother status does not answer after restart"

    _UPGRADE_STEP="undrain"
    mother_drain_clear || _upgrade_fail "could not remove the drain flag"
    echo "upgrade: drain OFF"

    echo "upgrade: done. $(git -C "$root" rev-parse --short "$old_full") -> $new (runner pid $newpid)"
    "$cli" limiter status 2>/dev/null | head -1 || true
    return 0
}
