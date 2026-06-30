#!/bin/sh
# No Donuts — install the repo's git hooks.
# Points git at .githooks/ so the pre-commit hook regenerates the docs site.

set -e

# Fix 4: operate from the repo root so the relative paths below resolve no
# matter where this script is invoked from.
cd "$(git rev-parse --show-toplevel)" || {
	echo "No Donuts: not inside a git repository — cannot install hooks." >&2
	exit 1
}

# Fix 6: don't silently clobber an existing hooks setup.
existing="$(git config --get core.hooksPath || true)"
if [ -n "$existing" ] && [ "$existing" != ".githooks" ]; then
	echo "No Donuts: overriding existing core.hooksPath (was '$existing') with '.githooks'." >&2
fi

git config core.hooksPath .githooks
chmod +x .githooks/pre-commit

echo "No Donuts: git hooks installed (core.hooksPath = .githooks)."
echo "  The pre-commit hook regenerates the docs site when docs/ or mkdocs.yml are staged"
echo "  and mkdocs is available (.venv/bin/mkdocs or on PATH)."
