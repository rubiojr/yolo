#!/usr/bin/env bash
# gen-hub-index.sh — regenerate web/hub/index.json.
#
# The yolo hub (web/index.html) is a static page served from GitHub Pages,
# which offers no directory listing. To know which Yolofiles exist it reads a
# tiny manifest: a JSON array of the sub-directory names under web/hub/ that
# contain a `Yolofile`. The page then fetches each `hub/<name>/Yolofile` and
# parses its front matter in the browser, so this script deliberately does NOT
# duplicate the front-matter parser — the Yolofiles stay the single source of
# truth.
#
# Run it after adding/removing a yolofile:
#   scripts/gen-hub-index.sh
#
# It is also run automatically in CI before the Pages deploy (see
# .github/workflows/static.yml), so the manifest can never silently drift.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
hub_dir="$repo_root/web/hub"
out="$hub_dir/index.json"

[ -d "$hub_dir" ] || { echo "gen-hub-index: no such directory: $hub_dir" >&2; exit 1; }

# Collect directory names that actually contain a Yolofile, sorted for stable
# output (so the manifest diffs cleanly in git).
names=()
while IFS= read -r dir; do
  [ -f "$dir/Yolofile" ] || continue
  names+=("$(basename "$dir")")
done < <(find "$hub_dir" -mindepth 1 -maxdepth 1 -type d | sort)

# Emit a JSON array. Hub entry names are slugs (no quotes/backslashes), but we
# escape defensively anyway so a stray character can never produce invalid JSON.
json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  printf '%s' "$s"
}

{
  printf '[\n'
  count="${#names[@]}"
  for i in "${!names[@]}"; do
    sep=","
    [ "$i" -eq "$((count - 1))" ] && sep=""
    printf '  "%s"%s\n' "$(json_escape "${names[$i]}")" "$sep"
  done
  printf ']\n'
} > "$out"

echo "gen-hub-index: wrote $out (${#names[@]} entr$([ "${#names[@]}" -eq 1 ] && echo y || echo ies))"
