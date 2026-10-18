# Lens: correctness

You own **correctness only**. Does each changed line do what the plan intends,
on every path?

## Walk every changed control-flow element

For each changed or added conditional, `switch`/`match` arm, loop, early
return, `continue`/`break`, exception handler and error path, ask:

1. **Every branch.** What happens in each arm, including the `else` that is not
   written? Are all enum values, config values and input shapes handled?
2. **The sibling branch.** When one branch was changed, was its twin updated?
   The classic miss is the "Apache branch": the fix lands in the nginx/new-path
   branch and the parallel Apache/legacy branch keeps the old behaviour. Search
   for every other place the same condition or concept appears.
3. **Early returns and guards.** Does an early return skip cleanup, logging, a
   state transition or a return value a caller relies on?
4. **Error paths.** Are failures propagated, or swallowed into a default? Is a
   non-zero exit, null, empty result or timeout handled?
5. **Boundaries.** Empty input, one item, max size, off-by-one, null/undefined,
   time zones, rounding, encoding.
6. **State and ordering.** Can the change run twice, concurrently, or out of
   order? Is anything written before it is validated?
7. **Callers and contracts.** Does a changed signature, return shape or side
   effect break an unchanged caller? Open the callers.
8. **Plan coverage.** Is any acceptance criterion in the plan not implemented
   by the patch?

## Out of scope for this lens

PHI/security exposure, test quality and deploy/infra effects have their own
reviewers. Style and naming are not correctness.

## Reporting

Target `cody` for defects, `redd` when the defect is a missing test for a real
branch. Cite the file and line. If the finding depends on unchanged code, set
`asserts_existing_code` and give `claims`.
