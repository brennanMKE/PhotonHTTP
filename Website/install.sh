#!/bin/bash
# Installs the `photon` web server.
#
#   curl -fsSL https://photon-http.sstools.co/install.sh | bash
#   curl -fsSL https://photon-http.sstools.co/install.sh | bash -s -- --prefix /usr/local
#   scripts/install.sh                 # from a checkout: builds that checkout
#
# Options:
#   --prefix DIR    install to DIR/bin (default: ~/.local, so ~/.local/bin/photon)
#   --version REF   git tag or branch to build (default: main). From a checkout, building a
#                   REF other than the checkout's own clones it fresh.
#   --help          this text
#
# Builds from source with the Swift toolchain (macOS 15+, Swift 6.4: Xcode or swift.org) and
# never uses sudo. Uninstall: rm ~/.local/bin/photon

set -euo pipefail

REPO="https://github.com/brennanMKE/PhotonHTTP.git"
PREFIX="${HOME}/.local"
VERSION=""

usage() { sed -n '2,16p' "${BASH_SOURCE[0]:-/dev/null}" 2>/dev/null | sed 's/^# \{0,1\}//' || true; }
fail() { echo "install: $*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --prefix) [[ $# -ge 2 ]] || fail "missing value for --prefix"; PREFIX="$2"; shift 2 ;;
        --prefix=*) PREFIX="${1#*=}"; shift ;;
        --version) [[ $# -ge 2 ]] || fail "missing value for --version"; VERSION="$2"; shift 2 ;;
        --version=*) VERSION="${1#*=}"; shift ;;
        -h|--help) usage; exit 0 ;;
        *) fail "unknown argument '$1' (try --help)" ;;
    esac
done

[[ "$(uname -s)" == "Darwin" ]] || fail "PhotonHTTP runs on macOS only"
major="$(sw_vers -productVersion | cut -d. -f1)"
(( major >= 15 )) || fail "macOS 15 or later is required (this Mac runs $(sw_vers -productVersion))"
command -v swift >/dev/null 2>&1 || fail "the Swift toolchain was not found: install Xcode or the toolchain from https://swift.org/install"
command -v git >/dev/null 2>&1 || fail "git was not found: run 'xcode-select --install'"

# A checkout builds itself unless another version was asked for.
SOURCE=""
script="${BASH_SOURCE[0]:-}"
if [[ -n "$script" && -f "$script" ]]; then
    checkout="$(cd "$(dirname "$script")/.." && pwd)"
    if [[ -f "$checkout/Package.swift" ]] && grep -q '"photon"' "$checkout/Package.swift" && [[ -z "$VERSION" ]]; then
        SOURCE="$checkout"
    fi
fi

WORK=""
cleanup() { [[ -n "$WORK" ]] && rm -rf "$WORK"; }
trap cleanup EXIT

if [[ -z "$SOURCE" ]]; then
    WORK="$(mktemp -d "${TMPDIR:-/tmp}/photon-install.XXXXXX")"
    echo "==> Downloading PhotonHTTP ${VERSION:-main}"
    git clone --quiet --depth 1 --branch "${VERSION:-main}" "$REPO" "$WORK/PhotonHTTP" \
        || fail "could not clone $REPO at '${VERSION:-main}'"
    SOURCE="$WORK/PhotonHTTP"
fi

echo "==> Building photon (release; this takes a few minutes the first time)"
(cd "$SOURCE" && swift build -c release --product photon) || fail "the build failed; see the output above"
built="$(cd "$SOURCE" && swift build -c release --show-bin-path)/photon"
[[ -x "$built" ]] || fail "the build did not produce $built"

BIN="$PREFIX/bin"
mkdir -p "$BIN" 2>/dev/null || fail "cannot create $BIN; choose a writable --prefix (this script never uses sudo)"
[[ -w "$BIN" ]] || fail "$BIN is not writable; choose another --prefix (this script never uses sudo)"
# Replace atomically, so a running photon keeps its binary.
install -m 755 "$built" "$BIN/.photon.new"
mv -f "$BIN/.photon.new" "$BIN/photon"

echo "==> Installed $BIN/photon"
case ":$PATH:" in
    *":$BIN:"*) ;;
    *)
        echo
        echo "$BIN is not on your PATH. Add it with:"
        echo "  echo 'export PATH=\"$BIN:\$PATH\"' >> ~/.zshrc && source ~/.zshrc"
        ;;
esac
echo
echo "Serve a folder as a website (index.html for / and every directory):"
echo "  cd ~/Sites/my-site && photon serve        # http://127.0.0.1:8080/"
echo "Docs: https://photon-http.sstools.co/docs/"
