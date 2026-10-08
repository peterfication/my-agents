---
name: remediate-security-scan
description: Resolve findings from a repository's `just security-scan` by updating vulnerable Node/Yarn or Python/uv dependencies and documenting findings that cannot currently be fixed in `.trivyignore.yaml`. Use when asked to fix, clear, or remediate dependency security-scan failures and prepare the work on a branch. Do not use for a read-only vulnerability assessment.
---

# Remediate security scan

Leave the repository on a dedicated branch created from `main`, with every reported dependency
vulnerability either fixed by the smallest safe dependency update or explicitly explained in
`.trivyignore.yaml`, and commit the completed remediation.
Push the branch and open a pull request against `main`.

## Establish the baseline

- Inspect `git status --short`, the current branch, project manifests, lockfiles, Just recipes,
  Trivy configuration, and the existing ignore file before changing anything. Preserve unrelated
  user changes; stop if they overlap files this work must edit.
- Run `just security-scan` and retain the package, installed version, vulnerability ID, fixed
  version, and dependency ecosystem for every finding. Do not infer the active findings solely
  from an old ignore file or advisory list.
- Create a new branch from `main` before editing. Prefer `security-scan-updates`; if it already
  exists, use a clear date- or finding-qualified variant. Do not stash, discard, overwrite, or
  strand local work to switch branches; stop if existing changes prevent safely branching from
  `main`.

## Remediate each finding

Prefer the narrowest lockfile-compatible update that reaches a fixed version. Avoid broad major
upgrades, unrelated dependency refreshes, and manifest constraint changes unless required.

- For Yarn projects, use the repository's Yarn version and inspect ancestry with `yarn why
  <package>`. Update direct dependencies through Yarn; for transitive dependencies use the
  supported Yarn lockfile update mechanism and verify which parent constraints select the result.
- For uv projects, inspect ancestry with `uv tree --invert --package <package>` and normally try
  `uv lock --upgrade-package <package>`. Change `pyproject.toml` constraints only when the
  vulnerable package is direct or an existing constraint prevents the fixed version.
- Respect checked-in package-manager configuration, workspace layout, and Python version bounds.
  Never hand-edit a generated lockfile.
- After each attempted update, inspect the diff and dependency ancestry. Keep only necessary,
  coherent changes.

Classify a finding only after checking the scanner's fixed-version data, the lockfile, dependency
ancestry, and the latest version allowed by the relevant parent package:

1. **Fix available and selectable:** update to it.
2. **No fixed release exists:** add a temporary ignore with an expiration seven calendar days from
   today (ISO `YYYY-MM-DD`). Add a comment naming the package and stating that no fixed version is
   available.
3. **A parent dependency pins or constrains the vulnerable transitive package below the fix:** first
   try a safe parent update. If the latest usable parent still blocks the fix, ignore the
   vulnerability and add a comment naming both the vulnerable package and blocking parent, the
   required fixed version or major where useful, and relevant scope such as dev-only. Do not add an
   expiration to this category: the comment records the actionable upstream constraint.

Do not ignore a finding merely because its update is inconvenient, introduces an ordinary lockfile
diff, or requires a compatible direct dependency update. Do not use package-manager overrides or
resolutions to force a version past a parent's declared compatibility unless explicitly requested.

## Maintain `.trivyignore.yaml`

Preserve the existing structure and local style. For Trivy vulnerability ignores, use entries like:

```yaml
vulnerabilities:
  # braces - no fixed version available yet
  - id: CVE-YYYY-NNNNN
    expired_at: YYYY-MM-DD
  # tinypool - fix needs 2.x, vitest pins ^1.1.1 (dev-only)
  - id: CVE-YYYY-NNNNN
```

- Group multiple IDs governed by the same reason under one comment.
- Remove or update stale entries encountered for the same packages when the new dependency graph
  makes them fixable. Leave unrelated ignores unchanged.
- Never ignore a vulnerability without a concise, evidence-based comment.

## Verify and report

Run `just security-scan` again and require a clean exit. Then run the repository's normal lockfile
or dependency validation if separate. If the repository has a `ci` recipe, finish with one full
`just ci` run; fix failures caused by this work and rerun the full gate.

Review `git diff`, `git status`, and the resulting dependency versions. Stage only the files changed
for this remediation and commit them with a concise message such as `chore: remediate security scan
findings`. Push the branch to `origin`, setting its upstream, then open a pull request against
`main`. Give the pull request a concise title and a body summarizing the dependency changes,
documented ignores, and verification performed. Report the branch name, commit hash, pull request
URL, updated packages and vulnerability IDs, ignored IDs with their reason and any expiration, and
the verification commands that passed.
