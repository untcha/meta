---
name: meta-check
description: Use when checking whether a repo, or every repo in a folder, has drifted from the untcha/meta templates (Taskfile.yml, taskfiles/common.yml, .gitignore, .golangci.yml, AGENTS.md, docs/COMMIT_GUIDE.md, internal/appmeta), when asked about "meta drift" or being "out of sync with meta", or when asked which repo-specific tasks could be reused in other repos.
---

# meta-check

## Overview

`scripts/meta-check.sh`, next to this file, is the drift check. It decides which
files are compared, blanks per-project vars, and diffs against `untcha/meta` on
GitHub. Your job is to pick the mode, run it once, and turn its output into a
report. The comparison itself is always the script's.

## Run it

Invoke it through `bash` with the absolute path under this skill's base
directory: `bash <base-dir>/scripts/meta-check.sh`.

| User asks about | Command |
| --- | --- |
| the current repo | `bash …/meta-check.sh` |
| one other repo | `bash …/meta-check.sh PATH` |
| every repo in a folder | `bash …/meta-check.sh --dir FOLDER` |
| a meta branch or tag | prefix `META_REF=<ref>` |

Exit codes: `0` in sync, `1` drift, `2` error, `3` not meta-managed. Exit 1 is
a result, not a failure. On exit 2, report the `!!` or `meta-check:` line and
stop.

Folder output is long: redirect it to a file under `/tmp`, read the
`##### summary` and `##### project tasks` sections first, then the diffs of the
drifted repos.

## Report

Nothing in a checked repo changes until the user picks fixes. The report has
these parts, in this order:

1. **Status line** — meta ref, counts of in sync / drift / not migrated / error,
   counted per summary row (a monorepo can have several).
2. **Summary table** (folder mode) — repo, path, type, status, drifted files.
   Single-repo mode instead lists the files from the `-- checked:` line, marking
   which drifted.
3. **Drift by cause** — one entry per distinct hunk, listing every repo that has
   it ("golines formatter missing from `.golangci.yml`: rotatr, upsctl, …").
   Each entry gets a class and a fix; a hunk that mixes two classes gets both:
   - **behind meta** — meta has a change the repo lacks → re-copy or apply the hunk.
   - **local extension** — project-specific additions (extra lint rule, ignore
     entries, embed sources) → keep; say if it is worth upstreaming to meta.
   - **comment-only** — only comments differ → refresh from the template, low priority.
   - **missing** — a required file is absent → copy it from meta.
   - **meta is wrong** — the repo follows meta's own `AGENTS.md` where the
     template contradicts it → fix meta, keep the repo.
4. **Not migrated** — one line per module the script lists, no diff.
5. **Project tasks** — from the project-tasks output, the reuse candidates: a
   task name or purpose that recurs in two or more repos, or a generic task
   (vulnerability scan, install, tool pinning) that other repos lack. For each,
   propose copying it or promoting it into a meta template. A missing
   `Taskfile.project.yml` is information, not drift — the include is optional.
6. **Proposed fixes** — numbered; changes to meta itself first, then grouped by
   repo; end by asking which to apply.

## Scope

The script's file set is the scope. `LICENSE` is excluded on purpose, because
licenses legitimately differ per repo. The only Go code checked is
`internal/appmeta`, for cli and lambda targets that have it; a missing package
is not drift, because the Taskfiles build without it. Other Go code and layout
are not part of a drift check. Meta content comes from GitHub at `META_REF`, pinned to its current commit
(header: `main @ 067a297`), so unpushed changes in
a local meta clone are invisible to the check — say so when the user is editing
meta.

## Common Mistakes

| Mistake | Instead |
| --- | --- |
| Diffing files by hand or writing a compare script | Run the script; it already normalizes vars |
| Looping over repos yourself | One `--dir FOLDER` run |
| Pasting raw diffs repo by repo | Group by cause across repos |
| Diffing a not-migrated repo against a template | One line under Not migrated |
| Fixing drift without being asked | Propose fixes, wait for the pick |
