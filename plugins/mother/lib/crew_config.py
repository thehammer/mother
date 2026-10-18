#!/usr/bin/env python3
"""crew_config.py — load, validate and resolve a repo's `.mother/crew.yml`.

The file is always read from a git ref (`git show <ref>:.mother/crew.yml`),
never from the working tree, so a worker cannot weaken its own gates.

CLI:
  crew_config.py resolve <repo_path> <ref> <repo_name>
      exit 0, stdout `null`            no .mother/crew.yml at <ref>
      exit 0, stdout resolved JSON     valid
      exit 1, stdout {"errors": [...]} invalid; each error is {path, message}
      exit 2, stderr message           <ref> can't be resolved / git failed
  crew_config.py applicable <resolved.json> <files...>
      prints a JSON array of the names of checks that apply to those files.
      A lone `-` reads the newline-separated file list from stdin instead.

  crew_config.py select <resolved.json> <posture> <plan_lenses_json> <files...>
      prints a JSON array [{reviewer, lens, run, skip_reason}] — which reviewer
      lenses run for those changed files. A lone `-` reads files from stdin.

The `gates` and `lenses` sections are validated here.
"""
import json
import os
import re
import subprocess
import sys

try:
    import yaml
except ImportError:  # pragma: no cover - PyYAML is a Mother requirement
    print("crew_config.py: PyYAML is required", file=sys.stderr)
    sys.exit(2)

CONFIG_PATH = ".mother/crew.yml"
SANDBOX_PATH = ".rwx/sandbox.yml"
NAME_RE = re.compile(r"^[a-z0-9][a-z0-9_-]{0,31}$")
CHECK_KEYS = {"name", "run", "when", "blocking", "where", "timeout_s", "hint"}
DEFAULT_PHI_REPOS = "admin-portal referral-monitor"

DEFAULT_MODE = "observe"
DEFAULT_MAX_ATTEMPTS = 3
DEFAULT_BUDGET_MINUTES = 15
DEFAULT_TIMEOUT_S = 900

LENSES = ("correctness", "phi-security", "tests", "ops-infra")
PHI_LENS = "phi-security"
LENS_KEYS = {"mode", "default", "mandatory", "scopes", "budget_usd", "cycle_cap"}
DEFAULT_LENS_BUDGET_USD = 3
MAX_LENS_BUDGET_USD = 20
DEFAULT_LENS_CYCLE_CAP = 2


def _is_int(value):
    return isinstance(value, int) and not isinstance(value, bool)


def _validate_lens_list(value, path, err):
    if not isinstance(value, list):
        err(path, "must be a list of lens names (%s)" % ", ".join(LENSES))
        return
    for i, name in enumerate(value):
        if name not in LENSES:
            err("%s[%d]" % (path, i),
                "unknown lens %r (known: %s)" % (name, ", ".join(LENSES)))


def _validate_lenses(lenses, err):
    if lenses is None:
        return
    if not isinstance(lenses, dict):
        err("lenses", "must be a mapping")
        return
    for key in lenses:
        if key not in LENS_KEYS:
            err("lenses.%s" % key, "unknown key")
    if "mode" in lenses and lenses["mode"] not in ("observe", "enforce"):
        err("lenses.mode", "must be 'observe' or 'enforce'")
    for key in ("default", "mandatory"):
        if key in lenses:
            _validate_lens_list(lenses[key], "lenses." + key, err)
    if "scopes" in lenses:
        scopes = lenses["scopes"]
        if not isinstance(scopes, dict):
            err("lenses.scopes", "must be a mapping of lens name to a list of globs")
        else:
            for lens, paths in scopes.items():
                path = "lenses.scopes.%s" % lens
                if lens not in LENSES:
                    err(path, "unknown lens (known: %s)" % ", ".join(LENSES))
                elif (not isinstance(paths, list) or not paths
                        or not all(isinstance(p, str) and p for p in paths)):
                    err(path, "must be a non-empty list of glob strings")
    if "budget_usd" in lenses:
        v = lenses["budget_usd"]
        if (isinstance(v, bool) or not isinstance(v, (int, float))
                or not 0 < v <= MAX_LENS_BUDGET_USD):
            err("lenses.budget_usd",
                "must be a number greater than 0 and at most %d" % MAX_LENS_BUDGET_USD)
    if "cycle_cap" in lenses:
        v = lenses["cycle_cap"]
        if not _is_int(v) or not 1 <= v <= 3:
            err("lenses.cycle_cap", "must be an integer between 1 and 3")


def validate(doc, sandbox_exists=True):
    """Return a list of {path, message} errors (empty when valid)."""
    errors = []

    def err(path, message):
        errors.append({"path": path, "message": message})

    if not isinstance(doc, dict):
        err("(root)", "must be a mapping")
        return errors

    if doc.get("version") != 1 or isinstance(doc.get("version"), bool):
        err("version", "must be 1")

    if "phi_sensitive" in doc and not isinstance(doc["phi_sensitive"], bool):
        err("phi_sensitive", "must be true or false")

    _validate_lenses(doc.get("lenses"), err)

    gates = doc.get("gates")
    if gates is None:
        return errors
    if not isinstance(gates, dict):
        err("gates", "must be a mapping")
        return errors

    if "mode" in gates and gates["mode"] not in ("observe", "enforce"):
        err("gates.mode", "must be 'observe' or 'enforce'")
    if "max_attempts" in gates:
        v = gates["max_attempts"]
        if not _is_int(v) or not 1 <= v <= 5:
            err("gates.max_attempts", "must be an integer between 1 and 5")
    if "budget_minutes" in gates:
        v = gates["budget_minutes"]
        if not _is_int(v) or v < 1:
            err("gates.budget_minutes", "must be a positive integer")

    checks = gates.get("checks")
    if checks is None:
        return errors
    if not isinstance(checks, list):
        err("gates.checks", "must be a list")
        return errors

    seen = set()
    for i, check in enumerate(checks):
        base = "gates.checks[%d]" % i
        if not isinstance(check, dict):
            err(base, "must be a mapping")
            continue
        for key in check:
            if key not in CHECK_KEYS:
                err("%s.%s" % (base, key), "unknown key")

        name = check.get("name")
        if not isinstance(name, str) or not NAME_RE.match(name):
            err(base + ".name", "must match [a-z0-9][a-z0-9_-]{0,31}")
        elif name in seen:
            err(base + ".name", "duplicate check name '%s'" % name)
        else:
            seen.add(name)

        run = check.get("run")
        if not isinstance(run, str) or not run.strip():
            err(base + ".run", "must be a non-empty string")

        if "when" in check and check["when"] is not None:
            when = check["when"]
            if not isinstance(when, dict):
                err(base + ".when", "must be a mapping with a 'paths' list")
            else:
                for key in when:
                    if key != "paths":
                        err("%s.when.%s" % (base, key), "unknown key")
                paths = when.get("paths")
                if (not isinstance(paths, list) or not paths
                        or not all(isinstance(p, str) and p for p in paths)):
                    err(base + ".when.paths", "must be a non-empty list of glob strings")

        if "blocking" in check and not isinstance(check["blocking"], bool):
            err(base + ".blocking", "must be true or false")

        where = check.get("where", "any")
        if where not in ("any", "sandbox"):
            err(base + ".where", "must be 'any' or 'sandbox'")
        elif where == "sandbox" and not sandbox_exists:
            err(base + ".where",
                "'sandbox' requires %s at the config's ref" % SANDBOX_PATH)

        if "timeout_s" in check:
            v = check["timeout_s"]
            if not _is_int(v) or not 1 <= v <= 3600:
                err(base + ".timeout_s", "must be an integer between 1 and 3600")

        if "hint" in check and check["hint"] is not None:
            hint = check["hint"]
            if not isinstance(hint, str):
                err(base + ".hint", "must be a string")
            elif len(hint) > 500:
                err(base + ".hint", "must be at most 500 characters")

    return errors


def _phi_repos():
    return os.environ.get("MOTHER_PHI_REPOS", DEFAULT_PHI_REPOS).split()


def _ordered(names):
    return [lens for lens in LENSES if lens in names]


def _resolve_lenses(raw, phi):
    """Apply defaults to a validated `lenses` section (None -> None unless PHI)."""
    if raw is None and not phi:
        return None
    raw = raw or {}
    mandatory = set(raw.get("mandatory") or [])
    default = set(raw.get("default") or []) | mandatory
    scopes = {k: list(v) for k, v in (raw.get("scopes") or {}).items()}
    if phi:
        mandatory.add(PHI_LENS)
        default.add(PHI_LENS)
        scopes.pop(PHI_LENS, None)
    return {
        "mode": raw.get("mode", DEFAULT_MODE),
        "default": _ordered(default),
        "mandatory": _ordered(mandatory),
        "scopes": scopes,
        "budget_usd": raw.get("budget_usd", DEFAULT_LENS_BUDGET_USD),
        "cycle_cap": raw.get("cycle_cap", DEFAULT_LENS_CYCLE_CAP),
    }


def _resolve_doc(doc, ref, sha, repo_name):
    """Apply defaults to an already-validated doc."""
    gates = doc.get("gates") or {}
    checks = []
    for c in gates.get("checks") or []:
        checks.append({
            "name": c["name"],
            "run": c["run"],
            "when": c.get("when"),
            "blocking": c.get("blocking", True),
            "where": c.get("where", "any"),
            "timeout_s": c.get("timeout_s", DEFAULT_TIMEOUT_S),
            "hint": c.get("hint"),
        })
    phi = bool(doc.get("phi_sensitive", False)) or repo_name in _phi_repos()
    return {
        "version": 1,
        "source_ref": ref,
        "source_sha": sha,
        "phi_sensitive": phi,
        "gates": {
            "mode": gates.get("mode", DEFAULT_MODE),
            "max_attempts": gates.get("max_attempts", DEFAULT_MAX_ATTEMPTS),
            "budget_minutes": gates.get("budget_minutes", DEFAULT_BUDGET_MINUTES),
            "checks": checks,
        },
        "lenses": _resolve_lenses(doc.get("lenses"), phi),
    }


def _git(repo_path, *args):
    return subprocess.run(["git", "-C", repo_path] + list(args),
                          capture_output=True, text=True)


def load(repo_path, ref, repo_name=""):
    """Return (resolved_or_None, errors). Raises RuntimeError if ref is unusable."""
    rev = _git(repo_path, "rev-parse", "--verify", "--quiet", ref + "^{commit}")
    if rev.returncode != 0:
        raise RuntimeError("cannot resolve ref '%s' in %s" % (ref, repo_path))
    sha = rev.stdout.strip()

    shown = _git(repo_path, "show", "%s:%s" % (sha, CONFIG_PATH))
    if shown.returncode != 0:
        return None, []

    try:
        doc = yaml.safe_load(shown.stdout)
    except yaml.YAMLError as e:
        first = str(e).strip().splitlines()[0] if str(e).strip() else "invalid YAML"
        return None, [{"path": "(yaml)", "message": first}]

    sandbox_exists = _git(repo_path, "cat-file", "-e",
                          "%s:%s" % (sha, SANDBOX_PATH)).returncode == 0
    errors = validate(doc, sandbox_exists=sandbox_exists)
    if errors:
        return None, errors
    return _resolve_doc(doc, ref, sha, repo_name), []


def glob_to_regex(pattern):
    """Translate a path glob to an anchored regex.

    `**/` matches zero or more directories, `**` matches anything including
    `/`, `*` and `?` never cross a `/`.
    """
    out = []
    i, n = 0, len(pattern)
    while i < n:
        ch = pattern[i]
        if ch == "*":
            if pattern.startswith("**", i):
                i += 2
                if i < n and pattern[i] == "/":
                    i += 1
                    out.append("(?:.*/)?")
                else:
                    out.append(".*")
                continue
            out.append("[^/]*")
        elif ch == "?":
            out.append("[^/]")
        else:
            out.append(re.escape(ch))
        i += 1
    return re.compile("^" + "".join(out) + "$")


def path_matches(patterns, path):
    return any(glob_to_regex(p).match(path) for p in patterns)


def applicable(checks, changed_files):
    """Checks whose path scope matches at least one changed file (or have none)."""
    result = []
    for check in checks:
        when = check.get("when")
        paths = (when or {}).get("paths")
        if not paths or any(path_matches(paths, f) for f in changed_files):
            result.append(check)
    return result


def select(crew, plan_lenses, changed_files, posture):
    """Decide which lenses run for a diff.

    Returns [{reviewer, lens, run, skip_reason}] in canonical lens order for
    every default lens plus any the plan adds. Mandatory lenses (and
    phi-security in a PHI repo, even if the snapshot lacks it) always run:
    no plan removal, path scope or posture skips them.
    """
    crew = crew or {}
    lenses = crew.get("lenses") or {}
    plan = plan_lenses or {}
    removed = set(plan.get("remove") or [])
    mandatory = set(lenses.get("mandatory") or [])
    candidates = set(lenses.get("default") or []) | set(plan.get("add") or [])
    scopes = dict(lenses.get("scopes") or {})
    if crew.get("phi_sensitive"):
        mandatory.add(PHI_LENS)
        candidates.add(PHI_LENS)
    candidates |= mandatory

    result = []
    for lens in _ordered(candidates):
        reason = None
        if lens not in mandatory:
            scope = scopes.get(lens)
            if lens in removed:
                reason = "removed_by_plan"
            elif scope and not any(path_matches(scope, f) for f in changed_files):
                reason = "path_scope"
            elif posture == "conservative":
                reason = "posture"
        result.append({"reviewer": "perri:" + lens, "lens": lens,
                       "run": reason is None, "skip_reason": reason})
    return result


def _main(argv):
    if len(argv) >= 5 and argv[1] == "resolve":
        try:
            resolved, errors = load(argv[2], argv[3], argv[4])
        except RuntimeError as e:
            print(str(e), file=sys.stderr)
            return 2
        if errors:
            print(json.dumps({"errors": errors}))
            return 1
        print(json.dumps(resolved))
        return 0

    if len(argv) >= 3 and argv[1] == "applicable":
        with open(argv[2], encoding="utf-8") as f:
            resolved = json.load(f)
        checks = (resolved.get("gates") or {}).get("checks") or []
        if argv[3:] == ["-"]:
            files = [f for f in sys.stdin.read().split("\n") if f]
        else:
            files = [f for f in argv[3:] if f]
        print(json.dumps([c["name"] for c in applicable(checks, files)]))
        return 0

    if len(argv) >= 5 and argv[1] == "select":
        with open(argv[2], encoding="utf-8") as f:
            resolved = json.load(f)
        plan_lenses = json.loads(argv[4]) if argv[4] else None
        if argv[5:] == ["-"]:
            files = [f for f in sys.stdin.read().split("\n") if f]
        else:
            files = [f for f in argv[5:] if f]
        print(json.dumps(select(resolved, plan_lenses, files, argv[3])))
        return 0

    print("usage: crew_config.py resolve <repo_path> <ref> <repo_name>\n"
          "       crew_config.py applicable <resolved.json> <files...>\n"
          "       crew_config.py select <resolved.json> <posture> <plan_lenses_json> <files...>",
          file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(_main(sys.argv))
