#!/usr/bin/env bash
# drain.sh — maintenance mode (`mother drain` / `undrain`) and the ordered `mother upgrade`.
#
# The flag is $RUNNER_DIR/drain.json {since, by, reason} (0600). mother-runner's
# `_dispatch_drained` makes dispatch start nothing while it exists. It survives a runner restart; only
# `undrain` (or the end of a successful `mother upgrade`) removes it. Running jobs are never touched.
# Everything the CLI does for it lives here so the runner file stays untouched beyond the gate.
# Relies on helpers from bin/mother: _die, _owner_only_refusal, _iso_now.

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

# mother_drain_running — "<job_id> (supervisor pid N)" per live supervisor entry.
mother_drain_running() {
    local f pid jid
    for f in "$RUNNER_DIR/children"/*.json; do
        [ -f "$f" ] || continue
        pid=$(basename "$f" .json)
        kill -0 "$pid" 2>/dev/null || continue
        jid=$(jq -r '.job_id // "?"' "$f" 2>/dev/null)
        echo "$jid (supervisor pid $pid)"
    done
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
    jq -r --arg r "${running:-0}" --arg w "$waiting" \
        '"dispatch: DRAINING since \(.since)\(if (.reason // "") != "" then " (\(.reason))" else "" end), \($r) running, \($w) waiting"' "$f" 2>/dev/null \
        || echo "dispatch: DRAINING, ${running:-0} running, $waiting waiting"
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

_UPGRADE_STEP=""
_upgrade_fail() {
    echo "mother upgrade: FAILED at step '$_UPGRADE_STEP': $*" >&2
    if mother_drain_active; then
        echo "  dispatch is still DRAINING. Fix the problem and run \`mother upgrade --resume\`, or \`mother undrain\`." >&2
    fi
    exit 1
}

# mother upgrade [--timeout SECS] [--dry-run] [--resume] [--restart-with-running]
cmd_upgrade() {
    local timeout=900 dry=0 force_running=0
    while [ $# -gt 0 ]; do
        case "$1" in
            --timeout) [ $# -ge 2 ] || _die "upgrade: --timeout needs a value"; timeout="$2"; shift 2 ;;
            --dry-run) dry=1; shift ;;
            --resume) shift ;;  # drain stays on after a timeout; re-running continues from the top
            --restart-with-running) force_running=1; shift ;;
            *) _die "usage: mother upgrade [--timeout SECS] [--dry-run] [--resume] [--restart-with-running]" ;;
        esac
    done
    case "$timeout" in ''|*[!0-9]*) _die "upgrade: --timeout must be a whole number of seconds" ;; esac
    _drain_guard upgrade

    local root cli old new
    root="$(mother_code_root)/mother"
    cli="${MOTHER_UPGRADE_CLI:-${MOTHER_BIN_DIR:-$(dirname "$0")}/mother}"

    _UPGRADE_STEP="preflight"
    [ -e "$root/.git" ] || _die "upgrade: $root is not a git checkout"
    local branch; branch=$(git -C "$root" rev-parse --abbrev-ref HEAD 2>/dev/null)
    [ "$branch" = "main" ] || _die "upgrade: $root is not on main (found: ${branch:-unknown})"
    [ -z "$(git -C "$root" status --porcelain 2>/dev/null)" ] || _die "upgrade: $root has uncommitted changes"
    if [ "$dry" -eq 0 ]; then
        git -C "$root" fetch >/dev/null 2>&1 || _die "upgrade: git fetch failed in $root"
    fi
    old=$(git -C "$root" rev-parse --short HEAD 2>/dev/null)
    local pending; pending=$(git -C "$root" log --oneline HEAD..origin/main 2>/dev/null)
    if [ -z "$pending" ]; then echo "upgrade: nothing new on origin/main ($old); nothing to do"; return 0; fi
    echo "upgrade: new commits on origin/main:"; printf '%s\n' "$pending" | sed 's/^/  /'

    if [ "$dry" -eq 1 ]; then
        echo "upgrade (dry run; fetch skipped, nothing changed). Would:"
        echo "  1. drain (dispatch stops; running jobs untouched)"
        echo "  2. wait up to ${timeout}s for no running job (abort with exit 3, drain stays on)"
        echo "  3. git pull --ff-only in $root"
        echo "  4. rebuild the broker if Go/broker files changed"
        echo "  5. mother daemon stop, then start; verify a new runner pid and that mother status answers"
        echo "  6. undrain"
        echo "  7. print old/new commit and the limiter line"
        return 0
    fi

    _UPGRADE_STEP="drain"
    mother_drain_set "mother upgrade" || _upgrade_fail "could not write drain flag"
    echo "upgrade: drain ON"

    _UPGRADE_STEP="wait"
    if ! _drain_wait_idle "$timeout"; then
        if [ "$force_running" -ne 1 ]; then
            echo "mother upgrade: aborted (jobs still running); drain stays ON, nothing pulled." >&2
            echo "  Wait and run \`mother upgrade --resume\`, \`mother undrain\` to cancel, or pass --restart-with-running" >&2
            echo "  to pull and restart anyway (running jobs survive a restart; scripts are replaced under them)." >&2
            exit 3
        fi
        echo "upgrade: proceeding with jobs running (--restart-with-running)"
    fi

    _UPGRADE_STEP="pull"
    git -C "$root" pull --ff-only >/dev/null 2>&1 || _upgrade_fail "git pull --ff-only failed in $root"
    new=$(git -C "$root" rev-parse --short HEAD)

    _UPGRADE_STEP="build"
    if git -C "$root" diff --name-only "$old" "$new" 2>/dev/null | grep -Eq '(^|/)broker/|\.go$|go\.(mod|sum)$'; then
        "$root/plugins/mother/scripts/build-broker.sh" >/dev/null 2>&1 || _upgrade_fail "broker rebuild failed"
        echo "upgrade: broker rebuilt"
    else
        echo "upgrade: no Go/broker changes; broker not rebuilt"
    fi

    _UPGRADE_STEP="restart"
    local oldpid=""
    [ -f "$RUNNER_DIR/runner.pid" ] && oldpid=$(cat "$RUNNER_DIR/runner.pid" 2>/dev/null)
    "$cli" daemon stop >/dev/null 2>&1 || _upgrade_fail "mother daemon stop failed"
    "$cli" daemon start >/dev/null 2>&1 || _upgrade_fail "mother daemon start failed"
    local newpid="" tries=0
    while [ "$tries" -lt 20 ]; do
        newpid=$(cat "$RUNNER_DIR/runner.pid" 2>/dev/null)
        [ -n "$newpid" ] && kill -0 "$newpid" 2>/dev/null && [ "$newpid" != "$oldpid" ] && break
        newpid=""; sleep 0.5; tries=$((tries + 1))
    done
    [ -n "$newpid" ] || _upgrade_fail "no new live runner pid after restart (old pid: ${oldpid:-none})"
    "$cli" status >/dev/null 2>&1 || _upgrade_fail "mother status does not answer after restart"

    _UPGRADE_STEP="undrain"
    mother_drain_clear || _upgrade_fail "could not remove the drain flag"
    echo "upgrade: drain OFF"

    echo "upgrade: done. $old -> $new (runner pid $newpid)"
    "$cli" limiter status 2>/dev/null | head -1 || true
    return 0
}
