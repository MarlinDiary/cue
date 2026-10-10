#!/bin/sh
# Publishes site/ — Cue's support page and privacy policy — to the gh-pages branch, which GitHub Pages serves at
# https://chenyeni.com/cue/ (the user site's domain; user, 2026-10-10: "github 上部署"). Only that branch changes:
# main, its index and the working tree are left alone.
#
#   tools/publish_site.sh ["message"]
set -eu
cd "$(dirname "$0")/.."

git fetch -q origin gh-pages 2>/dev/null || true
index=$(mktemp -u)
trap 'rm -f "$index"' EXIT
GIT_INDEX_FILE=$index git add site
tree=$(GIT_INDEX_FILE=$index git write-tree --prefix=site/)

parent=$(git rev-parse -q --verify refs/remotes/origin/gh-pages || true)
if [ -n "$parent" ] && [ "$(git rev-parse "$parent^{tree}")" = "$tree" ]; then
  echo "gh-pages already has this site."
  exit 0
fi
commit=$(git commit-tree "$tree" ${parent:+-p "$parent"} -m "${1:-Update the site}")
git push -q origin "$commit:refs/heads/gh-pages"
git fetch -q origin gh-pages
echo "Published $(git rev-parse --short "$commit") to gh-pages."
