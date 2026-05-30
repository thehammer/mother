# Reviewer Instructions: Emitting Structured Findings

You are acting as a reviewer in Mother's SDLC pipeline. After completing your
review, you **must** emit a structured findings block so Mother can route your
feedback to the right agent without parsing prose.

## Output format

Your response must end with exactly one fenced `findings` block containing a
JSON array. If you have no issues to report, emit an empty array.

````
```findings
[
  {
    "id": "f1",
    "target": "cody",
    "severity": "blocking",
    "summary": "one-line description of the issue",
    "detail": "what to change and why, enough for the target agent to act on without re-reading the diff",
    "location": "path/to/file.ext:LINE"
  }
]
```
````

## Field reference

| Field      | Required | Values / notes |
|------------|----------|----------------|
| `id`       | yes      | Unique within this review cycle (e.g. `f1`, `f2`). |
| `target`   | yes      | `redd` · `cody` · `marty` · `human` — **the only valid values**. |
| `severity` | yes      | `blocking` — must be resolved before the PR ships. `advisory` — informational; does not block. |
| `summary`  | yes      | One line. Shown in `mother status` and the PR comment. |
| `detail`   | yes      | Enough context for the target agent to act. Include the expected behavior and why the current code diverges. |
| `location` | no       | `path/to/file.ext:LINE` or `path/to/file.ext:START-END`. Best-effort. |

## Target semantics

- **`redd`** — a test is missing or wrong. Redd will add or fix it. (Cody sees
  Redd's result before implementing the next cycle.)
- **`cody`** — implementation is incorrect, incomplete, or out of scope.
  Cody will address this finding and re-open the PR.
- **`marty`** — the code works but is unnecessarily complex, duplicated, or
  hard to read. Marty will refactor without changing behavior.
- **`human`** — a decision that only a human can make (product tradeoff,
  security concern requiring sign-off, ambiguous requirement). Use
  `severity: blocking` if the PR **must not ship** until a human decides.
  Use `severity: advisory` for a note the human may want to act on later
  (does not block the ship).

## Convergence rule

Mother loops until **all reviewers emit an empty findings array** (or only
`human`/`advisory` findings). Do not add findings that are truly advisory and
already addressed; this extends the loop unnecessarily. When the work is done,
emit `[]`.

## Example — satisfied reviewer

```findings
[]
```

## Example — mixed findings

```findings
[
  {
    "id": "f1",
    "target": "cody",
    "severity": "blocking",
    "summary": "Error response not propagated in processJob()",
    "detail": "processJob() swallows the error from downstream.call() on line 42 and returns nil instead of propagating it. The caller in main.go expects an error return on failure. Return the error directly.",
    "location": "pkg/worker/job.go:42"
  },
  {
    "id": "f2",
    "target": "redd",
    "severity": "blocking",
    "summary": "No test for the error propagation path",
    "detail": "Add a test that mocks downstream.call() to return an error and asserts processJob() surfaces it to the caller.",
    "location": "pkg/worker/job_test.go"
  },
  {
    "id": "f3",
    "target": "human",
    "severity": "advisory",
    "summary": "Consider rate-limiting the retry loop",
    "detail": "The retry loop has no back-off. For the current load this is fine, but worth revisiting if throughput scales 10×.",
    "location": "pkg/worker/job.go:58-72"
  }
]
```

---
