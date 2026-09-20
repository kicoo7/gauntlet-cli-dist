#!/usr/bin/env bash
#
# Install or upgrade the Gauntlet toolkit into ~/.claude/skills/gauntlet-cli.
#
#   curl -fsSL https://raw.githubusercontent.com/kicoo7/gauntlet-cli-dist/main/install.sh | bash
#
# Running it again is the upgrade: the toolkit directory is replaced wholesale rather than written over, so a
# directory that stops shipping stops existing instead of lingering next to the new files. Nothing is deleted
# until a downloaded tree has passed its checksum and been confirmed to be a toolkit, and any failure after that
# point puts the previous install back.
#
# Two environment variables, both defaulted, exist so this can be tested and rehosted without editing it:
#   GAUNTLET_DIST_URL    where the archive and its checksum come from
#   GAUNTLET_SKILL_DIR   where the toolkit is installed
#
set -euo pipefail

DIST_URL="${GAUNTLET_DIST_URL:-https://github.com/kicoo7/gauntlet-cli-dist/releases/latest/download}"
SKILL_DIR="${GAUNTLET_SKILL_DIR:-$HOME/.claude/skills/gauntlet-cli}"
ARCHIVE="gauntlet-cli.tar.gz"

WORK=""
STAGING=""
BACKUP=""

die() { printf 'install: %s\n' "$*" >&2; exit 1; }

cleanup() {
    if [ -n "$WORK" ] && [ -d "$WORK" ]; then rm -rf "$WORK"; fi
    if [ -n "$STAGING" ] && [ -d "$STAGING" ]; then rm -rf "$STAGING"; fi
    if [ -n "$BACKUP" ] && [ -d "$BACKUP" ]; then
        # only reachable if we died between moving the old install aside and moving the new one in
        if [ -d "$SKILL_DIR" ]; then rm -rf "$BACKUP"; else mv "$BACKUP" "$SKILL_DIR"; fi
    fi
}
trap cleanup EXIT

sha256_of() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | cut -d' ' -f1
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | cut -d' ' -f1
    else
        python3 -c 'import hashlib, sys; print(hashlib.sha256(open(sys.argv[1], "rb").read()).hexdigest())' "$1"
    fi
}

# ---- preflight: the toolkit's own requirements, checked before anything is downloaded
command -v curl >/dev/null 2>&1 || die "curl is required"
command -v tar  >/dev/null 2>&1 || die "tar is required"
command -v git  >/dev/null 2>&1 || die "git is required"
command -v python3 >/dev/null 2>&1 || die "python3 3.8 or newer is required, and none is on PATH"
python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 8) else 1)' >/dev/null 2>&1 \
    || die "python3 3.8 or newer is required (found $(python3 --version 2>&1))"

# ---- download
WORK="$(mktemp -d)"
curl -fsSL "$DIST_URL/$ARCHIVE" -o "$WORK/$ARCHIVE" \
    || die "could not download $DIST_URL/$ARCHIVE"
curl -fsSL "$DIST_URL/$ARCHIVE.sha256" -o "$WORK/$ARCHIVE.sha256" \
    || die "could not download $DIST_URL/$ARCHIVE.sha256"

want="$(cut -d' ' -f1 < "$WORK/$ARCHIVE.sha256")"
have="$(sha256_of "$WORK/$ARCHIVE")"
[ "$want" = "$have" ] \
    || die "checksum mismatch: expected $want, got $have — the download is damaged or the release changed mid-flight"

# ---- unpack, and refuse anything that is not a toolkit before touching what is installed
mkdir -p "$WORK/stage"
tar -xzf "$WORK/$ARCHIVE" -C "$WORK/stage" || die "could not unpack $ARCHIVE"
[ -f "$WORK/stage/SKILL.md" ] && [ -f "$WORK/stage/tools/VERSION" ] \
    || die "that archive is not a Gauntlet toolkit: SKILL.md and tools/VERSION must both be in it"

new="$(tr -d '[:space:]' < "$WORK/stage/tools/VERSION")"
old=""
if [ -f "$SKILL_DIR/tools/VERSION" ]; then old="$(tr -d '[:space:]' < "$SKILL_DIR/tools/VERSION")"; fi

for launcher in tools/gate tools/gauntlet tools/prepatch; do
    if [ -f "$WORK/stage/$launcher" ]; then chmod 0755 "$WORK/stage/$launcher"; fi
done

# ---- swap: old aside, new in, old gone
mkdir -p "$(dirname "$SKILL_DIR")"
STAGING="$SKILL_DIR.incoming.$$"
rm -rf "$STAGING"
mv "$WORK/stage" "$STAGING" || die "could not stage the new toolkit beside $SKILL_DIR"
if [ -d "$SKILL_DIR" ]; then
    BACKUP="$SKILL_DIR.previous.$$"
    rm -rf "$BACKUP"
    mv "$SKILL_DIR" "$BACKUP" || die "could not move the existing install aside"
fi
if ! mv "$STAGING" "$SKILL_DIR"; then
    if [ -n "$BACKUP" ]; then mv "$BACKUP" "$SKILL_DIR"; BACKUP=""; fi
    die "could not move the new toolkit into place; the previous install is still there"
fi
STAGING=""
if [ -n "$BACKUP" ]; then rm -rf "$BACKUP"; BACKUP=""; fi

# ---- report, then let the toolkit speak for itself
if [ -n "$old" ]; then
    printf '· %s → %s\n' "$old" "$new"
else
    printf '· installed %s\n' "$new"
fi
printf '· %s\n' "$SKILL_DIR"
"$SKILL_DIR/tools/gate" version
