#!/bin/bash
# Installs the `photon` web server.
#
#   curl -fsSL https://photon-http.sstools.co/install.sh | bash
#   curl -fsSL https://photon-http.sstools.co/install.sh | bash -s -- --prefix /usr/local
#   scripts/install.sh                 # from a checkout: builds that checkout
#
# Options:
#   --prefix DIR    install to DIR/bin (default: /usr/local, so /usr/local/bin/photon)
#   --version REF   git tag or branch to build (default: main). From a checkout, building a
#                   REF other than the checkout's own clones it fresh.
#   --help          this text
#
# Builds from source with the Swift toolchain (macOS 15+, Swift 6.4: Xcode or swift.org) as
# you, then copies the binary into place, with sudo only when DIR/bin is not writable (it asks
# for your password). Uninstall: sudo rm /usr/local/bin/photon

set -euo pipefail

REPO="https://github.com/brennanMKE/PhotonHTTP.git"
PREFIX="/usr/local"
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
# Only the copy is privileged. PHOTON_INSTALL_SUDO overrides the command (tests).
SUDO=""
if [[ -d "$BIN" && -w "$BIN" ]] || { [[ ! -e "$BIN" ]] && mkdir -p "$BIN" 2>/dev/null; }; then
    :
else
    SUDO="${PHOTON_INSTALL_SUDO:-sudo}"
    echo "==> $BIN is not writable by $(id -un); using sudo to install there (it may ask for your password)"
    if [[ "$SUDO" == "sudo" ]] && ! sudo -n true 2>/dev/null && [[ ! -r /dev/tty ]]; then
        fail "sudo needs a password but there is no terminal; run the installer from a terminal or pass --prefix DIR for a writable DIR"
    fi
    $SUDO mkdir -p "$BIN" || fail "could not create $BIN"
fi
# Replace atomically, so a running photon keeps its binary.
$SUDO install -m 755 "$built" "$BIN/.photon.new" || fail "could not copy photon into $BIN"
$SUDO mv -f "$BIN/.photon.new" "$BIN/photon" || fail "could not move photon into place in $BIN"

echo "==> Installed $BIN/photon"
found="$(command -v photon 2>/dev/null || true)"
case ":$PATH:" in
    *":$BIN:"*)
        if [[ -n "$found" && "$found" != "$BIN/photon" ]]; then
            echo
            echo "Note: 'photon' runs $found, which comes earlier on your PATH."
            echo "Remove it to use the new one: rm \"$found\""
        fi
        ;;
    *)
        echo
        echo "$BIN is not on your PATH. To run photon by name, add this line to your shell's"
        echo "startup file (for zsh, ~/.zshrc):"
        echo "  export PATH=\"$BIN:\$PATH\""
        ;;
esac
echo
echo "Serve a folder as a website (index.html for / and every directory):"
echo "  cd ~/Sites/my-site && photon serve        # http://127.0.0.1:8080/"
echo "Docs: https://photon-http.sstools.co/docs/"
