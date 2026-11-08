#!/usr/bin/env bash
# checkpoint.sh — WIP checkpoint of a job's repository state and transcript (cluster P1-3, B8/B9).
#
# mother_checkpoint_take    snapshot the worktree (tracked edits, staged, untracked, not ignored) as a
#                           commit built in a TEMP index, push it fenced to refs/mother/wip/<job>, copy the
#                           transcript delta and write a manifest (docs/worker-protocol.md section 9).
# mother_checkpoint_restore rebuild HEAD, the working changes and the transcript at another path.
#
# Never runs `git stash`, `git add` on the real index, `git commit` or `git reset` in the job's worktree.
# Every git call goes through _ckpt_git: hardened against repo-controlled config (hooks, fsmonitor,
# filter/textconv drivers, signing, credential helpers, upload/receive-pack overrides), bounded by the
# take's deadline, and killed as a process group when it hangs.
# No runtime path calls this library yet (P1-6 wires it). Sourced under `set -u`, bash 3.2: no
# `declare -A`, no `mapfile`. Needs lib/state.sh (_bounded_run, _switch_with_lock, _iso_now,
# safe_rm_tree) and jq.

_CKPT_TMPS=""
_CKPT_DEADLINE=0
_CKPT_PREPARED=0
_CKPT_REFUSE=""
_CKPT_GITARGS=()
_CKPT_INDEX=""
_CKPT_RESTORED_T=""

_ckpt_cleanup() {
    local f
    for f in $_CKPT_TMPS; do rm -f "$f"; done
    _CKPT_TMPS=""
}

_ckpt_mktemp() {
    local f; f=$(mktemp "${TMPDIR:-/tmp}/mother-ckpt.XXXXXX") || return 1
    _CKPT_TMPS="$_CKPT_TMPS $f"
    printf '%s' "$f"
}

# mother_checkpoint_interval_s: seconds between checkpoints. 240 is the MC-14 ceiling (interval + 60 s
# watchdog <= 300 s). Anything not an integer in 30..240 falls back to 120 with one stderr line.
mother_checkpoint_interval_s() {
    local v="${MOTHER_CHECKPOINT_INTERVAL_S:-}"
    if [ -z "$v" ] && type mother_config_get >/dev/null 2>&1; then
        v=$(mother_config_get MOTHER_CHECKPOINT_INTERVAL_S 2>/dev/null) || v=""
    fi
    if [ -z "$v" ]; then echo 120; return 0; fi
    case "$v" in
        ''|*[!0-9]*) echo "mother: MOTHER_CHECKPOINT_INTERVAL_S=$v is not a number; using 120" >&2; echo 120; return 0 ;;
    esac
    if [ "$v" -lt 30 ] || [ "$v" -gt 240 ]; then
        echo "mother: MOTHER_CHECKPOINT_INTERVAL_S=$v is outside 30..240; using 120" >&2
        echo 120; return 0
    fi
    echo "$v"
}

# --- hardened, bounded git -----------------------------------------------------------------------

_ckpt_expired() { [ "$SECONDS" -ge "${_CKPT_DEADLINE:-0}" ]; }

_ckpt_remaining() {
    local left=$(( ${_CKPT_DEADLINE:-0} - SECONDS ))
    [ "$left" -lt 1 ] && left=1
    echo "$left"
}

# _ckpt_run <secs> <out-file> <in-file> <cmd...>: run in its OWN process group (job control), stdout to
# <out-file>, stdin from <in-file>; after <secs> the whole group is killed (git's ssh and
# git-remote-https children included). Returns the exit code (137 when killed).
_ckpt_run() {
    local secs="$1" out="$2" in="$3"; shift 3
    local pid wd rc=0
    set -m
    ( "$@" >"$out" 2>/dev/null <"$in" 3>&- ) &
    pid=$!
    ( sleep "$secs"; kill -KILL -- "-$pid" 2>/dev/null ) >/dev/null 2>&1 3>&- &
    wd=$!
    set +m
    wait "$pid" 2>/dev/null || rc=$?
    kill -KILL -- "-$wd" 2>/dev/null
    kill "$wd" 2>/dev/null
    wait "$wd" 2>/dev/null
    return "$rc"
}

# _ckpt_env <cmd...>: the sanitized environment every git runs in.
_ckpt_env() {
    env -u GIT_DIR -u GIT_WORK_TREE -u GIT_EXTERNAL_DIFF -u GIT_ASKPASS -u GIT_PAGER \
        GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_TERMINAL_PROMPT=0 \
        GIT_OPTIONAL_LOCKS=0 LC_ALL=C LANG=C \
        ${_CKPT_INDEX:+"GIT_INDEX_FILE=$_CKPT_INDEX"} "$@"
}

# _ckpt_prepare <dir>: build the -c overrides for one operation. Call it from the main shell (not inside
# $(...)): the result is cached in _CKPT_GITARGS and applies to every directory of the operation (a
# repo, its worktrees, the new worktree all share the local config). Besides the fixed switches it
# empties every filter clean/smudge/process, diff textconv/command and credential helper and resets the
# remote vcs commands found in the local (and worktree) config. remote.<n>.uploadpack/receivepack
# cannot be overridden with -c (git keeps the first value), so push/fetch/ls-remote pass
# --receive-pack / --upload-pack explicitly.
_ckpt_prepare() {
    local d="$1" name
    _CKPT_GITARGS=(-c core.fsmonitor=false -c core.hooksPath=/dev/null -c commit.gpgsign=false
        -c tag.gpgsign=false -c push.gpgsign=false -c gpg.program=false -c core.sshCommand=ssh
        -c protocol.ext.allow=never -c credential.helper= -c core.gitProxy= -c core.pager=cat
        -c core.askPass= -c core.editor=true -c push.recurseSubmodules=no -c fetch.recurseSubmodules=false
        -c diff.external= -c advice.detachedHead=false -c core.alternateRefsCommand= -c core.alternateRefsPrefixes=)
    _CKPT_REFUSE=""
    while IFS= read -r -d '' name; do
        case "$name" in
            filter.*.clean|filter.*.smudge|filter.*.process|diff.*.textconv|diff.*.command|credential.*.helper|remote.*.vcs)
                _CKPT_GITARGS+=(-c "$name=") ;;
            filter.*.required) _CKPT_GITARGS+=(-c "$name=false") ;;
            core.worktree) _CKPT_REFUSE="core.worktree is set (it would redirect git to another directory)" ;;
        esac
    done < <(_ckpt_env git -C "$d" config --list --name-only -z 2>/dev/null)
    _CKPT_PREPARED=1
}

# _ckpt_git <dir> <git args...>: hardened, deadline-bounded git. stdout passes through; stdin is
# $_CKPT_IN (default /dev/null); stderr is dropped. Returns 137 once the deadline has passed.
_ckpt_git() {
    local d="$1"; shift
    _ckpt_expired && return 137
    [ "$_CKPT_PREPARED" = 1 ] || _ckpt_prepare "$d"
    local out rc=0
    out=$(mktemp "${TMPDIR:-/tmp}/mother-ckpt.XXXXXX") || return 1
    _ckpt_run "$(_ckpt_remaining)" "$out" "${_CKPT_IN:-/dev/null}" \
        _ckpt_env git -C "$d" ${_CKPT_GITARGS[@]+"${_CKPT_GITARGS[@]}"} "$@" || rc=$?
    cat "$out"
    rm -f "$out"
    return "$rc"
}

# --- helpers -------------------------------------------------------------------------------------

# Claude slugs a path by replacing '/' and '.' with '-' (same as cmd_peek).
_ckpt_encode_path() {
    local p="$1"
    p="${p//\//-}"
    printf '%s' "${p//./-}"
}

_ckpt_projects_dir() { printf '%s' "${MOTHER_CLAUDE_PROJECTS_DIR:-$HOME/.claude/projects}"; }

# A job id usable as a git ref component: [A-Za-z0-9._:-]{1,128}, no "..", no leading/trailing ".",
# no ".lock" suffix (mirrors workerproto.JobRefOK).
_ckpt_job_ok() {
    case "$1" in
        ''|*[!A-Za-z0-9._:-]*|*..*|.*|*.|*.lock) return 1 ;;
    esac
    [ "${#1}" -le 128 ]
}

# A conservative branch name (mirrors workerproto.BranchOK) that git also accepts.
_ckpt_branch_ok() {
    case "$1" in
        ''|*[!A-Za-z0-9._/-]*|*..*|*//*|*/.*|.*|-*|*/|*.|*.lock) return 1 ;;
    esac
    [ "${#1}" -le 200 ] || return 1
    git check-ref-format "refs/heads/$1" 2>/dev/null
}

# A session or lease id is a path component: IDOK charset, no "..", not starting with ".".
_ckpt_session_ok() {
    case "$1" in ''|*[!A-Za-z0-9._:-]*|*..*|.*) return 1 ;; esac
    [ "${#1}" -le 128 ]
}

_ckpt_sha_ok() {
    case "$1" in *[!0-9a-f]*|'') return 1 ;; esac
    [ "${#1}" -eq 40 ] || [ "${#1}" -eq 64 ]
}

_ckpt_sha256() {
    if command -v shasum >/dev/null 2>&1; then shasum -a 256 | awk '{print $1}'
    else sha256sum | awk '{print $1}'; fi
}

_ckpt_size() { wc -c <"$1" | tr -d ' '; }

# A repo-relative path from a tree is safe to rm/join: no empty, absolute, "." / ".." / ".git" component.
_ckpt_relpath_ok() {
    case "$1" in ''|/*) return 1 ;; esac
    case "/$1/" in */../*|*/./*|*/.git/*|*//*) return 1 ;; esac
    return 0
}

# _ckpt_git_path <dir> <name>: absolute path of a file in the worktree's private git dir.
_ckpt_git_path() {
    local p; p=$(_ckpt_git "$1" rev-parse --git-path "$2") || return 1
    case "$p" in /*) printf '%s' "$p" ;; *) printf '%s/%s' "$1" "$p" ;; esac
}

_ckpt_ls_remote_ref() {
    local o; o=$(_ckpt_git "$1" ls-remote --upload-pack=git-upload-pack origin "$2") || return 1
    printf '%s' "$o" | awk 'NR==1 {print $1}'
}

# _ckpt_tree_of <work_dir> <tmpidx> <skipfile>: tree of the worktree contents (non-ignored), built in
# <tmpidx>, which must already hold a copy of the index. Prints the tree sha. Never hashes a file it
# will not keep, never follows a symlink, never runs git inside a nested repository. Not captured
# (written to <skipfile> as "<bytes>\t<reason>\t<path>"): untracked files over the size cap
# (too_large), nested repositories and checked-out submodules (embedded_repo: their dirty files and
# unpushed commits are NOT in the checkpoint), special files. A path git or the wire cannot carry
# is written as "0\t!\tunlisted".
_ckpt_tree_of() {
    local wd="$1" tmpidx="$2" skipfile="$3" max_mb="${MOTHER_CHECKPOINT_MAX_FILE_MB:-50}"
    case "$max_mb" in ''|*[!0-9]*) max_mb=50 ;; esac
    local max_bytes=$((max_mb * 1048576)) f sz rec p paths="$skipfile.paths"
    local _CKPT_INDEX="$tmpidx"
    : >"$skipfile"
    : >"$paths"
    # Tracked files changed or deleted in the worktree (submodules excluded: their content is never read).
    while IFS= read -r -d '' f; do printf '%s\0' "$f" >>"$paths"; done \
        < <(_ckpt_git "$wd" diff-files -z --name-only --ignore-submodules=all)
    # Untracked, not ignored.
    while IFS= read -r -d '' f; do
        case "$f" in
            *[[:cntrl:]]*|*\\*) printf '0\t!\tunlisted\n' >>"$skipfile"; continue ;;
        esac
        case "$f" in
            */) printf '0\tembedded_repo\t%s\n' "${f%/}" >>"$skipfile"; continue ;;
        esac
        if [ -L "$wd/$f" ]; then
            printf '%s\0' "$f" >>"$paths"
        elif [ -f "$wd/$f" ]; then
            sz=$(_ckpt_size "$wd/$f")
            if [ "$sz" -gt "$max_bytes" ]; then
                printf '%s\ttoo_large\t%s\n' "$sz" "$f" >>"$skipfile"
            else
                printf '%s\0' "$f" >>"$paths"
            fi
        elif [ -e "$wd/$f" ]; then
            printf '0\tspecial_file\t%s\n' "$f" >>"$skipfile"
        fi
    done < <(_ckpt_git "$wd" ls-files --others --exclude-standard -z)
    # Tracked submodules that are checked out: the gitlink stays as the index has it; the contents are not captured.
    while IFS= read -r -d '' rec; do
        case "$rec" in
            160000\ *)
                p="${rec#*$'\t'}"
                if [ -e "$wd/$p/.git" ]; then
                    case "$p" in
                        *[[:cntrl:]]*|*\\*) printf '0\t!\tunlisted\n' >>"$skipfile" ;;
                        *) printf '0\tembedded_repo\t%s\n' "$p" >>"$skipfile" ;;
                    esac
                fi ;;
        esac
    done < <(_ckpt_git "$wd" ls-files --stage -z)
    if [ -s "$paths" ]; then
        _CKPT_IN="$paths" _ckpt_git "$wd" update-index --add --remove -z --stdin >/dev/null || { rm -f "$paths"; return 1; }
    fi
    rm -f "$paths"
    _ckpt_git "$wd" write-tree
}

# _ckpt_push <work_dir> <out> <git push args...>: bounded `git push --porcelain`, stdout in <out>.
_ckpt_push() {
    local wd="$1" out="$2" o rc=0; shift 2
    o=$(_ckpt_git "$wd" push --porcelain --no-verify --no-recurse-submodules --receive-pack=git-receive-pack "$@") || rc=$?
    printf '%s\n' "$o" >"$out"
    return "$rc"
}

# --- take ----------------------------------------------------------------------------------------

# mother_checkpoint_take <job-file> <out-dir> [--salvage-epoch N] [--final] [--expect-sha SHA]
# Prints the manifest (or {"skipped":"unchanged"}, or {"why":...} on a failure that produced no
# manifest: timeout, unborn_head, snapshot_failed). Exit 0 ok (a failed push is pushed:false, not an
# error), 3 fenced (lease lost), 1 usage/other failure. Needs MOTHER_LEASE_ID (an id) and, without
# --salvage-epoch, MOTHER_LEASE_EPOCH (a positive integer); both are checked before anything runs or is
# pushed. The previous manifest is $MOTHER_CHECKPOINT_PREV_MANIFEST, else <out-dir>/manifest.json.
# The lease's expected remote value (what a push may replace) is --expect-sha /
# $MOTHER_CHECKPOINT_EXPECT_SHA, else <out-dir>/../.last-pushed, else the work dir's mother-wip-expect
# marker (written by a successful take and by restore), else the remote's current value: a missing
# local state file is never "fenced". The timeout (60 s, 30 s with --final) is one deadline for the
# whole take: every git call, local or network, is bounded by it and killed as a process group.
mother_checkpoint_take() {
    local job_file="${1:-}" out_dir="${2:-}"
    [ $# -ge 2 ] && shift 2 || shift $#
    local salvage="" final=0 expect_flag="${MOTHER_CHECKPOINT_EXPECT_SHA:-}"
    while [ $# -gt 0 ]; do
        case "$1" in
            --salvage-epoch) salvage="${2:-}"; shift 2 ;;
            --final) final=1; shift ;;
            --expect-sha) expect_flag="${2:-}"; shift 2 ;;
            *) echo "mother: checkpoint take: unknown argument: $1" >&2; return 1 ;;
        esac
    done
    [ -r "$job_file" ] && [ -n "$out_dir" ] || { echo "mother: checkpoint take: usage: <job-file> <out-dir>" >&2; return 1; }
    case "$salvage" in
        '') ;;
        *[!0-9]*|0*) echo "mother: checkpoint take: --salvage-epoch must be a positive integer" >&2; return 1 ;;
    esac
    if [ -n "$expect_flag" ] && ! _ckpt_sha_ok "$expect_flag"; then
        echo "mother: checkpoint take: --expect-sha must be a 40 or 64 hex sha" >&2; return 1
    fi
    # Lease identity first: nothing is built or pushed without it.
    if ! _ckpt_session_ok "${MOTHER_LEASE_ID:-}"; then
        echo "mother: checkpoint take: MOTHER_LEASE_ID must be set to an id (1..128 of [A-Za-z0-9._:-])" >&2; return 1
    fi
    if [ -z "$salvage" ]; then
        case "${MOTHER_LEASE_EPOCH:-}" in
            ''|*[!0-9]*|0*) echo "mother: checkpoint take: MOTHER_LEASE_EPOCH must be set to a positive integer" >&2; return 1 ;;
        esac
        [ "${#MOTHER_LEASE_EPOCH}" -le 15 ] || { echo "mother: checkpoint take: MOTHER_LEASE_EPOCH is too large" >&2; return 1; }
    fi
    [ "${#salvage}" -le 15 ] || { echo "mother: checkpoint take: --salvage-epoch is too large" >&2; return 1; }

    local timeout="${MOTHER_CHECKPOINT_TIMEOUT_S:-60}"
    [ "$final" -eq 1 ] && timeout="${MOTHER_CHECKPOINT_FINAL_TIMEOUT_S:-30}"
    case "$timeout" in ''|*[!0-9]*|0) timeout=60 ;; esac
    _CKPT_DEADLINE=$((SECONDS + timeout))
    _CKPT_PREPARED=0

    mkdir -p "$out_dir" || return 1
    local parent; parent=$(cd "$out_dir/.." && pwd) || return 1
    _switch_with_lock "$parent/.ckpt" "checkpoint" 200 _ckpt_take_locked "$job_file" "$out_dir" "$parent" "$salvage" "$final" "$expect_flag"
    local rc=$?
    _ckpt_cleanup
    return $rc
}

# _ckpt_take_fail <why> <message>: a failure that produced no manifest. A passed deadline wins.
_ckpt_take_fail() {
    local why="$1"
    _ckpt_expired && why=timeout
    echo "mother: checkpoint take: $2 ($why)" >&2
    jq -n -c --arg why "$why" '{why:$why}'
    return 1
}

_ckpt_take_locked() {
    local job_file="$1" out_dir="$2" parent="$3" salvage="$4" final="$5" expect_flag="$6"
    local job wd branch base_sha session
    job=$(jq -r '.id // ""' "$job_file") || return 1
    wd=$(jq -r '.work_dir // ""' "$job_file")
    branch=$(jq -r '.branch // ""' "$job_file")
    base_sha=$(jq -r '.base_sha // ""' "$job_file")
    session=$(jq -r '.session_id // ""' "$job_file")
    _ckpt_job_ok "$job" || { echo "mother: checkpoint take: job id is not a valid ref component" >&2; return 1; }
    [ -n "$wd" ] && [ -d "$wd" ] || { echo "mother: checkpoint take: work_dir missing: $wd" >&2; return 1; }
    _ckpt_branch_ok "$branch" || { echo "mother: checkpoint take: branch is not a conservative ref name: $branch" >&2; return 1; }
    _ckpt_session_ok "$session" || { echo "mother: checkpoint take: bad session_id" >&2; return 1; }

    local lease="$MOTHER_LEASE_ID" epoch="${MOTHER_LEASE_EPOCH:-}"
    [ -n "$salvage" ] && epoch="$salvage"

    _ckpt_prepare "$wd"
    [ -z "$_CKPT_REFUSE" ] || { echo "mother: checkpoint take: refusing $wd: $_CKPT_REFUSE" >&2; jq -n -c '{why:"unsafe_config"}'; return 1; }
    local head
    head=$(_ckpt_git "$wd" rev-parse --verify -q HEAD) || { _ckpt_take_fail unborn_head "no commit at HEAD in $wd (an unborn HEAD cannot be checkpointed)"; return 1; }
    _ckpt_sha_ok "$head" || { _ckpt_take_fail unborn_head "HEAD did not resolve in $wd"; return 1; }

    # 1. Transcript: copied ONCE; size, sha256 and the delta all come from this copy.
    local tdir tfile="" tcopy tsize=0 tsha t_trunc=false tcap_mb="${MOTHER_CHECKPOINT_MAX_TRANSCRIPT_MB:-256}" tcap
    case "$tcap_mb" in ''|*[!0-9]*|0) tcap_mb=256 ;; esac
    tcap=$((tcap_mb * 1048576))
    tdir="$(_ckpt_projects_dir)/$(_ckpt_encode_path "$wd")"
    tcopy=$(_ckpt_mktemp) || return 1
    if [ -n "$session" ] && [ -f "$tdir/$session.jsonl" ] && [ ! -L "$tdir/$session.jsonl" ]; then
        tfile="$tdir/$session.jsonl"
        head -c "$((tcap + 1))" "$tfile" >"$tcopy" || return 1
        tsize=$(_ckpt_size "$tcopy")
        if [ "$tsize" -gt "$tcap" ]; then
            head -c "$tcap" "$tcopy" >"$tcopy.cap" && mv "$tcopy.cap" "$tcopy" || return 1
            tsize=$tcap; t_trunc=true
        fi
        tsha=$(_ckpt_sha256 <"$tcopy")
    else
        tsha=$(: | _ckpt_sha256)
    fi

    # 2. WIP tree from a temp copy of the index; the worktree and its index are never written.
    local idx tmpidx skipfile tree
    idx=$(_ckpt_git_path "$wd" index) || { _ckpt_take_fail snapshot_failed "could not locate the index"; return 1; }
    tmpidx=$(_ckpt_mktemp) || return 1
    skipfile=$(_ckpt_mktemp) || return 1
    if [ -f "$idx" ]; then cp "$idx" "$tmpidx" || return 1; else rm -f "$tmpidx"; fi
    tree=$(_ckpt_tree_of "$wd" "$tmpidx" "$skipfile") || { rm -f "$skipfile.paths"; _ckpt_take_fail snapshot_failed "could not snapshot $wd"; return 1; }
    [ -n "$tree" ] || { _ckpt_take_fail snapshot_failed "could not snapshot $wd"; return 1; }

    local prev="${MOTHER_CHECKPOINT_PREV_MANIFEST:-$out_dir/manifest.json}"
    local prev_n=0 prev_head="" prev_wip="" prev_tbytes=0 prev_tsha="" prev_pushed=false
    if [ -s "$prev" ] && jq -e . "$prev" >/dev/null 2>&1; then
        prev_n=$(jq -r '.n // 0' "$prev")
        prev_head=$(jq -r '.head_sha // ""' "$prev")
        prev_wip=$(jq -r '.wip_sha // ""' "$prev")
        prev_tbytes=$(jq -r '.transcript.bytes // 0' "$prev")
        prev_tsha=$(jq -r '.transcript.sha256 // ""' "$prev")
        prev_pushed=$(jq -r '.pushed // false' "$prev")
    fi

    # 3. Skip only when the previous take really reached the remote and nothing changed since.
    if [ "$final" -ne 1 ] && [ -z "$salvage" ] && [ "$prev_pushed" = true ] && [ -n "$prev_wip" ] && [ "$prev_head" = "$head" ] \
        && [ "$prev_tbytes" = "$tsize" ] && [ "$prev_tsha" = "$tsha" ] \
        && [ "$(_ckpt_git "$wd" rev-parse "$prev_wip^{tree}" 2>/dev/null || true)" = "$tree" ]; then
        echo '{"skipped":"unchanged"}'
        return 0
    fi

    local n=$((prev_n + 1)) now wip
    now=$(_iso_now)
    wip=$(_ckpt_git "$wd" -c user.name=mother-checkpoint -c user.email=mother@localhost \
        commit-tree "$tree" -p "$head" -m "mother wip $job n=$n at $now") \
        || { _ckpt_take_fail commit_failed "could not create the wip commit"; return 1; }

    # 4. Push with fencing.
    local pushed=false push_error="" branch_push="" rc=0 pout wip_ref="refs/mother/wip/$job" target expect="" state_file marker
    state_file="$parent/.last-pushed"
    marker=$(_ckpt_git_path "$wd" mother-wip-expect) || marker=""
    pout=$(_ckpt_mktemp) || return 1
    if [ -n "$salvage" ]; then
        target="refs/mother/wip-salvage/$job/lease-$salvage"
        _ckpt_push "$wd" "$pout" origin "+$wip:$target" || rc=$?
    else
        target="$wip_ref"
        if [ -n "$expect_flag" ]; then expect="$expect_flag"
        elif [ -s "$state_file" ]; then expect=$(cat "$state_file")
        elif [ -n "$marker" ] && [ -s "$marker" ]; then expect=$(cat "$marker")
        else expect=$(_ckpt_ls_remote_ref "$wd" "$target" || true)
        fi
        # No "+" on the refspec: a "+" overrides the lease check, so a moved ref would be overwritten.
        # The explicit lease alone allows the non-fast-forward update when the ref is where we left it.
        _ckpt_push "$wd" "$pout" origin "$wip:$target" "--force-with-lease=$target:$expect" || rc=$?
    fi
    local exit_code=0 cur
    if [ "$rc" -eq 0 ]; then
        pushed=true
        if [ -z "$salvage" ]; then
            printf '%s' "$wip" >"$state_file"
            [ -n "$marker" ] && printf '%s' "$wip" >"$marker" 2>/dev/null
        fi
    elif [ "$rc" -eq 137 ]; then
        push_error="push timed out"
    elif [ -z "$salvage" ] && grep -q '^!' "$pout" 2>/dev/null \
        && cur=$(_ckpt_ls_remote_ref "$wd" "$target") && [ "$cur" != "$expect" ]; then
        # The remote refused the update (a "!" porcelain flag) AND the ref is no longer where our lease
        # said it was: the lease is lost. Language-independent: no message text is matched.
        push_error="fenced"; exit_code=3
    else
        push_error="push failed (exit $rc)"
    fi

    # Committed work also goes to the job branch (fast-forward only, never forced), unless this worker
    # lost its lease or is salvaging.
    if [ "$exit_code" -eq 0 ] && [ -z "$salvage" ]; then
        branch_push=$(_ckpt_push_branch "$wd" "$branch" "$head" "$pout")
    fi

    # 5. Transcript delta from the copy (the whole copy when it shrank or its prefix changed); outputs
    # are written to temp names and moved into place.
    local t_reset=false sub_skipped=false dtmp="$out_dir/.transcript.delta.tmp.$$"
    if [ -n "$tfile" ] && [ "$prev_tbytes" -gt 0 ] && [ "$tsize" -ge "$prev_tbytes" ] \
        && [ "$(head -c "$prev_tbytes" "$tcopy" | _ckpt_sha256)" = "$prev_tsha" ]; then
        tail -c +"$((prev_tbytes + 1))" "$tcopy" >"$dtmp" || return 1
    elif [ -n "$tfile" ]; then
        cp "$tcopy" "$dtmp" || return 1
        [ "$prev_tbytes" -gt 0 ] && t_reset=true
    else
        : >"$dtmp"
    fi
    mv "$dtmp" "$out_dir/transcript.delta" || return 1
    local subsrc="$tdir/$session" subtmp="$out_dir/.transcript.subagents.tmp.$$" scap_mb="${MOTHER_CHECKPOINT_MAX_SUBAGENT_MB:-64}" kb
    case "$scap_mb" in ''|*[!0-9]*|0) scap_mb=64 ;; esac
    safe_rm_tree "$subtmp"
    if [ -n "$tfile" ] && [ -d "$subsrc" ] && [ ! -L "$subsrc" ]; then
        kb=$(du -sk "$subsrc" 2>/dev/null | awk '{print $1}')
        if [ "${kb:-0}" -gt $((scap_mb * 1024)) ]; then
            sub_skipped=true
        else
            cp -RP "$subsrc" "$subtmp" || { safe_rm_tree "$subtmp"; sub_skipped=true; }
        fi
    fi
    safe_rm_tree "$out_dir/transcript.subagents"
    [ -d "$subtmp" ] && mv "$subtmp" "$out_dir/transcript.subagents"

    # 6. Manifest.
    local skipped_json skip_trunc manifest sk
    sk=$(jq -R -s -c '
        split("\n") | map(select(length>0) | split("\t")) as $rows
        | ($rows | map(select(.[1] != "!")) | map({path: (.[2:] | join("\t")), bytes: (.[0] | tonumber), reason: .[1]})) as $list
        | {list: $list[:1024], truncated: (($list | length) > 1024 or ($rows | map(select(.[1] == "!")) | length) > 0)}' <"$skipfile")
    skipped_json=$(printf '%s' "$sk" | jq -c .list)
    skip_trunc=$(printf '%s' "$sk" | jq -c .truncated)
    manifest=$(jq -n -c \
        --arg job "$job" --arg lease "$lease" --argjson epoch "$epoch" --argjson n "$n" --arg at "$now" \
        --arg head "$head" --arg branch "$branch" --arg base "$base_sha" --arg wip "$wip" --arg wipref "$wip_ref" \
        --argjson pushed "$pushed" --arg perr "$push_error" --arg bp "$branch_push" --arg sess "$session" \
        --arg tpath "checkpoints/$job/$session.jsonl" --argjson tbytes "$tsize" --arg tsha "$tsha" --argjson treset "$t_reset" \
        --argjson ttrunc "$t_trunc" --argjson subskip "$sub_skipped" \
        --argjson skipped "$skipped_json" --argjson skiptrunc "$skip_trunc" '
        {v:1, job:$job, lease:$lease, epoch:$epoch, n:$n, at:$at, head_sha:$head, branch:$branch, base_sha:$base,
         wip_sha:$wip, wip_ref:$wipref, pushed:$pushed}
        + (if $perr != "" then {push_error:$perr} else {} end)
        + (if $bp != "" then {branch_push:$bp} else {} end)
        + {session_id:$sess,
           transcript: ({path_rel:$tpath, bytes:$tbytes, sha256:$tsha}
               + (if $treset then {reset:true} else {} end)
               + (if $ttrunc then {truncated:true} else {} end)
               + (if $subskip then {subagents_skipped:true} else {} end)),
           untracked_skipped:$skipped}
        + (if $skiptrunc then {untracked_skipped_truncated:true} else {} end)') || return 1
    printf '%s\n' "$manifest" >"$out_dir/manifest.json.tmp.$$" && mv "$out_dir/manifest.json.tmp.$$" "$out_dir/manifest.json" || return 1
    printf '%s\n' "$manifest"
    return "$exit_code"
}

# _ckpt_push_branch <wd> <branch> <head> <tmpfile>: fast-forward origin/<branch> to HEAD when the branch
# already exists there. Prints uptodate|fast_forwarded|diverged|behind|failed, or nothing when the
# branch is not on origin (or origin is unreachable).
_ckpt_push_branch() {
    local wd="$1" branch="$2" head="$3" tmp="$4" remote rc=0
    remote=$(_ckpt_ls_remote_ref "$wd" "refs/heads/$branch") || return 0
    [ -n "$remote" ] || return 0
    if [ "$remote" = "$head" ]; then echo uptodate; return 0; fi
    if _ckpt_git "$wd" merge-base --is-ancestor "$remote" "$head" >/dev/null 2>&1; then
        _ckpt_push "$wd" "$tmp" origin "$head:refs/heads/$branch" || rc=$?
        if [ "$rc" -eq 0 ]; then echo fast_forwarded; else echo failed; fi
    elif _ckpt_git "$wd" merge-base --is-ancestor "$head" "$remote" >/dev/null 2>&1; then
        echo behind
    else
        echo diverged
    fi
}

# --- restore -------------------------------------------------------------------------------------

_ckpt_restore_fail() {
    jq -n -c --arg why "$1" '{restored:false, why:$why}'
    return 4
}

# mother_checkpoint_restore <manifest> <transcript-file> <repo_path> <new_work_dir>
# Exit 0 restored, 4 not restorable (why: wip_missing, head_missing, chain_mismatch,
# transcript_mismatch, tree_mismatch), 1 usage/other. Never falls back to a fresh start; a failure after
# the worktree was added removes it again. <new_work_dir> must be absolute, without "..", and
# nonexistent or empty. Branch handling: the local branch at head_sha is used; one that is an
# ancestor of head_sha is fast-forwarded; a newer or diverged one is left alone and the work is
# restored detached (branch_state "detached"); a branch checked out in another worktree is refused.
# Output: restored, head_sha, wip_sha, transcript_sha, source, branch_state, detached, base_sha,
# base_moved, incomplete (embedded repos were not captured), skipped.
mother_checkpoint_restore() {
    local manifest="${1:-}" tfile="${2:-}" repo="${3:-}" newwd="${4:-}"
    [ -r "$manifest" ] && [ -n "$repo" ] && [ -n "$newwd" ] \
        || { echo "mother: checkpoint restore: usage: <manifest> <transcript-file> <repo_path> <new_work_dir>" >&2; return 1; }
    local job branch head wip session tsha_want base_sha
    job=$(jq -r '.job // ""' "$manifest") || return 1
    branch=$(jq -r '.branch // ""' "$manifest")
    head=$(jq -r '.head_sha // ""' "$manifest")
    wip=$(jq -r '.wip_sha // ""' "$manifest")
    base_sha=$(jq -r '.base_sha // ""' "$manifest")
    session=$(jq -r '.session_id // ""' "$manifest")
    tsha_want=$(jq -r '.transcript.sha256 // ""' "$manifest")
    _ckpt_job_ok "$job" && _ckpt_branch_ok "$branch" && _ckpt_sha_ok "$head" && _ckpt_sha_ok "$wip" \
        || { echo "mother: checkpoint restore: manifest has a malformed job, branch or sha" >&2; return 1; }
    _ckpt_session_ok "$session" || { echo "mother: checkpoint restore: bad session_id" >&2; return 1; }

    newwd="${newwd%/}"
    case "$newwd" in
        /*) ;;
        *) echo "mother: checkpoint restore: new work dir must be an absolute path: $newwd" >&2; return 1 ;;
    esac
    case "$newwd/" in
        */../*|*/./*|*//*) echo "mother: checkpoint restore: new work dir must not contain '..', '.' or '//': $newwd" >&2; return 1 ;;
    esac
    if [ -e "$newwd" ] || [ -L "$newwd" ]; then
        if [ -L "$newwd" ] || [ ! -d "$newwd" ] || [ -n "$(ls -A "$newwd" 2>/dev/null)" ]; then
            echo "mother: checkpoint restore: new work dir exists and is not an empty directory: $newwd" >&2; return 1
        fi
    fi
    git -C "$repo" rev-parse --git-dir >/dev/null 2>&1 || { echo "mother: checkpoint restore: not a git repo: $repo" >&2; return 1; }

    # Transcript first: nothing is created if it does not match.
    if [ ! -f "$tfile" ] || [ "$(_ckpt_sha256 <"$tfile")" != "$tsha_want" ]; then
        _ckpt_restore_fail transcript_mismatch; return $?
    fi

    local rt="${MOTHER_CHECKPOINT_RESTORE_TIMEOUT_S:-300}"
    case "$rt" in ''|*[!0-9]*|0) rt=300 ;; esac
    _CKPT_DEADLINE=$((SECONDS + rt))
    _ckpt_prepare "$repo"
    [ -z "$_CKPT_REFUSE" ] || { echo "mother: checkpoint restore: refusing $repo: $_CKPT_REFUSE" >&2; return 1; }

    # 1. The wip commit: fetch it, or use the object already in a shared store.
    local ref="refs/mother/wip/$job" source=origin
    _ckpt_git "$repo" fetch --no-tags --no-recurse-submodules --upload-pack=git-upload-pack origin "+$ref:$ref" >/dev/null || source=local_object
    _ckpt_git "$repo" cat-file -e "$wip^{commit}" >/dev/null 2>&1 || { _ckpt_restore_fail wip_missing; return $?; }
    _ckpt_git "$repo" cat-file -e "$head^{commit}" >/dev/null 2>&1 || { _ckpt_restore_fail head_missing; return $?; }
    local wip_tree parents
    wip_tree=$(_ckpt_git "$repo" rev-parse "$wip^{tree}") || { _ckpt_restore_fail wip_missing; return $?; }
    # The wip commit must be exactly one commit on top of head_sha.
    parents=$(_ckpt_git "$repo" rev-list --parents -n 1 "$wip") || { _ckpt_restore_fail wip_missing; return $?; }
    # shellcheck disable=SC2086
    set -- $parents
    if [ $# -ne 2 ] || [ "$2" != "$head" ]; then _ckpt_restore_fail chain_mismatch; return $?; fi

    # 2. New worktree (no checkout yet), then the content under the hardened wrapper (no hooks, no drivers).
    _ckpt_git "$repo" worktree prune >/dev/null 2>&1 || true
    local tip="" branch_state=exact detached=false created_branch=0
    if _ckpt_git "$repo" show-ref --verify --quiet "refs/heads/$branch" >/dev/null 2>&1; then
        tip=$(_ckpt_git "$repo" rev-parse "refs/heads/$branch") || return 1
        if [ "$tip" = "$head" ]; then
            _ckpt_git "$repo" worktree add --no-checkout "$newwd" "$branch" >/dev/null \
                || { echo "mother: checkpoint restore: worktree add failed (branch $branch may be checked out elsewhere)" >&2; return 1; }
        elif _ckpt_git "$repo" merge-base --is-ancestor "$tip" "$head" >/dev/null 2>&1; then
            _ckpt_git "$repo" worktree add --no-checkout "$newwd" "$branch" >/dev/null \
                || { echo "mother: checkpoint restore: worktree add failed (branch $branch may be checked out elsewhere)" >&2; return 1; }
            _ckpt_git "$newwd" update-ref -m "mother checkpoint restore: fast-forward" "refs/heads/$branch" "$head" "$tip" >/dev/null \
                || { _ckpt_restore_cleanup "$repo" "$newwd" 0 "$branch"; echo "mother: checkpoint restore: could not fast-forward $branch" >&2; return 1; }
            branch_state=fast_forwarded
        else
            _ckpt_git "$repo" worktree add --no-checkout --detach "$newwd" "$head" >/dev/null \
                || { echo "mother: checkpoint restore: worktree add failed" >&2; return 1; }
            branch_state=detached; detached=true
        fi
    else
        _ckpt_git "$repo" worktree add --no-checkout -b "$branch" "$newwd" "$head" >/dev/null \
            || { echo "mother: checkpoint restore: worktree add failed" >&2; return 1; }
        branch_state=created; created_branch=1
    fi

    local rc=0
    _CKPT_RESTORED_T=""
    _ckpt_restore_populate "$manifest" "$tfile" "$repo" "$newwd" "$head" "$wip" "$wip_tree" "$session" "$tsha_want" || rc=$?
    if [ "$rc" -ne 0 ]; then
        _ckpt_restore_cleanup "$repo" "$newwd" "$created_branch" "$branch"
        return "$rc"
    fi

    local base_moved=true
    if _ckpt_sha_ok "$base_sha" && _ckpt_git "$repo" cat-file -e "$base_sha^{commit}" >/dev/null 2>&1 \
        && _ckpt_git "$repo" merge-base --is-ancestor "$base_sha" "$head" >/dev/null 2>&1; then
        base_moved=false
    fi
    local mk; mk=$(_ckpt_git_path "$newwd" mother-wip-expect) && printf '%s' "$wip" >"$mk" 2>/dev/null
    jq -n -c --arg head "$head" --arg wip "$wip" --arg tsha "$tsha_want" --arg src "$source" \
        --arg bs "$branch_state" --argjson det "$detached" --arg base "$base_sha" --argjson bm "$base_moved" \
        --slurpfile m "$manifest" '
        {restored:true, head_sha:$head, wip_sha:$wip, transcript_sha:$tsha, source:$src, branch_state:$bs, detached:$det,
         base_sha:$base, base_moved:$bm,
         incomplete: ((($m[0].untracked_skipped // []) | map(select(.reason == "embedded_repo")) | length) > 0),
         skipped:($m[0].untracked_skipped // [])}'
}

# _ckpt_restore_populate: lay head + the wip tree into <newwd>, copy the transcript, verify. Prints a
# failure JSON itself for the exit-4 reasons; returns 0 / 1 / 4.
_ckpt_restore_populate() {
    local manifest="$1" tfile="$2" repo="$3" newwd="$4" head="$5" wip="$6" wip_tree="$7" session="$8" tsha_want="$9" f
    _ckpt_git "$newwd" reset -q --hard "$head" >/dev/null || { echo "mother: checkpoint restore: could not check out $head" >&2; return 1; }
    # Files deleted in the worktree at capture time (in HEAD, absent from the wip tree) go first, while
    # the tree is exactly HEAD, so no path is resolved through anything the wip tree adds.
    while IFS= read -r -d '' f; do
        _ckpt_relpath_ok "$f" || { echo "mother: checkpoint restore: unsafe path in the wip tree: $f" >&2; return 1; }
        rm -f "${newwd:?}/${f:?}"
    done < <(_ckpt_git "$newwd" diff-tree -r -z --name-only --diff-filter=D "$head" "$wip_tree")
    _ckpt_git "$newwd" read-tree "$wip_tree" >/dev/null || return 1
    _ckpt_git "$newwd" checkout-index -a -f >/dev/null || return 1
    _ckpt_git "$newwd" reset -q --mixed "$head" >/dev/null || return 1

    # Transcript under the new path's encoded dir (plus the subagent dir next to the file).
    local tdir; tdir="$(_ckpt_projects_dir)/$(_ckpt_encode_path "$newwd")"
    mkdir -p "$tdir" && cp "$tfile" "$tdir/$session.jsonl" || { echo "mother: checkpoint restore: could not write the transcript" >&2; return 1; }
    _CKPT_RESTORED_T="$tdir/$session.jsonl"
    if [ -d "$(dirname "$tfile")/$session" ]; then
        safe_rm_tree "$tdir/$session"
        cp -RP "$(dirname "$tfile")/$session" "$tdir/$session" || return 1
    fi

    # Verify HEAD, the working tree and the transcript.
    local got_head idx tmpidx skipfile got_tree
    got_head=$(_ckpt_git "$newwd" rev-parse HEAD) || return 1
    [ "$got_head" = "$head" ] || { _ckpt_restore_fail head_missing; return $?; }
    idx=$(_ckpt_git_path "$newwd" index) || return 1
    tmpidx=$(_ckpt_mktemp) || return 1
    skipfile=$(_ckpt_mktemp) || return 1
    cp "$idx" "$tmpidx" || return 1
    got_tree=$(_ckpt_tree_of "$newwd" "$tmpidx" "$skipfile") || got_tree=""
    rm -f "$skipfile.paths"
    _ckpt_cleanup
    [ "$got_tree" = "$wip_tree" ] || { _ckpt_restore_fail tree_mismatch; return $?; }
    [ "$(_ckpt_sha256 <"$tdir/$session.jsonl")" = "$tsha_want" ] || { _ckpt_restore_fail transcript_mismatch; return $?; }
    return 0
}

# _ckpt_restore_cleanup <repo> <newwd> <created_branch> <branch>: undo a half-built restore so a retry
# at the same path starts clean.
_ckpt_restore_cleanup() {
    local repo="$1" newwd="$2" created="$3" branch="$4"
    _CKPT_DEADLINE=$((SECONDS + 30))
    _ckpt_git "$repo" worktree remove --force "$newwd" >/dev/null 2>&1 || true
    [ -d "$newwd" ] && safe_rm_tree "$newwd"
    _ckpt_git "$repo" worktree prune >/dev/null 2>&1 || true
    [ "$created" = 1 ] && { _ckpt_git "$repo" branch -D "$branch" >/dev/null 2>&1 || true; }
    [ -n "${_CKPT_RESTORED_T:-}" ] && rm -f "$_CKPT_RESTORED_T"
    _ckpt_cleanup
    return 0
}
