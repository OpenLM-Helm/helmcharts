#!/bin/sh
# Installs the OpenLM Platform Orchestrator (openlm) from OpenLM-Helm/helmcharts.
#   curl -fsSL https://raw.githubusercontent.com/OpenLM-Helm/helmcharts/openlm-latest/dist/install.sh | sh
#   curl -fsSL .../openlm-latest/dist/install.sh | VERSION=1.0.3 sh
set -eu

REPO="OpenLM-Helm/helmcharts"
RAW="https://raw.githubusercontent.com/$REPO"
API="https://api.github.com/repos/$REPO"
INSTALL_DIR="${INSTALL_DIR:-/usr/local/bin}"
DEFAULT_VERSION="1.261120.1509"
VERSION="${VERSION:-}"
LIST=0

usage() {
  cat >&2 <<'EOF'
Usage: install.sh [VERSION] [--list]
  VERSION   X.Y.Z to install (also via the VERSION environment variable); default is this installer's version
  --list    print the available versions
Environment: INSTALL_DIR (default /usr/local/bin)
EOF
  exit 1
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

while [ $# -gt 0 ]; do
  case "$1" in
    --list) LIST=1 ;;
    -h | --help) usage ;;
    -*) usage ;;
    *) VERSION=$1 ;;
  esac
  shift
done

command -v curl > /dev/null 2>&1 || die "curl is required"

if [ "$LIST" = 1 ]; then
  curl -fsSL "$API/git/matching-refs/tags/openlm-v" |
    sed -n 's|.*"ref": *"refs/tags/openlm-v\([^"]*\)".*|\1|p' | sort -V
  exit 0
fi

[ "$(uname -s)" = Linux ] || die "only Linux is supported"
case "$(uname -m)" in
  x86_64 | amd64) ARCH=amd64 ;;
  aarch64 | arm64) ARCH=arm64 ;;
  *) die "unsupported architecture $(uname -m)" ;;
esac

if command -v sha256sum > /dev/null 2>&1; then
  SHA_CHECK="sha256sum -c -"
elif command -v shasum > /dev/null 2>&1; then
  SHA_CHECK="shasum -a 256 -c -"
else
  die "sha256sum or shasum is required"
fi

if [ -z "$VERSION" ] && [ "$DEFAULT_VERSION" != "@VERSION@" ]; then
  VERSION=$DEFAULT_VERSION
fi
if [ -z "$VERSION" ]; then
  VERSION=$(curl -fsSL "$RAW/openlm-latest/dist/version.txt") || die "cannot read the latest version"
fi
VERSION=$(printf '%s' "$VERSION" | tr -d ' \r\n')
VERSION="${VERSION#v}"
case "$VERSION" in
  "" | *[!0-9A-Za-z.-]*) die "invalid version '$VERSION'" ;;
esac

BASE="$RAW/openlm-v$VERSION/dist"
BIN="openlm_linux_$ARCH"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

curl -fsSL "$BASE/checksums.txt" -o "$TMP/checksums.txt" || die "version $VERSION not found, run with --list to see the available versions"
grep " $BIN\$" "$TMP/checksums.txt" > "$TMP/check.txt" || die "no checksum for $BIN in version $VERSION"

echo "Installing openlm $VERSION ($ARCH)"
curl -fsSL "$BASE/$BIN" -o "$TMP/$BIN" || die "cannot download $BASE/$BIN"
(cd "$TMP" && $SHA_CHECK < check.txt) || die "checksum mismatch for $BIN"

if [ -w "$INSTALL_DIR" ]; then
  install -m 0755 "$TMP/$BIN" "$INSTALL_DIR/openlm"
else
  command -v sudo > /dev/null 2>&1 || die "$INSTALL_DIR is not writable and sudo is missing, set INSTALL_DIR"
  sudo install -m 0755 "$TMP/$BIN" "$INSTALL_DIR/openlm"
fi

"$INSTALL_DIR/openlm" version
