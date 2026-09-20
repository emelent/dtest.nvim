#!/usr/bin/env bash
# Works out the next version from the commits since the last tag, prints it,
# and tags HEAD with it. Run with --dry-run to see the answer without
# touching anything.
#
# The bump comes from conventional-commit prefixes, since a commit subject is
# the only thing a push carries that says how big a change is:
#
#   feat!: …  or  BREAKING CHANGE: in a body   breaking
#   feat: …                                    a feature
#   anything else                              a fix
#
# The last line is the one that matters here: a subject written as prose
# still tags, as a patch. Nothing has to change about how commits are
# written; prefixes only buy a bigger bump when one is wanted.
#
# While the major version is 0 a breaking change bumps the minor, which is
# what 0.x is for — reaching 1.0.0 stays a decision rather than a side
# effect of a commit subject.
set -euo pipefail

dry_run=false
[ "${1:-}" = "--dry-run" ] && dry_run=true

last=$(git tag --list 'v*' --sort=-v:refname | head -n1)

if [ -z "$last" ]; then
  # Nothing released yet. 0.1.0 rather than 0.0.1: the first tag says the
  # thing exists, not that one bug in it was fixed.
  next="0.1.0"
  range=()
else
  if [ -z "$(git log "$last..HEAD" --format='%H')" ]; then
    echo "No commits since $last; nothing to tag."
    exit 0
  fi
  range=("$last..HEAD")

  bump=patch
  if git log "${range[@]}" --format='%s' | grep -qE '^[a-z]+(\([^)]*\))?!:' \
    || git log "${range[@]}" --format='%B' | grep -qE '^BREAKING[ -]CHANGE:'; then
    bump=major
  elif git log "${range[@]}" --format='%s' | grep -qE '^feat(\([^)]*\))?:'; then
    bump=minor
  fi

  IFS=. read -r major minor patch <<<"${last#v}"
  case "$bump" in
    major)
      if [ "$major" -eq 0 ]; then minor=$((minor + 1)); patch=0
      else major=$((major + 1)); minor=0; patch=0; fi ;;
    minor) minor=$((minor + 1)); patch=0 ;;
    patch) patch=$((patch + 1)) ;;
  esac
  next="$major.$minor.$patch"
fi

if git rev-parse -q --verify "refs/tags/v$next" >/dev/null; then
  echo "v$next already exists; nothing to tag."
  exit 0
fi

echo "v$next"
if [ "$dry_run" = true ]; then
  echo "--- commits it would cover ---"
  git log "${range[@]+"${range[@]}"}" --format='  %s'
  exit 0
fi

git tag -a "v$next" -m "v$next"
git push origin "v$next"
