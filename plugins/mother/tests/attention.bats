#!/usr/bin/env bats
# attention.bats — the single "needs the operator's attention" list.
#
# Contract under test (lib/attention.sh + its renderers):
#   mother_attention_items   prints a JSON array of
#                            {kind, job_id, repo, branch, reason, since, detail, hint}
#   mother_attention_write   atomically writes that array to $MOTHER_ROOT/attention.json
#   mother status            (no id) queue overview + awaiting + needs-attention
#   mother status --format json   {counts, awaiting, needs_attention}
#   mother status <id>       dependency-wait banner / awaiting-notify line
#   mother list              footer `⚑ N item(s) need attention — run: mother status`
#   statusline               6th cache field ATTENTION, rendered as ⚑N
#   mother-runner --attention-tick   one throttled refresh of attention.json
#
# Hard rule: every read path here is local-only. `gh` must never be called —
# the gh stub installed by setup() fails the test if anything invokes it.

load 'test_helper'

setup() {
    setup_mother_env

    # Never touch the operator's real ~/.claude (plugin-cache check) and never
    # fire a real desktop notification.
    export HOME="$MOTHER_ROOT/home"
    mkdir -p "$HOME"
    export MOTHER_NOTIFY_TRANSPORT=none

    # gh tripwire: any invocation records a marker and fails.
    GH_MARKER="$MOTHER_ROOT/gh-was-called"
    cat > "$_MOCK_BIN/gh" <<GH
#!/usr/bin/env bash
echo "\$*" >> "$GH_MARKER"
exit 1
GH
    chmod +x "$_MOCK_BIN/gh"
}

teardown() {
    teardown_mother_env
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

_source_attention_libs() {
    printf "set -u; source '%s/state.sh'; source '%s/attention.sh';" "$_LIB_DIR" "$_LIB_DIR"
}

# JSON array printed by mother_attention_items.
_items() {
    bash -c "$(_source_attention_libs) mother_attention_items" 2>/dev/null
}

# Number of items of <kind> (optionally for one <job_id>).
# Usage: _kind_count <kind> [job_id]
_kind_count() {
    _items | jq --arg k "$1" --arg j "${2:-}" \
        '[.[] | select(.kind == $k and ($j == "" or .job_id == $j))] | length'
}

# The first item of <kind> for <job_id>, as compact JSON.
_item() {
    _items | jq -c --arg k "$1" --arg j "$2" \
        '[.[] | select(.kind == $k and .job_id == $j)] | .[0] // empty'
}

# ISO-8601 UTC timestamp <seconds> in the past.
_iso_ago() {
    /usr/bin/perl -MPOSIX=strftime -e \
        'print strftime("%Y-%m-%dT%H:%M:%SZ", gmtime(time - $ARGV[0]))' "$1"
}
_days() { echo $(( $1 * 86400 )); }

# Pending-teardown record (schema per the teardown queue contract).
# Usage: _pending <id> <jq-filter>
_pending() {
    local id="$1" extra="${2:-.}"
    jq -n --arg id "$id" \
        '{id: $id, repo: "testrepo", repo_path: "/tmp/nonexistent-repo", branch: ("feature/" + $id),
          work_dir: "", isolation: "worktree", pr_url: null, state: "succeeded", no_pr: false,
          events_path: "", deferrals: 0, stall_deferrals: 0, last_reason: "gh_inconclusive",
          deferred_at: "2026-09-01T00:00:00Z"}' \
        | jq "$extra" > "$TEARDOWN_DIR/$id.json"
}

# Real git repo with one tracked file, for stash fixtures.
_make_stash_repo() {
    local dir="$1"
    git init -q "$dir"
    git -C "$dir" config user.email "test@test.com"
    git -C "$dir" config user.name "Test"
    echo base > "$dir/f.txt"
    git -C "$dir" add f.txt
    git -C "$dir" commit -q -m init
}

# Stash a modification the way Mother's main-dir auto-stash does.
# Usage: _auto_stash <repo_dir> <job_id>
_auto_stash() {
    local dir="$1" id="$2"
    echo "changed by $id" > "$dir/f.txt"
    git -C "$dir" stash push -q -m "mother:auto-stash:$id"
}

# A main-dir job pointed at a real repo.
# Usage: _make_maindir_job <id> <state> <repo_dir>
_make_maindir_job() {
    make_job "$1" "$2" ".isolation = \"main-dir\" | .repo_path = \"$3\""
}

# Text of one `=== <heading> ...===` section of `mother status` output
# (everything up to the next `=== ` heading), from $output.
_section() {
    printf '%s\n' "$output" | awk -v h="$1" 'index($0, h) {f=1; next} /^=== / {f=0} f'
}

_gh_not_called() { [ ! -e "$GH_MARKER" ]; }

# ---------------------------------------------------------------------------
# mother_attention_items — empty state and shape
# ---------------------------------------------------------------------------

@test "with nothing wrong the attention list is an empty JSON array" {
    run bash -c "$(_source_attention_libs) mother_attention_items 2>/dev/null"
    [ "$status" -eq 0 ]
    [ "$(printf '%s' "$output" | jq -c '.')" = "[]" ]
}

@test "every attention item carries kind, job_id, repo, branch, reason, since, detail and hint" {
    _pending "shape-stall" '.stall_deferrals = 31'
    make_job "shape-flag" "failed" '.needs_attention = {reason: "review_me", note: "look at this", since: "2026-09-20T00:00:00Z"}'
    make_job "shape-blocked" "queued" '.dep_wait = {dep_id: "d1", status: "blocked", reason: "dep_failed", checked_at: "2026-09-20T00:00:00Z"}'

    run _items
    [ "$status" -eq 0 ]
    [ "$(printf '%s' "$output" | jq 'length')" -ge 3 ]
    [ "$(printf '%s' "$output" | jq 'all(.[]; has("kind") and has("job_id") and has("repo") and has("branch") and has("reason") and has("since") and has("detail") and has("hint"))')" = "true" ]
}

# ---------------------------------------------------------------------------
# teardown_stalled
# ---------------------------------------------------------------------------

@test "teardown_stalled: a pending teardown past the default cap of 30 is listed" {
    _pending "stall-over" '.last_reason = "gh_inconclusive" | .stall_deferrals = 31'
    [ "$(_kind_count teardown_stalled stall-over)" = "1" ]
    local item; item=$(_item teardown_stalled stall-over)
    [ "$(printf '%s' "$item" | jq -r '.repo')" = "testrepo" ]
    [ "$(printf '%s' "$item" | jq -r '.branch')" = "feature/stall-over" ]
}

@test "teardown_stalled: a pending teardown exactly at the cap of 30 is not yet listed" {
    _pending "stall-at-cap" '.last_reason = "gh_inconclusive" | .stall_deferrals = 30'
    [ "$(_kind_count teardown_stalled stall-at-cap)" = "0" ]
}

@test "teardown_stalled: worktree_probe_failed uses the much lower probe-failed cap of 2" {
    _pending "probe-over" '.last_reason = "worktree_probe_failed" | .stall_deferrals = 3'
    _pending "probe-at-cap" '.last_reason = "worktree_probe_failed" | .stall_deferrals = 2'
    [ "$(_kind_count teardown_stalled probe-over)" = "1" ]
    [ "$(_kind_count teardown_stalled probe-at-cap)" = "0" ]
}

@test "teardown_stalled: MOTHER_TEARDOWN_PROBE_FAILED_MAX_DEFERRALS and MOTHER_TEARDOWN_MAX_DEFERRALS tune the caps" {
    export MOTHER_TEARDOWN_PROBE_FAILED_MAX_DEFERRALS=5 MOTHER_TEARDOWN_MAX_DEFERRALS=3
    _pending "tuned-probe" '.last_reason = "worktree_probe_failed" | .stall_deferrals = 4'
    _pending "tuned-other" '.last_reason = "unsafe_worktree" | .stall_deferrals = 4'
    [ "$(_kind_count teardown_stalled tuned-probe)" = "0" ]
    [ "$(_kind_count teardown_stalled tuned-other)" = "1" ]
}

@test "teardown_stalled: a healthy PR-open wait is never a stall, however long it has waited" {
    _pending "healthy-not-stall" \
        '.last_reason = "pr_open" | .stall_deferrals = 0 | .deferrals = 500
         | .open_pr = {url: "https://github.com/x/y/pull/1", created_at: null, first_seen_open_at: null}'
    [ "$(_kind_count teardown_stalled healthy-not-stall)" = "0" ]
}

# ---------------------------------------------------------------------------
# pr_open_stale
# ---------------------------------------------------------------------------

@test "pr_open_stale: a PR that has been open for 8 days is listed with its URL and age" {
    _pending "stale-8d" \
        ".pr_url = \"https://github.com/x/y/pull/77\" | .last_reason = \"pr_open\"
         | .open_pr = {url: \"https://github.com/x/y/pull/77\", created_at: \"$(_iso_ago $(( $(_days 8) + 3600 )))\", first_seen_open_at: \"$(_iso_ago 3600)\"}"
    [ "$(_kind_count pr_open_stale stale-8d)" = "1" ]
    local item; item=$(_item pr_open_stale stale-8d)
    local detail; detail=$(printf '%s' "$item" | jq -r '.detail | tostring')
    [[ "$detail" == *"https://github.com/x/y/pull/77"* ]]
    [[ "$detail" == *"8"* ]]
}

@test "pr_open_stale: a PR that has been open for 6 days is not listed" {
    _pending "stale-6d" \
        ".last_reason = \"pr_open\"
         | .open_pr = {url: \"https://github.com/x/y/pull/78\", created_at: \"$(_iso_ago $(( $(_days 6) + 3600 )))\", first_seen_open_at: \"$(_iso_ago 3600)\"}"
    [ "$(_kind_count pr_open_stale stale-6d)" = "0" ]
}

@test "pr_open_stale: applies to a live-branch wait (pr_open_live) too" {
    _pending "stale-live" \
        ".last_reason = \"pr_open_live\"
         | .open_pr = {url: \"https://github.com/x/y/pull/79\", created_at: \"$(_iso_ago $(( $(_days 9) )))\", first_seen_open_at: \"$(_iso_ago 3600)\"}"
    [ "$(_kind_count pr_open_stale stale-live)" = "1" ]
}

@test "pr_open_stale: falls back to first_seen_open_at when created_at is unknown" {
    _pending "stale-fallback" \
        ".last_reason = \"pr_open\"
         | .open_pr = {url: \"https://github.com/x/y/pull/80\", created_at: null, first_seen_open_at: \"$(_iso_ago $(( $(_days 8) + 3600 )))\"}"
    _pending "fresh-fallback" \
        ".last_reason = \"pr_open\"
         | .open_pr = {url: \"https://github.com/x/y/pull/81\", created_at: null, first_seen_open_at: \"$(_iso_ago $(( $(_days 1) )))\"}"
    [ "$(_kind_count pr_open_stale stale-fallback)" = "1" ]
    [ "$(_kind_count pr_open_stale fresh-fallback)" = "0" ]
}

@test "pr_open_stale: MOTHER_TEARDOWN_PR_OPEN_ATTENTION_DAYS moves the threshold" {
    export MOTHER_TEARDOWN_PR_OPEN_ATTENTION_DAYS=3
    _pending "stale-tuned" \
        ".last_reason = \"pr_open\"
         | .open_pr = {url: \"https://github.com/x/y/pull/82\", created_at: \"$(_iso_ago $(( $(_days 4) )))\", first_seen_open_at: \"$(_iso_ago 3600)\"}"
    [ "$(_kind_count pr_open_stale stale-tuned)" = "1" ]
}

@test "pr_open_stale: a record that is not in a healthy PR wait is not listed even with an old open_pr" {
    _pending "stale-but-stalled" \
        ".last_reason = \"gh_inconclusive\" | .stall_deferrals = 1
         | .open_pr = {url: \"https://github.com/x/y/pull/83\", created_at: \"$(_iso_ago $(( $(_days 30) )))\", first_seen_open_at: \"$(_iso_ago $(( $(_days 30) )))\"}"
    [ "$(_kind_count pr_open_stale stale-but-stalled)" = "0" ]
}

@test "pr_open_stale: a healthy wait with no recorded PR age is not listed" {
    _pending "stale-unknown-age" '.last_reason = "pr_open"'
    [ "$(_kind_count pr_open_stale stale-unknown-age)" = "0" ]
}

# ---------------------------------------------------------------------------
# dependency_blocked
# ---------------------------------------------------------------------------

@test "dependency_blocked: a queued job blocked on its dependency is listed with force-start and cancel hints" {
    make_job "dep-blocked-job" "queued" \
        '.depends_on = ["dep-1"] | .dep_wait = {dep_id: "dep-1", status: "blocked", reason: "dep_failed", pr_url: null, checked_at: "2026-09-20T00:00:00Z"}'
    [ "$(_kind_count dependency_blocked dep-blocked-job)" = "1" ]
    local item hint
    item=$(_item dependency_blocked dep-blocked-job)
    hint=$(printf '%s' "$item" | jq -r '.hint')
    [[ "$hint" == *"mother force-start dep-blocked-job"* ]]
    [[ "$hint" == *"mother cancel dep-blocked-job"* ]]
}

@test "dependency_blocked: a job that is merely waiting on its dependency is not listed" {
    make_job "dep-waiting-job" "queued" \
        '.depends_on = ["dep-2"] | .dep_wait = {dep_id: "dep-2", status: "wait", reason: "pr_open", pr_url: "https://github.com/x/y/pull/5", checked_at: "2026-09-20T00:00:00Z"}'
    [ "$(_kind_count dependency_blocked dep-waiting-job)" = "0" ]
}

@test "dependency_blocked: only queued jobs count, a stale blocked marker on a ready job is ignored" {
    make_job "dep-stale-marker" "ready" \
        '.dep_wait = {dep_id: "dep-3", status: "blocked", reason: "dep_failed", checked_at: "2026-09-20T00:00:00Z"}'
    [ "$(_kind_count dependency_blocked dep-stale-marker)" = "0" ]
}

# ---------------------------------------------------------------------------
# auto_stash_unrestored
# ---------------------------------------------------------------------------

@test "auto_stash_unrestored: lists a mother auto-stash whose job is no longer active, never lists a running job's stash" {
    local repo="$MOTHER_ROOT/stash-repo"
    _make_stash_repo "$repo"
    _make_maindir_job "stash-run" "running" "$repo"
    _make_maindir_job "stash-done" "succeeded" "$repo"
    _auto_stash "$repo" "stash-run"
    _auto_stash "$repo" "stash-done"

    [ "$(_kind_count auto_stash_unrestored stash-done)" = "1" ]
    [ "$(_kind_count auto_stash_unrestored stash-run)" = "0" ]
}

@test "auto_stash_unrestored: ready and awaiting jobs still own their stash" {
    local repo="$MOTHER_ROOT/stash-repo-active"
    _make_stash_repo "$repo"
    _make_maindir_job "stash-ready" "ready" "$repo"
    _make_maindir_job "stash-await" "awaiting" "$repo"
    _auto_stash "$repo" "stash-ready"
    _auto_stash "$repo" "stash-await"

    [ "$(_kind_count auto_stash_unrestored stash-ready)" = "0" ]
    [ "$(_kind_count auto_stash_unrestored stash-await)" = "0" ]
}

@test "auto_stash_unrestored: a stash whose job record is gone entirely is listed, other stashes are ignored" {
    local repo="$MOTHER_ROOT/stash-repo-gone"
    _make_stash_repo "$repo"
    _make_maindir_job "stash-anchor" "succeeded" "$repo"   # makes the repo discoverable
    _auto_stash "$repo" "stash-vanished"
    echo "operator work" > "$repo/f.txt"
    git -C "$repo" stash push -q -m "my own wip"

    [ "$(_kind_count auto_stash_unrestored stash-vanished)" = "1" ]
    # Only Mother's own auto-stashes are flagged.
    [ "$(_items | jq '[.[] | select(.kind == "auto_stash_unrestored")] | length')" = "1" ]
}

@test "auto_stash_unrestored: the hint points at git stash list and the stash's own index, and nothing is popped" {
    local repo="$MOTHER_ROOT/stash-repo-hint"
    _make_stash_repo "$repo"
    _make_maindir_job "stash-hint-done" "failed" "$repo"
    _auto_stash "$repo" "stash-hint-done"
    _auto_stash "$repo" "stash-hint-newer"   # pushes the first one down to index 1

    local idx
    idx=$(git -C "$repo" stash list | grep -n 'mother:auto-stash:stash-hint-done' | cut -d: -f1)
    idx=$((idx - 1))

    local hint
    hint=$(_item auto_stash_unrestored stash-hint-done | jq -r '.hint')
    # (may be spelled `git -C <repo> stash list`; the sub-commands are the contract)
    [[ "$hint" == *"stash list"* ]]
    [[ "$hint" == *"stash show -p stash@{$idx}"* ]]

    # Read-only: both stashes still stashed, working tree still clean.
    [ "$(git -C "$repo" stash list | wc -l | tr -d ' ')" = "2" ]
    [ -z "$(git -C "$repo" status --porcelain)" ]
}

@test "auto_stash_unrestored: repos of worktree-isolated jobs are not scanned" {
    local repo="$MOTHER_ROOT/stash-repo-wt"
    _make_stash_repo "$repo"
    make_job "stash-wt-job" "succeeded" ".isolation = \"worktree\" | .repo_path = \"$repo\""
    _auto_stash "$repo" "stash-wt-job"

    [ "$(_kind_count auto_stash_unrestored)" = "0" ]
}

@test "auto_stash_unrestored: a main-dir job whose repo_path no longer exists does not break the list" {
    make_job "stash-missing-repo" "succeeded" ".isolation = \"main-dir\" | .repo_path = \"$MOTHER_ROOT/no-such-repo\""
    make_job "still-flagged" "failed" '.needs_attention = {reason: "r", note: "n", since: "2026-09-20T00:00:00Z"}'

    run bash -c "$(_source_attention_libs) mother_attention_items 2>/dev/null"
    [ "$status" -eq 0 ]
    [ "$(printf '%s' "$output" | jq '[.[] | select(.kind == "job_flagged")] | length')" = "1" ]
}

# ---------------------------------------------------------------------------
# job_flagged
# ---------------------------------------------------------------------------

@test "job_flagged: a job carrying a needs_attention object is listed with its reason and since" {
    make_job "flagged-job" "failed" \
        '.needs_attention = {reason: "manual_review", note: "PR touches billing, please eyeball", since: "2026-09-21T09:30:00Z"}'
    [ "$(_kind_count job_flagged flagged-job)" = "1" ]
    local item; item=$(_item job_flagged flagged-job)
    [ "$(printf '%s' "$item" | jq -r '.reason')" = "manual_review" ]
    [ "$(printf '%s' "$item" | jq -r '.since')" = "2026-09-21T09:30:00Z" ]
    [[ "$item" == *"PR touches billing, please eyeball"* ]]
}

@test "job_flagged: jobs without a needs_attention object are not listed" {
    make_job "not-flagged" "failed"
    [ "$(_kind_count job_flagged not-flagged)" = "0" ]
}

# ---------------------------------------------------------------------------
# plugin_cache_stale
# ---------------------------------------------------------------------------

# Register a plugin install at <install_dir> under <plugin_key>.
_register_plugin() {
    local key="$1" install_dir="$2"
    mkdir -p "$HOME/.claude/plugins"
    jq -n --arg k "$key" --arg p "$install_dir" \
        '{version: 2, plugins: {($k): [{scope: "user", installPath: $p}]}}' \
        > "$HOME/.claude/plugins/installed_plugins.json"
}

@test "plugin_cache_stale: an installed copy of the inject hook that differs from the running plugin's is flagged" {
    mkdir -p "$MOTHER_ROOT/cache-stale/hooks"
    echo "# an older hook" > "$MOTHER_ROOT/cache-stale/hooks/mother-inject.sh"
    _register_plugin "mother@testmkt" "$MOTHER_ROOT/cache-stale"

    [ "$(_kind_count plugin_cache_stale)" = "1" ]
}

@test "plugin_cache_stale: an installed copy identical to the running plugin's is not flagged" {
    mkdir -p "$MOTHER_ROOT/cache-fresh/hooks"
    cp "$_PLUGIN_DIR/hooks/mother-inject.sh" "$MOTHER_ROOT/cache-fresh/hooks/mother-inject.sh"
    _register_plugin "mother@testmkt" "$MOTHER_ROOT/cache-fresh"

    [ "$(_kind_count plugin_cache_stale)" = "0" ]
}

@test "plugin_cache_stale: other plugins' installs are ignored" {
    mkdir -p "$MOTHER_ROOT/cache-other/hooks"
    echo "# different" > "$MOTHER_ROOT/cache-other/hooks/mother-inject.sh"
    _register_plugin "hookify@testmkt" "$MOTHER_ROOT/cache-other"

    [ "$(_kind_count plugin_cache_stale)" = "0" ]
}

@test "plugin_cache_stale: a missing installed_plugins.json is skipped silently" {
    [ ! -e "$HOME/.claude/plugins/installed_plugins.json" ]
    run bash -c "$(_source_attention_libs) mother_attention_items"
    [ "$status" -eq 0 ]
    [ "$(printf '%s' "$output" | jq -c '.')" = "[]" ]
}

# ---------------------------------------------------------------------------
# mother_attention_write
# ---------------------------------------------------------------------------

@test "mother_attention_write writes [] to attention.json when nothing needs attention" {
    run bash -c "$(_source_attention_libs) mother_attention_write"
    [ "$status" -eq 0 ]
    [ -f "$MOTHER_ROOT/attention.json" ]
    [ "$(jq -c '.' "$MOTHER_ROOT/attention.json")" = "[]" ]
}

@test "mother_attention_write replaces a previous file with the current items, leaving no temp files behind" {
    printf '%s\n' '[{"kind":"old","job_id":"gone"}]' > "$MOTHER_ROOT/attention.json"
    make_job "write-flagged" "failed" '.needs_attention = {reason: "r", note: "n", since: "2026-09-20T00:00:00Z"}'

    run bash -c "$(_source_attention_libs) mother_attention_write"
    [ "$status" -eq 0 ]
    [ "$(jq 'length' "$MOTHER_ROOT/attention.json")" = "1" ]
    [ "$(jq -r '.[0].kind' "$MOTHER_ROOT/attention.json")" = "job_flagged" ]
    [ "$(jq -r '.[0].job_id' "$MOTHER_ROOT/attention.json")" = "write-flagged" ]
    [ -z "$(find "$MOTHER_ROOT" -maxdepth 1 -name 'attention.json.*' 2>/dev/null)" ]
}

# ---------------------------------------------------------------------------
# No gh, ever
# ---------------------------------------------------------------------------

@test "computing, writing and rendering attention never calls gh" {
    local repo="$MOTHER_ROOT/nogh-repo"
    _make_stash_repo "$repo"
    _make_maindir_job "nogh-done" "succeeded" "$repo"
    _auto_stash "$repo" "nogh-done"
    _pending "nogh-wait" \
        ".last_reason = \"pr_open\" | .pr_url = \"https://github.com/x/y/pull/1\"
         | .open_pr = {url: \"https://github.com/x/y/pull/1\", created_at: \"$(_iso_ago $(( $(_days 20) )))\", first_seen_open_at: null}"
    make_job "nogh-blocked" "queued" \
        '.dep_wait = {dep_id: "d", status: "blocked", reason: "dep_failed", checked_at: "2026-09-20T00:00:00Z"}'
    make_job "nogh-await" "awaiting" '.paused_at = "2026-09-20T00:00:00Z" | .paused_reason = "user" | .question = "q?"'

    run bash -c "$(_source_attention_libs) mother_attention_items; mother_attention_write"
    [ "$status" -eq 0 ]
    run mother status
    [ "$status" -eq 0 ]
    run mother status --format json
    [ "$status" -eq 0 ]
    run mother status "nogh-blocked"
    [ "$status" -eq 0 ]
    run mother list
    [ "$status" -eq 0 ]
    run mother list --format json
    [ "$status" -eq 0 ]
    run bash -c "export MOTHER_ROOT='$MOTHER_ROOT'; source '$_PLUGIN_DIR/statusline/segment.sh'; mother_statusline_refresh '$MOTHER_ROOT/sl-cache'"
    [ "$status" -eq 0 ]

    _gh_not_called
}

# ---------------------------------------------------------------------------
# mother status (no id)
# ---------------------------------------------------------------------------

@test "mother status with no id prints queue counts on one line" {
    make_job "cnt-run-1" "running"
    make_job "cnt-run-2" "running"
    make_job "cnt-queued" "queued"
    make_job "cnt-await" "awaiting" '.paused_at = "2026-09-20T00:00:00Z" | .paused_reason = "user" | .question = "q?"'

    run mother status
    [ "$status" -eq 0 ]
    printf '%s\n' "$output" | grep -Eq '(running[^0-9]*2|2[^0-9]*running)'
    printf '%s\n' "$output" | grep -Eq '(queued[^0-9]*1|1[^0-9]*queued)'
    printf '%s\n' "$output" | grep -Eq '(awaiting[^0-9]*1|1[^0-9]*awaiting)'
}

@test "mother status lists awaiting jobs with id, age, paused_reason and the first 100 chars of the question" {
    local q="0123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ-tail-that-must-be-cut"
    make_job "aw-listed" "awaiting" \
        ".paused_at = \"$(_iso_ago 11400)\" | .paused_reason = \"user\" | .question = \"$q\""

    run mother status
    [ "$status" -eq 0 ]
    [[ "$output" == *"=== awaiting operator ==="* ]]
    local section; section=$(_section "=== awaiting operator")
    [[ "$section" == *"aw-listed"* ]]
    [[ "$section" == *"user"* ]]
    # age since paused_at (3h10m ago) — "3h", "3.1h", "3h10m" all acceptable
    [[ "$section" =~ 3(\.[0-9]+)?h ]]
    # first 100 characters shown, the rest cut
    [[ "$section" == *"${q:0:100}"* ]]
    [[ "$section" != *"${q:0:101}"* ]]
}

@test "mother status does not present a quota pause as needing the operator (omitted or tagged auto-resumes)" {
    make_job "aw-quota" "awaiting" \
        ".paused_at = \"$(_iso_ago 600)\" | .paused_reason = \"quota_5h\" | .question = \"paused for quota\""
    make_job "aw-human" "awaiting" \
        ".paused_at = \"$(_iso_ago 600)\" | .paused_reason = \"user\" | .question = \"please decide\""

    run mother status
    [ "$status" -eq 0 ]
    local section; section=$(_section "=== awaiting operator")
    [[ "$section" == *"aw-human"* ]]
    if [[ "$section" == *"aw-quota"* ]]; then
        printf '%s\n' "$section" | grep 'aw-quota' | grep -Fq '(auto-resumes)'
    fi
}

@test "mother status lists needs-attention items with their hints, counted in the heading" {
    make_job "na-blocked" "queued" \
        '.dep_wait = {dep_id: "d", status: "blocked", reason: "dep_failed", checked_at: "2026-09-20T00:00:00Z"}'
    make_job "na-flagged" "failed" \
        '.needs_attention = {reason: "manual_review", note: "check the migration", since: "2026-09-21T00:00:00Z"}'

    run mother status
    [ "$status" -eq 0 ]
    [[ "$output" == *"=== needs attention (2) ==="* ]]
    local section; section=$(_section "=== needs attention")
    [[ "$section" == *"na-blocked"* ]]
    [[ "$section" == *"na-flagged"* ]]
    [[ "$section" == *"mother force-start na-blocked"* ]]
}

@test "mother status says so when nothing needs attention" {
    make_job "calm-job" "succeeded"

    run mother status
    [ "$status" -eq 0 ]
    [[ "$output" == *"(nothing needs attention)"* ]]
}

@test "mother status refreshes attention.json as a side effect" {
    make_job "side-effect-flagged" "failed" \
        '.needs_attention = {reason: "r", note: "n", since: "2026-09-20T00:00:00Z"}'
    [ ! -e "$MOTHER_ROOT/attention.json" ]

    run mother status
    [ "$status" -eq 0 ]
    [ "$(jq 'length' "$MOTHER_ROOT/attention.json")" = "1" ]
    [ "$(jq -r '.[0].job_id' "$MOTHER_ROOT/attention.json")" = "side-effect-flagged" ]
}

@test "mother status --format json with no id returns counts, awaiting and needs_attention" {
    make_job "js-run" "running"
    make_job "js-await" "awaiting" \
        '.paused_at = "2026-09-20T00:00:00Z" | .paused_reason = "user" | .question = "which way?"'
    make_job "js-flagged" "failed" \
        '.needs_attention = {reason: "manual_review", note: "n", since: "2026-09-21T00:00:00Z"}'

    run mother status --format json
    [ "$status" -eq 0 ]
    printf '%s' "$output" | jq -e 'has("counts") and has("awaiting") and has("needs_attention")' >/dev/null
    [ "$(printf '%s' "$output" | jq '.counts.running')" = "1" ]
    [ "$(printf '%s' "$output" | jq '.counts.awaiting')" = "1" ]
    [ "$(printf '%s' "$output" | jq '.awaiting | length')" = "1" ]
    [ "$(printf '%s' "$output" | jq -r '.awaiting | tostring | contains("js-await")')" = "true" ]
    [ "$(printf '%s' "$output" | jq '[.needs_attention[] | select(.kind == "job_flagged" and .job_id == "js-flagged")] | length')" = "1" ]
}

@test "mother status <id> keeps working for a single job" {
    make_job "single-job" "succeeded"
    run mother status "single-job"
    [ "$status" -eq 0 ]
    [[ "$output" == *"single-job"* ]]
}

# ---------------------------------------------------------------------------
# mother status <id> — dependency wait and awaiting notification
# ---------------------------------------------------------------------------

@test "mother status <id> shows a WAITING-ON-DEPENDENCY banner with the dependency's PR" {
    make_job "wait-banner" "queued" \
        '.depends_on = ["dep-x"] | .dep_wait = {dep_id: "dep-x", status: "wait", reason: "pr_open", pr_url: "https://github.com/x/y/pull/7", checked_at: "2026-09-20T00:00:00Z"}'

    run mother status "wait-banner"
    [ "$status" -eq 0 ]
    [[ "$output" == *"⏳ [WAITING-ON-DEPENDENCY] dep-x — pr_open (https://github.com/x/y/pull/7)"* ]]
    [[ "$output" != *"mother force-start wait-banner"* ]]
}

@test "mother status <id> for a blocked dependent adds the force-start and cancel hint" {
    make_job "blocked-banner" "queued" \
        '.depends_on = ["dep-y"] | .dep_wait = {dep_id: "dep-y", status: "blocked", reason: "dep_failed", pr_url: null, checked_at: "2026-09-20T00:00:00Z"}'

    run mother status "blocked-banner"
    [ "$status" -eq 0 ]
    [[ "$output" == *"⏳ [WAITING-ON-DEPENDENCY] dep-y — dep_failed"* ]]
    [[ "$output" == *"mother force-start blocked-banner"* ]]
    [[ "$output" == *"mother cancel blocked-banner"* ]]
}

@test "mother status <id> for a job without dep_wait prints no dependency banner" {
    make_job "no-banner" "queued"
    run mother status "no-banner"
    [ "$status" -eq 0 ]
    [[ "$output" != *"WAITING-ON-DEPENDENCY"* ]]
}

@test "mother status <id> for an awaiting job reports how many times the operator was notified" {
    make_job "notified-await" "awaiting" \
        '.paused_at = "2026-09-27T10:00:00Z" | .paused_reason = "user" | .question = "q?"
         | .awaiting_notify = {episode: "2026-09-27T10:00:00Z", first_seen_at: "2026-09-27T10:00:30Z", count: 2, last_notified_at: "2026-09-28T10:00:31Z"}'

    run mother status "notified-await"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Notified: 2 time(s), last 2026-09-28T10:00:31Z"* ]]
}

# ---------------------------------------------------------------------------
# mother list footer
# ---------------------------------------------------------------------------

@test "mother list ends with an attention footer when attention.json has items" {
    make_job "list-job" "succeeded"
    printf '%s\n' '[{"kind":"job_flagged","job_id":"a"},{"kind":"job_flagged","job_id":"b"}]' > "$MOTHER_ROOT/attention.json"

    run mother list
    [ "$status" -eq 0 ]
    local last="${lines[$((${#lines[@]} - 1))]}"
    [[ "$last" == *"⚑ 2 item(s) need attention — run: mother status"* ]]
}

@test "mother list prints no footer when attention.json is empty" {
    make_job "list-job-empty" "succeeded"
    printf '%s\n' '[]' > "$MOTHER_ROOT/attention.json"

    run mother list
    [ "$status" -eq 0 ]
    [[ "$output" != *"need attention"* ]]
}

@test "mother list prints no footer when attention.json does not exist, and does not compute one itself" {
    make_job "list-job-nofile" "failed" \
        '.needs_attention = {reason: "r", note: "n", since: "2026-09-20T00:00:00Z"}'
    [ ! -e "$MOTHER_ROOT/attention.json" ]

    run mother list
    [ "$status" -eq 0 ]
    [[ "$output" != *"need attention"* ]]
    [ ! -e "$MOTHER_ROOT/attention.json" ]
}

@test "mother list --format json is unchanged by attention items" {
    make_job "list-json" "succeeded"
    printf '%s\n' '[{"kind":"job_flagged","job_id":"a"}]' > "$MOTHER_ROOT/attention.json"

    run mother list --format json
    [ "$status" -eq 0 ]
    printf '%s' "$output" | jq -e 'type == "array"' >/dev/null
    [[ "$output" != *"⚑"* ]]
}

# ---------------------------------------------------------------------------
# Statusline
# ---------------------------------------------------------------------------

# Run a snippet with the statusline segment sourced.
# Usage: _seg <snippet>   (cache path is $SL_CACHE)
_seg() {
    bash -c "export MOTHER_ROOT='$MOTHER_ROOT' MOTHER_STATUSLINE_TTL=99999 MOTHER_STATUSLINE_CACHE='$SL_CACHE'
             source '$_PLUGIN_DIR/statusline/segment.sh'
             $1" 2>/dev/null
}

@test "statusline refresh writes six fields, the last being the attention count" {
    SL_CACHE="$MOTHER_ROOT/sl-cache"
    make_job "sl-run" "running"
    make_job "sl-queued" "queued"
    printf '%s\n' '[{"kind":"k","job_id":"a"},{"kind":"k","job_id":"b"},{"kind":"k","job_id":"c"}]' > "$MOTHER_ROOT/attention.json"

    _seg "mother_statusline_refresh '$SL_CACHE'"
    [ "$(tr -d '\n' < "$SL_CACHE")" = "1:1:0:0:0:3" ]
}

@test "statusline refresh reports zero attention when attention.json is missing, empty or unreadable" {
    SL_CACHE="$MOTHER_ROOT/sl-cache"
    make_job "sl-run" "running"

    _seg "mother_statusline_refresh '$SL_CACHE'"
    [ "$(tr -d '\n' < "$SL_CACHE")" = "1:0:0:0:0:0" ]

    printf '%s\n' '[]' > "$MOTHER_ROOT/attention.json"
    _seg "mother_statusline_refresh '$SL_CACHE'"
    [ "$(tr -d '\n' < "$SL_CACHE")" = "1:0:0:0:0:0" ]

    printf '%s\n' 'this is not json' > "$MOTHER_ROOT/attention.json"
    _seg "mother_statusline_refresh '$SL_CACHE'"
    [ "$(tr -d '\n' < "$SL_CACHE")" = "1:0:0:0:0:0" ]
}

@test "statusline segment renders ⚑N when there are attention items" {
    SL_CACHE="$MOTHER_ROOT/sl-cache"
    printf '%s\n' '0:0:0:0:0:3' > "$SL_CACHE"

    run _seg "mother_segment"
    [ "$status" -eq 0 ]
    [[ "$output" == *"⚑3"* ]]
}

@test "statusline segment renders nothing when every count including attention is zero" {
    SL_CACHE="$MOTHER_ROOT/sl-cache"
    printf '%s\n' '0:0:0:0:0:0' > "$SL_CACHE"

    run _seg "mother_segment"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "statusline segment still renders an old 5-field cache, treating attention as zero" {
    SL_CACHE="$MOTHER_ROOT/sl-cache"
    printf '%s\n' '2:1:0:0:0' > "$SL_CACHE"

    run _seg "mother_segment"
    [ "$status" -eq 0 ]
    [[ "$output" == *"▶2"* ]]
    [[ "$output" == *"⏸1"* ]]
    [[ "$output" != *"⚑"* ]]
}

# ---------------------------------------------------------------------------
# mother-runner --attention-tick
# ---------------------------------------------------------------------------

@test "mother-runner --attention-tick writes attention.json" {
    export MOTHER_ATTENTION_INTERVAL=0
    make_job "tick-flagged" "failed" \
        '.needs_attention = {reason: "r", note: "n", since: "2026-09-20T00:00:00Z"}'

    run mother-runner --attention-tick
    [ "$status" -eq 0 ]
    [ -f "$MOTHER_ROOT/attention.json" ]
    [ "$(jq -r '.[0].job_id' "$MOTHER_ROOT/attention.json")" = "tick-flagged" ]
}

@test "mother-runner --attention-tick is throttled by MOTHER_ATTENTION_INTERVAL" {
    make_job "tick-throttle" "failed" \
        '.needs_attention = {reason: "r", note: "n", since: "2026-09-20T00:00:00Z"}'

    # First tick: no marker yet, so it fires.
    MOTHER_ATTENTION_INTERVAL=3600 run mother-runner --attention-tick
    [ "$status" -eq 0 ]
    [ -f "$MOTHER_ROOT/attention.json" ]

    # Second tick inside the interval: does nothing.
    rm -f "$MOTHER_ROOT/attention.json"
    MOTHER_ATTENTION_INTERVAL=3600 run mother-runner --attention-tick
    [ "$status" -eq 0 ]
    [ ! -e "$MOTHER_ROOT/attention.json" ]

    # Interval 0: always fires.
    MOTHER_ATTENTION_INTERVAL=0 run mother-runner --attention-tick
    [ "$status" -eq 0 ]
    [ -f "$MOTHER_ROOT/attention.json" ]
}

@test "mother-runner --attention-tick never calls gh" {
    export MOTHER_ATTENTION_INTERVAL=0
    _pending "tick-gh-wait" \
        ".last_reason = \"pr_open\" | .pr_url = \"https://github.com/x/y/pull/1\"
         | .open_pr = {url: \"https://github.com/x/y/pull/1\", created_at: \"$(_iso_ago $(( $(_days 20) )))\", first_seen_open_at: null}"

    run mother-runner --attention-tick
    [ "$status" -eq 0 ]
    _gh_not_called
}
