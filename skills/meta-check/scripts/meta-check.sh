#!/usr/bin/env bash
# meta-check — check copied meta files for drift against untcha/meta.
#
# Usage:
#     meta-check.sh [--type cli|library|lambda] [PATH]   # one repo (default: cwd)
#     meta-check.sh --dir FOLDER                        # every repo directly in FOLDER
#
# A meta-managed Taskfile.yml is one that declares META_TYPE or includes a
# common.yml. Every such Taskfile in the repo (tracked or untracked, never
# ignored, any depth) is a target: a Go module root such as `daemon/` or
# `src/<lambda>/`. Run from a subdirectory, only the nearest target above it is
# checked; run from the repo root, all of them are.
#
# Per target:  Taskfile.yml vs its type template (project vars blanked),
#              the vendored common.yml, the shared files below if present, and
#              the tasks in taskfiles/Taskfile.project.yml (listed, never diffed).
# Per repo:    the shared files at the repo root, once.
#
# The project type comes from the Taskfile's META_TYPE var, so the Taskfiles
# only carry that meta info and all logic lives here.
#
# Type resolution:  --type  ->  Taskfile.yml (META_TYPE)  ->  auto-detect by content
# Env:  META_REF (branch/tag, default main)   META_RAW (full base URL override)
# Exit: 0 in sync, 1 drift, 2 error (unknown type, fetch failed), 3 not meta-managed.
#       In --dir mode: 2 if any repo errored, else 1 if any drifted, else 0.
set -euo pipefail

META_REF="${META_REF:-main}"
META_RAW="${META_RAW:-https://raw.githubusercontent.com/untcha/meta/${META_REF}}"

# Type-independent files, checked only if present. Same path locally and in meta.
SHARED_FILES=(".gitignore" ".golangci.yml" "AGENTS.md" "docs/COMMIT_GUIDE.md")

# Values you fill in per project — blanked on both sides before diffing the
# typed Taskfile, so only real task/structure drift shows (needs yq; without it
# you get a raw diff that also shows the var values).
# Only keys that exist are blanked: assigning a missing key would add it, and the
# diff would then show vars the file never had.
NORMALIZE='(if (.vars | tag) == "!!map" then .vars |= with_entries(select(.key | test("^(OWNER|REPO|APP_NAME|BIN_NAME|LAMBDA_FUNCTION_NAME)$")) |= (.value = "_")) else . end) | (if .includes.common.taskfile != null then .includes.common.taskfile = "_" else . end)'

usage() {
  sed -n '4,6p' "$0" | sed 's/^# \{0,1\}//' >&2
  exit 2
}

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/cache"
ROWS="$tmp/rows"           # repo  path  type  status  details
TASK_ROWS="$tmp/task_rows" # repo  path  task  desc
: >"$ROWS"
: >"$TASK_ROWS"

have_yq() { command -v yq >/dev/null 2>&1; }

# fetch META_PATH -> prints the cached local copy; each meta file is fetched once
# per run, however many repos are checked.
fetch() {
  local mp="$1" out="$tmp/cache/${1//\//__}"
  if [ ! -f "$out" ]; then
    curl -fsSL "$META_RAW/$mp" -o "$out" 2>/dev/null || {
      rm -f "$out"
      return 1
    }
  fi
  printf '%s' "$out"
}

# join DIR FILE -> FILE relative to the repo root ("." is the root itself).
join() { if [ "$1" = . ]; then printf '%s' "$2"; else printf '%s/%s' "$1" "$2"; fi; }

row() { printf '%s\t%s\t%s\t%s\t%s\n' "$@" >>"$ROWS"; }

# list_named NAME -> repo-relative paths of files called NAME, sorted. Runs from
# the repo root; outside git it falls back to find, pruning the usual noise.
list_named() {
  if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git ls-files -co --exclude-standard -- "*$1" | grep -E "(^|/)$1\$" || true
  else
    find . \( -name .git -o -name .terraform -o -name node_modules -o -name vendor \) -prune \
      -o -name "$1" -type f -print | sed 's|^\./||'
  fi | sort -u
}

tf_type() {
  if have_yq; then
    yq '.includes.common.vars.META_TYPE // .vars.META_TYPE // ""' "$1" 2>/dev/null || true
  else
    grep -E '^[[:space:]]*META_TYPE:' "$1" 2>/dev/null | head -1 |
      sed -E 's/.*META_TYPE:[[:space:]]*//; s/[[:space:]]*#.*//; s/["'\'']//g' || true
  fi
}

tf_common() {
  if have_yq; then
    yq '.includes.common.taskfile // ""' "$1" 2>/dev/null || true
  else
    grep -E '^[[:space:]]*taskfile:[[:space:]]*\S*common\.yml' "$1" 2>/dev/null |
      head -1 | sed -E 's/.*taskfile:[[:space:]]*//; s/[[:space:]]*#.*//' || true
  fi
}

is_managed() {
  grep -qE '^[[:space:]]*META_TYPE:' "$1" 2>/dev/null || [ -n "$(tf_common "$1")" ]
}

# check LOCAL META MODE(exact|novars) REQUIRED(yes|no) — diffs one file and
# records the result in the caller's `drift`, `failed`, `drifted`, `checked`
# and `absent`.
check() {
  local lp="$1" mp="$2" mode="$3" required="$4" remote
  if [ ! -f "$lp" ]; then
    [ "$required" = no ] && absent="${absent:+$absent, }$lp"
    if [ "$required" = yes ]; then
      printf '?? missing locally: %s\n' "$lp"
      drift=1
      drifted="${drifted:+$drifted, }$lp (missing)"
    fi
    return 0
  fi
  checked="${checked:+$checked, }$lp"
  if ! remote="$(fetch "$mp")"; then
    printf '!! could not fetch %s\n' "$mp"
    failed=1
    return 0
  fi
  if [ "$mode" = novars ] && have_yq; then
    yq "$NORMALIZE" "$lp" >"$tmp/l"
    yq "$NORMALIZE" "$remote" >"$tmp/r"
  else
    cp "$lp" "$tmp/l"
    cp "$remote" "$tmp/r"
  fi
  if ! diff -u "$tmp/r" "$tmp/l" >"$tmp/d"; then
    printf '\n=== drift: %s  vs  meta/%s ===\n' "$lp" "$mp"
    sed -e "s| $tmp/r| meta/$mp|" -e "s| $tmp/l| $lp|" "$tmp/d"
    drift=1
    drifted="${drifted:+$drifted, }$lp"
  fi
  return 0
}

# report_coverage — names every compared file, so "no drift shown" can be told
# apart from "not present".
report_coverage() {
  printf -- '-- checked: %s\n' "${checked:-none}"
  [ -z "$absent" ] || printf -- '-- absent (optional, not checked): %s\n' "$absent"
}

# list_project_tasks REPO TARGET — prints the target's repo-specific tasks so
# they can be compared across repos. Information only: never counts as drift.
list_project_tasks() {
  local repo="$1" t="$2" pf name desc
  pf="$(join "$t" taskfiles/Taskfile.project.yml)"
  if [ ! -f "$pf" ]; then
    printf -- '-- project tasks: none (%s missing)\n' "$pf"
    return 0
  fi
  if ! have_yq; then
    printf -- '-- project tasks: %s present (install yq to list them)\n' "$pf"
    return 0
  fi
  printf -- '-- project tasks (%s):\n' "$pf"
  yq '.tasks // {} | to_entries | .[] | .key + "\t" + (.value.desc // "")' "$pf" 2>/dev/null >"$tmp/tasks" || : >"$tmp/tasks"
  [ -s "$tmp/tasks" ] || echo "   (none defined)"
  while IFS="$(printf '\t')" read -r name desc; do
    printf '   %-24s %s\n' "$name" "$desc"
    printf '%s\t%s\t%s\t%s\n' "$repo" "$t" "$name" "${desc:--}" >>"$TASK_ROWS"
  done <"$tmp/tasks"
}

# check_target REPO TARGET TYPE — checks one meta-managed Taskfile and its
# siblings; returns 0 sync, 1 drift, 2 error.
check_target() {
  local repo="$1" t="$2" type="$3" tf common f drift=0 failed=0 drifted="" checked="" absent=""
  tf="$(join "$t" Taskfile.yml)"
  [ -n "$type" ] || type="$(tf_type "$tf")"
  [ "$type" = "null" ] && type=""
  if [ -z "$type" ]; then
    if grep -q 'LAMBDA_FUNCTION_NAME' "$tf"; then
      type=lambda
    elif grep -q 'dev:install' "$tf"; then
      type=cli
    else
      type=library
    fi
  fi
  case "$type" in
  cli | library | lambda) ;;
  *)
    echo "meta-check: $tf: could not determine type (cli|library|lambda)" >&2
    row "$repo" "$t" "?" error "unknown type '$type'"
    return 2
    ;;
  esac
  printf '\n### %s   (type: %s, meta ref: %s)\n' "$tf" "$type" "$META_REF"

  check "$tf" "taskfiles/${type}/Taskfile.yml" novars yes
  common="$(tf_common "$tf")"
  case "$common" in
  http* | "") ;; # remote include or none
  *) check "$(join "$t" "${common#./}")" "taskfiles/common.yml" exact yes ;;
  esac
  for f in "${SHARED_FILES[@]}"; do
    check "$(join "$t" "$f")" "$f" exact no
  done
  # Below the root the shared files normally live at the repo root instead.
  [ "$t" = . ] || absent=""
  report_coverage
  list_project_tasks "$repo" "$t"

  if [ "$failed" = 1 ]; then
    row "$repo" "$t" "$type" error "fetch failed"
    return 2
  elif [ "$drift" = 1 ]; then
    echo "✗ drift: $drifted"
    row "$repo" "$t" "$type" drift "$drifted"
    return 1
  fi
  echo "✓ in sync with meta"
  row "$repo" "$t" "$type" "in sync" "-"
  return 0
}

# check_root_files REPO — the shared files at the repo root, for repos whose
# root is not itself a target (monorepos, Terraform modules with a Lambda).
check_root_files() {
  local repo="$1" f drift=0 failed=0 drifted="" checked="" absent=""
  printf '\n### repo root shared files   (meta ref: %s)\n' "$META_REF"
  for f in "${SHARED_FILES[@]}"; do
    check "$f" "$f" exact no
  done
  report_coverage
  if [ "$failed" = 1 ]; then
    row "$repo" "(root)" - error "fetch failed"
    return 2
  elif [ "$drift" = 1 ]; then
    echo "✗ drift: $drifted"
    row "$repo" "(root)" - drift "$drifted"
    return 1
  fi
  echo "✓ in sync with meta"
  row "$repo" "(root)" - "in sync" "-"
  return 0
}

# report_unmanaged REPO — explains why a repo has no target, per Go module.
report_unmanaged() {
  local repo="$1" m d found=0
  echo "no meta-managed Taskfile.yml (needs META_TYPE or a common.yml include)"
  while IFS= read -r m; do
    found=1
    d="$(dirname "$m")"
    if [ -f "$(join "$d" Taskfile.yml)" ]; then
      printf '  %s: not migrated (Taskfile.yml without the meta include)\n' "$d"
      row "$repo" "$d" - "not migrated" "Taskfile.yml without meta include"
    else
      printf '  %s: not migrated (no Taskfile.yml)\n' "$d"
      row "$repo" "$d" - "not migrated" "no Taskfile.yml"
    fi
  done < <(list_named go.mod)
  if [ "$found" = 0 ]; then
    echo "  no Go module found"
    row "$repo" . - "not managed" "no go.mod"
  fi
}

# check_repo PATH TYPE [NAME] — checks one repo; returns the worst target result
# (2 > 1 > 0), or 3 if it has no meta-managed Taskfile. Runs in a subshell so
# the cd stays local.
check_repo() (
  local here root repo rel t f rc worst=0 root_is_target=0
  local targets=()
  cd "$1" || return 2
  here="$(pwd -P)"
  root="$(git rev-parse --show-toplevel 2>/dev/null)" || root="$here"
  cd "$root" || return 2
  repo="${3:-$(basename "$root")}"

  while IFS= read -r f; do
    case "$f" in taskfiles/* | */taskfiles/*) continue ;; esac # meta's own templates
    is_managed "$f" && targets+=("$(dirname "$f")")
  done < <(list_named Taskfile.yml)

  if [ "${#targets[@]}" -eq 0 ]; then
    report_unmanaged "$repo"
    return 3
  fi

  # From a subdirectory: only the nearest target at or above it.
  if [ "$here" != "$root" ]; then
    rel="${here#"$root"/}"
    while :; do
      for t in "${targets[@]}"; do
        if [ "$t" = "$rel" ]; then
          targets=("$t")
          break 2
        fi
      done
      [ "$rel" = . ] && break
      rel="$(dirname "$rel")"
    done
  fi

  for t in "${targets[@]}"; do
    [ "$t" = . ] && root_is_target=1
    rc=0
    check_target "$repo" "$t" "$2" || rc=$?
    [ "$rc" -gt "$worst" ] && worst="$rc"
  done
  if [ "$root_is_target" = 0 ] && [ "$here" = "$root" ]; then
    rc=0
    check_root_files "$repo" || rc=$?
    [ "$rc" -gt "$worst" ] && worst="$rc"
  fi
  return "$worst"
)

table() { column -t -s "$(printf '\t')"; }

# check_dir FOLDER — checks every repo directly inside FOLDER, then prints a
# summary and the project tasks across all repos.
check_dir() {
  local folder="${1%/}" d name rc errored=0 drifted=0
  [ -d "$folder" ] || {
    echo "meta-check: not a directory: $folder" >&2
    exit 2
  }
  for d in "$folder"/*/; do
    d="${d%/}"
    name="$(basename "$d")"
    if [ ! -e "$d/.git" ]; then
      row "$name" . - skipped "not a git repo"
      continue
    fi
    printf '\n##### %s\n' "$name"
    rc=0
    check_repo "$d" "" "$name" 2>&1 || rc=$?
    case "$rc" in
    1) drifted=1 ;;
    2) errored=1 ;;
    esac
  done
  printf '\n##### summary   (meta ref: %s)\n' "$META_REF"
  { printf 'REPO\tPATH\tTYPE\tSTATUS\tDETAILS\n'; cat "$ROWS"; } | table
  if [ -s "$TASK_ROWS" ]; then
    printf '\n##### project tasks (taskfiles/Taskfile.project.yml)\n'
    { printf 'REPO\tPATH\tTASK\tDESC\n'; cat "$TASK_ROWS"; } | table
  fi
  [ "$errored" = 1 ] && return 2
  [ "$drifted" = 1 ] && return 1
  return 0
}

type="" dir="" path="."
while [ $# -gt 0 ]; do
  case "$1" in
  --type)
    [ $# -ge 2 ] || usage
    type="$2"
    shift 2
    ;;
  --dir)
    [ $# -ge 2 ] || usage
    dir="$2"
    shift 2
    ;;
  -h | --help) usage ;;
  cli | library | lambda) # legacy positional type
    type="$1"
    shift
    ;;
  -*) usage ;;
  *)
    path="$1"
    shift
    ;;
  esac
done

if [ -n "$dir" ]; then
  [ -z "$type" ] || {
    echo "meta-check: --type cannot be combined with --dir (each repo declares its own)" >&2
    exit 2
  }
  rc=0
  check_dir "$dir" || rc=$?
  exit "$rc"
fi

rc=0
check_repo "$path" "$type" || rc=$?
exit "$rc"
