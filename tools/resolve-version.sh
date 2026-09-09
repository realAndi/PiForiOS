#!/usr/bin/env bash
# Which upstream Pi version should we build?
#
#   tools/resolve-version.sh          the version Earendil currently ships
#   tools/resolve-version.sh 0.85.1   that version, validated
#
# Echoes the version on stdout and NOTHING else -- CI captures it. Progress and
# errors go to stderr.
#
# Runs on Linux, before the macOS job exists. See CONTRACT.md in ios-port-ci.
set -euo pipefail

REPO="earendil-works/pi"

VERSION="${1:-}"
# A leading v is tolerated because it is the habit from every other port; the
# version inside the release is written without one.
VERSION="${VERSION#v}"

if [ -z "$VERSION" ]; then
    # The /releases/latest web endpoint answers with a redirect to the tagged
    # release. api.github.com would answer the same question, but off the
    # anonymous 60-requests-per-hour-per-IP quota, which on a shared runner
    # egress IP is permanently exhausted. Pi's own updater resolves it this way
    # for exactly that reason.
    LOCATION=$(curl -fsSI -o /dev/null -w '%{redirect_url}' \
               "https://github.com/$REPO/releases/latest" || true)
    VERSION="${LOCATION##*/releases/tag/v}"
    if ! printf '%s' "$VERSION" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$'; then
        echo "redirect gave '$LOCATION', falling back to the API" >&2
        VERSION=$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" \
                  | python3 -c 'import json,sys; print(json.load(sys.stdin)["tag_name"].lstrip("v"))')
    fi
    echo "==> latest upstream release is $VERSION" >&2
fi

printf '%s' "$VERSION" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$' \
    || { echo "not a version: '$VERSION'" >&2; exit 1; }

# A version with no darwin-arm64 build would otherwise fail minutes later inside
# build-deb.sh, after paying for two checkouts and a macOS build. -L because the
# release URL redirects to the asset CDN, and stderr discarded because curl
# announces the miss itself in a less useful way than the line below.
curl -fsIL -o /dev/null \
    "https://github.com/$REPO/releases/download/v$VERSION/pi-darwin-arm64.tar.gz" \
    2>/dev/null \
    || { echo "no pi-darwin-arm64.tar.gz published for $VERSION" >&2; exit 1; }

echo "$VERSION"
