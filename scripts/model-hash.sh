#!/usr/bin/env bash
# No Donuts — deterministic SHA-256 of a compiled Core ML model directory (ND-087).
#
# The hash covers every regular file in the directory: its path relative to the
# directory and its contents. Files are listed in byte order (LC_ALL=C), each as
# "<sha256>  <relative path>", and that list is hashed. So the result doesn't depend on
# mtimes, permissions, or filesystem order, but changes if any file is added, removed,
# renamed or edited. Finder litter (.DS_Store) is ignored.
#
# Usage:
#   scripts/model-hash.sh [path/to/Model.mlmodelc]
#       (default: Resources/Models/FaceNetVGGFace2.mlmodelc)
#   Prints the 64-hex digest on stdout.
#
# Record a new model's hash (only after deliberately regenerating it):
#   scripts/model-hash.sh > Resources/Models/FaceNetVGGFace2.sha256
#
# Pure local: shasum + find, no network.

set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

DIR="${1:-Resources/Models/FaceNetVGGFace2.mlmodelc}"
if [ ! -d "${DIR}" ]; then
    echo "error: model directory not found: ${DIR}" >&2
    exit 1
fi

(
    cd "${DIR}"
    find . -type f ! -name '.DS_Store' -print0 \
        | LC_ALL=C sort -z \
        | xargs -0 shasum -a 256
) | shasum -a 256 | awk '{ print $1 }'
