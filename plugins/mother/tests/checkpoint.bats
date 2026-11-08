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
