#!/usr/bin/env bats
# checkpoint_restore_seed.bats — after a failover the new lease's checkpoints must keep advancing latest.json (P1-6).
#
# THE BUG. A checkpoint with pushed:false still ships its transcript delta, and the coordinator appends it to the
# reassembled transcript (checkpoints/<job>/transcript/<session>.jsonl) without moving latest.json. So the coordinator's
# transcript can be LONGER than latest.json's transcript.bytes. A resumed lease restores from latest.json: the staged
# transcript is only the first latest.transcript.bytes bytes (bin/mother-runner), the new session continues from THAT, and
# the new worker's own takes are numbered and diffed against the seed `_restore_from_checkpoint` leaves in its checkpoints
# directory. The new worker's transcript therefore forks from the coordinator's at latest.transcript.bytes, and its deltas
# do not line up with the coordinator's file: "transcript is at X, expected Y", transcript_ok false, latest.json frozen
# at the first lease's checkpoint for the rest of the new lease (and the next failover restores from the old point).
#
# WHAT THESE TESTS RUN FOR REAL (no stand-ins for the code under test):
#   - `mother checkpoint take` / `restore` (lib/checkpoint.sh) against a real git origin and worktrees;
#   - `_restore_from_checkpoint` from bin/mother-run-job (including whatever it leaves in the worker's checkpoints dir),
#     loaded as a function; it is not edited or re-implemented here;
#   - lib/coord_apply.sh replaying the shipped ops onto a canonical root.
# What is re-stated here (the thin glue between them): shipping a finished take as artifact.put x2 + checkpoint.taken
# (lib/checkpoint.sh `mother_checkpoint_ship`), and the runner's staging of the transcript the new lease restores from (the
# first latest.transcript.bytes bytes of the reassembled file, bin/mother-runner `_resume_lost_lease`).
#
# Contract asserted (fix-location agnostic): after the failover, the new lease's checkpoints are accepted (transcript_ok),
# latest.json advances to the new epoch and to its newest checkpoint, and the coordinator's transcript is the new worker's
# transcript byte for byte.

load 'test_helper'

COORD_APPLY="$_LIB_DIR/coord_apply.sh"

setup() {
    setup_mother_env
    export GIT_AUTHOR_NAME=tester GIT_AUTHOR_EMAIL=tester@example.com
    export GIT_COMMITTER_NAME=tester GIT_COMMITTER_EMAIL=tester@example.com
    unset MOTHER_WORKER_MODE MOTHER_WORKER_OUTBOX_DIR MOTHER_LIVE_ROOT MOTHER_CHECKPOINT_AUTO_N \
          MOTHER_CHECKPOINT_TIMEOUT_S MOTHER_CHECKPOINT_EXPECT_SHA MOTHER_RESUME_CHECKPOINT MOTHER_RESUME_TRANSCRIPT MOTHER_RESUME_INFO
    export MOTHER_LIMITER_MODE=off

    T="$(cd "$MOTHER_ROOT" && pwd -P)/fx"
    mkdir -p "$T"
    JOB=j-seed
    SID=sess-seed
    BRANCH=feature/x
    ORIGIN="$T/origin.git"
    REPO1="$T/repo1"     # the first worker's clone
    REPO2="$T/repo2"     # another machine's clone
    WT1="$T/wt1"
    export MOTHER_CLAUDE_PROJECTS_DIR="$T/projects"
    mkdir -p "$MOTHER_CLAUDE_PROJECTS_DIR"

    git init -q --bare -b main "$ORIGIN"
    git clone -q "$ORIGIN" "$REPO1" 2>/dev/null
    git -C "$REPO1" config user.name tester
    git -C "$REPO1" config user.email tester@example.com
    git -C "$REPO1" checkout -q -B main
    printf 'a0\n' > "$REPO1/a.txt"
    git -C "$REPO1" add -A
    git -C "$REPO1" commit -qm seed
    git -C "$REPO1" push -q origin main
    git clone -q "$ORIGIN" "$REPO2" 2>/dev/null
    git -C "$REPO2" config user.name tester
    git -C "$REPO2" config user.email tester@example.com
    git -C "$REPO1" worktree add -q -b "$BRANCH" "$WT1" main
    BASE_SHA="$(git -C "$REPO1" rev-parse main)"

    # Three roots: the coordinator's canonical one, and one per worker (a failover to another machine = a different root).
    CROOT="$T/canon"; W1="$T/w1"; W2="$T/w2"
    local r
    for r in "$CROOT" "$W1" "$W2"; do
        mkdir -p "$r/jobs" "$r/events" "$r/logs" "$r/drafts" "$r/cursors" "$r/runner" "$r/archive" "$r/teardown-pending"
    done
    jq -n --arg id "$JOB" --arg rp "$REPO1" --arg b "$BRANCH" --arg base "$BASE_SHA" --arg sid "$SID" \
        '{id:$id, state:"running", repo_path:$rp, branch:$b, base_sha:$base, session_id:$sid, isolation:"worktree"}' \
        > "$CROOT/jobs/$JOB.json"
    jq --arg wd "$WT1" '. + {work_dir:$wd}' "$CROOT/jobs/$JOB.json" > "$W1/jobs/$JOB.json"
    # The coordinator's lease history: both epochs were granted.
    mkdir -p "$CROOT/runner/leases"
    jq -nc --arg j "$JOB" '{job:$j, epoch:1, id:"L-1", worker:"w1"}' >> "$CROOT/runner/leases/$JOB.history.jsonl"
    jq -nc --arg j "$JOB" '{job:$j, epoch:2, id:"L-2", worker:"w2"}' >> "$CROOT/runner/leases/$JOB.history.jsonl"

    OPS="$T/ops.ndjson"; : > "$OPS"
    TR1="$MOTHER_CLAUDE_PROJECTS_DIR/$(_enc "$WT1")/$SID.jsonl"
    mkdir -p "$(dirname "$TR1")"
}

teardown() {
    teardown_mother_env
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

_enc() { printf '%s' "$1" | sed 's/[\/.]/-/g'; }

# _w <root> <cmd...>: run <cmd> with <root> as the whole state tree (a subshell; nothing leaks into the test shell).
_w() {
    local r="$1"; shift
    (
        export MOTHER_ROOT="$r" JOBS_DIR="$r/jobs" EVENTS_DIR="$r/events" LOGS_DIR="$r/logs" DRAFTS_DIR="$r/drafts" \
               CURSORS_DIR="$r/cursors" RUNNER_DIR="$r/runner" ARCHIVE_DIR="$r/archive" TEARDOWN_DIR="$r/teardown-pending"
        "$@"
    )
}

# _take <root> <epoch>: a worker's cadence take (`mother checkpoint take <job>`, auto-numbered). Sets TAKE_N / TAKE_PUSHED.
_take() {
    local out rc=0
    out=$(_w "$1" env MOTHER_LEASE_ID="L-$2" MOTHER_LEASE_EPOCH="$2" mother checkpoint take "$JOB" 2>"$T/take.err") || rc=$?
    if [ "$rc" -ne 0 ]; then echo "take failed (rc=$rc): $(cat "$T/take.err")" >&2; return 1; fi
    TAKE_N=$(printf '%s\n' "$out" | tail -n 1 | jq -r '.n // empty')
    TAKE_PUSHED=$(printf '%s\n' "$out" | tail -n 1 | jq -r '.pushed | tostring')
    [ -n "$TAKE_N" ] || { echo "take reported no n: $out" >&2; return 1; }
}

_op() { # <type> <data-json>: append one op with the next contiguous seq
    local seq=$(( $(wc -l < "$OPS") + 1 ))
    jq -nc --argjson seq "$seq" --arg t "$1" --argjson data "$2" \
        '{seq:$seq, t:$t, ts:"2026-11-08T12:00:00.000Z", data:$data}' >> "$OPS"
}

# _ship <worker-root> <n>: what mother_checkpoint_ship puts in the outbox for a finished take.
_ship() {
    local d="$1/checkpoints/$JOB/$2" f
    for f in transcript.delta manifest.json; do
        _op artifact.put "$(jq -nc --arg p "checkpoints/$JOB/$2/$f" --arg b "$(base64 < "$d/$f" | tr -d '\n')" \
            --arg s "$(shasum -a 256 < "$d/$f" | cut -d' ' -f1)" '{path:$p, offset:0, b64:$b, final:true, sha256:$s}')"
    done
    _op checkpoint.taken "$(jq -nc --slurpfile m "$d/manifest.json" '{manifest:$m[0]}')"
}

# _apply: the coordinator replays the whole outbox (already-applied seqs are skipped).
_apply() {
    local rc=0
    _w "$CROOT" bash -c '"$0" "$1" "$2" < "$3"' "$COORD_APPLY" "$CROOT" "$JOB" "$OPS" >"$T/apply.out" 2>"$T/apply.err" || rc=$?
    if [ "$rc" -ne 0 ]; then echo "coord_apply rc=$rc: $(cat "$T/apply.err")" >&2; return 1; fi
}

# _take_ship <worker-root> <epoch>: a take and its outbox ops (the coordinator replays them with _apply; one replay after
# several takes yields the same state as one per take, only cheaper).
_take_ship() { _take "$1" "$2" && _ship "$1" "$TAKE_N"; }

_latest() { jq -r "$1" "$CROOT/checkpoints/$JOB/latest.json"; }
_ctranscript() { printf '%s/checkpoints/%s/transcript/%s.jsonl' "$CROOT" "$JOB" "$SID"; }

# Epoch 1 on worker 1: n=1 "hello" pushed, then n=2 " world" taken while the remote is unreachable (pushed:false).
_epoch1() {
    printf 'hello' > "$TR1"
    _take_ship "$W1" 1 || return 1
    [ "$TAKE_N" = 1 ] && [ "$TAKE_PUSHED" = true ] || { echo "epoch 1 n=1 was not a pushed take 1" >&2; return 1; }
    mv "$ORIGIN" "$T/origin.away"
    printf ' world' >> "$TR1"
    _take "$W1" 1; local rc=$?
    mv "$T/origin.away" "$ORIGIN"
    [ "$rc" -eq 0 ] || return 1
    [ "$TAKE_N" = 2 ] && [ "$TAKE_PUSHED" = false ] || { echo "epoch 1 n=2 was not an unpushed take 2 (n=$TAKE_N pushed=$TAKE_PUSHED)" >&2; return 1; }
    _ship "$W1" 2 && _apply || return 1
    # The set-up the bug needs: the coordinator holds MORE transcript than latest.json describes.
    [ "$(_latest '[.epoch, .n, .transcript.bytes] | @tsv')" = "$(printf '1\t1\t5')" ] || { echo "latest.json moved: $(cat "$CROOT/checkpoints/$JOB/latest.json")" >&2; return 1; }
    [ "$(cat "$(_ctranscript)")" = "hello world" ] || { echo "canonical transcript: $(cat "$(_ctranscript)")" >&2; return 1; }
}

# _failover <dest-worker-root> <dest-repo> <new-work-dir> <expected-restored-transcript>: the new lease restores from latest.json exactly as the runner and
# mother-run-job do. Leaves the job document of <dest-worker-root> pointing at the new work dir and sets TR2 (its transcript).
_failover() {
    local wroot="$1" repo="$2" newwd="$3" want="$4" epoch="${5:-2}" stage="$T/resume-e${5:-2}" bytes
    mkdir -p "$stage"
    cp "$CROOT/checkpoints/$JOB/latest.json" "$stage/manifest.json"
    bytes=$(jq -r '.transcript.bytes' "$stage/manifest.json")
    # bin/mother-runner: the transcript the new session continues is the first <bytes> bytes of the reassembled file.
    head -c "$bytes" "$(_ctranscript)" > "$stage/transcript.jsonl"
    : > "$stage/info.json"; printf '{}' > "$stage/info.json"
    jq --arg rp "$repo" '.repo_path = $rp' "$CROOT/jobs/$JOB.json" > "$wroot/jobs/$JOB.json"

    # Load the real functions of mother-run-job. _restore_from_checkpoint sits below its SOURCE_ONLY guard, so the function
    # blocks after the guard are cut out (one file each) and sourced; nothing from the script body is executed.
    local fdir="$T/fns"; mkdir -p "$fdir"
    awk -v dir="$fdir" '
        /^\[ "\$\{SOURCE_ONLY:-\}" = "1" \] && return 0/ { on = 1; next }
        !on { next }
        infn { buf = buf $0 "\n"; if ($0 == "}") { infn = 0; n++; f = dir "/fn" n ".sh"; printf "%s", buf > f; close(f) } next }
        /^[A-Za-z_][A-Za-z0-9_]*\(\) \{$/ { infn = 1; buf = $0 "\n" }
    ' "$_BIN_DIR/mother-run-job"
    cat > "$T/restore-driver.sh" <<DRV
set -u
SOURCE_ONLY=1 source "$_BIN_DIR/mother-run-job"
source "\$MOTHER_LIB_DIR/state.sh"
_install_core_job_helpers
for f in "$fdir"/fn*.sh; do source "\$f" 2>/dev/null || true; done
type _restore_from_checkpoint >/dev/null 2>&1 || { echo "_restore_from_checkpoint is not defined" >&2; exit 90; }
id="$JOB"; job_file="\$JOBS_DIR/\$id.json"
branch="$BRANCH"; repo_path="$repo"; mother_cli="$_BIN_DIR/mother"
export MOTHER_RESUME_CHECKPOINT="$stage/manifest.json" MOTHER_RESUME_TRANSCRIPT="$stage/transcript.jsonl" MOTHER_RESUME_INFO="$stage/info.json"
_restore_from_checkpoint "$newwd"
DRV
    local rc=0
    _w "$wroot" env MOTHER_LEASE_EPOCH="$epoch" bash "$T/restore-driver.sh" >"$T/restore.out" 2>"$T/restore.err" || rc=$?
    if [ "$rc" -ne 0 ]; then echo "restore failed (rc=$rc): $(cat "$T/restore.err") $(tail -n 3 "$T/restore.out")" >&2; return 1; fi
    TR2="$MOTHER_CLAUDE_PROJECTS_DIR/$(_enc "$newwd")/$SID.jsonl"
    [ "$(cat "$TR2")" = "$want" ] || { echo "restored transcript is '$(cat "$TR2")', expected '$want'" >&2; return 1; }
    jq --arg wd "$newwd" '.work_dir = $wd' "$wroot/jobs/$JOB.json" > "$T/job.tmp" && mv "$T/job.tmp" "$wroot/jobs/$JOB.json"
}

_epoch2_entries_ok() { # every epoch-2 index entry has transcript_ok true, and there are <n> of them
    jq -e -s --argjson n "$1" '[.[] | select(.epoch == 2)] | (length == $n) and all(.[]; .transcript_ok == true)' \
        "$CROOT/checkpoints/$JOB/index.jsonl" >/dev/null
}

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

@test "failover to another machine after an unpushed checkpoint: the new lease's checkpoints advance latest.json and the transcript matches the new worker's byte for byte" {
    _epoch1

    _failover "$W2" "$REPO2" "$T/wt2-e2" hello

    printf 'XYZ' >> "$TR2"
    _take_ship "$W2" 2
    [ "$TAKE_PUSHED" = true ]
    printf '!!' >> "$TR2"
    _take_ship "$W2" 2
    [ "$TAKE_PUSHED" = true ]
    _apply

    # The coordinator accepted both of the new lease's checkpoints ...
    _epoch2_entries_ok 2 || { cat "$CROOT/checkpoints/$JOB/index.jsonl" >&2; cat "$T/apply.err" >&2; false; }
    # ... latest.json moved to the new lease's newest one ...
    [ "$(_latest '[.epoch, .n] | @tsv')" = "$(printf '2\t3')" ] || { cat "$CROOT/checkpoints/$JOB/latest.json" >&2; false; }
    # ... and what a third lease would restore from is exactly the new worker's session.
    cmp "$(_ctranscript)" "$TR2"
    [ "$(cat "$TR2")" = "helloXYZ!!" ]
}

@test "failover on the same machine after an unpushed checkpoint (the older manifest is still in the local checkpoints dir): the new lease's checkpoints advance latest.json too" {
    _epoch1

    # Same worker root (its checkpoints dir already holds the epoch-1 n=1 and n=2 manifests), same clone.
    _failover "$W1" "$REPO1" "$T/wt1-e2" hello

    printf 'XYZ' >> "$TR2"
    _take_ship "$W1" 2
    [ "$TAKE_PUSHED" = true ]
    printf '!!' >> "$TR2"
    _take_ship "$W1" 2
    [ "$TAKE_PUSHED" = true ]
    last_n="$TAKE_N"
    _apply

    _epoch2_entries_ok 2 || { cat "$CROOT/checkpoints/$JOB/index.jsonl" >&2; cat "$T/apply.err" >&2; false; }
    [ "$(_latest .epoch)" = 2 ]
    [ "$(_latest .n)" = "$last_n" ]
    cmp "$(_ctranscript)" "$TR2"
    [ "$(cat "$TR2")" = "helloXYZ!!" ]
}

@test "failover after a PUSHED last checkpoint (nothing ahead of latest.json): the new lease's checkpoints advance latest.json (the case that already works)" {
    printf 'hello' > "$TR1"
    _take_ship "$W1" 1
    printf ' world' >> "$TR1"
    _take_ship "$W1" 1
    [ "$TAKE_PUSHED" = true ]
    _apply
    [ "$(_latest '[.epoch, .n] | @tsv')" = "$(printf '1\t2')" ]

    # The restored transcript is now the whole "hello world" (latest.json describes all of it).
    _failover "$W2" "$REPO2" "$T/wt2-e2" "hello world"

    printf 'XYZ' >> "$TR2"
    _take_ship "$W2" 2
    _apply
    [ "$(_latest '[.epoch, .n] | @tsv')" = "$(printf '2\t3')" ]
    cmp "$(_ctranscript)" "$TR2"
}

@test "a checkpoint for a job with no lease history is refused and audited, never trusted on the worker's word" {
    rm -f "$CROOT/runner/leases/$JOB.history.jsonl"
    printf 'hello' > "$TR1"
    _take_ship "$W1" 1
    run _apply
    [ ! -e "$CROOT/checkpoints/$JOB/latest.json" ]
    grep -q manifest_refused "$CROOT/runner/leases/audit.jsonl"
    grep -q epoch "$CROOT/runner/leases/audit.jsonl"
}

@test "a second loss after a pushed:false epoch: epoch 3 on a third machine restores the epoch-2 files and transcript, then advances latest.json (epoch 3, numbering continued) with matching bytes" {
    _epoch1
    _failover "$W2" "$REPO2" "$T/wt2-e2" hello
    printf 'XYZ' >> "$TR2"
    _take_ship "$W2" 2
    [ "$TAKE_PUSHED" = true ]
    # The origin refuses the per-checkpoint ref for one take: pushed:false, yet its transcript delta still ships.
    mkdir -p "$ORIGIN/hooks"
    printf '#!/bin/sh\ncase "$1" in refs/mother/wip-ckpt/*) [ -e "%s/refuse-ckpt" ] && exit 1 ;; esac\nexit 0\n' "$T" > "$ORIGIN/hooks/update"
    chmod +x "$ORIGIN/hooks/update"
    touch "$T/refuse-ckpt"
    printf '!!' >> "$TR2"
    _take_ship "$W2" 2
    [ "$TAKE_PUSHED" = false ]
    rm -f "$T/refuse-ckpt"
    _apply
    # latest.json stays at the last PUSHED checkpoint while the coordinator's transcript is already longer.
    [ "$(_latest '[.epoch, .n] | @tsv')" = "$(printf '2\t2')" ]
    printf 'epoch2-file\n' > "$T/wt2-e2/e2.txt"
    printf '??' >> "$TR2"
    _take_ship "$W2" 2
    _apply
    [ "$(_latest '[.epoch, .n] | @tsv')" = "$(printf '2\t4')" ]
    [ "$(_latest .transcript.bytes)" = "$(wc -c < "$TR2" | tr -d ' ')" ]

    # Machine 2 dies; epoch 3 starts on a third machine.
    local W3="$T/w3" REPO3="$T/repo3" r
    mkdir -p "$W3/jobs" "$W3/events" "$W3/logs" "$W3/drafts" "$W3/cursors" "$W3/runner" "$W3/archive" "$W3/teardown-pending"
    git clone -q "$ORIGIN" "$REPO3" 2>/dev/null
    git -C "$REPO3" config user.name tester
    git -C "$REPO3" config user.email tester@example.com
    jq -nc --arg j "$JOB" '{job:$j, epoch:3, id:"L-3", worker:"w3"}' >> "$CROOT/runner/leases/$JOB.history.jsonl"
    _failover "$W3" "$REPO3" "$T/wt3-e3" "helloXYZ!!??" 3
    # (the restore pulled the epoch-2 work along with the transcript)
    [ "$(cat "$T/wt3-e3/e2.txt")" = "epoch2-file" ]

    printf 'third' >> "$TR2"
    printf 'third' >> "$TR2"
    local tr3="$TR2"
    _take_ship "$W3" 3
    [ "$TAKE_PUSHED" = true ]
    printf '+' >> "$tr3"
    _take_ship "$W3" 3
    [ "$TAKE_PUSHED" = true ]
    _apply
    [ "$(_latest '[.epoch, .n] | @tsv')" = "$(printf '3\t6')" ] || { cat "$CROOT/checkpoints/$JOB/latest.json" >&2; cat "$T/apply.err" >&2; false; }
    [ "$(_latest .transcript.bytes)" = "$(wc -c < "$tr3" | tr -d ' ')" ]
    cmp "$(_ctranscript)" "$tr3"
}
