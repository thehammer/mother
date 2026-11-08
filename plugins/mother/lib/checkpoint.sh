#!/usr/bin/env bash
# checkpoint.sh — WIP checkpoint of a job's repository state and transcript (cluster P1-3, B8/B9).
#
# mother_checkpoint_take    snapshot the worktree (tracked edits, staged, untracked, not ignored) as a
#                           commit built in a TEMP index, push it fenced to refs/mother/wip/<job>, copy the
#                           transcript delta and write a manifest (docs/worker-protocol.md section 9).
# mother_checkpoint_restore rebuild HEAD, the working changes and the transcript at another path.
#
# Never runs `git stash`, `git add` on the real index, `git commit` or `git reset` in the job's worktree.
# No runtime path calls this library yet (P1-6 wires it). Sourced under `set -u`, bash 3.2: no
# `declare -A`, no `mapfile`. Needs lib/state.sh (_bounded_run, _switch_with_lock, _iso_now,
# safe_rm_tree) and jq.

_CKPT_TMPS=""

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

_ckpt_sha_ok() {
    case "$1" in *[!0-9a-f]*|'') return 1 ;; esac
    [ "${#1}" -eq 40 ] || [ "${#1}" -eq 64 ]
}

_ckpt_sha256() {
    if command -v shasum >/dev/null 2>&1; then shasum -a 256 | awk '{print $1}'
    else sha256sum | awk '{print $1}'; fi
}

_ckpt_size() { wc -c <"$1" | tr -d ' '; }

# _ckpt_index_path <work_dir>: absolute path of the worktree's real index.
_ckpt_index_path() {
    local idx; idx=$(git -C "$1" rev-parse --git-path index) || return 1
    case "$idx" in /*) printf '%s' "$idx" ;; *) printf '%s/%s' "$1" "$idx" ;; esac
}

# _ckpt_tree_of <work_dir> <tmpidx> <skipfile>: tree of the worktree contents (non-ignored), built in
# <tmpidx>, which must already hold a copy of the index. Untracked files over the size cap are left
# out and written to <skipfile> as "<bytes>\t<path>". Prints the tree sha.
_ckpt_tree_of() {
    local wd="$1" tmpidx="$2" skipfile="$3" max_mb="${MOTHER_CHECKPOINT_MAX_FILE_MB:-50}"
    case "$max_mb" in ''|*[!0-9]*) max_mb=50 ;; esac
    local max_bytes=$((max_mb * 1048576)) f sz
    : >"$skipfile"
    GIT_INDEX_FILE="$tmpidx" git -C "$wd" add -A -- . >/dev/null 2>&1 || return 1
    while IFS= read -r -d '' f; do
        [ -f "$wd/$f" ] || continue
        sz=$(_ckpt_size "$wd/$f")
        if [ "$sz" -gt "$max_bytes" ]; then
            GIT_INDEX_FILE="$tmpidx" git -C "$wd" update-index --force-remove -- "$f" >/dev/null 2>&1 || return 1
            printf '%s\t%s\n' "$sz" "$f" >>"$skipfile"
        fi
    done < <(git -C "$wd" ls-files --others --exclude-standard -z)
    GIT_INDEX_FILE="$tmpidx" git -C "$wd" write-tree
}

# _ckpt_push <work_dir> <timeout> <out> <git push args...>: bounded `git push --porcelain`, stdout in <out>.
_ckpt_push() {
    local wd="$1" secs="$2" out="$3"; shift 3
    GIT_TERMINAL_PROMPT=0 _bounded_run "$secs" "$out" git -C "$wd" push --porcelain --no-verify "$@"
}

_ckpt_remaining() {
    local left=$(( ${_CKPT_DEADLINE:-0} - SECONDS ))
    [ "$left" -lt 1 ] && left=1
    echo "$left"
}

# --- take ----------------------------------------------------------------------------------------

# mother_checkpoint_take <job-file> <out-dir> [--salvage-epoch N] [--final]
# Prints the manifest (or {"skipped":"unchanged"}). Exit 0 ok (a failed push is pushed:false, not an
# error), 3 fenced (lease lost), 1 usage/other failure. The previous manifest is
# $MOTHER_CHECKPOINT_PREV_MANIFEST, else <out-dir>/manifest.json. The timeout (60 s, 30 s with --final)
# is a deadline shared by every git network call of the take.
mother_checkpoint_take() {
    local job_file="${1:-}" out_dir="${2:-}"
    [ $# -ge 2 ] && shift 2 || shift $#
    local salvage="" final=0
    while [ $# -gt 0 ]; do
        case "$1" in
            --salvage-epoch) salvage="${2:-}"; shift 2 ;;
            --final) final=1; shift ;;
            *) echo "mother: checkpoint take: unknown argument: $1" >&2; return 1 ;;
        esac
    done
    [ -r "$job_file" ] && [ -n "$out_dir" ] || { echo "mother: checkpoint take: usage: <job-file> <out-dir>" >&2; return 1; }
    case "$salvage" in
        '') ;;
        *[!0-9]*|0*) echo "mother: checkpoint take: --salvage-epoch must be a positive integer" >&2; return 1 ;;
    esac

    local timeout="${MOTHER_CHECKPOINT_TIMEOUT_S:-60}"
    [ "$final" -eq 1 ] && timeout="${MOTHER_CHECKPOINT_FINAL_TIMEOUT_S:-30}"
    _CKPT_DEADLINE=$((SECONDS + timeout))

    mkdir -p "$out_dir" || return 1
    local parent; parent=$(cd "$out_dir/.." && pwd) || return 1
    _switch_with_lock "$parent/.ckpt" "checkpoint" 200 _ckpt_take_locked "$job_file" "$out_dir" "$parent" "$salvage" "$final"
    local rc=$?
    _ckpt_cleanup
    return $rc
}

_ckpt_take_locked() {
    local job_file="$1" out_dir="$2" parent="$3" salvage="$4" final="$5"
    local job wd branch base_sha session
    job=$(jq -r '.id // ""' "$job_file") || return 1
    wd=$(jq -r '.work_dir // ""' "$job_file")
    branch=$(jq -r '.branch // ""' "$job_file")
    base_sha=$(jq -r '.base_sha // ""' "$job_file")
    session=$(jq -r '.session_id // ""' "$job_file")
    _ckpt_job_ok "$job" || { echo "mother: checkpoint take: job id is not a valid ref component" >&2; return 1; }
    [ -n "$wd" ] && [ -d "$wd" ] || { echo "mother: checkpoint take: work_dir missing: $wd" >&2; return 1; }
    _ckpt_branch_ok "$branch" || { echo "mother: checkpoint take: branch is not a conservative ref name: $branch" >&2; return 1; }
    case "$session" in *[!A-Za-z0-9._:-]*) echo "mother: checkpoint take: bad session_id" >&2; return 1 ;; esac

    local head
    head=$(git -C "$wd" rev-parse HEAD 2>/dev/null) || { echo "mother: checkpoint take: no HEAD in $wd" >&2; return 1; }

    # 1. WIP tree from a temp copy of the index; the worktree and its index are never written.
    local idx tmpidx skipfile tree
    idx=$(_ckpt_index_path "$wd") || return 1
    tmpidx=$(_ckpt_mktemp) || return 1
    skipfile=$(_ckpt_mktemp) || return 1
    if [ -f "$idx" ]; then cp "$idx" "$tmpidx" || return 1; else rm -f "$tmpidx"; fi
    tree=$(_ckpt_tree_of "$wd" "$tmpidx" "$skipfile") || { echo "mother: checkpoint take: could not snapshot $wd" >&2; return 1; }

    local prev="${MOTHER_CHECKPOINT_PREV_MANIFEST:-$out_dir/manifest.json}"
    local prev_n=0 prev_head="" prev_wip="" prev_tbytes=0 prev_tsha=""
    if [ -s "$prev" ] && jq -e . "$prev" >/dev/null 2>&1; then
        prev_n=$(jq -r '.n // 0' "$prev")
        prev_head=$(jq -r '.head_sha // ""' "$prev")
        prev_wip=$(jq -r '.wip_sha // ""' "$prev")
        prev_tbytes=$(jq -r '.transcript.bytes // 0' "$prev")
        prev_tsha=$(jq -r '.transcript.sha256 // ""' "$prev")
    fi

    local tdir tfile="" tsize=0
    tdir="$(_ckpt_projects_dir)/$(_ckpt_encode_path "$wd")"
    if [ -n "$session" ] && [ -f "$tdir/$session.jsonl" ]; then
        tfile="$tdir/$session.jsonl"
        tsize=$(_ckpt_size "$tfile")
    fi

    # 2. Skip when nothing changed.
    if [ "$final" -ne 1 ] && [ -n "$prev_wip" ] && [ "$prev_head" = "$head" ] && [ "$prev_tbytes" = "$tsize" ] \
        && [ "$(git -C "$wd" rev-parse "$prev_wip^{tree}" 2>/dev/null || true)" = "$tree" ]; then
        echo '{"skipped":"unchanged"}'
        return 0
    fi

    local n=$((prev_n + 1)) now wip
    now=$(_iso_now)
    wip=$(git -C "$wd" -c user.name=mother-checkpoint -c user.email=mother@localhost \
        commit-tree "$tree" -p "$head" -m "mother wip $job n=$n at $now") || return 1

    # 3. Push with fencing. The lease's expected value is the last wip sha THIS job dir pushed (a
    # failed push does not advance it), kept next to the per-take dirs.
    local pushed=false push_error="" branch_push="" rc=0 pout wip_ref="refs/mother/wip/$job" target expect state_file
    state_file="$parent/.last-pushed"
    pout=$(_ckpt_mktemp) || return 1
    if [ -n "$salvage" ]; then
        target="refs/mother/wip-salvage/$job/lease-$salvage"
        _ckpt_push "$wd" "$(_ckpt_remaining)" "$pout" origin "+$wip:$target" || rc=$?
    else
        target="$wip_ref"
        expect=""
        [ -s "$state_file" ] && expect=$(cat "$state_file")
        # No "+" on the refspec: a "+" overrides the lease check, so a moved ref would be overwritten.
        # The explicit lease alone allows the non-fast-forward update when the ref is where we left it.
        _ckpt_push "$wd" "$(_ckpt_remaining)" "$pout" origin "$wip:$target" \
            "--force-with-lease=$target:$expect" || rc=$?
    fi
    local exit_code=0
    if [ "$rc" -eq 0 ]; then
        pushed=true
        [ -z "$salvage" ] && printf '%s' "$wip" >"$state_file"
    elif grep -q 'stale info' "$pout" 2>/dev/null; then
        push_error="fenced"; exit_code=3
    elif [ "$rc" -eq 137 ]; then
        push_error="push timed out"
    else
        push_error="push failed (exit $rc)"
    fi

    # Committed work also goes to the job branch (fast-forward only, never forced), unless this worker
    # lost its lease or is salvaging.
    if [ "$exit_code" -eq 0 ] && [ -z "$salvage" ]; then
        branch_push=$(_ckpt_push_branch "$wd" "$branch" "$head" "$pout")
    fi

    # 4. Transcript delta (the whole file when it shrank or its prefix changed).
    local tsha t_reset=false
    if [ -n "$tfile" ]; then tsha=$(_ckpt_sha256 <"$tfile"); else tsha=$(: | _ckpt_sha256); fi
    : >"$out_dir/transcript.delta"
    safe_rm_tree "$out_dir/transcript.subagents"
    if [ -n "$tfile" ]; then
        if [ "$prev_tbytes" -gt 0 ] && [ "$tsize" -ge "$prev_tbytes" ] \
            && [ "$(head -c "$prev_tbytes" "$tfile" | _ckpt_sha256)" = "$prev_tsha" ]; then
            tail -c +"$((prev_tbytes + 1))" "$tfile" >"$out_dir/transcript.delta"
        else
            cp "$tfile" "$out_dir/transcript.delta"
            [ "$prev_tbytes" -gt 0 ] && t_reset=true
        fi
        if [ -d "$tdir/$session" ]; then cp -R "$tdir/$session" "$out_dir/transcript.subagents"; fi
    fi

    # 5. Manifest.
    local skipped_json lease epoch manifest
    skipped_json=$(jq -R -s -c '
        split("\n") | map(select(length>0) | split("\t") | {path: (.[1:] | join("\t")), bytes: (.[0] | tonumber)})' <"$skipfile")
    lease="${MOTHER_LEASE_ID:-}"; epoch="${MOTHER_LEASE_EPOCH:-0}"
    [ -n "$salvage" ] && epoch="$salvage"
    manifest=$(jq -n -c \
        --arg job "$job" --arg lease "$lease" --argjson epoch "${epoch:-0}" --argjson n "$n" --arg at "$now" \
        --arg head "$head" --arg branch "$branch" --arg base "$base_sha" --arg wip "$wip" --arg wipref "$wip_ref" \
        --argjson pushed "$pushed" --arg perr "$push_error" --arg bp "$branch_push" --arg sess "$session" \
        --arg tpath "checkpoints/$job/$session.jsonl" --argjson tbytes "$tsize" --arg tsha "$tsha" --argjson treset "$t_reset" \
        --argjson skipped "$skipped_json" '
        {v:1, job:$job, lease:$lease, epoch:$epoch, n:$n, at:$at, head_sha:$head, branch:$branch, base_sha:$base,
         wip_sha:$wip, wip_ref:$wipref, pushed:$pushed}
        + (if $perr != "" then {push_error:$perr} else {} end)
        + (if $bp != "" then {branch_push:$bp} else {} end)
        + {session_id:$sess,
           transcript: ({path_rel:$tpath, bytes:$tbytes, sha256:$tsha} + (if $treset then {reset:true} else {} end)),
           untracked_skipped:$skipped}') || return 1
    printf '%s\n' "$manifest" >"$out_dir/manifest.json.tmp.$$" && mv "$out_dir/manifest.json.tmp.$$" "$out_dir/manifest.json" || return 1
    printf '%s\n' "$manifest"
    return "$exit_code"
}

# _ckpt_push_branch <wd> <branch> <head> <tmpfile>: fast-forward origin/<branch> to HEAD when the branch
# already exists there. Prints uptodate|fast_forwarded|diverged|behind|failed, or nothing when the
# branch is not on origin (or origin is unreachable).
_ckpt_push_branch() {
    local wd="$1" branch="$2" head="$3" tmp="$4" remote rc=0
    GIT_TERMINAL_PROMPT=0 _bounded_run "$(_ckpt_remaining)" "$tmp" git -C "$wd" ls-remote origin "refs/heads/$branch" || return 0
    remote=$(awk 'NR==1 {print $1}' "$tmp")
    [ -n "$remote" ] || return 0
    if [ "$remote" = "$head" ]; then echo uptodate; return 0; fi
    if git -C "$wd" merge-base --is-ancestor "$remote" "$head" 2>/dev/null; then
        _ckpt_push "$wd" "$(_ckpt_remaining)" "$tmp" origin "$head:refs/heads/$branch" || rc=$?
        if [ "$rc" -eq 0 ]; then echo fast_forwarded; else echo failed; fi
    elif git -C "$wd" merge-base --is-ancestor "$head" "$remote" 2>/dev/null; then
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
# Exit 0 restored, 4 not restorable (why: wip_missing, head_missing, transcript_mismatch, tree_mismatch),
# 1 usage. Never falls back to a fresh start.
mother_checkpoint_restore() {
    local manifest="${1:-}" tfile="${2:-}" repo="${3:-}" newwd="${4:-}"
    [ -r "$manifest" ] && [ -n "$repo" ] && [ -n "$newwd" ] \
        || { echo "mother: checkpoint restore: usage: <manifest> <transcript-file> <repo_path> <new_work_dir>" >&2; return 1; }
    local job branch head wip session tsha_want
    job=$(jq -r '.job // ""' "$manifest") || return 1
    branch=$(jq -r '.branch // ""' "$manifest")
    head=$(jq -r '.head_sha // ""' "$manifest")
    wip=$(jq -r '.wip_sha // ""' "$manifest")
    session=$(jq -r '.session_id // ""' "$manifest")
    tsha_want=$(jq -r '.transcript.sha256 // ""' "$manifest")
    _ckpt_job_ok "$job" && _ckpt_branch_ok "$branch" && _ckpt_sha_ok "$head" && _ckpt_sha_ok "$wip" \
        || { echo "mother: checkpoint restore: manifest has a malformed job, branch or sha" >&2; return 1; }
    case "$session" in ''|*[!A-Za-z0-9._:-]*) echo "mother: checkpoint restore: bad session_id" >&2; return 1 ;; esac
    git -C "$repo" rev-parse --git-dir >/dev/null 2>&1 || { echo "mother: checkpoint restore: not a git repo: $repo" >&2; return 1; }

    # Transcript first: nothing is created if it does not match.
    if [ ! -f "$tfile" ] || [ "$(_ckpt_sha256 <"$tfile")" != "$tsha_want" ]; then
        _ckpt_restore_fail transcript_mismatch; return $?
    fi

    # 1. The wip commit: fetch it, or use the object already in a shared store.
    local ref="refs/mother/wip/$job" source=origin
    if ! GIT_TERMINAL_PROMPT=0 _bounded_run "${MOTHER_CHECKPOINT_TIMEOUT_S:-60}" - \
            git -C "$repo" fetch --no-tags origin "+$ref:$ref"; then
        source=local_object
    fi
    git -C "$repo" cat-file -e "$wip^{commit}" 2>/dev/null || { _ckpt_restore_fail wip_missing; return $?; }
    git -C "$repo" cat-file -e "$head^{commit}" 2>/dev/null || { _ckpt_restore_fail head_missing; return $?; }
    local wip_tree; wip_tree=$(git -C "$repo" rev-parse "$wip^{tree}") || { _ckpt_restore_fail wip_missing; return $?; }

    # 2. New worktree at head_sha, then the wip tree laid over it as unstaged changes.
    git -C "$repo" worktree prune >/dev/null 2>&1 || true
    if git -C "$repo" show-ref --verify --quiet "refs/heads/$branch"; then
        git -C "$repo" worktree add --force "$newwd" "$branch" >/dev/null 2>&1 \
            || { echo "mother: checkpoint restore: worktree add failed" >&2; return 1; }
    else
        git -C "$repo" worktree add --force -b "$branch" "$newwd" "$head" >/dev/null 2>&1 \
            || { echo "mother: checkpoint restore: worktree add failed" >&2; return 1; }
    fi
    git -C "$newwd" reset -q --hard "$head" || return 1
    local f
    git -C "$newwd" read-tree "$wip_tree" || return 1
    git -C "$newwd" checkout-index -a -f || return 1
    # Files deleted in the worktree at capture time: in HEAD, absent from the wip tree.
    while IFS= read -r -d '' f; do rm -f "$newwd/$f"; done \
        < <(git -C "$newwd" diff-tree -r -z --name-only --diff-filter=D "$head" "$wip_tree")
    git -C "$newwd" reset -q --mixed "$head" || return 1

    # 3. Transcript under the new path's encoded dir (plus the subagent dir next to the file).
    local tdir; tdir="$(_ckpt_projects_dir)/$(_ckpt_encode_path "$newwd")"
    mkdir -p "$tdir" && cp "$tfile" "$tdir/$session.jsonl" || return 1
    if [ -d "$(dirname "$tfile")/$session" ]; then
        safe_rm_tree "$tdir/$session"
        cp -R "$(dirname "$tfile")/$session" "$tdir/$session" || return 1
    fi

    # 4. Verify HEAD, the working tree and the transcript.
    local got_head idx tmpidx skipfile got_tree
    got_head=$(git -C "$newwd" rev-parse HEAD)
    [ "$got_head" = "$head" ] || { _ckpt_restore_fail head_missing; return $?; }
    idx=$(_ckpt_index_path "$newwd") || return 1
    tmpidx=$(_ckpt_mktemp) || return 1
    skipfile=$(_ckpt_mktemp) || return 1
    cp "$idx" "$tmpidx" || return 1
    got_tree=$(_ckpt_tree_of "$newwd" "$tmpidx" "$skipfile") || got_tree=""
    _ckpt_cleanup
    [ "$got_tree" = "$wip_tree" ] || { _ckpt_restore_fail tree_mismatch; return $?; }
    [ "$(_ckpt_sha256 <"$tdir/$session.jsonl")" = "$tsha_want" ] || { _ckpt_restore_fail transcript_mismatch; return $?; }

    jq -n -c --arg head "$head" --arg wip "$wip" --arg tsha "$tsha_want" --arg src "$source" \
        --slurpfile m "$manifest" \
        '{restored:true, head_sha:$head, wip_sha:$wip, transcript_sha:$tsha, source:$src, skipped:($m[0].untracked_skipped // [])}'
}
