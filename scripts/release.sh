#!/usr/bin/env bash
# Publishes a new version: ./scripts/release.sh 1.2.3
# Sets the version in build.sh, commits, tags vX.Y.Z and pushes; GitHub Actions
# then builds DockEcho.app and publishes the release, which Ronnie offers to
# install.
set -euo pipefail
cd "$(dirname "$0")/.."

version=${1:?usage: scripts/release.sh X.Y.Z}
[[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "invalid version: $version (expected X.Y.Z)" >&2; exit 1; }
[[ -z $(git status --porcelain) ]] || { echo "uncommitted changes" >&2; exit 1; }
[[ $(git branch --show-current) == main ]] || { echo "run it from main" >&2; exit 1; }

sed -i.bak -E "s#(CFBundle(ShortVersionString|Version)</key><string>)[^<]*#\1$version#" build.sh
sed -i.bak -E "s/^# DockEcho [0-9.]+$/# DockEcho $version/; s/Version: [0-9.]+$/Version: $version/" README.md
rm -f build.sh.bak README.md.bak
git diff --quiet || git commit -am "Release v$version"
git tag -a "v$version" -m "DockEcho $version"
git push origin main "v$version"
echo "v$version pushed: follow the build in the repository's Actions tab."
