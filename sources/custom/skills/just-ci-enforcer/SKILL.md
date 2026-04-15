---
name: just-ci-enforcer
description: Use this skill when work should be gated by a repository Justfile target named ci. It checks the current git repository for a repo-root Justfile, detects whether a ci recipe exists, and requires `just ci` to pass after implementation before the task is considered complete.
---

# Just CI Enforcer

Use this skill when the user wants implementation work validated through `just ci` when the current repository supports it.

## Workflow

1. Determine the current git repository root with `git rev-parse --show-toplevel`.
2. Check whether a `Justfile` exists at the repository root.
3. If there is no git repository or no repo-root `Justfile`, continue normally and note that the CI gate does not apply.
4. If a `Justfile` exists, check whether it defines a `ci` recipe.
5. If the `ci` recipe is present, treat `just ci` as required post-implementation validation.

## Enforcement

When the repository has a repo-root `Justfile` with a `ci` recipe:

- Run `just ci` after making implementation changes and before the final response.
- If `just ci` fails, do not treat the task as complete.
- Investigate and fix failures that are within the task's scope, then rerun `just ci`.
- If failures are unrelated or cannot be resolved safely in the current task, report that clearly and include the failing command or relevant error summary.

## Notes

- Prefer running `just ci` from the repository root.
- Do not invent alternate validation in place of `just ci` when the recipe exists; it is the gate.
- If the user explicitly instructs you not to run validation, follow the instruction and note that the CI gate was skipped at the user's request.
