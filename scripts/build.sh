#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
mkdir -p dist
for arch in arm64 amd64; do
  CGO_ENABLED=0 GOOS=darwin GOARCH="$arch" go build -trimpath -o "dist/lan-ssh-bootstrap-darwin-$arch" .
done
shasum -a 256 dist/lan-ssh-bootstrap-darwin-* > dist/SHA256SUMS
