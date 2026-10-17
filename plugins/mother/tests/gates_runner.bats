#!/usr/bin/env bats
# gates_runner.bats — the standalone quality-gate runner (HC-05).
#
# Covers:
#   lib/gates.sh   mother_gates_run <work_dir> <crew-json-file> <base_ref> <out_dir>
#                                   [--posture P] [--attempt N] [--allow-unpushed]
#   mother gates run | check       (CLI)
#   mother add                     (add-time .crew snapshot / validation)
#   mother doctor                  (crew config section)
#   templates/preamble.md          (tells workers to run `mother gates run`)
#
# Harness: a temp git repo with a BARE origin (main + a pushed feature branch),
# and a fake `rwx` in mock-bin that records one argv line per call to
# $RWX_LOG, with per-action knobs:
#   MOCK_RWX_EXIT_<ACTION>   exit code (default 0)       ACTION = RESET|EXEC|STOP
#   MOCK_RWX_SLEEP_<ACTION>  seconds to hang instead of exiting
# All watchdog cases use 1s limits so the whole file stays fast.

bats_require_minimum_version 1.5.0
load 'test_helper'

setup() {
    setup_mother_env
    unset MOTHER_GATES_ENABLED MOTHER_PHI_REPOS MOTHER_JOB_ID
    export MOTHER_POSTURE_ENABLED=0

    ORIGIN="$MOTHER_ROOT/origin.git"
    REPO="$MOTHER_ROOT/work/gaterepo"
    OUT="$MOTHER_ROOT/out"            # outside the work tree on purpose
    CREW="$MOTHER_ROOT/crew.json"
    RWX_LOG="$MOTHER_ROOT/rwx-calls.log"
    mkdir -p "$REPO" "$OUT"
    git init -q --bare "$ORIGIN"
    (
        cd "$REPO"
        git init -q
        git symbolic-ref HEAD refs/heads/main
        git config user.email "test@example.com"
        git config user.name "Test"
        echo "# repo" > README.md
        mkdir -p .rwx && printf 'base: ubuntu\n' > .rwx/sandbox.yml
        git add .
        git commit -q -m "init"
        git remote add origin "$ORIGIN"
        git push -q -u origin main
        git checkout -q -b feature/x
        mkdir -p app docs
        echo '<?php' > app/Foo.php
        echo 'docs' > docs/readme.md
        git add .
        git commit -q -m "feature work"
        git push -q -u origin feature/x
    ) >/dev/null 2>&1
    REPO_REAL="$(cd "$REPO" && pwd -P)"
    HEAD_SHA="$(git -C "$REPO" rev-parse HEAD)"
    BASE_SHA="$(git -C "$REPO" merge-base origin/main HEAD)"
}

teardown() {
    teardown_mother_env
}

# ---------------------------------------------------------------------------
# Harness helpers

_install_fake_rwx() {
    cat > "$_MOCK_BIN/rwx" <<'RWX'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$MOTHER_ROOT/rwx-calls.log"
action="${2:-}"
upper=$(printf '%s' "$action" | tr 'a-z' 'A-Z')
_pick() {
    local v="MOCK_RWX_${1}_${upper}"
    if [ -n "${!v:-}" ]; then printf '%s' "${!v}"; return; fi
    printf '%s' "$2"
}
sl=$(_pick SLEEP 0)
[ "$sl" != "0" ] && exec sleep "$sl"
exit "$(_pick EXIT 0)"
RWX
    chmod +x "$_MOCK_BIN/rwx"
}

# _check <name> <run> [extra-jq-object] — one resolved check with defaults.
_check() {
    jq -nc --arg name "$1" --arg run "$2" --argjson extra "${3:-{\}}" '
        {name: $name, run: $run, when: null, blocking: true, where: "any",
         timeout_s: 30, hint: null} + $extra'
}

# _write_crew <check-json>... — writes the resolved .crew shape to $CREW.
_write_crew() {
    local checks
    checks=$(printf '%s\n' "$@" | jq -sc '.')
    jq -n --argjson checks "$checks" '{
        version: 1, source_ref: "origin/main", source_sha: "abc", phi_sensitive: false,
        gates: {mode: "observe", max_attempts: 3, budget_minutes: 15, checks: $checks},
        lenses: null}' > "$CREW"
}

# _gates [flags...] — run mother_gates_run against $REPO; stdout lands in $output.
# Runs under `set -u` from a neutral cwd, like the real callers.
_gates() {
    run --separate-stderr env PATH="${GATES_TEST_PATH:-$PATH}" bash -c '
        set -u
        source "$1/gates.sh"
        shift
        mother_gates_run "$@"' _ "$_LIB_DIR" "$REPO" "$CREW" origin/main "$OUT" "$@"
}

# _res <name> <jq-field> — field of the named result in $output.
_res() {
    printf '%s' "$output" | jq -r --arg n "$1" '.results[] | select(.name == $n) | .'"$2"
}

_status() { printf '%s' "$output" | jq -r '.status'; }

# _rwx_actions — "<sandbox> <action>" per recorded rwx call, in order.
_rwx_actions() {
    [ -f "$RWX_LOG" ] || return 0
    cut -d' ' -f1-2 "$RWX_LOG"
}

# _publish_crew <yaml> — commit .mother/crew.yml on main, push, and fold it
# into the feature branch (so HEAD stays pushed and origin/main has the file).
_publish_crew() {
    (
        cd "$REPO"
        git checkout -q main
        mkdir -p .mother
        printf '%s\n' "$1" > .mother/crew.yml
        git add .mother/crew.yml
        git commit -q -m "crew config"
        git push -q origin main
        git checkout -q feature/x
        git merge -q --no-edit main
        git push -q origin feature/x
    ) >/dev/null 2>&1
    HEAD_SHA="$(git -C "$REPO" rev-parse HEAD)"
}

_one_check_yaml() { # name run [extra lines]
    printf 'version: 1\ngates:\n  checks:\n    - name: %s\n      run: "%s"\n%s\n' "$1" "$2" "${3:-}"
}

# ---------------------------------------------------------------------------
# mother_gates_run — outcomes

@test "a passing blocking check yields status passed with a passed result" {
    _write_crew "$(_check lint 'true')"
    _gates
    [ "$status" -eq 0 ]
    [ "$(_status)" = "passed" ]
    [ "$(_res lint result)" = "passed" ]
    [ "$(_res lint exit_code)" = "0" ]
    [ "$(_res lint blocking)" = "true" ]
    [ "$(printf '%s' "$output" | jq -c '.not_run')" = "[]" ]
    [ "$(printf '%s' "$output" | jq -r '.head_sha')" = "$HEAD_SHA" ]
}

@test "each result carries the documented fields" {
    _write_crew "$(_check lint 'true')"
    _gates
    printf '%s' "$output" | jq -e '
        .results[] | select(.name == "lint")
        | has("result") and has("blocking") and has("duration_s") and has("exit_code")
          and has("unavailable_reason") and has("skip_reason")
          and (.duration_s | type) == "number"
          and .unavailable_reason == null and .skip_reason == null' >/dev/null
}

@test "a failing blocking check yields status failed and records its exit code" {
    _write_crew "$(_check lint 'exit 3')" "$(_check other 'true')"
    _gates
    [ "$(_status)" = "failed" ]
    [ "$(_res lint result)" = "failed" ]
    [ "$(_res lint exit_code)" = "3" ]
    [ "$(_res other result)" = "passed" ]
}

@test "mother_gates_run returns 0 whenever it produced JSON, even for failed status" {
    _write_crew "$(_check lint 'exit 1')"
    _gates
    [ "$status" -eq 0 ]
    [ "$(_status)" = "failed" ]
}

@test "a failing advisory check is recorded as failed but status stays passed" {
    _write_crew "$(_check style 'exit 1' '{"blocking":false}')"
    _gates
    [ "$(_res style result)" = "failed" ]
    [ "$(_res style blocking)" = "false" ]
    [ "$(_status)" = "passed" ]
}

@test "a check whose path scope misses the diff is skipped as not_applicable" {
    _write_crew "$(_check jsonly 'exit 1' '{"when":{"paths":["**/*.js"]}}')" \
                "$(_check phponly 'true' '{"when":{"paths":["**/*.php"]}}')"
    _gates
    [ "$(_res jsonly result)" = "skipped" ]
    [ "$(_res jsonly skip_reason)" = "not_applicable" ]
    [ "$(_res phponly result)" = "passed" ]
    [ "$(_status)" = "passed" ]
}

@test "posture conservative skips advisory checks with reason posture but still runs blocking ones" {
    _write_crew "$(_check style 'exit 1' '{"blocking":false}')" "$(_check lint 'true')"
    _gates --posture conservative
    [ "$(_res style result)" = "skipped" ]
    [ "$(_res style skip_reason)" = "posture" ]
    [ "$(_res lint result)" = "passed" ]
    [ "$(_status)" = "passed" ]
    [ "$(printf '%s' "$output" | jq -r '.posture')" = "conservative" ]
}

@test "an any-check that exceeds timeout_s fails with exit code 124 and fails the run" {
    _write_crew "$(_check slow 'sleep 10' '{"timeout_s":1}')"
    local started=$SECONDS
    _gates
    [ $((SECONDS - started)) -lt 8 ]
    [ "$(_res slow result)" = "failed" ]
    [ "$(_res slow exit_code)" = "124" ]
    [ "$(_status)" = "failed" ]
}

# ---------------------------------------------------------------------------
# Gate environment

@test "any-checks run in the work dir with MOTHER_GATE_BASE set to the merge-base sha" {
    _write_crew \
        "$(_check cwd "test \"\$(pwd -P)\" = \"$REPO_REAL\"")" \
        "$(_check base "test \"\$MOTHER_GATE_BASE\" = \"$BASE_SHA\"")"
    _gates
    [ "$(_res cwd result)" = "passed" ]
    [ "$(_res base result)" = "passed" ]
}

@test "any-checks see MOTHER_GATE_CHANGED_FILES as newline-separated diff paths" {
    _write_crew "$(_check files "[ \"\$MOTHER_GATE_CHANGED_FILES\" = \"\$(printf 'app/Foo.php\\ndocs/readme.md')\" ]")"
    _gates
    [ "$(_res files result)" = "passed" ]
}

# ---------------------------------------------------------------------------
# Logs, excerpts, and no output in the JSON

@test "every executed check leaves a full .log and a bounded .excerpt in out_dir" {
    _write_crew "$(_check noisy 'i=1; while [ $i -le 200 ]; do echo "noise line $i xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"; i=$((i+1)); done; exit 2')" \
                "$(_check quiet 'echo hello-quiet')"
    _gates
    [ -f "$OUT/noisy.log" ]
    [ -f "$OUT/noisy.excerpt" ]
    [ -f "$OUT/quiet.log" ]
    [ -f "$OUT/quiet.excerpt" ]
    # full log has everything
    grep -q 'noise line 1 ' "$OUT/noisy.log"
    grep -q 'noise line 200 ' "$OUT/noisy.log"
    # excerpt is the tail, within 60 lines and 4096 bytes
    grep -q 'noise line 200 ' "$OUT/noisy.excerpt"
    [ "$(grep -c 'noise line 1 ' "$OUT/noisy.excerpt")" = "0" ]
    [ "$(wc -l < "$OUT/noisy.excerpt" | tr -d ' ')" -le 60 ]
    [ "$(wc -c < "$OUT/noisy.excerpt" | tr -d ' ')" -le 4096 ]
    grep -q 'hello-quiet' "$OUT/quiet.log"
}

@test "skipped checks do not run and so leave no log" {
    _write_crew "$(_check jsonly 'echo should-not-run' '{"when":{"paths":["**/*.js"]}}')"
    _gates
    [ ! -f "$OUT/jsonly.log" ]
}

@test "the JSON never contains the command's output text or any output-ish key" {
    _write_crew "$(_check chatty 'echo DISTINCTIVE-OUTPUT-MARKER-8731; echo DISTINCTIVE-OUTPUT-MARKER-8731 >&2; exit 1')"
    _gates
    [ "$(_res chatty result)" = "failed" ]
    [[ "$output" != *DISTINCTIVE-OUTPUT-MARKER-8731* ]]
    printf '%s' "$output" | jq -e '
        [.. | objects | keys[] | select(. == "output" or . == "excerpt" or . == "tail" or . == "log")]
        | length == 0' >/dev/null
    grep -q DISTINCTIVE-OUTPUT-MARKER-8731 "$OUT/chatty.log"
}

# ---------------------------------------------------------------------------
# Pre-checks

@test "clean_tree and pushed pre-checks pass on a clean, pushed checkout" {
    _write_crew "$(_check lint 'true')"
    _gates
    [ "$(_res clean_tree result)" = "passed" ]
    [ "$(_res clean_tree blocking)" = "true" ]
    [ "$(_res pushed result)" = "passed" ]
    [ "$(_res pushed blocking)" = "true" ]
}

@test "uncommitted changes fail the clean_tree pre-check and the run" {
    _write_crew "$(_check lint 'true')"
    echo "dirty" >> "$REPO/README.md"
    _gates
    [ "$(_res clean_tree result)" = "failed" ]
    [ "$(_status)" = "failed" ]
}

@test "an unpushed HEAD fails the pushed pre-check and the run" {
    _write_crew "$(_check lint 'true')"
    (cd "$REPO" && git commit -q --allow-empty -m "local only") >/dev/null 2>&1
    _gates
    [ "$(_res pushed result)" = "failed" ]
    [ "$(_status)" = "failed" ]
}

@test "--allow-unpushed skips the pushed pre-check so an unpushed HEAD can still pass" {
    _write_crew "$(_check lint 'true')"
    (cd "$REPO" && git commit -q --allow-empty -m "local only") >/dev/null 2>&1
    _gates --allow-unpushed
    [ "$(_res pushed result)" != "failed" ]
    [ "$(_res lint result)" = "passed" ]
    [ "$(_status)" = "passed" ]
}

# ---------------------------------------------------------------------------
# Sandbox checks (fake rwx)

@test "a sandbox check runs as reset, then exec -- bash -c <script>, then stop" {
    _install_fake_rwx
    _write_crew "$(_check unit 'echo sbx-ran-ok' '{"where":"sandbox"}')"
    _gates
    [ "$(_res unit result)" = "passed" ]
    [ "$(_res unit exit_code)" = "0" ]
    [ "$(_status)" = "passed" ]
    [ "$(_rwx_actions | tr '\n' ',')" = "sandbox reset,sandbox exec,sandbox stop," ]
    grep -q '^sandbox reset \.rwx/sandbox\.yml$' "$RWX_LOG"
    local exec_line
    exec_line=$(grep '^sandbox exec' "$RWX_LOG")
    [[ "$exec_line" == "sandbox exec -- bash -c "* ]]
}

@test "the sandbox script begins with the gate-env exports, then the run command" {
    _install_fake_rwx
    _write_crew "$(_check unit 'echo sbx-ran-ok' '{"where":"sandbox"}')"
    _gates
    local exec_line script
    exec_line=$(grep '^sandbox exec' "$RWX_LOG")
    script="${exec_line#sandbox exec -- bash -c }"
    [[ "$script" == "export MOTHER_GATE_BASE="* ]]
    [[ "$script" == *"export MOTHER_GATE_CHANGED_FILES="*"echo sbx-ran-ok" ]]
    [[ "$script" == *"$BASE_SHA"* ]]
    [[ "$script" == *"app/Foo.php"* ]]
    [[ "$script" == *"docs/readme.md"* ]]
}

@test "sandbox exec exiting nonzero is a failed check carrying that exit code" {
    _install_fake_rwx
    export MOCK_RWX_EXIT_EXEC=7
    _write_crew "$(_check unit 'false' '{"where":"sandbox"}')"
    _gates
    [ "$(_res unit result)" = "failed" ]
    [ "$(_res unit exit_code)" = "7" ]
    [ "$(_status)" = "failed" ]
}

@test "several sandbox checks share one reset and one stop" {
    _install_fake_rwx
    _write_crew "$(_check a 'echo a' '{"where":"sandbox"}')" \
                "$(_check b 'echo b' '{"where":"sandbox"}')"
    _gates
    [ "$(_rwx_actions | tr '\n' ',')" = "sandbox reset,sandbox exec,sandbox exec,sandbox stop," ]
}

@test "with no sandbox check that actually runs, rwx is never called" {
    _install_fake_rwx
    _write_crew "$(_check lint 'true')" \
                "$(_check skipped 'true' '{"where":"sandbox","when":{"paths":["**/*.js"]}}')"
    _gates
    [ ! -s "$RWX_LOG" ]
}

@test "a sandbox check is unavailable (head_not_pushed) when HEAD is not pushed, and rwx is not used" {
    _install_fake_rwx
    _write_crew "$(_check unit 'true' '{"where":"sandbox"}')"
    (cd "$REPO" && git commit -q --allow-empty -m "local only") >/dev/null 2>&1
    _gates
    [ "$(_res unit result)" = "unavailable" ]
    [ "$(_res unit unavailable_reason)" = "head_not_pushed" ]
    [ "$(_status)" = "failed" ]      # the pushed pre-check itself failed
    [ ! -s "$RWX_LOG" ]
}

@test "--allow-unpushed lets sandbox checks run on an unpushed HEAD" {
    _install_fake_rwx
    _write_crew "$(_check unit 'true' '{"where":"sandbox"}')"
    (cd "$REPO" && git commit -q --allow-empty -m "local only") >/dev/null 2>&1
    _gates --allow-unpushed
    [ "$(_res unit result)" = "passed" ]
    [ "$(_status)" = "passed" ]
}

@test "a failing rwx sandbox reset makes every sandbox check unavailable (rwx_error), never passed" {
    _install_fake_rwx
    export MOCK_RWX_EXIT_RESET=1
    _write_crew "$(_check a 'true' '{"where":"sandbox"}')" "$(_check b 'true' '{"where":"sandbox"}')" \
                "$(_check local 'true')"
    _gates
    [ "$(_res a result)" = "unavailable" ]
    [ "$(_res a unavailable_reason)" = "rwx_error" ]
    [ "$(_res b result)" = "unavailable" ]
    [ "$(_res b unavailable_reason)" = "rwx_error" ]
    [ "$(_res local result)" = "passed" ]
    [ "$(_status)" = "incomplete" ]
    [ "$(printf '%s' "$output" | jq -c '.not_run | sort')" = '["a","b"]' ]
    [ "$(_rwx_actions | grep -c 'sandbox exec')" = "0" ]
}

@test "a hanging rwx sandbox reset times out into unavailable rwx_timeout" {
    _install_fake_rwx
    export MOCK_RWX_SLEEP_RESET=10 MOTHER_RWX_RESET_TIMEOUT=1
    _write_crew "$(_check unit 'true' '{"where":"sandbox"}')"
    local started=$SECONDS
    _gates
    [ $((SECONDS - started)) -lt 8 ]
    [ "$(_res unit result)" = "unavailable" ]
    [ "$(_res unit unavailable_reason)" = "rwx_timeout" ]
    [ "$(_status)" = "incomplete" ]
    [ "$(_rwx_actions | grep -c 'sandbox exec')" = "0" ]
}

@test "a hanging rwx sandbox exec past timeout_s is unavailable rwx_timeout, not failed or passed" {
    _install_fake_rwx
    export MOCK_RWX_SLEEP_EXEC=10
    _write_crew "$(_check unit 'true' '{"where":"sandbox","timeout_s":1}')"
    local started=$SECONDS
    _gates
    [ $((SECONDS - started)) -lt 8 ]
    [ "$(_res unit result)" = "unavailable" ]
    [ "$(_res unit unavailable_reason)" = "rwx_timeout" ]
    [ "$(_status)" = "incomplete" ]
    [ "$(printf '%s' "$output" | jq -c '.not_run')" = '["unit"]' ]
}

@test "without an rwx CLI a sandbox check is unavailable (no_cli) and the run is incomplete, never passed" {
    # PATH containing the tools gates need, but no rwx (a real one may exist on the dev box).
    local farm="$MOTHER_ROOT/farm" t p
    mkdir -p "$farm"
    for t in bash sh env git jq python3 sed awk grep egrep tr mktemp date sort head tail cat wc rm \
             mkdir rmdir sleep cut dirname basename ls cp mv kill ps pgrep touch uniq tee xargs \
             find diff id whoami stat readlink realpath printf test expr timeout gtimeout perl uname; do
        p=$(command -v "$t" 2>/dev/null) || continue
        case "$p" in /*) ln -sf "$p" "$farm/$t" ;; esac
    done
    PATH="$farm" command -v rwx >/dev/null 2>&1 && skip "rwx still reachable on restricted PATH"
    _write_crew "$(_check unit 'true' '{"where":"sandbox"}')" "$(_check local 'true')"
    GATES_TEST_PATH="$farm" _gates
    [ "$(_res unit result)" = "unavailable" ]
    [ "$(_res unit unavailable_reason)" = "no_cli" ]
    [ "$(_res local result)" = "passed" ]
    [ "$(_status)" = "incomplete" ]
    [ "$(printf '%s' "$output" | jq -c '.not_run')" = '["unit"]' ]
}

@test "MOTHER_RWX_SANDBOX_ENABLED=0 makes sandbox checks unavailable (disabled) without calling rwx" {
    _install_fake_rwx
    export MOTHER_RWX_SANDBOX_ENABLED=0
    _write_crew "$(_check unit 'true' '{"where":"sandbox"}')"
    _gates
    [ "$(_res unit result)" = "unavailable" ]
    [ "$(_res unit unavailable_reason)" = "disabled" ]
    [ "$(_status)" = "incomplete" ]
    [ ! -s "$RWX_LOG" ]
}

@test "a sandbox check in a repo without .rwx/sandbox.yml is unavailable (no_config)" {
    _install_fake_rwx
    (cd "$REPO" && git rm -q .rwx/sandbox.yml && git commit -q -m "drop sandbox" && git push -q origin feature/x) >/dev/null 2>&1
    _write_crew "$(_check unit 'true' '{"where":"sandbox"}')"
    _gates
    [ "$(_res unit result)" = "unavailable" ]
    [ "$(_res unit unavailable_reason)" = "no_config" ]
    [ "$(_status)" = "incomplete" ]
    [ ! -s "$RWX_LOG" ]
}

@test "a blocking failure outranks an unavailable check: status failed, still listed in not_run" {
    _install_fake_rwx
    export MOCK_RWX_EXIT_RESET=1
    _write_crew "$(_check lint 'exit 1')" "$(_check unit 'true' '{"where":"sandbox"}')"
    _gates
    [ "$(_status)" = "failed" ]
    [ "$(printf '%s' "$output" | jq -c '.not_run')" = '["unit"]' ]
}

@test "an unavailable advisory sandbox check still makes the run incomplete rather than passed" {
    _install_fake_rwx
    export MOCK_RWX_EXIT_RESET=1
    _write_crew "$(_check unit 'true' '{"where":"sandbox","blocking":false}')"
    _gates
    [ "$(_res unit result)" = "unavailable" ]
    [ "$(_status)" = "incomplete" ]
}

# ---------------------------------------------------------------------------
# mother gates run (CLI)

@test "gates run: repo with no .mother/crew.yml at base reports no gates configured and exits 0" {
    run mother gates run --repo "$REPO" --base origin/main
    [ "$status" -eq 0 ]
    [[ "$output" == *"no gates configured"* ]]
}

@test "gates run --format json with no crew.yml reports status no_gates" {
    run --separate-stderr mother gates run --repo "$REPO" --base origin/main --format json
    [ "$status" -eq 0 ]
    [ "$(printf '%s' "$output" | jq -r '.status')" = "no_gates" ]
}

@test "gates run with MOTHER_GATES_ENABLED=0 is a no-op reporting disabled" {
    _publish_crew "$(_one_check_yaml lint 'exit 1')"
    MOTHER_GATES_ENABLED=0 run mother gates run --repo "$REPO" --base origin/main
    [ "$status" -eq 0 ]
    [[ "$output" == *"gates disabled (MOTHER_GATES_ENABLED=0)"* ]]

    MOTHER_GATES_ENABLED=0 run --separate-stderr mother gates run --repo "$REPO" --base origin/main --format json
    [ "$status" -eq 0 ]
    [ "$(printf '%s' "$output" | jq -r '.status')" = "disabled" ]
}

@test "gates run text: passing gate prints a tick line with its duration and exits 0" {
    _publish_crew "$(_one_check_yaml pint 'true')"
    run mother gates run --repo "$REPO" --base origin/main
    [ "$status" -eq 0 ]
    local re='✓ pint [0-9]+(\.[0-9]+)?s'
    [[ "$output" =~ $re ]]
}

@test "gates run text: failing gate shows a cross line with its log path, then excerpt and hint; exits 1" {
    _publish_crew "$(_one_check_yaml lint 'echo EXCERPT-MARKER-4412; exit 4' '      hint: "Fix the lint errors and commit."')"
    run mother gates run --repo "$REPO" --base origin/main
    [ "$status" -eq 1 ]
    local re='✗ lint [0-9]+(\.[0-9]+)?s — see [^[:space:]]*lint\.log'
    [[ "$output" =~ $re ]]
    [[ "$output" == *"EXCERPT-MARKER-4412"* ]]
    [[ "$output" == *"Fix the lint errors and commit."* ]]
    [ -f "$MOTHER_ROOT/gates/adhoc/lint.log" ]
    [ -f "$MOTHER_ROOT/gates/adhoc/lint.excerpt" ]
}

@test "gates run text: not-applicable gates print a dash line" {
    _publish_crew 'version: 1
gates:
  checks:
    - name: jsonly
      run: "true"
      when: { paths: ["**/*.js"] }'
    run mother gates run --repo "$REPO" --base origin/main
    [ "$status" -eq 0 ]
    [[ "$output" == *"– jsonly (not applicable)"* ]]
}

@test "gates run text: unavailable gates print a question-mark line and the exit code is 2" {
    _install_fake_rwx
    _publish_crew 'version: 1
gates:
  checks:
    - name: unit
      run: "true"
      where: sandbox'
    MOTHER_RWX_SANDBOX_ENABLED=0 run mother gates run --repo "$REPO" --base origin/main
    [ "$status" -eq 2 ]
    [[ "$output" == *"? unit (unavailable: disabled)"* ]]
}

@test "gates run works on an unpushed HEAD (on-demand runs always allow unpushed)" {
    _publish_crew "$(_one_check_yaml pint 'true')"
    (cd "$REPO" && git commit -q --allow-empty -m "local only") >/dev/null 2>&1
    run mother gates run --repo "$REPO" --base origin/main
    [ "$status" -eq 0 ]
    [[ "$output" == *"✓ pint"* ]]
}

@test "gates run --format json matches mother_gates_run for the same repo, base and config" {
    _publish_crew 'version: 1
gates:
  checks:
    - name: pass
      run: "true"
    - name: advisory
      run: "exit 1"
      blocking: false
    - name: jsonly
      run: "true"
      when: { paths: ["**/*.js"] }
    - name: bad
      run: "exit 5"'
    run --separate-stderr mother gates run --repo "$REPO" --base origin/main --format json
    local cli_json="$output"

    python3 "$_LIB_DIR/crew_config.py" resolve "$REPO" origin/main gaterepo > "$CREW"
    _gates --allow-unpushed
    local lib_json="$output"

    [ "$(printf '%s' "$cli_json" | jq -r '.status')" = "failed" ]
    [ "$(printf '%s' "$cli_json" | jq -r '.status')" = "$(printf '%s' "$lib_json" | jq -r '.status')" ]
    [ "$(printf '%s' "$cli_json" | jq -cS '[.results[] | del(.duration_s)]')" \
        = "$(printf '%s' "$lib_json" | jq -cS '[.results[] | del(.duration_s)]')" ]
}

# --- inside a job -----------------------------------------------------------

_make_gate_job() { # <id> [extra jq]
    make_job "$1" running "
        .repo_path = \"$REPO\" | .isolation = \"main-dir\" | .branch = \"feature/x\"
        | .base_ref = \"origin/main\" | ${2:-.}"
}

@test "gates run --job reads the repo and the job's .crew snapshot, and writes logs under gates/<id>" {
    _publish_crew "$(_one_check_yaml from-base 'true')"
    _write_crew "$(_check from-job 'echo job-ran')"
    _make_gate_job gj1 ".crew = $(jq -c . "$CREW")"
    run mother gates run --job gj1
    [ "$status" -eq 0 ]
    [[ "$output" == *"✓ from-job"* ]]
    [[ "$output" != *"from-base"* ]]
    [ -f "$MOTHER_ROOT/gates/gj1/from-job.log" ]
    grep -q job-ran "$MOTHER_ROOT/gates/gj1/from-job.log"
}

@test "gates run --job without a .crew snapshot resolves config from the job's base ref" {
    _publish_crew "$(_one_check_yaml from-base 'true')"
    _make_gate_job gj2
    run mother gates run --job gj2
    [ "$status" -eq 0 ]
    [[ "$output" == *"✓ from-base"* ]]
}

@test "gates run picks up the job from MOTHER_JOB_ID" {
    _write_crew "$(_check from-job 'true')"
    _make_gate_job gj3 ".crew = $(jq -c . "$CREW")"
    MOTHER_JOB_ID=gj3 run mother gates run
    [ "$status" -eq 0 ]
    [[ "$output" == *"✓ from-job"* ]]
    [ -f "$MOTHER_ROOT/gates/gj3/from-job.log" ]
}

@test "gates run --job with neither .crew nor a crew.yml at base reports no gates configured" {
    _make_gate_job gj4
    run mother gates run --job gj4
    [ "$status" -eq 0 ]
    [[ "$output" == *"no gates configured"* ]]
}

# ---------------------------------------------------------------------------
# mother gates check

@test "gates check passes a valid config" {
    _publish_crew "$(_one_check_yaml pint 'true')"
    run mother gates check --repo "$REPO" --ref origin/main
    [ "$status" -eq 0 ]
}

@test "gates check reports a missing crew.yml and exits 0" {
    run mother gates check --repo "$REPO" --ref origin/main
    [ "$status" -eq 0 ]
    [[ "$output" == *"no .mother/crew.yml"* ]]
}

@test "gates check prints each error as '<repo>: .mother/crew.yml: <path>: <message>' and exits 1" {
    _publish_crew 'version: 1
gates:
  checks:
    - name: pint
      run: "true"
      where: cloud
    - name: phpstan
      run: "true"
      timeout_s: 0'
    run mother gates check --repo "$REPO" --ref origin/main
    [ "$status" -eq 1 ]
    local line_where line_timeout
    line_where=$(printf '%s\n' "$output" | grep 'gates\.checks\[0\]\.where')
    line_timeout=$(printf '%s\n' "$output" | grep 'gates\.checks\[1\]\.timeout_s')
    local re_w='^gaterepo: \.mother/crew\.yml: gates\.checks\[0\]\.where: .+'
    local re_t='^gaterepo: \.mother/crew\.yml: gates\.checks\[1\]\.timeout_s: .+'
    [[ "$line_where" =~ $re_w ]]
    [[ "$line_timeout" =~ $re_t ]]
}

@test "gates check defaults --repo to the current git toplevel" {
    _publish_crew 'version: 1
gates:
  checks:
    - name: pint
      run: "true"
      where: cloud'
    cd "$REPO/app"
    run mother gates check --ref origin/main
    [ "$status" -eq 1 ]
    [[ "$output" == *"gaterepo: .mother/crew.yml: gates.checks[0].where"* ]]
}

# ---------------------------------------------------------------------------
# mother add — snapshot and validation

_add_plan() { # <extra yaml lines appended to the suggested_config block>
    make_plan_with_config "$MOTHER_ROOT/plan.md" "suggested_config:
  cody:
    model: sonnet
    effort: medium
    rationale: \"x\"
  redd:
    model: sonnet
    effort: medium
    rationale: \"x\"
  marty:
    model: sonnet
    effort: medium
    rationale: \"x\"
  perri:
    model: sonnet
    effort: medium
    rationale: \"x\"
${1:-}"
}

_add() {
    run mother add --plan-file "$MOTHER_ROOT/plan.md" --repo gaterepo \
        --repo-path "$REPO" --branch feature/test --base origin/main
}

@test "mother add rejects an invalid .mother/crew.yml on the base ref, naming repo and entry" {
    _publish_crew 'version: 1
gates:
  checks:
    - name: pint
      run: "true"
      where: cloud'
    _add_plan
    _add
    [ "$status" -eq 1 ]
    [[ "$output" == *"gaterepo: .mother/crew.yml: gates.checks[0].where"* ]]
    [ -z "$(ls "$JOBS_DIR")" ]
}

@test "mother add snapshots a valid config into .crew with the base ref and its sha" {
    _publish_crew 'version: 1
gates:
  mode: enforce
  checks:
    - name: pint
      run: "vendor/bin/pint --test"
      when: { paths: ["**/*.php"] }'
    _add_plan
    _add
    [ "$status" -eq 0 ]
    local id="$output" sha
    sha=$(git -C "$REPO" rev-parse origin/main)
    jq -e --arg sha "$sha" '
        .crew.version == 1
        and .crew.source_ref == "origin/main"
        and .crew.source_sha == $sha
        and .crew.gates.mode == "enforce"
        and .crew.gates.max_attempts == 3
        and .crew.gates.checks[0].name == "pint"
        and .crew.gates.checks[0].when == {"paths": ["**/*.php"]}
        and .crew.gates.checks[0].blocking == true
        and .crew.phi_sensitive == false' "$JOBS_DIR/$id.json" >/dev/null
}

@test "mother add applies a plan-level gates.max_attempts override to .crew" {
    _publish_crew "$(_one_check_yaml pint 'true')"
    _add_plan "gates:
  max_attempts: 2"
    _add
    [ "$status" -eq 0 ]
    assert_job_field "$output" '.crew.gates.max_attempts' 2
}

@test "mother add with no crew.yml at base leaves the job without a crew key" {
    _add_plan
    _add
    [ "$status" -eq 0 ]
    [ "$(jq 'has("crew")' "$JOBS_DIR/$output.json")" = "false" ]
}

@test "mother add with no crew.yml ignores a plan-level gates block and adds no crew key" {
    _add_plan "gates:
  max_attempts: 2"
    _add
    [ "$status" -eq 0 ]
    [ "$(jq 'has("crew")' "$JOBS_DIR/$output.json")" = "false" ]
}

@test "mother add with MOTHER_GATES_ENABLED=0 ignores even an invalid crew.yml and adds no crew key" {
    _publish_crew 'version: 1
gates:
  checks:
    - name: pint
      run: "true"
      where: cloud'
    _add_plan
    export MOTHER_GATES_ENABLED=0
    _add
    [ "$status" -eq 0 ]
    [ "$(jq 'has("crew")' "$JOBS_DIR/$output.json")" = "false" ]
}

# ---------------------------------------------------------------------------
# mother doctor — crew config section

@test "mother doctor is a real subcommand" {
    run mother doctor
    [[ "$output" != *"unknown subcommand"* ]]
}

@test "mother doctor reports an invalid crew.yml for a job's repo and exits non-zero" {
    _publish_crew 'version: 1
gates:
  checks:
    - name: pint
      run: "true"
      where: cloud'
    make_job dj1 queued ".repo = \"gaterepo\" | .repo_path = \"$REPO\" | .base_ref = \"origin/main\""
    run mother doctor
    [ "$status" -ne 0 ]
    [[ "$output" == *"crew config:"* ]]
    [[ "$output" == *"gaterepo: .mother/crew.yml: gates.checks[0].where"* ]]
}

@test "mother doctor's crew config section is clean for a valid config" {
    _publish_crew "$(_one_check_yaml pint 'true')"
    make_job dj2 queued ".repo = \"gaterepo\" | .repo_path = \"$REPO\" | .base_ref = \"origin/main\""
    run mother doctor
    [[ "$output" == *"crew config:"* ]]
    [[ "$output" != *".mother/crew.yml: gates."* ]]
}

# ---------------------------------------------------------------------------
# Worker preamble

@test "the worker preamble tells workers to run 'mother gates run'" {
    grep -q 'mother gates run' "$_PLUGIN_DIR/templates/preamble.md"
}
