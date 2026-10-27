#!/usr/bin/env bash
# Prints the notes of release $VERSION, Russian first and then English: the install command and the commit
# subjects since the previous release tag (the highest X.Y.Z or vX.Y.Z tag in the history of $GITHUB_SHA other
# than $VERSION), newest first, without merges and without the release commits of scripts/make-release.sh.
#
# A release that the updaters on the routers must not install (DESIGN.md 11.1) ends with the line
# `shadow-update: console`: when build/CONSOLE_UPDATE holds this very version (a file left over from an earlier
# release marks nothing).
#
# Env: GH_REPO or GITHUB_REPOSITORY (owner/repo), GITHUB_SHA (default HEAD), VERSION (default: build/VERSION).
# Reads the tags and the history of this checkout (release.yml fetches them all).
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd -P)"
ROOT="$(cd "$HERE/../.." && pwd -P)"
# shellcheck source=scripts/lib/version.sh
. "$ROOT/scripts/lib/version.sh"

repo="${GH_REPO:-${GITHUB_REPOSITORY:?}}"
sha="${GITHUB_SHA:-HEAD}"
VERSION="${VERSION:-$(cat "$ROOT/build/VERSION")}"
version_valid "$VERSION" || {
	echo "release-notes: «${VERSION}» is not X.Y.Z" >&2
	exit 1
}

prev="$(git -C "$ROOT" tag --merged "$sha" | highest_tag "$VERSION")"
prev=${prev#* }
changes="$(git -C "$ROOT" log --no-merges --max-count=200 --pretty=format:'- %s' "${prev:+$prev..}$sha" |
	{ grep -v '^- feat: release - version [0-9]' || true; })"

cat <<EOF
Shadow для OpenWrt $VERSION (OpenWrt 25.12 и новее). Установка и обновление — одна и та же команда на роутере, удаление — она же с \`--uninstall\`:

Shadow for OpenWrt $VERSION (OpenWrt 25.12 and newer). Install or upgrade on the router with the same command, remove with \`--uninstall\`:

\`\`\`sh
sh <(wget -O - https://raw.githubusercontent.com/$repo/HEAD/install.sh)
\`\`\`

Подробнее: [README](https://github.com/$repo#readme) · Details: [README.en.md](https://github.com/$repo/blob/HEAD/README.en.md)

Изменения${prev:+ с $prev} / Changes${prev:+ since $prev}:

${changes:-- только новая версия / version bump only}
EOF

# The marker goes into the notes the release is created with: release.yml publishes the draft right after the
# uploads, and an edit after that would come when routers may have seen the release as the latest already.
console=
if [ -f "$ROOT/build/CONSOLE_UPDATE" ]; then
	console="$(tr -d ' \t\r\n' <"$ROOT/build/CONSOLE_UPDATE")"
fi
if [ "$console" = "$VERSION" ]; then
	cat <<EOF

Эту версию обновление из LuCI не устанавливает: установите её командой выше. / Updates from LuCI do not install this version: install it with the command above.

shadow-update: console
EOF
fi
