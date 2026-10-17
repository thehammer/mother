#!/usr/bin/env bats
# crew_config.bats — `.mother/crew.yml` resolution, validation and path-scope
# matching (lib/crew_config.py).
#
# Contract under test (HC-05):
#   crew_config.py resolve <repo_path> <ref> <repo_name>
#     - reads .mother/crew.yml via `git show <ref>:.mother/crew.yml` — never the
#       working tree.
#     - no file at ref   -> exit 0, stdout `null`
#     - valid            -> exit 0, resolved JSON:
#         {version, source_ref, source_sha, phi_sensitive,
#          gates:{mode, max_attempts, budget_minutes,
#                 checks:[{name, run, when, blocking, where, timeout_s, hint}]},
#          lenses: <raw section or null>}
#     - invalid          -> exit 1, stdout {"errors":[{"path","message"}...]}
#       reporting ALL errors.
#     - MOTHER_PHI_REPOS (space separated; default "admin-portal
#       referral-monitor") forces phi_sensitive=true for listed repo names.
#   crew_config.py applicable <resolved.json> <files...>
#     - prints a JSON array of names of the checks that apply to the changed files.

bats_require_minimum_version 1.5.0
load 'test_helper'

setup() {
    setup_mother_env
    unset MOTHER_PHI_REPOS

    REPO="$MOTHER_ROOT/work/somerepo"
    mkdir -p "$REPO"
    (
        cd "$REPO"
        git init -q
        git symbolic-ref HEAD refs/heads/main
        git config user.email "test@example.com"
        git config user.name "Test"
        echo "# repo" > README.md
        git add .
        git commit -q -m "init"
    ) >/dev/null 2>&1
}

teardown() {
    teardown_mother_env
}

# ---------------------------------------------------------------------------
# Helpers

# _commit_crew <yaml-content> — write .mother/crew.yml and commit it on main.
_commit_crew() {
    mkdir -p "$REPO/.mother"
    printf '%s\n' "$1" > "$REPO/.mother/crew.yml"
    (cd "$REPO" && git add .mother/crew.yml && git commit -q -m "crew config") >/dev/null 2>&1
}

# _commit_sandbox_config — commit .rwx/sandbox.yml on main.
_commit_sandbox_config() {
    mkdir -p "$REPO/.rwx"
    printf 'base: ubuntu\n' > "$REPO/.rwx/sandbox.yml"
    (cd "$REPO" && git add .rwx/sandbox.yml && git commit -q -m "sandbox config") >/dev/null 2>&1
}

# _resolve [ref] [repo_name]
_resolve() {
    run --separate-stderr python3 "$_LIB_DIR/crew_config.py" resolve \
        "$REPO" "${1:-main}" "${2:-somerepo}"
}

# _assert_error_at <path> — exit 1 and an error entry for that exact path.
_assert_error_at() {
    [ "$status" -eq 1 ] || { echo "expected exit 1, got $status: $output" >&2; return 1; }
    printf '%s' "$output" | jq -e --arg p "$1" \
        '.errors | map(select(.path == $p and ((.message // "") | length > 0))) | length >= 1' >/dev/null \
        || { echo "no error at path '$1' in: $output" >&2; return 1; }
}

# _yaml_one_check <extra check lines (indented 6 spaces)> — single-check config.
_yaml_one_check() {
    printf 'version: 1\ngates:\n  checks:\n    - name: pint\n      run: "vendor/bin/pint --test"\n%s\n' "${1:-}"
}

# ---------------------------------------------------------------------------
# Resolution: valid files

@test "resolve returns null with exit 0 when the ref has no .mother/crew.yml" {
    _resolve main
    [ "$status" -eq 0 ]
    [ "$output" = "null" ]
}

@test "resolve returns the full resolved shape for a valid file" {
    _commit_sandbox_config
    _commit_crew 'version: 1
phi_sensitive: false
gates:
  mode: enforce
  max_attempts: 4
  budget_minutes: 20
  checks:
    - name: pint
      run: "vendor/bin/pint --test"
      when: { paths: ["**/*.php"] }
      blocking: false
      where: sandbox
      timeout_s: 600
      hint: "Run pint."'
    _resolve main
    [ "$status" -eq 0 ]
    printf '%s' "$output" | jq -e '
        .version == 1
        and .phi_sensitive == false
        and .gates.mode == "enforce"
        and .gates.max_attempts == 4
        and .gates.budget_minutes == 20
        and (.gates.checks | length) == 1
        and .gates.checks[0].name == "pint"
        and .gates.checks[0].run == "vendor/bin/pint --test"
        and .gates.checks[0].when == {"paths": ["**/*.php"]}
        and .gates.checks[0].blocking == false
        and .gates.checks[0].where == "sandbox"
        and .gates.checks[0].timeout_s == 600
        and .gates.checks[0].hint == "Run pint."
        and .lenses == null' >/dev/null
}

@test "resolve fills defaults: observe mode, 3 attempts, 15 minutes, blocking, any, 900s, no hint, always-on" {
    _commit_crew "$(_yaml_one_check)"
    _resolve main
    [ "$status" -eq 0 ]
    printf '%s' "$output" | jq -e '
        .gates.mode == "observe"
        and .gates.max_attempts == 3
        and .gates.budget_minutes == 15
        and .gates.checks[0].blocking == true
        and .gates.checks[0].where == "any"
        and .gates.checks[0].timeout_s == 900
        and .gates.checks[0].hint == null
        and .gates.checks[0].when == null' >/dev/null
}

@test "resolve records the ref it read and the commit sha of that ref" {
    _commit_crew "$(_yaml_one_check)"
    local sha
    sha=$(git -C "$REPO" rev-parse main)
    _resolve main
    [ "$status" -eq 0 ]
    [ "$(printf '%s' "$output" | jq -r '.source_ref')" = "main" ]
    [ "$(printf '%s' "$output" | jq -r '.source_sha')" = "$sha" ]
}

@test "resolve reads the committed file at the ref, not the working tree" {
    _commit_crew "$(_yaml_one_check)"
    # Worker-style tampering: rewrite the worktree copy (uncommitted) to drop
    # the check and break the schema. Neither change may be visible.
    printf 'version: 1\ngates:\n  checks:\n    - name: BAD NAME\n      run: "true"\n' > "$REPO/.mother/crew.yml"
    _resolve main
    [ "$status" -eq 0 ]
    [ "$(printf '%s' "$output" | jq -r '.gates.checks[0].name')" = "pint" ]
}

@test "resolve of an older ref ignores later commits to the file" {
    _commit_crew "$(_yaml_one_check)"
    local old
    old=$(git -C "$REPO" rev-parse HEAD)
    _commit_crew 'version: 1
gates:
  checks:
    - name: newer
      run: "true"'
    _resolve "$old"
    [ "$status" -eq 0 ]
    [ "$(printf '%s' "$output" | jq -r '.gates.checks[0].name')" = "pint" ]
    [ "$(printf '%s' "$output" | jq -r '.source_sha')" = "$old" ]
}

@test "resolve does not see a worktree-only file when the ref has none" {
    mkdir -p "$REPO/.mother"
    printf 'version: 1\ngates:\n  checks: []\n' > "$REPO/.mother/crew.yml"
    _resolve main
    [ "$status" -eq 0 ]
    [ "$output" = "null" ]
}

@test "lenses section is accepted and returned untouched" {
    _commit_crew 'version: 1
gates:
  checks:
    - name: pint
      run: "true"
lenses:
  security:
    anything: [1, 2, {deep: true}]
  whatever: "not validated"'
    _resolve main
    [ "$status" -eq 0 ]
    printf '%s' "$output" | jq -e '
        .lenses == {"security": {"anything": [1, 2, {"deep": true}]}, "whatever": "not validated"}' >/dev/null
}

# ---------------------------------------------------------------------------
# phi_sensitive

@test "phi_sensitive follows the file for repos not in MOTHER_PHI_REPOS" {
    _commit_crew 'version: 1
phi_sensitive: true
gates:
  checks:
    - name: pint
      run: "true"'
    _resolve main somerepo
    [ "$status" -eq 0 ]
    [ "$(printf '%s' "$output" | jq -r '.phi_sensitive')" = "true" ]
}

@test "phi_sensitive is false when the file is silent and the repo is not listed" {
    _commit_crew "$(_yaml_one_check)"
    _resolve main somerepo
    [ "$status" -eq 0 ]
    [ "$(printf '%s' "$output" | jq -r '.phi_sensitive')" = "false" ]
}

@test "default MOTHER_PHI_REPOS forces phi_sensitive for admin-portal and referral-monitor" {
    _commit_crew 'version: 1
phi_sensitive: false
gates:
  checks:
    - name: pint
      run: "true"'
    _resolve main admin-portal
    [ "$status" -eq 0 ]
    [ "$(printf '%s' "$output" | jq -r '.phi_sensitive')" = "true" ]

    _resolve main referral-monitor
    [ "$status" -eq 0 ]
    [ "$(printf '%s' "$output" | jq -r '.phi_sensitive')" = "true" ]
}

@test "MOTHER_PHI_REPOS overrides the default list (space separated)" {
    _commit_crew "$(_yaml_one_check)"
    export MOTHER_PHI_REPOS="somerepo other-repo"
    _resolve main somerepo
    [ "$status" -eq 0 ]
    [ "$(printf '%s' "$output" | jq -r '.phi_sensitive')" = "true" ]

    _resolve main other-repo
    [ "$(printf '%s' "$output" | jq -r '.phi_sensitive')" = "true" ]

    # The default members are no longer forced once the list is overridden.
    _resolve main admin-portal
    [ "$(printf '%s' "$output" | jq -r '.phi_sensitive')" = "false" ]
}

# ---------------------------------------------------------------------------
# Validation — one test per rule

@test "invalid: duplicate check names are reported at the later entry" {
    _commit_crew 'version: 1
gates:
  checks:
    - name: pint
      run: "true"
    - name: pint
      run: "false"'
    _resolve main
    _assert_error_at "gates.checks[1].name"
}

@test "invalid: where must be any or sandbox" {
    _commit_crew "$(_yaml_one_check '      where: cloud')"
    _resolve main
    _assert_error_at "gates.checks[0].where"
}

@test "invalid: where sandbox requires .rwx/sandbox.yml at the ref" {
    _commit_crew "$(_yaml_one_check '      where: sandbox')"
    _resolve main
    _assert_error_at "gates.checks[0].where"
}

@test "invalid: where sandbox is not satisfied by an uncommitted .rwx/sandbox.yml" {
    _commit_crew "$(_yaml_one_check '      where: sandbox')"
    mkdir -p "$REPO/.rwx"
    printf 'base: ubuntu\n' > "$REPO/.rwx/sandbox.yml"
    _resolve main
    _assert_error_at "gates.checks[0].where"
}

@test "valid: where sandbox is accepted when .rwx/sandbox.yml exists at the ref" {
    _commit_sandbox_config
    _commit_crew "$(_yaml_one_check '      where: sandbox')"
    _resolve main
    [ "$status" -eq 0 ]
    [ "$(printf '%s' "$output" | jq -r '.gates.checks[0].where')" = "sandbox" ]
}

@test "invalid: timeout_s 0 is rejected" {
    _commit_crew "$(_yaml_one_check '      timeout_s: 0')"
    _resolve main
    _assert_error_at "gates.checks[0].timeout_s"
}

@test "invalid: timeout_s above 3600 is rejected, 3600 and 1 are accepted" {
    _commit_crew "$(_yaml_one_check '      timeout_s: 3601')"
    _resolve main
    _assert_error_at "gates.checks[0].timeout_s"

    _commit_crew "$(_yaml_one_check '      timeout_s: 3600')"
    _resolve main
    [ "$status" -eq 0 ]

    _commit_crew "$(_yaml_one_check '      timeout_s: 1')"
    _resolve main
    [ "$status" -eq 0 ]
}

@test "invalid: an unknown key under a check is rejected and named" {
    _commit_crew "$(_yaml_one_check '      bogus_key: 1')"
    _resolve main
    [ "$status" -eq 1 ]
    printf '%s' "$output" | jq -e '
        .errors | map(select((.path | startswith("gates.checks[0]"))
                             and ((.path + " " + .message) | contains("bogus_key")))) | length >= 1' >/dev/null
}

@test "invalid: max_attempts 9 is rejected; 0 and 6 too; 1 and 5 accepted" {
    local n
    for n in 9 0 6; do
        _commit_crew "version: 1
gates:
  max_attempts: $n
  checks:
    - name: pint
      run: \"true\""
        _resolve main
        _assert_error_at "gates.max_attempts"
    done
    for n in 1 5; do
        _commit_crew "version: 1
gates:
  max_attempts: $n
  checks:
    - name: pint
      run: \"true\""
        _resolve main
        [ "$status" -eq 0 ]
        [ "$(printf '%s' "$output" | jq -r '.gates.max_attempts')" = "$n" ]
    done
}

@test "invalid: names must match [a-z0-9][a-z0-9_-]{0,31}" {
    local bad
    for bad in "Pint" "-pint" "_pint" "has space" "$(head -c 33 /dev/zero | tr '\0' a)"; do
        _commit_crew "version: 1
gates:
  checks:
    - name: \"$bad\"
      run: \"true\""
        _resolve main
        _assert_error_at "gates.checks[0].name"
    done
}

@test "valid: names at the pattern boundary are accepted" {
    local good
    for good in "a" "0" "a_b-c9" "$(head -c 32 /dev/zero | tr '\0' a)"; do
        _commit_crew "version: 1
gates:
  checks:
    - name: \"$good\"
      run: \"true\""
        _resolve main
        [ "$status" -eq 0 ]
        [ "$(printf '%s' "$output" | jq -r '.gates.checks[0].name')" = "$good" ]
    done
}

@test "invalid: hint longer than 500 characters is rejected; exactly 500 is accepted" {
    local h501 h500
    h501=$(head -c 501 /dev/zero | tr '\0' x)
    h500=$(head -c 500 /dev/zero | tr '\0' x)

    _commit_crew "$(_yaml_one_check "      hint: \"$h501\"")"
    _resolve main
    _assert_error_at "gates.checks[0].hint"

    _commit_crew "$(_yaml_one_check "      hint: \"$h500\"")"
    _resolve main
    [ "$status" -eq 0 ]
}

@test "invalid: mode must be observe or enforce" {
    _commit_crew 'version: 1
gates:
  mode: yolo
  checks:
    - name: pint
      run: "true"'
    _resolve main
    _assert_error_at "gates.mode"
}

@test "validation reports every error in one pass, not just the first" {
    _commit_crew 'version: 1
gates:
  mode: yolo
  max_attempts: 9
  checks:
    - name: pint
      run: "true"
      where: cloud
    - name: pint
      run: "true"
      timeout_s: 0'
    _resolve main
    _assert_error_at "gates.mode"
    _assert_error_at "gates.max_attempts"
    _assert_error_at "gates.checks[0].where"
    _assert_error_at "gates.checks[1].name"
    _assert_error_at "gates.checks[1].timeout_s"
}

# ---------------------------------------------------------------------------
# applicable — path-scope matching

# _write_resolved <when-json> — resolved file with one check "c" and that scope.
_write_resolved() {
    RESOLVED="$MOTHER_ROOT/resolved.json"
    jq -n --argjson when "$1" '{
        version: 1, source_ref: "main", source_sha: "abc", phi_sensitive: false,
        gates: {mode: "observe", max_attempts: 3, budget_minutes: 15,
                checks: [{name: "c", run: "true", when: $when, blocking: true,
                          where: "any", timeout_s: 900, hint: null}]},
        lenses: null}' > "$RESOLVED"
}

# _assert_applies <when-json> <file>...   /   _assert_not_applies ...
_applicable() {
    local when="$1"; shift
    _write_resolved "$when"
    run --separate-stderr python3 "$_LIB_DIR/crew_config.py" applicable "$RESOLVED" "$@"
    [ "$status" -eq 0 ] || { echo "applicable exited $status: $output / $stderr" >&2; return 1; }
}
_assert_applies() {
    _applicable "$@" || return 1
    [ "$(printf '%s' "$output" | jq -c .)" = '["c"]' ] \
        || { echo "expected [\"c\"] for when=$1 files=${*:2}, got: $output" >&2; return 1; }
}
_assert_not_applies() {
    _applicable "$@" || return 1
    [ "$(printf '%s' "$output" | jq -c .)" = '[]' ] \
        || { echo "expected [] for when=$1 files=${*:2}, got: $output" >&2; return 1; }
}

@test "a check with no 'when' applies to any change, even an empty one" {
    _assert_applies 'null' "app/Foo.js"
    _assert_applies 'null'
}

@test "**/*.php matches nested, deeply nested and top-level php files" {
    _assert_applies '{"paths":["**/*.php"]}' "app/Foo.php"
    _assert_applies '{"paths":["**/*.php"]}' "a/b/c.php"
    _assert_applies '{"paths":["**/*.php"]}' "Foo.php"
}

@test "**/*.php does not match other extensions" {
    _assert_not_applies '{"paths":["**/*.php"]}' "app/Foo.js"
    _assert_not_applies '{"paths":["**/*.php"]}' "app/Foo.php.bak"
}

@test "a single * does not cross directory separators" {
    _assert_applies '{"paths":["app/*.php"]}' "app/Foo.php"
    _assert_not_applies '{"paths":["app/*.php"]}' "app/Sub/Foo.php"
}

@test "app/**/*.php matches files at any depth under app" {
    _assert_applies '{"paths":["app/**/*.php"]}' "app/Http/Controllers/FooController.php"
    _assert_applies '{"paths":["app/**/*.php"]}' "app/Foo.php"
    _assert_not_applies '{"paths":["app/**/*.php"]}' "tests/Foo.php"
    _assert_not_applies '{"paths":["app/**/*.php"]}' "app/Http/Foo.js"
}

@test "database/migrations/** matches everything beneath it and nothing outside" {
    _assert_applies '{"paths":["database/migrations/**"]}' "database/migrations/2026_01_01_000000_x.php"
    _assert_applies '{"paths":["database/migrations/**"]}' "database/migrations/sub/dir/x.sql"
    _assert_not_applies '{"paths":["database/migrations/**"]}' "database/seeders/X.php"
}

@test "an exact path matches only that path" {
    _assert_applies '{"paths":["composer.lock"]}' "composer.lock"
    _assert_not_applies '{"paths":["composer.lock"]}' "sub/composer.lock"
    _assert_not_applies '{"paths":["composer.lock"]}' "composer.json"
}

@test "a check applies when ANY of its patterns matches ANY changed file" {
    _assert_applies '{"paths":["docs/**","**/*.php"]}' "README.md" "app/Foo.php"
    _assert_applies '{"paths":["docs/**","**/*.php"]}' "docs/a/b.md"
    _assert_not_applies '{"paths":["docs/**","**/*.php"]}' "README.md" "app/Foo.js"
}

@test "a path-scoped check does not apply to an empty change set" {
    _assert_not_applies '{"paths":["**/*.php"]}'
}

@test "applicable returns only the names of applicable checks, in declaration order" {
    RESOLVED="$MOTHER_ROOT/resolved.json"
    jq -n '{
        version: 1, source_ref: "main", source_sha: "abc", phi_sensitive: false,
        gates: {mode: "observe", max_attempts: 3, budget_minutes: 15, checks: [
            {name: "always",  run: "true", when: null,                       blocking: true, where: "any", timeout_s: 900, hint: null},
            {name: "php",     run: "true", when: {paths: ["**/*.php"]},      blocking: true, where: "any", timeout_s: 900, hint: null},
            {name: "js",      run: "true", when: {paths: ["**/*.js"]},       blocking: true, where: "any", timeout_s: 900, hint: null},
            {name: "migrate", run: "true", when: {paths: ["database/**"]},   blocking: true, where: "any", timeout_s: 900, hint: null}]},
        lenses: null}' > "$RESOLVED"
    run --separate-stderr python3 "$_LIB_DIR/crew_config.py" applicable "$RESOLVED" \
        "app/Foo.php" "database/migrations/x.php"
    [ "$status" -eq 0 ]
    [ "$(printf '%s' "$output" | jq -c .)" = '["always","php","migrate"]' ]
}
