#!/usr/bin/env bash
# Assemble the .deb from a payload already built by tools/build-payload.sh.
#
#   tools/build-deb.sh [revision]
#
# The version comes from packaging/payload/PAYLOAD.version, which
# build-payload.sh writes, so the two cannot disagree about what was built.
#
# Split deliberately: build-payload.sh needs macOS (Xcode's iPhoneOS SDK, ldid),
# build-deb.sh needs dpkg-deb. In CI they are different runners and the shim
# moves between them as an artifact.
#
# The download below stays on this side of that split on purpose. Fetching a
# 31 MB tarball and hashing it needs no iPhoneOS SDK, and the checksums it
# produces are consumed by version.env, which this script writes -- so moving it
# to macOS would buy nothing and would put the slow, network-heavy step on the
# expensive runner.
#
# The upstream binary is NOT packaged. We fetch it here only to confirm it is
# still patchable and to record the checksums the postinst will re-verify on the
# device.
#
# Integrity: each Pi release publishes a SHA256SUMS asset covering its own
# artifacts, and this requires the tarball to match the line for it. That is one
# publisher over one channel, not two independent ones -- unlike the sibling
# Claude Code port, Pi has no second published checksum to cross-check against,
# and pretending otherwise would be worse than saying so. What the pin actually
# buys is that the device installs the exact bytes CI checked, and nothing else.
#
# This also re-runs piios_patch.py --check against the real upstream binary and
# fails if it links a new dylib or has dropped a symbol the shim provides, so a
# package that could not work is never published.
#
# Needs: dpkg-deb (brew install dpkg / apt install dpkg-dev), curl, python3.
# The payload must exist already -- run tools/build-payload.sh on macOS first.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GH="https://github.com/earendil-works/pi/releases/download"

PAYLOAD="$ROOT/packaging/payload"
REVISION="${1:-$(cat "$ROOT/packaging/revision" 2>/dev/null || echo 1)}"
OUT="${OUT:-$ROOT/repo/debs}"
GH_REPO="${GH_REPO:-}"
GH_PAGES="${GH_PAGES:-}"

command -v dpkg-deb >/dev/null || { echo "need dpkg-deb (brew install dpkg)"; exit 1; }
[ -f "$PAYLOAD/libshim.dylib" ] || {
    echo "missing packaging/payload/libshim.dylib -- run tools/build-payload.sh on macOS first"; exit 1; }
[ -f "$PAYLOAD/PAYLOAD.version" ] || {
    echo "missing packaging/payload/PAYLOAD.version -- run tools/build-payload.sh on macOS first"; exit 1; }

read -r VERSION < "$PAYLOAD/PAYLOAD.version"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
sha256() {
    if command -v sha256sum >/dev/null; then sha256sum "$1" | cut -d' ' -f1
    else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

TARBALL="pi-darwin-arm64.tar.gz"

echo "==> SHA256SUMS for $VERSION"
curl -fsSL "$GH/v$VERSION/SHA256SUMS" -o "$TMP/SHA256SUMS"
TGZ_SHA=$(awk -v f="$TARBALL" '$2 == f || $2 == "*" f { print $1 }' "$TMP/SHA256SUMS")
[ -n "$TGZ_SHA" ] || { echo "$TARBALL is not listed in SHA256SUMS"; exit 1; }
echo "    published tarball sha256: $TGZ_SHA"

echo "==> $TARBALL (~31MB)"
curl -fsSL "$GH/v$VERSION/$TARBALL" -o "$TMP/$TARBALL"
GOT=$(sha256 "$TMP/$TARBALL")
if [ "$GOT" != "$TGZ_SHA" ]; then
    echo "!! the tarball does not match the SHA256SUMS published beside it"
    echo "   SHA256SUMS: $TGZ_SHA"
    echo "   downloaded: $GOT"
    exit 1
fi

tar xzf "$TMP/$TARBALL" -C "$TMP" pi/pi
BIN_SHA=$(sha256 "$TMP/pi/pi")
echo "    binary sha256: $BIN_SHA"

echo "==> is it still patchable?"
python3 "$PAYLOAD/piios_patch.py" "$TMP/pi/pi" --check

# Upstream's upload time for this asset, reformatted for the Debian changelog
# below. From the asset's own Last-Modified rather than `date`, so that
# rebuilding the same version produces the same bytes -- a timestamp here would
# change the package on every run and fire the already-published guard forever.
BUILD_DATE=$(python3 - "$GH/v$VERSION/$TARBALL" <<'PYDATE'
import email.utils, datetime, subprocess, sys
raw = subprocess.run(
    ["curl", "-fsSLI", "-o", "/dev/null", "-w", "%header{last-modified}", sys.argv[1]],
    capture_output=True, text=True).stdout.strip()
try:
    t = email.utils.parsedate_to_datetime(raw)
except (TypeError, ValueError):
    # No usable header: fall back to a fixed date rather than to now, which
    # would be non-deterministic. A wrong-but-stable date is recoverable; a
    # package that differs on every build is not.
    t = datetime.datetime(1970, 1, 1, tzinfo=datetime.timezone.utc)
print(t.strftime("%a, %d %b %Y %H:%M:%S %z"))
PYDATE
)

echo "==> staging"
STAGE="$TMP/stage"
LIB="$STAGE/var/jb/usr/local/lib/pi-native"
BIN="$STAGE/var/jb/usr/local/bin"
mkdir -p "$STAGE/DEBIAN" "$LIB/shims" "$BIN"

install -m 755 "$PAYLOAD/libshim.dylib"      "$LIB/libshim.dylib"
install -m 644 "$PAYLOAD/piios_patch.py"     "$LIB/piios_patch.py"
install -m 644 "$PAYLOAD/shim.c"             "$LIB/shim.c"
install -m 644 "$PAYLOAD/entitlements.plist" "$LIB/entitlements.plist"
install -m 755 "$PAYLOAD/pi-native"          "$BIN/pi-native"

# What Pi spawns when it wants a browser. A symlink, so the thing exec'd is a
# signed Mach-O and no shebang is involved; the wrapper puts this directory
# first on PATH. Dangles harmlessly if uikittools is ever removed -- Pi treats
# opening a browser as best-effort and ignores the spawn error.
ln -sfn /var/jb/usr/bin/uiopen "$LIB/shims/open"

sed -e "s|@PI_VERSION@|$VERSION|g" \
    -e "s|@PI_TARBALL_SHA256@|$TGZ_SHA|g" \
    -e "s|@PI_BINARY_SHA256@|$BIN_SHA|g" \
    "$PAYLOAD/version.env.in" > "$LIB/version.env"
chmod 644 "$LIB/version.env"

sed -e "s|@VERSION@|$VERSION-$REVISION|g" \
    -e "s|@PI_VERSION@|$VERSION|g" \
    -e "s|@REPO@|$GH_REPO|g" -e "s|@PAGES@|$GH_PAGES|g" \
    "$ROOT/packaging/DEBIAN/control.in" > "$STAGE/DEBIAN/control"

# Which Pi this build wraps, in the place dpkg and apt look for it. Generated
# rather than committed: the only thing that changes between releases of this
# package is the upstream version it packages, and that is already known here --
# a hand-maintained file would just be a second place to forget to update.
# Debian format so `apt changelog` and on-device inspection both parse it; the
# urgency and maintainer fields are required by that format.
DOC="$STAGE/var/jb/usr/share/doc/com.andi.pi-coding-agent"
mkdir -p "$DOC"
cat > "$DOC/changelog" <<CHANGELOG
com.andi.pi-coding-agent ($VERSION-$REVISION) stable; urgency=low

  * Pi updated to $VERSION.
  * Downloaded from the upstream GitHub release and patched for iOS on install;
    see https://github.com/realAndi/PiForiOS for what the patch does.

 -- andi <tafilajandi@gmail.com>  $BUILD_DATE
CHANGELOG
chmod 644 "$DOC/changelog"
[ -n "$GH_REPO"  ] || sed -i.bak '/^Icon:/d'      "$STAGE/DEBIAN/control"
[ -n "$GH_PAGES" ] || sed -i.bak '/^Native-Depiction:/d;/^SileoDepiction:/d' "$STAGE/DEBIAN/control"
rm -f "$STAGE/DEBIAN/control.bak"

install -m 755 "$ROOT/packaging/DEBIAN/postinst" "$STAGE/DEBIAN/postinst"
install -m 755 "$ROOT/packaging/DEBIAN/prerm"    "$STAGE/DEBIAN/prerm"

mkdir -p "$OUT"
DEB="$OUT/com.andi.pi-coding-agent_${VERSION}-${REVISION}_iphoneos-arm64.deb"
dpkg-deb -Zxz --root-owner-group --build "$STAGE" "$DEB" >/dev/null
echo "==> $DEB ($(du -h "$DEB" | cut -f1))"

# --- has the payload changed without the revision moving? -------------------
#
# A package version only advances when upstream ships a new Pi, or when
# packaging/revision is bumped by hand. So a change to the wrapper, the postinst
# or the patcher that forgets the bump republishes an identical version -- and
# apt, quite correctly, offers nobody an upgrade. The fix reaches no device, and
# every workflow run is green while it happens.
#
# The published repository is the only honest reference for "what does this
# version currently mean", so compare against it rather than a lockfile that can
# itself go stale.
#
# Compared by content, not .deb bytes -- an archive carries timestamps and
# ordering that differ between builds of identical input. libshim.dylib and
# md5sums are excluded for the same reason one step further down: a compiled,
# ldid-signed binary is never byte-identical twice, so including it would fire
# this guard on every single run. Its source, shim.c, ships in the package and
# IS compared, so a real change to the shim is still caught. version.env is
# compared too and is safe to compare: every hash in it is of something upstream
# published, not of anything built here.
payload_digest() {
    local deb="$1" dir
    dir="$(mktemp -d)"
    ( cd "$dir" && ar x "$deb" \
      && mkdir -p x && tar xf data.tar.* -C x 2>/dev/null \
      && tar xf control.tar.* -C x 2>/dev/null )
    # Excluded by PATH, not by name. `! -name libshim.dylib` would also exclude
    # any other file that happened to share the basename, which is how a sibling
    # port lost sight of a second file called `gh`.
    ( cd "$dir/x" && find . -type f \
        ! -path './control' ! -path './md5sums' \
        ! -path './var/jb/usr/local/lib/pi-native/libshim.dylib' -print0 | sort -z \
      | xargs -0 shasum -a 256 2>/dev/null ) | shasum -a 256 | cut -d' ' -f1
    rm -rf "$dir"
}

if [ -n "$GH_PAGES" ]; then
    PREV="$TMP/published.deb"
    if curl -fsSL "https://$GH_PAGES/debs/$(basename "$DEB")" -o "$PREV" 2>/dev/null; then
        if [ "$(payload_digest "$PREV")" != "$(payload_digest "$DEB")" ]; then
            echo
            echo "!! $VERSION-$REVISION is already published with different content."
            echo "   Republishing it would change nothing on anyone's device: apt sees"
            echo "   the same version and offers no upgrade."
            echo
            echo "   Bump packaging/revision (currently $REVISION) and rebuild."
            exit 1
        fi
        echo "    matches what is already published at this version"
    else
        echo "    not published yet at this version"
    fi
fi
