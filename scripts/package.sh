#!/usr/bin/env bash
# Builds the archive published in the GitHub releases, which Ronnie downloads
# from its Downloads page: dist/dockecho-aarch64-apple-darwin.tar.gz holding
# DockEcho.app. The name must match what Ronnie looks for (src/modules.rs in
# Ronnie). Signed by build.sh (SIGN_IDENTITY, else the keychain's first
# identity, else ad hoc).
set -euo pipefail
cd "$(dirname "$0")/.."

[ "$(uname -m)" = arm64 ] || { echo "Apple Silicon only, like Ronnie" >&2; exit 1; }
./build.sh
rm -rf dist
mkdir -p dist
tar -czf dist/dockecho-aarch64-apple-darwin.tar.gz DockEcho.app
ls -l dist
