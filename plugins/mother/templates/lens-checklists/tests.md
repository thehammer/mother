# Lens: tests

You own **test quality only**. Do the tests the branch added or changed prove
the plan's acceptance criteria, and will they prove it in CI?

## Check

1. **Criteria coverage.** Map each acceptance criterion in the plan to a test.
   A criterion with no test that would fail without the implementation is a
   finding (target `redd`).
2. **Behaviour, not internals.** Tests should assert outputs and observable
   effects. Flag tests that mirror the implementation, assert on private
   methods or call counts, or would break on a harmless refactor.
3. **Would it pass the same in CI?** Look for tests that depend on:
   - running as a normal user (CI runs as root, so `chmod`-based permission
     tests pass or fail the wrong way; flag them);
   - local state: existing files, a seeded or dirty DB (CI starts fresh),
     env vars, the clock, time zone, locale, network, test ordering;
   - sleeps, races or flaky timing.
4. **Failure strength.** Does the assertion actually fail when the behaviour is
   wrong? Flag tests that assert nothing, always pass, or swallow exceptions.
5. **Edge and error paths.** Are the failure paths and boundaries in the diff
   covered, not just the happy path?

## Gaming the gates: always blocking

Any **new suppression, baseline entry, `skip`, `markTestSkipped`, `xit`,
`@ignore`, `# noqa`, `@phpstan-ignore`, `eslint-disable`, lint or static
analysis baseline addition, loosened threshold or deleted/commented-out
assertion** in the patch is a **blocking** finding unless the plan explicitly
asks for it. A fix loop must not turn a gate green by hiding the failure.
Quote the added line in `claims`.

## Out of scope for this lens

Production-code logic, PHI exposure and infra effects belong to other
reviewers.

## Reporting

Target `redd` for missing or weak tests, `cody` for gate suppressions in
production code or config. Cite the file and line.
