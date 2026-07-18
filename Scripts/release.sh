#!/bin/bash
# One-command release: merge the current branch into main, bump the version,
# build the DMG + updater zip, tag, push, and publish a GitHub release.
#
#   Scripts/release.sh <version> [--draft] [--dry-run]
#
#   <version>   new marketing version, e.g. 1.1.0 (must be > the current one)
#   --draft     create the GitHub release as a draft (safe for a trial run)
#   --dry-run   do everything locally but skip `git push` and `gh release create`
#
# The in-app updater downloads the .zip asset and verifies it against the
# `zip-sha256:` line this script writes into the release notes.
set -euo pipefail
cd "$(dirname "$0")/.."

REPO="antoine-debroye/sweep"

# ---- args ---------------------------------------------------------------
VERSION="${1:-}"
DRAFT=""
DRY_RUN=""
for arg in "${@:2}"; do
    case "$arg" in
        --draft) DRAFT="--draft" ;;
        --dry-run) DRY_RUN="1" ;;
        *) echo "Unknown option: $arg" >&2; exit 1 ;;
    esac
done

if [[ -z "$VERSION" ]]; then
    echo "Usage: Scripts/release.sh <version> [--draft] [--dry-run]" >&2
    exit 1
fi
if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "Error: <version> must be semver X.Y.Z (got '$VERSION')." >&2
    exit 1
fi

# ---- preconditions ------------------------------------------------------
command -v gh >/dev/null        || { echo "Error: gh CLI not found." >&2; exit 1; }
command -v create-dmg >/dev/null || { echo "Error: create-dmg not found (brew install create-dmg)." >&2; exit 1; }
gh auth status >/dev/null 2>&1  || { echo "Error: not logged in to gh (run: gh auth login)." >&2; exit 1; }

if [[ -n "$(git status --porcelain)" ]]; then
    echo "Error: working tree is dirty. Commit or stash first." >&2
    exit 1
fi

CURRENT_VERSION=$(grep -m1 'MARKETING_VERSION' project.yml | awk -F'"' '{print $2}')
# Ensure the new version is strictly greater than the current one.
if [[ "$VERSION" == "$CURRENT_VERSION" ]] || \
   [[ "$(printf '%s\n%s\n' "$CURRENT_VERSION" "$VERSION" | sort -V | tail -1)" != "$VERSION" ]]; then
    echo "Error: <version> ($VERSION) must be greater than current ($CURRENT_VERSION)." >&2
    exit 1
fi

RELEASE_BRANCH=$(git rev-parse --abbrev-ref HEAD)
CURRENT_BUILD=$(grep -m1 'CURRENT_PROJECT_VERSION' project.yml | awk -F'"' '{print $2}')
NEW_BUILD=$((CURRENT_BUILD + 1))

echo "──────────────────────────────────────────────"
echo " Release plan"
echo "   version : $CURRENT_VERSION  →  $VERSION   (build $CURRENT_BUILD → $NEW_BUILD)"
echo "   merge   : $RELEASE_BRANCH  →  main"
echo "   publish : release v$VERSION on $REPO ${DRAFT:+(draft)}${DRY_RUN:+  [DRY RUN — no push/publish]}"
echo "──────────────────────────────────────────────"
read -r -p "Proceed? [y/N] " reply
[[ "$reply" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }

# ---- merge to main ------------------------------------------------------
git checkout main
git pull --ff-only origin main || echo "(couldn't fast-forward main from origin — continuing with local main)"
if [[ "$RELEASE_BRANCH" != "main" ]]; then
    git merge --no-ff "$RELEASE_BRANCH" -m "Merge $RELEASE_BRANCH for v$VERSION"
fi

# ---- bump version -------------------------------------------------------
sed -i '' -E "s/(MARKETING_VERSION: \")[^\"]*(\")/\1${VERSION}\2/" project.yml
sed -i '' -E "s/(CURRENT_PROJECT_VERSION: \")[^\"]*(\")/\1${NEW_BUILD}\2/" project.yml
git add project.yml
git commit -m "Release v$VERSION"

# ---- build artifacts ----------------------------------------------------
./Scripts/build.sh
./Scripts/make-dmg.sh   # → dist/Sweep-<version>.dmg

DMG="dist/Sweep-${VERSION}.dmg"
ZIP="dist/Sweep-${VERSION}.zip"
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent build/Release/Sweep.app "$ZIP"
ZIP_SHA=$(shasum -a 256 "$ZIP" | awk '{print $1}')
echo "✓ Built $DMG and $ZIP (sha256 $ZIP_SHA)"

# ---- release notes ------------------------------------------------------
LAST_TAG=$(git describe --tags --abbrev=0 2>/dev/null || echo "")
NOTES_FILE=$(mktemp)
{
    echo "## Sweep $VERSION"
    echo
    if [[ -n "$LAST_TAG" ]]; then
        git log "${LAST_TAG}..HEAD" --pretty="- %s" --no-merges
    else
        git log --pretty="- %s" --no-merges -n 20
    fi
    echo
    echo "zip-sha256: $ZIP_SHA"
} > "$NOTES_FILE"

# ---- confirm before anything irreversible -------------------------------
if [[ -n "$DRY_RUN" ]]; then
    echo "DRY RUN — skipping push and release. Notes preview:"
    echo "──────────────────────────────────────────────"
    cat "$NOTES_FILE"
    echo "──────────────────────────────────────────────"
    echo "Local main now has the merge + version bump. Undo with: git reset --hard origin/main"
    exit 0
fi

echo
echo "About to PUSH main + tag v$VERSION and PUBLISH the release. This is irreversible."
read -r -p "Push & publish now? [y/N] " reply
if ! [[ "$reply" =~ ^[Yy]$ ]]; then
    echo "Stopped before push. Local main has the merge + bump; undo with: git reset --hard origin/main"
    exit 0
fi

# ---- tag, push, publish -------------------------------------------------
git tag "v$VERSION"
git push origin main
git push origin "v$VERSION"

gh release create "v$VERSION" \
    --repo "$REPO" \
    --title "Sweep $VERSION" \
    --notes-file "$NOTES_FILE" \
    $DRAFT \
    "$DMG" "$ZIP"

rm -f "$NOTES_FILE"
echo
echo "✓ Released v$VERSION ${DRAFT:+(draft) }— DMG + zip uploaded to $REPO."
echo "  Installed copies will offer the update on their next launch check."