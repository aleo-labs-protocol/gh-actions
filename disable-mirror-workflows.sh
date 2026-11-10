#!/usr/bin/env bash
# disable-mirror-workflows.sh [--show] OWNER/REPO [KEEP...] — disable every
# workflow in a mirror (see "Mirroring branches" in README.md) except KEEP.
#
# A mirror receives its source's workflows, and runs them: its own schedules,
# releases and bumps, with none of the source's secrets. KEEP names the files
# that should run there, by base name; the default is ci.yml, so pull requests
# in the mirror still get CI.
#
#   ./disable-mirror-workflows.sh my-org/app-private
#   ./disable-mirror-workflows.sh my-org/lib-private ci.yml gpu-test.yml
#
# Run it again after mirror-branches.yml warns of a new workflow. A disabled
# workflow stays disabled when its file changes. GitHub lists a file only once
# something has triggered it, so one that has not run yet is reported, not
# disabled. Dependabot's own entry cannot be disabled this way.
set -euo pipefail
show=0
if [ "${1:-}" = --show ]; then show=1; shift; fi
[ $# -ge 1 ] || { sed -n '2,3p' "$0" >&2; exit 2; }
repo=$1; shift
keep=("${@:-ci.yml}")

kept() { local k; for k in "${keep[@]}"; do [ "$1" = "$k" ] && return 0; done; return 1; }

listed=$(gh api --paginate "repos/$repo/actions/workflows" --jq '.workflows[] | "\(.id)\t\(.state)\t\(.path)"')
failed=0
while IFS=$'\t' read -r id state path; do
  [ -n "$id" ] || continue
  name=${path##*/}
  case $path in
    dynamic/*) echo "skip     $path (GitHub's own; not disabled this way)"; continue ;;
  esac
  if kept "$name"; then
    echo "keep     $path ($state)"
  elif [ "$state" != active ]; then
    echo "already  $path ($state)"
  elif (( show )); then
    echo "would    $path"
  elif gh api -X PUT "repos/$repo/actions/workflows/$id/disable" >/dev/null; then
    echo "disabled $path"
  else
    echo "FAILED   $path" >&2
    failed=1
  fi
done <<< "$listed"

# Files on the default branch that GitHub has not listed yet.
files=$(gh api "repos/$repo/contents/.github/workflows" --jq '.[] | select(.type == "file") | .path' 2>/dev/null || true)
while IFS= read -r path; do
  [ -n "$path" ] || continue
  grep -qF $'\t'"$path" <<< "$listed" && continue
  kept "${path##*/}" && continue
  echo "unlisted $path: not triggered yet, so it cannot be disabled; run this again once it has"
done <<< "$files"
exit "$failed"
