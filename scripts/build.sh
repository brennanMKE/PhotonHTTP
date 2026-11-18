#!/bin/bash
# Release build of the PhotonHTTP executable.

cd "$(dirname "$0")/.."

echo "Building!"
swift build -c release -j 2 --product photon || exit 1
echo "Done"

echo "$(swift build -c release --show-bin-path)/photon"
