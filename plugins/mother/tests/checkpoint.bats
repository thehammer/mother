#!/usr/bin/env bats
# checkpoint.bats — worker checkpoints (docs/worker-protocol.md section 9).
#
# Contract under test:
#   lib/checkpoint.sh (sourced after lib/state.sh)
#     mother_checkpoint_take <job-file> <out-dir> [--salvage-epoch N] [--final]
#     mother_checkpoint_restore <manifest> <transcript-file> <repo_path> <new_work_dir>
#     mother_checkpoint_interval_s
#   bin/mother   mother checkpoint take|restore ...
#
# Exit codes: take 0 ok (also when the remote is down), 3 fenced; restore 4 failed.
# Remote refs: refs/mother/wip/<job>; salvage refs/mother/wip-salvage/<job>/lease-<N>.
#
# Everything here is expected to FAIL until the feature exists.

load 'test_helper'

setup() {
    setup_mother_env
    export GIT_AUTHOR_NAME=tester GIT_AUTHOR_EMAIL=tester@example.com
    export GIT_COMMITTER_NAME=tester GIT_COMMITTER_EMAIL=tester@example.com
    unset MOTHER_CHECKPOINT_INTERVAL_S MOTHER_CHECKPOINT_MAX_FILE_MB
    unset MOTHER_CHECKPOINT_EXPECT_SHA MOTHER_CHECKPOINT_TIMEOUT_S MOTHER_CHECKPOINT_MAX_TRANSCRIPT_MB MOTHER_CHECKPOINT_MAX_SUBAGENT_MB
    export MOTHER_LEASE_ID=lease-1 MOTHER_LEASE_EPOCH=1

    T="$(cd "$MOTHER_ROOT" && pwd -P)/fx"
    mkdir -p "$T"
    ORIGIN="$T/origin.git"
    REPO="$T/repo"
    WT="$T/wt"
    OUT="$T/out"
    JOB=j1
    SID=sess-1
    WIPREF="refs/mother/wip/$JOB"
    export MOTHER_CLAUDE_PROJECTS_DIR="$T/projects"
    mkdir -p "$OUT" "$MOTHER_CLAUDE_PROJECTS_DIR"

    git init -q --bare -b main "$ORIGIN"
    git clone -q "$ORIGIN" "$REPO" 2>/dev/null
    git -C "$REPO" config user.name tester
    git -C "$REPO" config user.email tester@example.com
    git -C "$REPO" checkout -q -B main
    printf 'a0\n' > "$REPO/a.txt"
    printf 'b0\n' > "$REPO/b.txt"
    printf 'c0\n' > "$REPO/c.txt"
    printf 'ignored.log\n' > "$REPO/.gitignore"
    git -C "$REPO" add -A
    git -C "$REPO" commit -qm seed
    git -C "$REPO" push -q origin main
    git -C "$REPO" worktree add -q -b feature/x "$WT" main
    BASE_SHA="$(git -C "$REPO" rev-parse main)"

    TDIR="$MOTHER_CLAUDE_PROJECTS_DIR/$(_enc "$WT")"
    mkdir -p "$TDIR"
    TR="$TDIR/$SID.jsonl"
    printf '{"n":1}\n{"n":2}\n{"n":3}\n' > "$TR"

    JOBF="$JOBS_DIR/$JOB.json"
    jq -n --arg id "$JOB" --arg wd "$WT" --arg rp "$REPO" --arg b feature/x \
        --arg base "$BASE_SHA" --arg sid "$SID" \
        '{id:$id, state:"running", work_dir:$wd, repo_path:$rp, branch:$b,
          base_sha:$base, session_id:$sid, isolation:"worktree"}' > "$JOBF"
}

teardown() {
    teardown_mother_env
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

_enc() { printf '%s' "$1" | sed 's/[\/.]/-/g'; }

# Run a function from the libraries in a fresh shell. Sets CST, COUT, CERR.
call() {
    CST=0
    bash -c 'source "$MOTHER_LIB_DIR/state.sh"; source "$MOTHER_LIB_DIR/checkpoint.sh"; "$@"' _ "$@" \
        >"$T/stdout" 2>"$T/stderr" || CST=$?
    COUT="$(cat "$T/stdout")"
    CERR="$(cat "$T/stderr")"
}

take() { call mother_checkpoint_take "$JOBF" "$OUT" "$@"; }

# jq over the manifest written to the out dir.
m() { jq -r "$1" "$OUT/manifest.json"; }

remote_sha() { git -C "$ORIGIN" rev-parse --verify -q "$1" 2>/dev/null || true; }

remote_files() { git -C "$ORIGIN" ls-tree -r --name-only "$1"; }

make_dirty() {
    printf 'a-committed\n' >> "$WT/a.txt"
    git -C "$WT" add a.txt
    git -C "$WT" commit -qm "committed change"
    printf 'b-unstaged\n' >> "$WT/b.txt"
    printf 'c-staged\n' >> "$WT/c.txt"
    git -C "$WT" add c.txt
    printf 'new-untracked\n' > "$WT/u.txt"
    printf 'junk\n' > "$WT/ignored.log"
}

index_file() { printf '%s/index' "$(git -C "$WT" rev-parse --absolute-git-dir)"; }

# ---------------------------------------------------------------------------
# Capture
# ---------------------------------------------------------------------------

@test "take captures committed, unstaged, staged and untracked work in the remote wip ref" {
    make_dirty
    git -C "$WT" status --porcelain > "$T/status.before"
    cp "$(index_file)" "$T/index.before"

    take
    [ "$CST" -eq 0 ]
    [ "$(printf '%s' "$COUT" | jq -r .pushed)" = "true" ]

    sha="$(remote_sha "$WIPREF")"
    [ -n "$sha" ]
    [ "$sha" = "$(m .wip_sha)" ]
    [ "$(m .wip_ref)" = "$WIPREF" ]
    [ "$(m .head_sha)" = "$(git -C "$WT" rev-parse HEAD)" ]
    [ "$(m .branch)" = "feature/x" ]
    [ "$(m .base_sha)" = "$BASE_SHA" ]
    [ "$(m .session_id)" = "$SID" ]
    [ "$(m .n)" = "1" ]

    for f in a.txt b.txt c.txt u.txt; do
        git -C "$ORIGIN" show "$WIPREF:$f" > "$T/remote.$f"
        cmp "$T/remote.$f" "$WT/$f"
    done
}

@test "take leaves the worktree status and index file byte-identical" {
    make_dirty
    git -C "$WT" status --porcelain > "$T/status.before"
    cp "$(index_file)" "$T/index.before"

    take
    [ "$CST" -eq 0 ]

    git -C "$WT" status --porcelain > "$T/status.after"
    cmp "$T/status.before" "$T/status.after"
    cmp "$T/index.before" "$(index_file)"
    # The user's staged edit is still staged, not folded into a commit.
    [ -n "$(git -C "$WT" diff --cached --name-only)" ]
}

@test "take excludes gitignored files" {
    make_dirty
    take
    [ "$CST" -eq 0 ]
    run remote_files "$WIPREF"
    [[ "$output" != *ignored.log* ]]
    [[ "$output" == *u.txt* ]]
}

@test "untracked files over the size cap are skipped and listed in the manifest" {
    dd if=/dev/null of="$WT/big.bin" bs=1048576 seek=60 count=0 2>/dev/null
    printf 'small\n' > "$WT/small.txt"

    take
    [ "$CST" -eq 0 ]
    run remote_files "$WIPREF"
    [[ "$output" != *big.bin* ]]
    [[ "$output" == *small.txt* ]]
    [ "$(m '.untracked_skipped | length')" = "1" ]
    [ "$(m '.untracked_skipped[0].path')" = "big.bin" ]
    [ "$(m '.untracked_skipped[0].bytes')" = "62914560" ]
}

@test "MOTHER_CHECKPOINT_MAX_FILE_MB lowers the cap" {
    dd if=/dev/null of="$WT/mid.bin" bs=1048576 seek=3 count=0 2>/dev/null
    MOTHER_CHECKPOINT_MAX_FILE_MB=1 take
    [ "$CST" -eq 0 ]
    [ "$(m '.untracked_skipped[0].path')" = "mid.bin" ]
}

# ---------------------------------------------------------------------------
# Skip / final
# ---------------------------------------------------------------------------

@test "an unchanged second take reports skipped:unchanged and does not push" {
    make_dirty
    take
    [ "$CST" -eq 0 ]
    first="$(remote_sha "$WIPREF")"
    mkdir -p "$ORIGIN/hooks"
    printf '#!/bin/sh\necho push >> "%s/pushlog"\n' "$T" > "$ORIGIN/hooks/pre-receive"
    chmod +x "$ORIGIN/hooks/pre-receive"

    take
    [ "$CST" -eq 0 ]
    [ "$(printf '%s' "$COUT" | jq -r .skipped)" = "unchanged" ]
    [ "$(remote_sha "$WIPREF")" = "$first" ]
    [ ! -e "$T/pushlog" ]
}

@test "a changed worktree after a take is not skipped and advances n" {
    make_dirty
    take
    printf 'more\n' >> "$WT/b.txt"
    take
    [ "$CST" -eq 0 ]
    [ "$(m .n)" = "2" ]
    [ "$(m .pushed)" = "true" ]
    git -C "$ORIGIN" show "$WIPREF:b.txt" | grep -q more
}

@test "--final takes and pushes even when nothing changed" {
    make_dirty
    take
    take
    [ "$(printf '%s' "$COUT" | jq -r .skipped)" = "unchanged" ]

    take --final
    [ "$CST" -eq 0 ]
    [ "$(printf '%s' "$COUT" | jq -r '.skipped // empty')" = "" ]
    [ "$(printf '%s' "$COUT" | jq -r .pushed)" = "true" ]
    [ "$(m .n)" = "2" ]
}

# ---------------------------------------------------------------------------
# Fencing / salvage
# ---------------------------------------------------------------------------

@test "a take fenced by a moved remote ref exits 3 and never overwrites the remote ref" {
    make_dirty
    take
    [ "$CST" -eq 0 ]

    git clone -q "$ORIGIN" "$T/other" 2>/dev/null
    git -C "$T/other" config user.name other
    git -C "$T/other" config user.email other@example.com
    git -C "$T/other" checkout -q main
    printf 'other\n' > "$T/other/other.txt"
    git -C "$T/other" add other.txt
    git -C "$T/other" commit -qm other-lease
    git -C "$T/other" push -q --force origin "HEAD:$WIPREF"
    moved="$(remote_sha "$WIPREF")"
    [ "$moved" = "$(git -C "$T/other" rev-parse HEAD)" ]

    printf 'after-fence\n' >> "$WT/b.txt"
    take
    [ "$CST" -eq 3 ]
    [ "$(printf '%s' "$COUT" | jq -r .push_error)" = "fenced" ]
    [ "$(printf '%s' "$COUT" | jq -r .pushed)" = "false" ]
    [ "$(remote_sha "$WIPREF")" = "$moved" ]
}

@test "--salvage-epoch pushes to the salvage ref without a lease check" {
    make_dirty
    take
    git clone -q "$ORIGIN" "$T/other" 2>/dev/null
    git -C "$T/other" config user.name other
    git -C "$T/other" config user.email other@example.com
    git -C "$T/other" checkout -q main
    printf 'other\n' > "$T/other/other.txt"
    git -C "$T/other" add other.txt
    git -C "$T/other" commit -qm other-lease
    git -C "$T/other" push -q --force origin "HEAD:$WIPREF"
    moved="$(remote_sha "$WIPREF")"

    printf 'salvage-edit\n' >> "$WT/b.txt"
    take --salvage-epoch 2
    [ "$CST" -eq 0 ]
    [ "$(printf '%s' "$COUT" | jq -r .pushed)" = "true" ]
    salv="refs/mother/wip-salvage/$JOB/lease-2"
    [ -n "$(remote_sha "$salv")" ]
    [ "$(remote_sha "$salv")" = "$(m .wip_sha)" ]
    git -C "$ORIGIN" show "$salv:b.txt" | grep -q salvage-edit
    [ "$(remote_sha "$WIPREF")" = "$moved" ]
}

# ---------------------------------------------------------------------------
# Remote down
# ---------------------------------------------------------------------------

@test "with the remote down take exits 0, reports pushed:false and still writes manifest and transcript delta" {
    make_dirty
    mv "$ORIGIN" "$T/origin.away"

    take
    [ "$CST" -eq 0 ]
    [ "$(printf '%s' "$COUT" | jq -r .pushed)" = "false" ]
    [ -f "$OUT/manifest.json" ]
    [ "$(m .pushed)" = "false" ]
    [ -f "$OUT/transcript.delta" ]
    cmp "$OUT/transcript.delta" "$TR"
}

# ---------------------------------------------------------------------------
# Transcript
# ---------------------------------------------------------------------------

@test "transcript deltas concatenate to the file and the manifest sha matches" {
    take
    [ "$CST" -eq 0 ]
    cp "$OUT/transcript.delta" "$T/d1"
    [ "$(m .transcript.bytes)" = "$(wc -c < "$TR" | tr -d ' ')" ]

    printf '{"n":4}\n{"n":5}\n' >> "$TR"
    take
    [ "$CST" -eq 0 ]
    cp "$OUT/transcript.delta" "$T/d2"
    [ -s "$T/d2" ]
    # The second delta holds only the appended bytes.
    [ "$(printf '{"n":4}\n{"n":5}\n' | cmp - "$T/d2"; echo $?)" = "0" ]

    cat "$T/d1" "$T/d2" > "$T/joined"
    cmp "$T/joined" "$TR"
    [ "$(m .transcript.bytes)" = "$(wc -c < "$TR" | tr -d ' ')" ]
    [ "$(m .transcript.sha256)" = "$(shasum -a 256 "$TR" | cut -d' ' -f1)" ]
    [ -n "$(m .transcript.path_rel)" ]
}

@test "a transcript that shrank or was rewritten is copied whole with reset:true" {
    take
    printf '{"rewritten":true}\n' > "$TR"
    take
    [ "$CST" -eq 0 ]
    [ "$(m .transcript.reset)" = "true" ]
    cmp "$OUT/transcript.delta" "$TR"
    [ "$(m .transcript.sha256)" = "$(shasum -a 256 "$TR" | cut -d' ' -f1)" ]
}

# ---------------------------------------------------------------------------
# Branch push
# ---------------------------------------------------------------------------

@test "a branch that does not exist on origin is not created by take" {
    make_dirty
    take
    [ "$CST" -eq 0 ]
    [ -z "$(remote_sha refs/heads/feature/x)" ]
}

@test "take fast-forwards an existing origin branch when HEAD is ahead" {
    git -C "$WT" push -q origin feature/x
    printf 'ahead\n' >> "$WT/a.txt"
    git -C "$WT" commit -qam ahead

    take
    [ "$CST" -eq 0 ]
    [ "$(remote_sha refs/heads/feature/x)" = "$(git -C "$WT" rev-parse HEAD)" ]
}

@test "take never force-pushes a diverged origin branch and reports branch_push:diverged" {
    git -C "$WT" push -q origin feature/x
    git clone -q "$ORIGIN" "$T/other" 2>/dev/null
    git -C "$T/other" config user.name other
    git -C "$T/other" config user.email other@example.com
    git -C "$T/other" checkout -q feature/x
    printf 'theirs\n' > "$T/other/theirs.txt"
    git -C "$T/other" add theirs.txt
    git -C "$T/other" commit -qm theirs
    git -C "$T/other" push -q origin feature/x
    theirs="$(remote_sha refs/heads/feature/x)"

    printf 'ours\n' > "$WT/ours.txt"
    git -C "$WT" add ours.txt
    git -C "$WT" commit -qm ours

    take
    [ "$CST" -eq 0 ]
    [ "$(remote_sha refs/heads/feature/x)" = "$theirs" ]
    [ "$(m .branch_push)" = "diverged" ]
    # The wip ref is still pushed.
    [ "$(m .pushed)" = "true" ]
}

# ---------------------------------------------------------------------------
# Restore
# ---------------------------------------------------------------------------

@test "restore rebuilds the work at a different path with unstaged changes and the transcript" {
    make_dirty
    take
    [ "$CST" -eq 0 ]
    head="$(git -C "$WT" rev-parse HEAD)"
    mkdir -p "$T/snap"
    for f in a.txt b.txt c.txt u.txt; do cp "$WT/$f" "$T/snap/$f"; done
    cp "$TR" "$T/transcript.full"
    cp "$OUT/manifest.json" "$T/manifest.json"

    safe_rm_tree "$WT"
    [ ! -e "$WT" ]
    NEWWT="$T/newwt"

    call mother_checkpoint_restore "$T/manifest.json" "$T/transcript.full" "$REPO" "$NEWWT"
    [ "$CST" -eq 0 ]
    [ "$(printf '%s' "$COUT" | jq -r .restored)" = "true" ]
    [ "$(printf '%s' "$COUT" | jq -r .head_sha)" = "$head" ]
    [ "$(printf '%s' "$COUT" | jq -r .wip_sha)" = "$(jq -r .wip_sha "$T/manifest.json")" ]
    [ "$(printf '%s' "$COUT" | jq -r '.skipped | length')" = "0" ]

    [ "$(git -C "$NEWWT" rev-parse HEAD)" = "$head" ]
    [ -z "$(git -C "$NEWWT" diff --cached --name-only)" ]
    for f in a.txt b.txt c.txt u.txt; do cmp "$T/snap/$f" "$NEWWT/$f"; done
    # Edits are present as working-tree changes, not commits.
    git -C "$NEWWT" status --porcelain | grep -q 'b.txt'
    git -C "$NEWWT" status --porcelain | grep -q 'c.txt'
    git -C "$NEWWT" status --porcelain | grep -q '^?? u.txt'

    restored="$MOTHER_CLAUDE_PROJECTS_DIR/$(_enc "$NEWWT")/$SID.jsonl"
    [ -f "$restored" ]
    cmp "$restored" "$T/transcript.full"
    [ "$(printf '%s' "$COUT" | jq -r .transcript_sha)" = "$(shasum -a 256 "$restored" | cut -d' ' -f1)" ]
}

@test "restore fails with exit 4 and why wip_missing when the wip commit is nowhere" {
    jq -n --arg job "$JOB" --arg head "$BASE_SHA" --arg base "$BASE_SHA" \
        --arg sid "$SID" --arg ref "$WIPREF" \
        --arg sha "$(shasum -a 256 "$TR" | cut -d' ' -f1)" \
        '{v:1, job:$job, lease:"", epoch:0, n:1, at:"2026-11-08T00:00:00Z",
          head_sha:$head, branch:"feature/x", base_sha:$base,
          wip_sha:"deadbeefdeadbeefdeadbeefdeadbeefdeadbeef", wip_ref:$ref,
          pushed:true, session_id:$sid,
          transcript:{path_rel:"t.jsonl", bytes:0, sha256:$sha},
          untracked_skipped:[]}' > "$T/forged.json"

    call mother_checkpoint_restore "$T/forged.json" "$TR" "$REPO" "$T/newwt2"
    [ "$CST" -eq 4 ]
    [ "$(printf '%s' "$COUT" | jq -r .restored)" = "false" ]
    [ "$(printf '%s' "$COUT" | jq -r .why)" = "wip_missing" ]
}

# ---------------------------------------------------------------------------
# Interval knob
# ---------------------------------------------------------------------------

@test "interval defaults to 120 with no warning" {
    call mother_checkpoint_interval_s
    [ "$CST" -eq 0 ]
    [ "$COUT" = "120" ]
    [ -z "$CERR" ]
}

@test "interval accepts values from 30 to 240" {
    MOTHER_CHECKPOINT_INTERVAL_S=240 call mother_checkpoint_interval_s
    [ "$COUT" = "240" ]
    [ -z "$CERR" ]
    MOTHER_CHECKPOINT_INTERVAL_S=30 call mother_checkpoint_interval_s
    [ "$COUT" = "30" ]
    [ -z "$CERR" ]
}

@test "interval above 240 falls back to 120 with one stderr line" {
    MOTHER_CHECKPOINT_INTERVAL_S=300 call mother_checkpoint_interval_s
    [ "$COUT" = "120" ]
    [ "$(printf '%s\n' "$CERR" | wc -l | tr -d ' ')" = "1" ]
    [ -n "$CERR" ]
}

@test "interval below 30 falls back to 120 with one stderr line" {
    MOTHER_CHECKPOINT_INTERVAL_S=29 call mother_checkpoint_interval_s
    [ "$COUT" = "120" ]
    [ "$(printf '%s\n' "$CERR" | wc -l | tr -d ' ')" = "1" ]
    [ -n "$CERR" ]
}

@test "non-numeric interval falls back to 120 with one stderr line" {
    MOTHER_CHECKPOINT_INTERVAL_S=abc call mother_checkpoint_interval_s
    [ "$COUT" = "120" ]
    [ "$(printf '%s\n' "$CERR" | wc -l | tr -d ' ')" = "1" ]
    [ -n "$CERR" ]
}

# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

@test "mother checkpoint take writes the manifest into --out and prints it" {
    make_dirty
    run mother checkpoint take "$JOB" --out "$OUT"
    [ "$status" -eq 0 ]
    [ -f "$OUT/manifest.json" ]
    [ "$(jq -r .wip_sha "$OUT/manifest.json")" = "$(remote_sha "$WIPREF")" ]
    [[ "$output" == *'"wip_sha"'* ]]
}

@test "mother checkpoint restore rebuilds the job work at --work-dir" {
    make_dirty
    mother checkpoint take "$JOB" --out "$OUT" >/dev/null
    cp "$TR" "$T/transcript.full"
    head="$(git -C "$WT" rev-parse HEAD)"
    safe_rm_tree "$WT"

    run mother checkpoint restore "$JOB" --manifest "$OUT/manifest.json" \
        --transcript "$T/transcript.full" --work-dir "$T/newwt"
    [ "$status" -eq 0 ]
    [ "$(git -C "$T/newwt" rev-parse HEAD)" = "$head" ]
    [ -f "$T/newwt/u.txt" ]
    [ -f "$MOTHER_CLAUDE_PROJECTS_DIR/$(_enc "$T/newwt")/$SID.jsonl" ]
}

# ---------------------------------------------------------------------------
# Isolation: nothing but the CLI uses the library yet
# ---------------------------------------------------------------------------

@test "only bin/mother cmd_checkpoint and lib/checkpoint.sh reference mother_checkpoint_" {
    files="$(grep -rl 'mother_checkpoint_' "$_BIN_DIR" "$_LIB_DIR" | sed "s#^$_PLUGIN_DIR/##" | sort)"
    [ -n "$files" ]
    [ "$files" = "$(printf 'bin/mother\nlib/checkpoint.sh')" ]
    grep -q 'cmd_checkpoint' "$_BIN_DIR/mother"
}

# ===========================================================================
# Hardening round (P1-3 review): leases, fencing state, restore safety,
# hostile config, embedded repos, consistent transcripts, deadlines.
# ===========================================================================

# --- helpers ----------------------------------------------------------------

restore() { call mother_checkpoint_restore "$T/manifest.json" "$T/transcript.full" "$REPO" "$NEWWT"; }

# Keep copies of the manifest and transcript of the last take (the worktree stays).
_save_ckpt() {
    HEAD_SHA="$(git -C "$WT" rev-parse HEAD)"
    cp "$OUT/manifest.json" "$T/manifest.json"
    cp "$TR" "$T/transcript.full"
    NEWWT="$T/newwt"
}

# Dirty worktree, take, save copies, remove the worktree (as after a lost host).
_prep_restore() {
    make_dirty
    take
    [ "$CST" -eq 0 ]
    _save_ckpt
    safe_rm_tree "$WT"
    git -C "$REPO" worktree prune
}

# A commit unrelated to anything in the repo (empty tree, no parents).
_unrelated_commit() {
    local empty
    empty="$(git -C "$REPO" hash-object -w -t tree /dev/null)"
    git -C "$REPO" commit-tree "$empty" -m unrelated
}

_worktree_count() { git -C "$REPO" worktree list --porcelain | grep -c '^worktree '; }

# Another lease force-pushes the wip ref: the caller's next take must be fenced.
_make_fenced() {
    make_dirty
    take
    [ "$CST" -eq 0 ]
    git clone -q "$ORIGIN" "$T/other" 2>/dev/null
    git -C "$T/other" config user.name other
    git -C "$T/other" config user.email other@example.com
    git -C "$T/other" checkout -q main
    printf 'other\n' > "$T/other/other.txt"
    git -C "$T/other" add other.txt
    git -C "$T/other" commit -qm other-lease
    git -C "$T/other" push -q --force origin "HEAD:$WIPREF"
    MOVED="$(remote_sha "$WIPREF")"
    printf 'after-fence\n' >> "$WT/b.txt"
}

# Install a `git` stub in $T/stubbin; stdin is the stub body, which can use $REAL_GIT and must
# `exec "$REAL_GIT" "$@"` to fall through. Use with PATH="$T/stubbin:$PATH" take.
_install_git_stub() {
    mkdir -p "$T/stubbin"
    { printf '#!/bin/sh\nREAL_GIT=%s\n' "$(command -v git)"; cat; } > "$T/stubbin/git"
    chmod +x "$T/stubbin/git"
}

# ---------------------------------------------------------------------------
# Remote down, then up
# ---------------------------------------------------------------------------

@test "a take after a failed push re-pushes once the remote is back instead of reporting unchanged" {
    make_dirty
    mv "$ORIGIN" "$T/origin.away"
    take
    [ "$CST" -eq 0 ]
    [ "$(printf '%s' "$COUT" | jq -r .pushed)" = "false" ]
    mv "$T/origin.away" "$ORIGIN"

    take
    [ "$CST" -eq 0 ]
    [ "$(printf '%s' "$COUT" | jq -r '.skipped // empty')" = "" ]
    [ "$(printf '%s' "$COUT" | jq -r .pushed)" = "true" ]
    [ -n "$(m .wip_sha)" ]
    [ "$(remote_sha "$WIPREF")" = "$(m .wip_sha)" ]
}

# ---------------------------------------------------------------------------
# A restored worker can keep checkpointing
# ---------------------------------------------------------------------------

@test "a restored worker's first take advances the remote wip ref from a fresh out dir" {
    make_dirty
    take
    [ "$CST" -eq 0 ]
    wip1="$(m .wip_sha)"
    _save_ckpt
    safe_rm_tree "$WT"
    restore
    [ "$CST" -eq 0 ]
    [ -f "$MOTHER_CLAUDE_PROJECTS_DIR/$(_enc "$NEWWT")/$SID.jsonl" ]

    jq --arg wd "$NEWWT" '.work_dir = $wd' "$JOBF" > "$T/job.tmp" && mv "$T/job.tmp" "$JOBF"
    printf 'after-restore\n' >> "$NEWWT/b.txt"

    mkdir -p "$T/s2"
    call mother_checkpoint_take "$JOBF" "$T/s2/out"
    [ "$CST" -eq 0 ]
    [ "$(printf '%s' "$COUT" | jq -r .pushed)" = "true" ]
    wip2="$(remote_sha "$WIPREF")"
    [ -n "$wip2" ]
    [ "$wip2" != "$wip1" ]
    [ "$wip2" = "$(jq -r .wip_sha "$T/s2/out/manifest.json")" ]
    # The new wip commit is built on the restored HEAD and carries the new edit.
    [ "$(git -C "$ORIGIN" rev-parse "$WIPREF^")" = "$HEAD_SHA" ]
    git -C "$ORIGIN" show "$WIPREF:b.txt" | grep -q after-restore
}

@test "a take with a stale --expect-sha is fenced (exit 3) and leaves the remote ref alone" {
    make_dirty
    take
    [ "$CST" -eq 0 ]
    wip1="$(m .wip_sha)"
    _save_ckpt
    safe_rm_tree "$WT"
    restore
    [ "$CST" -eq 0 ]
    jq --arg wd "$NEWWT" '.work_dir = $wd' "$JOBF" > "$T/job.tmp" && mv "$T/job.tmp" "$JOBF"
    printf 'after-restore\n' >> "$NEWWT/b.txt"

    mkdir -p "$T/s2"
    call mother_checkpoint_take "$JOBF" "$T/s2/out" --expect-sha "$BASE_SHA"
    [ "$CST" -eq 3 ]
    [ "$(printf '%s' "$COUT" | jq -r .push_error)" = "fenced" ]
    [ "$(remote_sha "$WIPREF")" = "$wip1" ]
}

@test "MOTHER_CHECKPOINT_EXPECT_SHA acts like --expect-sha" {
    make_dirty
    take
    [ "$CST" -eq 0 ]
    wip1="$(m .wip_sha)"
    printf 'more\n' >> "$WT/b.txt"
    MOTHER_CHECKPOINT_EXPECT_SHA="$BASE_SHA" take
    [ "$CST" -eq 3 ]
    [ "$(remote_sha "$WIPREF")" = "$wip1" ]
}

# ---------------------------------------------------------------------------
# Restore: branch relations
# ---------------------------------------------------------------------------

@test "restore uses a local branch that is already at the checkpoint head and reports branch_state exact" {
    _prep_restore
    restore
    [ "$CST" -eq 0 ]
    [ "$(printf '%s' "$COUT" | jq -r .branch_state)" = "exact" ]
    [ "$(printf '%s' "$COUT" | jq -r .detached)" = "false" ]
    [ "$(printf '%s' "$COUT" | jq -r .incomplete)" = "false" ]
    [ "$(git -C "$NEWWT" symbolic-ref --short HEAD)" = "feature/x" ]
    [ "$(git -C "$NEWWT" rev-parse HEAD)" = "$HEAD_SHA" ]
}

@test "restore fast-forwards a local branch that is behind the checkpoint head" {
    _prep_restore
    git -C "$REPO" branch -f feature/x "$BASE_SHA"
    restore
    [ "$CST" -eq 0 ]
    [ "$(printf '%s' "$COUT" | jq -r .branch_state)" = "fast_forwarded" ]
    [ "$(printf '%s' "$COUT" | jq -r .detached)" = "false" ]
    [ "$(git -C "$REPO" rev-parse feature/x)" = "$HEAD_SHA" ]
    [ "$(git -C "$NEWWT" symbolic-ref --short HEAD)" = "feature/x" ]
    [ "$(git -C "$NEWWT" rev-parse HEAD)" = "$HEAD_SHA" ]
}

@test "restore detaches at the checkpoint head and never moves a local branch that is newer" {
    _prep_restore
    newer="$(git -C "$REPO" commit-tree "$HEAD_SHA^{tree}" -p "$HEAD_SHA" -m newer)"
    git -C "$REPO" branch -f feature/x "$newer"
    restore
    [ "$CST" -eq 0 ]
    [ "$(printf '%s' "$COUT" | jq -r .branch_state)" = "detached" ]
    [ "$(printf '%s' "$COUT" | jq -r .detached)" = "true" ]
    [ "$(git -C "$REPO" rev-parse feature/x)" = "$newer" ]
    [ "$(git -C "$NEWWT" rev-parse HEAD)" = "$HEAD_SHA" ]
    run git -C "$NEWWT" symbolic-ref -q HEAD
    [ "$status" -ne 0 ]
    # The working changes are still laid over the detached head.
    [ -f "$NEWWT/u.txt" ]
    git -C "$NEWWT" status --porcelain | grep -q 'b.txt'
}

@test "restore detaches when the local branch has diverged from the checkpoint head" {
    _prep_restore
    other="$(git -C "$REPO" commit-tree "$BASE_SHA^{tree}" -p "$BASE_SHA" -m diverged)"
    git -C "$REPO" branch -f feature/x "$other"
    restore
    [ "$CST" -eq 0 ]
    [ "$(printf '%s' "$COUT" | jq -r .branch_state)" = "detached" ]
    [ "$(git -C "$REPO" rev-parse feature/x)" = "$other" ]
    [ "$(git -C "$NEWWT" rev-parse HEAD)" = "$HEAD_SHA" ]
}

@test "restore creates the branch when it does not exist locally" {
    _prep_restore
    git -C "$REPO" branch -D feature/x >/dev/null
    restore
    [ "$CST" -eq 0 ]
    [ "$(printf '%s' "$COUT" | jq -r .branch_state)" = "created" ]
    [ "$(git -C "$REPO" rev-parse feature/x)" = "$HEAD_SHA" ]
    [ "$(git -C "$NEWWT" symbolic-ref --short HEAD)" = "feature/x" ]
}

@test "restore refuses a branch checked out in another worktree and leaves that worktree untouched" {
    make_dirty
    take
    [ "$CST" -eq 0 ]
    _save_ckpt
    before_head="$(git -C "$WT" rev-parse HEAD)"
    before_ref="$(git -C "$WT" symbolic-ref HEAD)"
    git -C "$WT" status --porcelain > "$T/status.before"
    count_before="$(_worktree_count)"

    restore
    [ "$CST" -ne 0 ]
    [[ "$CERR" == *"worktree add failed"* ]]
    [ ! -e "$NEWWT" ]
    [ "$(git -C "$WT" rev-parse HEAD)" = "$before_head" ]
    [ "$(git -C "$WT" symbolic-ref HEAD)" = "$before_ref" ]
    git -C "$WT" status --porcelain > "$T/status.after"
    cmp "$T/status.before" "$T/status.after"
    [ "$(_worktree_count)" = "$count_before" ]
}

@test "restore also refuses an in-use branch that is behind the checkpoint head" {
    make_dirty
    take
    [ "$CST" -eq 0 ]
    _save_ckpt
    git -C "$REPO" update-ref refs/heads/feature/x "$BASE_SHA"
    before_head="$(git -C "$WT" rev-parse HEAD)"
    git -C "$WT" status --porcelain > "$T/status.before"

    restore
    [ "$CST" -ne 0 ]
    [ ! -e "$NEWWT" ]
    [ "$(git -C "$REPO" rev-parse feature/x)" = "$BASE_SHA" ]
    [ "$(git -C "$WT" rev-parse HEAD)" = "$before_head" ]
    git -C "$WT" status --porcelain > "$T/status.after"
    cmp "$T/status.before" "$T/status.after"
}

@test "restore reports base_moved true when the manifest base is unrelated to the head" {
    _prep_restore
    unrel="$(_unrelated_commit)"
    jq --arg b "$unrel" '.base_sha = $b' "$T/manifest.json" > "$T/m2" && mv "$T/m2" "$T/manifest.json"
    restore
    [ "$CST" -eq 0 ]
    [ "$(printf '%s' "$COUT" | jq -r .base_moved)" = "true" ]
    [ "$(printf '%s' "$COUT" | jq -r .base_sha)" = "$unrel" ]
}

@test "restore reports base_moved true when the manifest base commit is not in the repo" {
    _prep_restore
    jq '.base_sha = "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"' "$T/manifest.json" > "$T/m2" && mv "$T/m2" "$T/manifest.json"
    restore
    [ "$CST" -eq 0 ]
    [ "$(printf '%s' "$COUT" | jq -r .base_moved)" = "true" ]
}

@test "restore reports base_moved false when the manifest base is an ancestor of the head" {
    _prep_restore
    restore
    [ "$CST" -eq 0 ]
    [ "$(printf '%s' "$COUT" | jq -r .base_moved)" = "false" ]
    [ "$(printf '%s' "$COUT" | jq -r .base_sha)" = "$BASE_SHA" ]
}

# ---------------------------------------------------------------------------
# Restore: chain verification
# ---------------------------------------------------------------------------

@test "restore exits 4 chain_mismatch when the wip commit's parent is not the manifest head" {
    _prep_restore
    unrel="$(_unrelated_commit)"
    jq --arg h "$unrel" '.head_sha = $h' "$T/manifest.json" > "$T/m2" && mv "$T/m2" "$T/manifest.json"
    restore
    [ "$CST" -eq 4 ]
    [ "$(printf '%s' "$COUT" | jq -r .restored)" = "false" ]
    [ "$(printf '%s' "$COUT" | jq -r .why)" = "chain_mismatch" ]
    [ ! -e "$NEWWT" ]
}

@test "restore exits 4 chain_mismatch when the wip commit has more than one parent" {
    _prep_restore
    wip="$(jq -r .wip_sha "$T/manifest.json")"
    twop="$(git -C "$REPO" commit-tree "$wip^{tree}" -p "$HEAD_SHA" -p "$BASE_SHA" -m two-parents)"
    jq --arg w "$twop" '.wip_sha = $w' "$T/manifest.json" > "$T/m2" && mv "$T/m2" "$T/manifest.json"
    restore
    [ "$CST" -eq 4 ]
    [ "$(printf '%s' "$COUT" | jq -r .why)" = "chain_mismatch" ]
    [ ! -e "$NEWWT" ]
}

# ---------------------------------------------------------------------------
# Hostile repository configuration
# ---------------------------------------------------------------------------

@test "hostile repo config is never executed by take or restore" {
    H="$T/hostile"
    mkdir -p "$H/hooks"
    # A filter attribute must exist in the commit before the filter is configured.
    printf '* filter=x\n' > "$WT/.gitattributes"
    git -C "$WT" add .gitattributes
    git -C "$WT" commit -qm attrs
    printf 'b-hostile-edit\n' >> "$WT/b.txt"
    printf 'new\n' > "$WT/u.txt"

    mk() {  # mk <name> <tail-command>
        printf '#!/bin/sh\ntouch "%s/marker-%s"\n%s\n' "$T" "$1" "$2" > "$H/$1.sh"
        chmod +x "$H/$1.sh"
    }
    mk fsmonitor 'exit 0'
    mk gpg 'exit 1'
    mk clean 'cat'
    mk smudge 'cat'
    mk uploadpack 'exec git upload-pack "$@"'
    mk receivepack 'exec git receive-pack "$@"'
    for hk in post-checkout pre-push reference-transaction pre-commit post-commit; do
        printf '#!/bin/sh\ntouch "%s/marker-hook"\nexit 0\n' "$T" > "$H/hooks/$hk"
        chmod +x "$H/hooks/$hk"
    done
    git -C "$REPO" config core.fsmonitor "$H/fsmonitor.sh"
    git -C "$REPO" config commit.gpgsign true
    git -C "$REPO" config gpg.program "$H/gpg.sh"
    git -C "$REPO" config filter.x.clean "$H/clean.sh"
    git -C "$REPO" config filter.x.smudge "$H/smudge.sh"
    git -C "$REPO" config core.hooksPath "$H/hooks"
    git -C "$REPO" config remote.origin.uploadpack "$H/uploadpack.sh"
    git -C "$REPO" config remote.origin.receivepack "$H/receivepack.sh"

    # Sanity: with plain git every planted program really does fire.
    git -C "$WT" status >/dev/null 2>&1 || true
    [ -e "$T/marker-fsmonitor" ]
    cp "$(index_file)" "$T/sanity.idx"
    GIT_INDEX_FILE="$T/sanity.idx" git -C "$WT" add b.txt
    [ -e "$T/marker-clean" ]
    mkdir -p "$T/sanity-wt"
    GIT_INDEX_FILE="$T/sanity.idx" GIT_WORK_TREE="$T/sanity-wt" git -C "$WT" checkout-index -a -f
    [ -e "$T/marker-smudge" ]
    git -C "$WT" commit-tree -S "$(git -C "$WT" rev-parse 'HEAD^{tree}')" -m sanity >/dev/null 2>&1 || true
    [ -e "$T/marker-gpg" ]
    git -C "$WT" update-ref refs/tmp/sanity HEAD
    git -C "$WT" update-ref -d refs/tmp/sanity
    [ -e "$T/marker-hook" ]
    git -C "$WT" ls-remote origin >/dev/null
    [ -e "$T/marker-uploadpack" ]
    git -C "$WT" push -q --dry-run origin HEAD:refs/heads/sanity-only >/dev/null 2>&1
    [ -e "$T/marker-receivepack" ]
    rm -f "$T"/marker-*

    take
    [ "$CST" -eq 0 ]
    [ "$(printf '%s' "$COUT" | jq -r .pushed)" = "true" ]
    [ "$(remote_sha "$WIPREF")" = "$(m .wip_sha)" ]

    _save_ckpt
    safe_rm_tree "$WT"
    git -C "$REPO" worktree prune
    restore
    [ "$CST" -eq 0 ]
    [ "$(printf '%s' "$COUT" | jq -r .restored)" = "true" ]
    [ -f "$NEWWT/u.txt" ]

    fired="$(find "$T" -maxdepth 1 -name 'marker-*')"
    [ -z "$fired" ]
}

# ---------------------------------------------------------------------------
# Untracked content: nested repos, symlinks, oversize files
# ---------------------------------------------------------------------------

@test "an untracked nested repo is listed as embedded_repo, never captured as a gitlink, and restore flags incomplete" {
    git init -q "$WT/emb"
    printf 'inner\n' > "$WT/emb/f.txt"
    git -C "$WT/emb" add f.txt
    git -C "$WT/emb" commit -qm inner
    printf 'dirty\n' >> "$WT/emb/f.txt"

    take
    [ "$CST" -eq 0 ]
    [ "$(m '[.untracked_skipped[] | select(.path == "emb")] | length')" = "1" ]
    [ "$(m '.untracked_skipped[] | select(.path == "emb") | .reason')" = "embedded_repo" ]
    run git -C "$ORIGIN" ls-tree -r "$WIPREF"
    [ "$status" -eq 0 ]
    [[ "$output" != *160000* ]]
    [[ "$output" != *emb* ]]

    _save_ckpt
    safe_rm_tree "$WT"
    git -C "$REPO" worktree prune
    restore
    [ "$CST" -eq 0 ]
    [ "$(printf '%s' "$COUT" | jq -r .incomplete)" = "true" ]
}

@test "a symlink is captured as a symlink and never followed to its (huge) target" {
    dd if=/dev/null of="$T/big70" bs=1048576 seek=70 count=0 2>/dev/null
    ln -s "$T/big70" "$WT/biglink"

    take
    [ "$CST" -eq 0 ]
    [ "$(m '.untracked_skipped | length')" = "0" ]
    mode="$(git -C "$ORIGIN" ls-tree "$WIPREF" biglink | awk '{print $1}')"
    [ "$mode" = "120000" ]
    [ "$(git -C "$ORIGIN" show "$WIPREF:biglink")" = "$T/big70" ]
}

@test "an oversize untracked file is skipped without ever being hashed into the object store" {
    dd if=/dev/null of="$WT/huge.bin" bs=1048576 seek=3 count=0 2>/dev/null
    h="$(git -C "$WT" hash-object "$WT/huge.bin")"
    run git -C "$WT" cat-file -e "$h"
    [ "$status" -ne 0 ]

    MOTHER_CHECKPOINT_MAX_FILE_MB=1 take
    [ "$CST" -eq 0 ]
    [ "$(m '.untracked_skipped[0].path')" = "huge.bin" ]
    [ "$(m '.untracked_skipped[0].reason')" = "too_large" ]
    run git -C "$ORIGIN" ls-tree -r --name-only "$WIPREF"
    [[ "$output" != *huge.bin* ]]
    run git -C "$WT" cat-file -e "$h"
    [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# Transcript consistency and caps
# ---------------------------------------------------------------------------

@test "manifest transcript bytes and sha describe exactly the delta copied, even if the transcript grows during the take" {
    _install_git_stub <<STUB
for a in "\$@"; do
    case "\$a" in push|commit-tree) printf '{"late":1}\n' >> "$TR"; break ;; esac
done
exec "\$REAL_GIT" "\$@"
STUB
    PATH="$T/stubbin:$PATH" take
    [ "$CST" -eq 0 ]
    [ "$(m .transcript.bytes)" = "$(wc -c < "$OUT/transcript.delta" | tr -d ' ')" ]
    [ "$(m .transcript.sha256)" = "$(shasum -a 256 "$OUT/transcript.delta" | cut -d' ' -f1)" ]
}

@test "a transcript over MOTHER_CHECKPOINT_MAX_TRANSCRIPT_MB is truncated to the cap and flagged" {
    head -c 2097152 /dev/zero | tr '\0' 'x' > "$TR"
    MOTHER_CHECKPOINT_MAX_TRANSCRIPT_MB=1 take
    [ "$CST" -eq 0 ]
    [ "$(m .transcript.truncated)" = "true" ]
    [ "$(m .transcript.bytes)" = "1048576" ]
    [ "$(wc -c < "$OUT/transcript.delta" | tr -d ' ')" = "1048576" ]
    [ "$(m .transcript.sha256)" = "$(shasum -a 256 "$OUT/transcript.delta" | cut -d' ' -f1)" ]
}

@test "a subagent dir over MOTHER_CHECKPOINT_MAX_SUBAGENT_MB is skipped and flagged" {
    mkdir -p "$TDIR/$SID/subagents"
    dd if=/dev/zero of="$TDIR/$SID/subagents/agent-1.jsonl" bs=1048576 count=2 2>/dev/null
    MOTHER_CHECKPOINT_MAX_SUBAGENT_MB=1 take
    [ "$CST" -eq 0 ]
    [ "$(m .transcript.subagents_skipped)" = "true" ]
    [ ! -e "$OUT/transcript.subagents" ] || [ -z "$(ls -A "$OUT/transcript.subagents")" ]
}

# ---------------------------------------------------------------------------
# Deadline and language-independent fencing
# ---------------------------------------------------------------------------

@test "a hung local git is killed with its children at the deadline and take reports why timeout" {
    make_dirty
    _install_git_stub <<STUB
# Block in the FIRST deadline-bounded git call (the unbounded safety pre-checks, config --list and check-ref-format, are let through): the
# deadline then always runs out while a child exists, however slow the machine is. Waiting for a particular later call
# (write-tree) raced the 2 s deadline under CPU load.
case " \$* " in *" config "*|*" check-ref-format "*) exec "\$REAL_GIT" "\$@" ;; esac
if [ ! -e "$T/blocked-once" ]; then
    : > "$T/blocked-once"
    sleep 20 &
    echo \$! > "$T/childpid"
    wait
    exit 0
fi
exec "\$REAL_GIT" "\$@"
STUB
    start=$SECONDS
    MOTHER_CHECKPOINT_TIMEOUT_S=2 PATH="$T/stubbin:$PATH" take
    elapsed=$((SECONDS - start))

    have_child=0; dead=0
    if [ -s "$T/childpid" ]; then
        have_child=1
        cpid="$(cat "$T/childpid")"
        # Generous under CPU load: the stub child sleeps 20 s, so a child that outlives the kill still fails this.
        for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16; do
            if ! kill -0 "$cpid" 2>/dev/null; then dead=1; break; fi
            sleep 0.5
        done
        # Our own stub's child: clean up by exact pid if the code under test left it running.
        [ "$dead" -eq 1 ] || kill "$cpid" 2>/dev/null || true
    fi

    [ "$elapsed" -le 15 ]
    [ "$CST" -eq 1 ]
    [ "$(printf '%s' "$COUT" | jq -r .why)" = "timeout" ]
    [ "$have_child" -eq 1 ]
    [ "$dead" -eq 1 ]
}

@test "fencing is detected under a localized environment" {
    _make_fenced
    LANG=de_DE.UTF-8 LC_ALL=de_DE.UTF-8 take
    [ "$CST" -eq 3 ]
    [ "$(printf '%s' "$COUT" | jq -r .push_error)" = "fenced" ]
    [ "$(printf '%s' "$COUT" | jq -r .pushed)" = "false" ]
    [ "$(remote_sha "$WIPREF")" = "$MOVED" ]
}

@test "fencing is detected when git's rejection reason is translated" {
    _make_fenced
    _install_git_stub <<'STUB'
case " $* " in
    *" push "*)
        out=$("$REAL_GIT" "$@"); rc=$?
        printf '%s\n' "$out" | sed 's/stale info/veraltete Informationen/g'
        exit $rc ;;
esac
exec "$REAL_GIT" "$@"
STUB
    PATH="$T/stubbin:$PATH" take
    [ "$CST" -eq 3 ]
    [ "$(printf '%s' "$COUT" | jq -r .push_error)" = "fenced" ]
    [ "$(remote_sha "$WIPREF")" = "$MOVED" ]
}

# ---------------------------------------------------------------------------
# Salvage alongside the normal ref
# ---------------------------------------------------------------------------

@test "a salvage take after a normal take leaves both the wip ref and the salvage ref on origin" {
    make_dirty
    take
    [ "$CST" -eq 0 ]
    wip1="$(m .wip_sha)"

    take --salvage-epoch 2
    [ "$CST" -eq 0 ]
    [ "$(printf '%s' "$COUT" | jq -r '.skipped // empty')" = "" ]
    salv="refs/mother/wip-salvage/$JOB/lease-2"
    [ -n "$(remote_sha "$salv")" ]
    [ "$(remote_sha "$salv")" = "$(m .wip_sha)" ]
    [ "$(remote_sha "$WIPREF")" = "$wip1" ]
}

# ---------------------------------------------------------------------------
# Lease validation and unborn HEAD
# ---------------------------------------------------------------------------

@test "take without MOTHER_LEASE_ID exits 1 naming the variable and pushes nothing" {
    make_dirty
    unset MOTHER_LEASE_ID
    take
    [ "$CST" -eq 1 ]
    [[ "$CERR" == *MOTHER_LEASE_ID* ]]
    [ -z "$(remote_sha "$WIPREF")" ]
}

@test "take with a malformed MOTHER_LEASE_ID exits 1 naming the variable and pushes nothing" {
    make_dirty
    MOTHER_LEASE_ID=$'bad\nid' take
    [ "$CST" -eq 1 ]
    [[ "$CERR" == *MOTHER_LEASE_ID* ]]
    [ -z "$(remote_sha "$WIPREF")" ]
}

@test "take with a missing or non-positive-integer MOTHER_LEASE_EPOCH exits 1 naming the variable and pushes nothing" {
    make_dirty
    for bad in abc 0 -1 1.5 ""; do
        MOTHER_LEASE_EPOCH="$bad" take
        [ "$CST" -eq 1 ]
        [[ "$CERR" == *MOTHER_LEASE_EPOCH* ]]
        [ -z "$(remote_sha "$WIPREF")" ]
    done
    unset MOTHER_LEASE_EPOCH
    take
    [ "$CST" -eq 1 ]
    [[ "$CERR" == *MOTHER_LEASE_EPOCH* ]]
    [ -z "$(remote_sha "$WIPREF")" ]
}

@test "a salvage take needs no MOTHER_LEASE_EPOCH (the epoch is its argument) but still needs a lease id" {
    make_dirty
    unset MOTHER_LEASE_EPOCH
    take --salvage-epoch 2
    [ "$CST" -eq 0 ]
    [ -n "$(remote_sha "refs/mother/wip-salvage/$JOB/lease-2")" ]
}

@test "take in a repo with no commits fails with why unborn_head" {
    git init -q "$T/unborn"
    jq --arg wd "$T/unborn" '.work_dir = $wd' "$JOBF" > "$T/job.tmp" && mv "$T/job.tmp" "$JOBF"
    take
    [ "$CST" -eq 1 ]
    [ "$(printf '%s' "$COUT" | jq -r .why)" = "unborn_head" ]
    [ -z "$(remote_sha "$WIPREF")" ]
}

# ---------------------------------------------------------------------------
# Restore: target directory validation and cleanup
# ---------------------------------------------------------------------------

@test "restore refuses a relative new work dir and creates nothing" {
    _prep_restore
    count_before="$(_worktree_count)"
    cd "$T"
    NEWWT="rel/newwt"
    restore
    [ "$CST" -eq 1 ]
    [ -n "$CERR" ]
    [ ! -e "$T/rel" ]
    [ ! -e "$REPO/rel" ]
    [ "$(_worktree_count)" = "$count_before" ]
}

@test "restore refuses a new work dir containing .." {
    _prep_restore
    count_before="$(_worktree_count)"
    mkdir -p "$T/x"
    NEWWT="$T/x/../newwt"
    restore
    [ "$CST" -eq 1 ]
    [ -n "$CERR" ]
    [ ! -e "$T/newwt" ]
    [ "$(_worktree_count)" = "$count_before" ]
}

@test "restore refuses a non-empty existing new work dir and leaves it as it was" {
    _prep_restore
    count_before="$(_worktree_count)"
    mkdir -p "$NEWWT"
    printf 'keep\n' > "$NEWWT/keep.txt"
    restore
    [ "$CST" -eq 1 ]
    [ -n "$CERR" ]
    [ "$(ls -A "$NEWWT")" = "keep.txt" ]
    [ "$(cat "$NEWWT/keep.txt")" = "keep" ]
    [ "$(_worktree_count)" = "$count_before" ]
}

@test "restore accepts an existing empty new work dir" {
    _prep_restore
    mkdir -p "$NEWWT"
    restore
    [ "$CST" -eq 0 ]
    [ "$(git -C "$NEWWT" rev-parse HEAD)" = "$HEAD_SHA" ]
}

@test "a restore that fails after the worktree was added removes it so a retry at the same path succeeds" {
    _prep_restore
    count_before="$(_worktree_count)"
    : > "$T/not-a-dir"

    MOTHER_CLAUDE_PROJECTS_DIR="$T/not-a-dir" restore
    [ "$CST" -ne 0 ]
    [ "$(_worktree_count)" = "$count_before" ]
    run git -C "$REPO" worktree list
    [[ "$output" != *newwt* ]]
    [ ! -e "$NEWWT" ]

    restore
    [ "$CST" -eq 0 ]
    [ "$(printf '%s' "$COUT" | jq -r .restored)" = "true" ]
    [ "$(git -C "$NEWWT" rev-parse HEAD)" = "$HEAD_SHA" ]
    [ -f "$MOTHER_CLAUDE_PROJECTS_DIR/$(_enc "$NEWWT")/$SID.jsonl" ]
}

@test "take refuses a repo whose config sets core.worktree" {
    make_dirty
    git -C "$REPO" config core.worktree "$T/elsewhere"
    take
    [ "$CST" -eq 1 ]
    [ "$(printf '%s' "$COUT" | jq -r .why)" = "unsafe_config" ]
    [ -z "$(remote_sha "$WIPREF")" ]
}

# ---------------------------------------------------------------------------
# One push per take, and a bounded ref history on origin (P1-6 round 3)
# ---------------------------------------------------------------------------

_ckpt_refs() { git -C "$ORIGIN" for-each-ref --format='%(refname)' "refs/mother/wip-ckpt/$JOB/" | sed "s|refs/mother/wip-ckpt/$JOB/||" | sort | tr '\n' ' '; }

@test "a take makes exactly ONE push, carrying the per-checkpoint ref and the rolling ref" {
    make_dirty
    _install_git_stub <<STUB
case " \$* " in *" push "*) echo "\$*" >> "$T/pushlog" ;; esac
exec "\$REAL_GIT" "\$@"
STUB
    PATH="$T/stubbin:$PATH" take
    [ "$CST" -eq 0 ]
    [ "$(m .pushed)" = "true" ]
    [ "$(grep -c . "$T/pushlog")" -eq 1 ]
    grep -q "refs/mother/wip-ckpt/$JOB/1-1" "$T/pushlog"
    grep -q "refs/mother/wip/$JOB" "$T/pushlog"
    [ "$(remote_sha "$WIPREF")" = "$(m .wip_sha)" ]
    [ "$(remote_sha "refs/mother/wip-ckpt/$JOB/1-1")" = "$(m .wip_sha)" ]
}

@test "this epoch keeps only the newest MOTHER_CHECKPOINT_KEEP_REFS refs on origin" {
    export MOTHER_CHECKPOINT_KEEP_REFS=2
    local i
    for i in 1 2 3 4; do
        printf 'x%s\n' "$i" >> "$WT/b.txt"
        take
        [ "$CST" -eq 0 ]
        [ "$(m .pushed)" = "true" ]
    done
    [ "$(_ckpt_refs)" = "1-3 1-4 " ]
}

@test "a later epoch removes the earlier epochs' refs except the restore point it was restored from, once, and never a salvage ref" {
    local seed
    seed="$(git -C "$WT" rev-parse HEAD)"
    git -C "$WT" push -q origin "$seed:refs/mother/wip-ckpt/$JOB/1-1" "$seed:refs/mother/wip-ckpt/$JOB/1-2" "$seed:refs/mother/wip-ckpt/$JOB/1-3" \
        "$seed:refs/mother/wip-salvage/$JOB/lease-1"
    printf '1-2' > "$OUT/../.restore-point"
    export MOTHER_LEASE_EPOCH=2
    make_dirty
    take
    [ "$CST" -eq 0 ]
    [ "$(m .pushed)" = "true" ]
    [ "$(_ckpt_refs)" = "1-2 2-1 " ]
    [ -n "$(remote_sha "refs/mother/wip-salvage/$JOB/lease-1")" ]
    [ "$(cat "$OUT/../.pruned-epoch")" = "2" ]
    # The sweep runs once per epoch: a ref that appears afterwards is not looked for (no extra ls-remote).
    git -C "$WT" push -q origin "$seed:refs/mother/wip-ckpt/$JOB/1-9"
    printf 'y\n' >> "$WT/b.txt"
    take
    [ "$(m .pushed)" = "true" ]
    [ -n "$(remote_sha "refs/mother/wip-ckpt/$JOB/1-9")" ]
}

@test "a refused delete (a ref already gone) never sinks the checkpoint" {
    export MOTHER_CHECKPOINT_KEEP_REFS=1
    make_dirty
    take                      # n=1
    git -C "$ORIGIN" update-ref -d "refs/mother/wip-ckpt/$JOB/1-1"
    printf 'z\n' >> "$WT/b.txt"
    take                      # n=2 deletes 1-1, which is already gone
    [ "$CST" -eq 0 ]
    [ "$(m .pushed)" = "true" ]
    [ "$(remote_sha "$WIPREF")" = "$(m .wip_sha)" ]
}

@test "a later epoch with no restore point on record deletes none of the earlier epochs' refs" {
    local seed
    seed="$(git -C "$WT" rev-parse HEAD)"
    git -C "$WT" push -q origin "$seed:refs/mother/wip-ckpt/$JOB/1-1" "$seed:refs/mother/wip-ckpt/$JOB/1-2"
    export MOTHER_LEASE_EPOCH=2
    make_dirty
    take
    [ "$(m .pushed)" = "true" ]
    [ "$(_ckpt_refs)" = "1-1 1-2 2-1 " ]
}

# --- one push, partial rejection (PR #124 round 4, B) ----------------------------------------------------------------

# An update hook on the bare origin: refuses refs/mother/wip-ckpt/* while $T/refuse-ckpt exists; logs every ref it sees.
_install_update_hook() {
    mkdir -p "$ORIGIN/hooks"
    cat > "$ORIGIN/hooks/update" <<HOOK
#!/bin/sh
echo "\$1" >> "$T/hooklog"
case "\$1" in refs/mother/wip-ckpt/*) [ -e "$T/refuse-ckpt" ] && { echo "refused by test hook" >&2; exit 1; } ;; esac
exit 0
HOOK
    chmod +x "$ORIGIN/hooks/update"
}

@test "B: a remote that refuses only the per-checkpoint ref is pushed:false, never fenced, and the next take is pushed:true" {
    _install_update_hook
    make_dirty
    take
    [ "$CST" -eq 0 ]
    [ "$(m .pushed)" = "true" ]
    touch "$T/refuse-ckpt"
    printf 'r1\n' >> "$WT/b.txt"
    take
    [ "$CST" -eq 0 ]
    [ "$(m .pushed)" = "false" ]
    [ "$(m .push_error)" != "fenced" ]
    # committed work still reached the remote: the rolling ref is at this take's wip
    [ "$(remote_sha "$WIPREF")" = "$(m .wip_sha)" ]
    [ -z "$(remote_sha "refs/mother/wip-ckpt/$JOB/1-2")" ]
    # still refused: still not fenced, and the expectation follows the rolling ref
    printf 'r2\n' >> "$WT/b.txt"
    take
    [ "$CST" -eq 0 ]
    [ "$(m .pushed)" = "false" ]
    [ "$(m .push_error)" != "fenced" ]
    # cause removed: back to normal
    rm -f "$T/refuse-ckpt"
    printf 'r3\n' >> "$WT/b.txt"
    take
    [ "$CST" -eq 0 ]
    [ "$(m .pushed)" = "true" ]
    [ "$(remote_sha "$WIPREF")" = "$(m .wip_sha)" ]
    [ "$(remote_sha "refs/mother/wip-ckpt/$JOB/1-4")" = "$(m .wip_sha)" ]
}

@test "B: pushed:true means the per-checkpoint ref and the rolling ref both sit at the manifest's wip_sha, on every take" {
    _install_update_hook
    make_dirty
    local i
    for i in 1 2 3; do
        printf 'x%s\n' "$i" >> "$WT/b.txt"
        take
        [ "$(m .pushed)" = "true" ]
        [ "$(remote_sha "$WIPREF")" = "$(m .wip_sha)" ]
        [ "$(remote_sha "refs/mother/wip-ckpt/$JOB/1-$i")" = "$(m .wip_sha)" ]
    done
    [ "$(grep -c "^refs/mother/wip-ckpt/$JOB/" "$T/hooklog")" -eq 3 ]
    [ "$(grep -c "^$WIPREF\$" "$T/hooklog")" -eq 3 ]
}

@test "B: a rolling ref another writer moved is still fenced even when a hook is installed" {
    _install_update_hook
    _make_fenced
    take
    [ "$CST" -eq 3 ]
    [ "$(printf '%s' "$COUT" | jq -r .push_error)" = "fenced" ]
    [ "$(remote_sha "$WIPREF")" = "$MOVED" ]
}
