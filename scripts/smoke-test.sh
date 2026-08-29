#!/usr/bin/env bash
# Build, sign, notarise, and smoke-test WhatCable.app.
#
# This is the day-to-day verification script. It does NOT touch the Homebrew
# tap. For a full release build (including the cask bump), use build-app.sh
# via scripts/release.sh.
#
# Modes:
#   - No DEVELOPER_ID set: ad-hoc signed (works locally, Gatekeeper warns elsewhere).
#   - DEVELOPER_ID set:   Developer ID signed + hardened runtime.
#   - Plus NOTARY_PROFILE: also notarises and staples (full distribution).
#
# Configure via .env (see .env.example).
#
set -euo pipefail

cd "$(dirname "$0")/.."

# Load .env if present
if [[ -f ".env" ]]; then
    # shellcheck disable=SC1091
    set -a; source .env; set +a
fi

APP_NAME="WhatCable"
BUNDLE_ID="uk.whatcable.whatcable"
VERSION="1.5.0-beta.6"
BUILD_NUMBER="135"
MIN_OS="14.0"
CLI_PRODUCT="whatcable-cli"
CLI_BIN_NAME="whatcable"

DEVELOPER_ID="${DEVELOPER_ID:-}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"

# --require-distributable turns "this build is not shippable" from a printed
# warning into a non-zero exit. build-app.sh passes it, so every release run
# has it; a bare smoke-test.sh run does not, because building unsigned locally
# to look at the UI is a legitimate thing to do.
#
# Without this the script detects an ad-hoc build correctly and then does
# nothing about it: release.sh only sources .env `if [[ -f .env ]]`, never
# asserts DEVELOPER_ID survived, and aborts on a non-zero exit alone. So a
# release from a worktree printed "NOT DISTRIBUTABLE" and carried straight on
# to publish, tag, bump the cask and push the tap.
REQUIRE_DISTRIBUTABLE=0
for arg in "$@"; do
    case "${arg}" in
        --require-distributable) REQUIRE_DISTRIBUTABLE=1 ;;
    esac
done

DIST_DIR="dist"
APP_DIR="${DIST_DIR}/${APP_NAME}.app"
CONTENTS_DIR="${APP_DIR}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
HELPERS_DIR="${CONTENTS_DIR}/Helpers"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"
PLUGINS_DIR="${CONTENTS_DIR}/PlugIns"
ENTITLEMENTS="scripts/${APP_NAME}.entitlements"
WIDGET_ENTITLEMENTS="scripts/WhatCableWidget.entitlements"
WIDGET_APPEX="WhatCableWidget.appex"

echo "==> Running tests"
swift test

echo "==> Cleaning previous build"
rm -rf "${DIST_DIR}"
mkdir -p "${MACOS_DIR}" "${HELPERS_DIR}" "${RESOURCES_DIR}" "${PLUGINS_DIR}"

echo "==> Building universal release binaries (arm64 + x86_64)"
swift build -c release --product "${APP_NAME}" \
    --arch arm64 --arch x86_64
swift build -c release --product "${CLI_PRODUCT}" \
    --arch arm64 --arch x86_64

BIN_PATH=$(swift build -c release --product "${APP_NAME}" \
    --arch arm64 --arch x86_64 --show-bin-path)
cp "${BIN_PATH}/${APP_NAME}" "${MACOS_DIR}/${APP_NAME}"
# CLI lives in Helpers/, not MacOS/, because macOS filesystems are case-insensitive
# by default. Putting "whatcable" next to "WhatCable" silently overwrote the
# main binary in v0.5.0. Helpers/ avoids the collision and is also where Apple
# expects bundled non-launch executables to live.
cp "${BIN_PATH}/${CLI_PRODUCT}" "${HELPERS_DIR}/${CLI_BIN_NAME}"

echo "==> Building widget extension (xcodebuild)"
# Generate the Xcode project from project.yml if xcodegen is available.
# The .xcodeproj is gitignored, so it may not exist yet.
if command -v xcodegen &>/dev/null; then
    xcodegen generate --quiet
elif [[ ! -d "WhatCableWidget.xcodeproj" ]]; then
    echo "    ERROR: xcodegen not installed and WhatCableWidget.xcodeproj not found." >&2
    echo "    Install with: brew install xcodegen" >&2
    exit 1
fi

# Build the widget as a universal binary with signing disabled.
# Version constants are passed via xcodebuild overrides so project.yml
# doesn't need to stay in sync with smoke-test.sh.
xcodebuild build -project WhatCableWidget.xcodeproj -scheme WhatCableWidget \
    -configuration Release \
    -destination 'platform=macOS' \
    CODE_SIGNING_ALLOWED=NO \
    ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
    MARKETING_VERSION="${VERSION}" \
    CURRENT_PROJECT_VERSION="${BUILD_NUMBER}" \
    -quiet

# Copy the built .appex into the app bundle's PlugIns directory.
WIDGET_BUILD_DIR=$(xcodebuild -project WhatCableWidget.xcodeproj -scheme WhatCableWidget \
    -configuration Release -showBuildSettings 2>/dev/null \
    | grep ' BUILD_DIR = ' | awk '{print $NF}')
cp -R "${WIDGET_BUILD_DIR}/Release/${WIDGET_APPEX}" "${PLUGINS_DIR}/${WIDGET_APPEX}"
echo "    Widget embedded at ${PLUGINS_DIR}/${WIDGET_APPEX}"

# WhatCableCore ships the bundled USB-IF vendor list as a `.process`
# resource. SPM wraps `Sources/WhatCableCore/Resources/` in a bundle
# named `WhatCable_WhatCableCore.bundle`. Put it in Contents/Resources
# so Bundle.main.resourceURL (which Bundle.module's lookup chain
# checks first) resolves it for both the GUI binary and the CLI when
# launched from inside the .app. We do not ship the bundle into
# Contents/Helpers because codesign rejects non-bundle directories
# placed there.
SPM_BUNDLE_NAME="WhatCable_WhatCableCore.bundle"
SPM_RESOURCES_SRC="Sources/WhatCableCore/Resources"
if [[ -d "${SPM_RESOURCES_SRC}" ]]; then
    bundle_path="${RESOURCES_DIR}/${SPM_BUNDLE_NAME}"
    rm -rf "${bundle_path}"
    mkdir -p "${bundle_path}"
    cp -R "${SPM_RESOURCES_SRC}/." "${bundle_path}/"
fi

# The WhatCable app target also has its own string catalog for UI strings.
APP_BUNDLE_NAME="WhatCable_WhatCable.bundle"
APP_RESOURCES_SRC="Sources/WhatCable/Resources"
if [[ -d "${APP_RESOURCES_SRC}" ]]; then
    bundle_path="${RESOURCES_DIR}/${APP_BUNDLE_NAME}"
    rm -rf "${bundle_path}"
    mkdir -p "${bundle_path}"
    cp -R "${APP_RESOURCES_SRC}/." "${bundle_path}/"
fi

# WhatCableNotifications (the notification decision module, PR #564) has its
# own localised strings, separate from the app's. WhatCableCLI does not
# depend on this target (verified against Package.swift), so unlike
# WhatCable_WhatCableCore.bundle above, this one is app-only: no CLI staging
# needed.
NOTIFICATIONS_BUNDLE_NAME="WhatCable_WhatCableNotifications.bundle"
NOTIFICATIONS_RESOURCES_SRC="Sources/WhatCableNotifications/Resources"
if [[ -d "${NOTIFICATIONS_RESOURCES_SRC}" ]]; then
    bundle_path="${RESOURCES_DIR}/${NOTIFICATIONS_BUNDLE_NAME}"
    rm -rf "${bundle_path}"
    mkdir -p "${bundle_path}"
    cp -R "${NOTIFICATIONS_RESOURCES_SRC}/." "${bundle_path}/"
fi

# TUIkit declares SPM resources, so the build produces TUIkit_TUIkit.bundle
# alongside the binaries in the products dir. Bundle.module's lookup chain
# needs it at runtime when the --dashboard command initialises the TUI.
# Unlike our own bundles (copied from source dirs), this is a dependency
# bundle so we copy it from the built products dir.
TUIKIT_BUNDLE_NAME="TUIkit_TUIkit.bundle"
TUIKIT_BUNDLE_SRC="${BIN_PATH}/${TUIKIT_BUNDLE_NAME}"
if [[ ! -d "${TUIKIT_BUNDLE_SRC}" ]]; then
    echo "ERROR: ${TUIKIT_BUNDLE_SRC} not found. The --dashboard command will" >&2
    echo "       trap at runtime without this dependency resource bundle." >&2
    exit 1
fi
cp -R "${TUIKIT_BUNDLE_SRC}" "${RESOURCES_DIR}/${TUIKIT_BUNDLE_NAME}"

# Guard against the class of bug that shipped WhatCableNotifications without
# its bundle staged (a `.process("Resources")` SPM target that nothing above
# copies into Contents/Resources crashes at launch with "unable to find
# bundle named ..." the first time Bundle.module is touched). Every target
# in the app's dependency closure that declares `resources:` in Package.swift
# must have a matching WhatCable_<Target>.bundle staged by this point. This
# is a static list, not a generic Package.swift parse: keep it in sync by
# hand whenever a target gains (or loses) a `resources:` declaration.
#
# A plain directory-existence check isn't enough: an interrupted `cp -R`
# (e.g. a rerun that races a partial previous copy) can leave the bundle
# directory present but empty, which satisfies `-d` while shipping no
# strings at all. `Bundle(url:)` succeeds on an empty directory, so that
# doesn't crash at launch; it silently falls back to English (or the raw
# key) for every string the bundle should have carried, everywhere except
# en. So the check also requires at least one `*.lproj/Localizable.strings`
# file inside, the shape every one of these targets' Resources/ carries
# today.
RESOURCE_BEARING_APP_TARGETS=(
    "WhatCableCore"
    "WhatCable"
    "WhatCableNotifications"
)
for target in "${RESOURCE_BEARING_APP_TARGETS[@]}"; do
    expected_bundle="${RESOURCES_DIR}/WhatCable_${target}.bundle"
    if [[ ! -d "${expected_bundle}" ]]; then
        echo "ERROR: ${expected_bundle} not found. ${target} declares SPM" >&2
        echo "       resources but nothing staged its bundle: the app will" >&2
        echo "       crash at launch the first time Bundle.module is touched." >&2
        exit 1
    fi
    if ! find "${expected_bundle}" -mindepth 2 -name "Localizable.strings" -print -quit | grep -q .; then
        echo "ERROR: ${expected_bundle} exists but has no *.lproj/Localizable.strings" >&2
        echo "       inside it. Staging left an empty or partial bundle: the app" >&2
        echo "       won't crash, but every string ${target} owns will silently" >&2
        echo "       fall back to English (or the raw key) at runtime." >&2
        exit 1
    fi
done

# macOS needs .lproj directories at the app bundle root to recognize
# supported languages. The actual strings live in the SPM sub-bundles,
# but without these markers the system won't select the right locale.
for lproj in "${APP_RESOURCES_SRC}"/*.lproj; do
    [[ -d "${lproj}" ]] || continue
    mkdir -p "${RESOURCES_DIR}/$(basename "${lproj}")"
done

echo "==> Verifying universal binaries"
lipo -archs "${MACOS_DIR}/${APP_NAME}" | sed 's/^/    app: /'
lipo -archs "${HELPERS_DIR}/${CLI_BIN_NAME}" | sed 's/^/    cli: /'
lipo -archs "${PLUGINS_DIR}/${WIDGET_APPEX}/Contents/MacOS/WhatCableWidget" | sed 's/^/    widget: /'

echo "==> Copying app icon"
if [[ ! -f "scripts/AppIcon.icns" ]]; then
    echo "    AppIcon.icns missing — regenerating via make-icon.sh"
    ./scripts/make-icon.sh
fi
cp "scripts/AppIcon.icns" "${RESOURCES_DIR}/AppIcon.icns"

echo "==> Building test kit probes (universal binaries)"
PROBES_SRC_DIR="probes/test-kit"
PROBES_DEST_DIR="${RESOURCES_DIR}/probes"
if [[ -d "${PROBES_SRC_DIR}" ]]; then
    mkdir -p "${PROBES_DEST_DIR}"
    for src in "${PROBES_SRC_DIR}"/*.c; do
        name=$(basename "${src}" .c)
        echo "    ${name}"
        clang -arch arm64 -arch x86_64 \
            -framework IOKit -framework CoreFoundation \
            -mmacosx-version-min="${MIN_OS}" \
            -O2 -o "${PROBES_DEST_DIR}/${name}" "${src}"
    done
    echo "    $(ls "${PROBES_DEST_DIR}" | wc -l | tr -d ' ') probes compiled"
else
    echo "    WARN: ${PROBES_SRC_DIR} not found, skipping probe compilation"
fi

echo "==> Writing Info.plist"
cat > "${CONTENTS_DIR}/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleLocalizations</key>
    <array>
        <string>en</string>
        <string>de</string>
        <string>es</string>
        <string>fr</string>
        <string>hi</string>
        <string>hy</string>
        <string>it</string>
        <string>ja</string>
        <string>ko</string>
        <string>lv</string>
        <string>nb</string>
        <string>nl</string>
        <string>pl</string>
        <string>pt-BR</string>
        <string>ru</string>
        <string>tr</string>
        <string>uk</string>
        <string>zh-Hans</string>
        <string>zh-Hant</string>
    </array>
    <key>CFBundleExecutable</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>
    <string>${APP_NAME}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${BUILD_NUMBER}</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.utilities</string>
    <key>LSMinimumSystemVersion</key>
    <string>${MIN_OS}</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHumanReadableCopyright</key>
    <string>© $(date +%Y) Darryl Morley</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

printf "APPL????" > "${CONTENTS_DIR}/PkgInfo"

# Strip macOS metadata sidecars before signing. AppleDouble files (._*)
# and .DS_Store can be created at any time by the OS when something
# touches a bundle directory (Finder browse, certain launch paths, even
# `open` during the smoke test step). If they exist at sign time they
# get sealed into the manifest; if they appear AFTER sign and before
# the final zip they are caught by `codesign --verify --strict` as
# "a sealed resource is missing or invalid". Stripping every time keeps
# the bundle clean regardless of what touched it.
echo "==> Stripping macOS metadata sidecars (._* and .DS_Store)"
find "${APP_DIR}" -name "._*" -delete 2>/dev/null || true
find "${APP_DIR}" -name ".DS_Store" -delete 2>/dev/null || true

if [[ -n "${DEVELOPER_ID}" ]]; then
    echo "==> Signing CLI binary (inner) with Developer ID + hardened runtime"
    codesign --force --options runtime --timestamp \
        --sign "${DEVELOPER_ID}" \
        "${HELPERS_DIR}/${CLI_BIN_NAME}"

    if [[ -d "${RESOURCES_DIR}/probes" ]]; then
        echo "==> Signing test kit probes with Developer ID + hardened runtime"
        for probe in "${RESOURCES_DIR}/probes"/*; do
            codesign --force --options runtime --timestamp \
                --sign "${DEVELOPER_ID}" \
                "${probe}"
        done
    fi

    echo "==> Signing widget extension with Developer ID + hardened runtime"
    # The appex must be signed with its own entitlements (app-sandbox +
    # app-group), not the host app's. Sign order matters: nested bundles
    # before the outer app, or codesign invalidates the outer signature.
    codesign --force --options runtime --timestamp \
        --entitlements "${WIDGET_ENTITLEMENTS}" \
        --sign "${DEVELOPER_ID}" \
        "${PLUGINS_DIR}/${WIDGET_APPEX}"

    echo "==> Signing app bundle (outer) with Developer ID + hardened runtime"
    echo "    Identity: ${DEVELOPER_ID}"
    codesign --force --options runtime --timestamp \
        --entitlements "${ENTITLEMENTS}" \
        --sign "${DEVELOPER_ID}" \
        "${APP_DIR}"
else
    echo "==> Ad-hoc signing (no DEVELOPER_ID set)"
    codesign --force --sign - "${HELPERS_DIR}/${CLI_BIN_NAME}"
    if [[ -d "${RESOURCES_DIR}/probes" ]]; then
        for probe in "${RESOURCES_DIR}/probes"/*; do
            codesign --force --sign - "${probe}"
        done
    fi
    codesign --force --entitlements "${WIDGET_ENTITLEMENTS}" \
        --sign - "${PLUGINS_DIR}/${WIDGET_APPEX}"
    codesign --force --entitlements "${ENTITLEMENTS}" \
        --sign - "${APP_DIR}"
fi

# --- CLI-only artifact for the whatcable-cli Homebrew formula ----------
# Stage a standalone zip containing the signed CLI binary plus the SPM
# resource bundle (USB-IF vendor list, cable DB). Bundle.module looks for
# the bundle next to the binary, so they have to ship together for the
# CLI to work when installed outside the .app.
echo "==> Staging CLI-only zip"
CLI_STAGING_DIR="${DIST_DIR}/whatcable-cli"
rm -rf "${CLI_STAGING_DIR}"
mkdir -p "${CLI_STAGING_DIR}"
cp "${HELPERS_DIR}/${CLI_BIN_NAME}" "${CLI_STAGING_DIR}/${CLI_BIN_NAME}"
if [[ -d "${RESOURCES_DIR}/${SPM_BUNDLE_NAME}" ]]; then
    cp -R "${RESOURCES_DIR}/${SPM_BUNDLE_NAME}" "${CLI_STAGING_DIR}/${SPM_BUNDLE_NAME}"
fi
# TUIkit_TUIkit.bundle must travel with the CLI binary so Bundle.module
# resolves it when --dashboard is used from a standalone Homebrew install.
if [[ ! -d "${RESOURCES_DIR}/${TUIKIT_BUNDLE_NAME}" ]]; then
    echo "ERROR: ${RESOURCES_DIR}/${TUIKIT_BUNDLE_NAME} not found for CLI staging." >&2
    echo "       The --dashboard command will trap at runtime without it." >&2
    exit 1
fi
cp -R "${RESOURCES_DIR}/${TUIKIT_BUNDLE_NAME}" "${CLI_STAGING_DIR}/${TUIKIT_BUNDLE_NAME}"

# AppInfo.version walks up from the binary looking for Info.plist. Inside
# the .app it finds Contents/Info.plist. For the standalone CLI we drop a
# minimal Info.plist alongside the binary so the walk-up finds it on the
# first iteration, instead of falling back to "dev".
cat > "${CLI_STAGING_DIR}/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${BUILD_NUMBER}</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}.cli</string>
</dict>
</plist>
PLIST

find "${CLI_STAGING_DIR}" -name "._*" -delete 2>/dev/null || true
find "${CLI_STAGING_DIR}" -name ".DS_Store" -delete 2>/dev/null || true

CLI_ZIP="${DIST_DIR}/whatcable-cli-${VERSION}.zip"
rm -f "${CLI_ZIP}"
( cd "${DIST_DIR}" && ditto --norsrc -c -k --keepParent "whatcable-cli" "whatcable-cli-${VERSION}.zip" )
echo "    Created ${CLI_ZIP}"

echo "==> Verifying signature"
codesign --verify --deep --strict --verbose=2 "${APP_DIR}" 2>&1 | sed 's/^/    /'

# The check above proves the bundle is INTERNALLY consistent. It says nothing
# about WHO signed it. An ad-hoc signature passes it, and satisfies its own
# designated requirement, by construction, so a build with no DEVELOPER_ID
# reached this point printing "valid on disk" and looking distributable.
#
# That is not cosmetic. The app declares the team-prefixed App Group
# M4RUJ7W6MP.uk.whatcable.whatcable. An ad-hoc binary carries no team identity,
# so macOS treats it as a stranger reaching into another app's container and
# prompts the user with "WhatCable would like to access data from other apps".
# Observed on a real worktree build (2026-07-31), which the old check called
# valid. Nothing in this script distinguished it from a shippable build.
#
# Building unsigned locally is fine and useful. Reporting it as success is not.
DISTRIBUTABLE=1
SIG_INFO="$(codesign -dvvv "${APP_DIR}" 2>&1)"
ACTUAL_TEAM="$(printf '%s\n' "${SIG_INFO}" | sed -n 's/^TeamIdentifier=//p' | head -1)"

if [[ -n "${DEVELOPER_ID}" ]]; then
    # Derive the expected team from DEVELOPER_ID itself rather than hardcoding
    # it, so there is one source of truth. Format is
    # "Developer ID Application: Name (TEAMID)".
    EXPECTED_TEAM="$(printf '%s\n' "${DEVELOPER_ID}" | sed -n 's/.*(\([A-Z0-9]*\))[[:space:]]*$/\1/p')"
    # Fail on a failed EXTRACTION, separately from a failed comparison. Folding
    # the two together (a `-n` guard on the comparison) means an unparseable
    # DEVELOPER_ID silently skips the check that follows and the build is then
    # declared distributable having been compared against nothing. codesign
    # accepts identities in other forms, a certificate SHA-1 among them, so this
    # is reachable without anything being obviously wrong.
    if [[ -z "${EXPECTED_TEAM}" ]]; then
        echo "ERROR: could not read a team id out of DEVELOPER_ID." >&2
        echo "       Expected \"Developer ID Application: Name (TEAMID)\", got: ${DEVELOPER_ID}" >&2
        echo "       Refusing to continue rather than skip the team check." >&2
        exit 1
    fi

    if ! printf '%s\n' "${SIG_INFO}" | grep -q "Authority=Developer ID Application"; then
        echo "ERROR: DEVELOPER_ID is set but the bundle carries no Developer ID Application authority." >&2
        echo "       Signature reads: ${ACTUAL_TEAM:-<no team>}. This build would be blocked by Gatekeeper." >&2
        exit 1
    fi
    if [[ -z "${ACTUAL_TEAM}" ]]; then
        echo "ERROR: signed bundle has no TeamIdentifier. Expected ${EXPECTED_TEAM:-a team id}." >&2
        exit 1
    fi
    if [[ "${ACTUAL_TEAM}" != "${EXPECTED_TEAM}" ]]; then
        echo "ERROR: TeamIdentifier mismatch. Expected ${EXPECTED_TEAM}, got ${ACTUAL_TEAM}." >&2
        exit 1
    fi

    # The invariant that actually causes the prompt: the App Group is team
    # prefixed, so its prefix must equal the signing team.
    #
    # BUNDLE_ID is interpolated rather than written out again. The literal was
    # here first and it is the kind of duplicate that rots quietly: rename the
    # bundle and the pattern stops matching, GROUP_ID comes back empty, and a
    # `-n` guard would have skipped the check and called the build good.
    BUNDLE_ID_RE="$(printf '%s\n' "${BUNDLE_ID}" | sed 's/\./\\./g')"
    GROUP_ID="$(codesign -d --entitlements - "${APP_DIR}" 2>/dev/null | tr -d '\0' \
        | sed -n "s/.*\([A-Z0-9]\{10\}\)\.${BUNDLE_ID_RE}.*/\1/p" | head -1)"
    if [[ -z "${GROUP_ID}" ]]; then
        echo "ERROR: no team-prefixed App Group entitlement found for ${BUNDLE_ID}." >&2
        echo "       Either the entitlement is missing from the signed bundle or it was" >&2
        echo "       renamed and this check no longer matches it. Both are release blockers:" >&2
        echo "       the App Group is what the widget reads the cable snapshot through." >&2
        exit 1
    fi
    if [[ "${GROUP_ID}" != "${ACTUAL_TEAM}" ]]; then
        echo "ERROR: App Group prefix ${GROUP_ID} does not match signing team ${ACTUAL_TEAM}." >&2
        echo "       macOS would prompt users with 'would like to access data from other apps'." >&2
        exit 1
    fi
    echo "    Developer ID signature confirmed (team ${ACTUAL_TEAM})"
else
    DISTRIBUTABLE=0
    echo "    *** AD-HOC SIGNED. NOT DISTRIBUTABLE. ***"
    echo "    No DEVELOPER_ID, so this bundle has no team identity. macOS will"
    echo "    prompt for access to the App Group container. Fine for a local"
    echo "    look at the UI; never ship it, and never quote this run as proof"
    echo "    a release build is sound. Usually means .env was not loaded,"
    echo "    e.g. running from a git worktree instead of the primary folder."
fi

echo "==> Smoke-testing main binary (must stay alive as a GUI app, not exit immediately)"
"${MACOS_DIR}/${APP_NAME}" >/dev/null 2>&1 &
SMOKE_PID=$!
sleep 2
if kill -0 "${SMOKE_PID}" 2>/dev/null; then
    echo "    main binary alive after 2s — looks like a GUI app"
    kill "${SMOKE_PID}" 2>/dev/null || true
    wait "${SMOKE_PID}" 2>/dev/null || true
else
    echo "    ERROR: ${MACOS_DIR}/${APP_NAME} exited within 2s. The menu bar binary"
    echo "    should stay running. Check whether it was overwritten by another"
    echo "    executable during build (case-insensitive FS collision, etc.)." >&2
    exit 1
fi

echo "==> Smoke-testing CLI binary (--version must match build VERSION)"
CLI_VERSION_OUTPUT=$("${HELPERS_DIR}/${CLI_BIN_NAME}" --version 2>&1 | tr -d '[:space:]')
if [[ "${CLI_VERSION_OUTPUT}" != "${VERSION}" ]]; then
    echo "    ERROR: CLI --version reported '${CLI_VERSION_OUTPUT}', expected '${VERSION}'." >&2
    echo "    The CLI binary may not be reading the bundle Info.plist correctly." >&2
    exit 1
fi
echo "    CLI reports ${CLI_VERSION_OUTPUT}"

# Exercise the JSON output path so we hit VendorDB / CableTrustReport
# / ChargingDiagnostic, not just the Info.plist read. Catches regressions
# where bundled resources (like the USB-IF vendor list) fail to load
# in the deployed .app and crash on first use. Output goes to /dev/null;
# we only care that the process exits 0.
if ! "${HELPERS_DIR}/${CLI_BIN_NAME}" --json >/dev/null 2>&1; then
    echo "    ERROR: CLI --json exited non-zero. A bundled resource may not be" >&2
    echo "    loadable in the deployed .app context." >&2
    exit 1
fi
echo "    CLI --json runs cleanly"

echo "==> Creating zip"
( cd "${DIST_DIR}" && ditto --norsrc -c -k --keepParent "${APP_NAME}.app" "${APP_NAME}.zip" )

if [[ -n "${DEVELOPER_ID}" && -n "${NOTARY_PROFILE}" ]]; then
    echo "==> Submitting to Apple notarisation (this can take a few minutes)"
    xcrun notarytool submit "${DIST_DIR}/${APP_NAME}.zip" \
        --keychain-profile "${NOTARY_PROFILE}" \
        --wait

    echo "==> Stapling notarisation ticket"
    xcrun stapler staple "${APP_DIR}"

    # Strip again just before the final zip. macOS may have created
    # AppleDouble or .DS_Store files while the bundle sat on disk
    # during notarisation / stapling. Any file added between sign and
    # zip would fail `codesign --verify --deep --strict` downstream
    # (which is what the in-app updater runs before installing).
    echo "==> Stripping macOS metadata sidecars (post-staple)"
    find "${APP_DIR}" -name "._*" -delete 2>/dev/null || true
    find "${APP_DIR}" -name ".DS_Store" -delete 2>/dev/null || true

    echo "==> Re-creating zip with stapled ticket"
    rm -f "${DIST_DIR}/${APP_NAME}.zip"
    ( cd "${DIST_DIR}" && ditto --norsrc -c -k --keepParent "${APP_NAME}.app" "${APP_NAME}.zip" )

    # Belt-and-braces: extract the final zip into a scratch directory
    # and run `codesign --verify --deep --strict`. This catches the
    # exact failure mode the in-app updater hits (sealed-resource
    # mismatch from cruft that was zipped but not signed). Failing
    # here aborts the script before publishing a broken release.
    echo "==> Verifying signed bundle in final zip (unzip, not ditto, to match updater)"
    _VERIFY_DIR=$(mktemp -d)
    unzip -q "${DIST_DIR}/${APP_NAME}.zip" -d "${_VERIFY_DIR}"
    if codesign --verify --deep --strict --verbose=2 "${_VERIFY_DIR}/${APP_NAME}.app" 2>&1 | sed 's/^/    /'; then
        echo "    Signed bundle in zip verifies clean."
    else
        echo "ERROR: codesign --verify --deep --strict failed on the final zip." >&2
        echo "       This is the failure mode the in-app updater would hit." >&2
        rm -rf "${_VERIFY_DIR}"
        exit 1
    fi
    rm -rf "${_VERIFY_DIR}"

    echo "==> Verifying Gatekeeper acceptance"
    spctl --assess --type execute --verbose "${APP_DIR}" 2>&1 | sed 's/^/    /'

    echo "==> Submitting CLI-only zip to Apple notarisation"
    # Bare CLI binaries can't be stapled (stapling is for .app / .pkg / .dmg),
    # so notarisation lives on Apple's servers and Gatekeeper checks online
    # at first launch. Acceptable for a Homebrew install path where users
    # will have network connectivity.
    xcrun notarytool submit "${CLI_ZIP}" \
        --keychain-profile "${NOTARY_PROFILE}" \
        --wait
elif [[ -n "${DEVELOPER_ID}" ]]; then
    DISTRIBUTABLE=0
    echo "==> NOTARY_PROFILE not set, skipping notarisation"
    echo "    Set it in .env once you've run:"
    echo "      xcrun notarytool store-credentials \"WhatCable-notary\" --apple-id ... --team-id ... --password ..."
else
    DISTRIBUTABLE=0
fi

# Confirm Gatekeeper actually accepts what we built, rather than inferring it
# from the fact that the notarytool call did not error. This is the only check
# here that asks the OS the same question a user's Mac will ask.
if [[ "${DISTRIBUTABLE}" == "1" ]]; then
    echo "==> Gatekeeper assessment"
    # Decide on spctl's EXIT STATUS, not on its prose containing the English
    # word "accepted". The wording is diagnostic output, not an API, and it is
    # the exit status that actually answers the question.
    SPCTL_OUT="$(spctl -a -vvv -t exec "${APP_DIR}" 2>&1)" && SPCTL_RC=0 || SPCTL_RC=$?
    if [[ "${SPCTL_RC}" -eq 0 ]]; then
        printf '%s\n' "${SPCTL_OUT}" | sed 's/^/    /'
        echo "    Gatekeeper accepted the bundle"
    else
        echo "ERROR: Gatekeeper rejected the notarised bundle. Do not ship it." >&2
        printf '%s\n' "${SPCTL_OUT}" | sed 's/^/    /' >&2
        exit 1
    fi
fi

echo "==> Smoke-testing standalone CLI zip"
# Extract the CLI zip to a scratch directory and exercise both --version
# and --json. The --json path is the important one: it hits VendorDB and
# the cable DB, so a broken resource-bundle lookup outside the .app
# would fail here rather than in the wild on a user's machine.
_CLI_VERIFY=$(mktemp -d)
ditto -x -k "${CLI_ZIP}" "${_CLI_VERIFY}"
STANDALONE_CLI="${_CLI_VERIFY}/whatcable-cli/${CLI_BIN_NAME}"
STANDALONE_VERSION=$("${STANDALONE_CLI}" --version 2>&1 | tr -d '[:space:]')
if [[ "${STANDALONE_VERSION}" != "${VERSION}" ]]; then
    echo "    ERROR: standalone CLI --version reported '${STANDALONE_VERSION}', expected '${VERSION}'." >&2
    rm -rf "${_CLI_VERIFY}"
    exit 1
fi
if ! "${STANDALONE_CLI}" --json >/dev/null 2>&1; then
    echo "    ERROR: standalone CLI --json exited non-zero. The SPM resource bundle" >&2
    echo "    may not be found alongside the binary when installed outside the .app." >&2
    rm -rf "${_CLI_VERIFY}"
    exit 1
fi
echo "    Standalone CLI runs cleanly"
rm -rf "${_CLI_VERIFY}"

echo
echo "Done."
echo "  App:     ${APP_DIR}"
echo "  CLI:     ${HELPERS_DIR}/${CLI_BIN_NAME} (inside the bundle)"
echo "  App zip: ${DIST_DIR}/${APP_NAME}.zip"
echo "  CLI zip: ${CLI_ZIP}"
# State distributability in the SUMMARY, not only in a line 200 rows up that
# has scrolled away. "Done." on its own used to read as "ready to ship"
# whether or not the bundle was signed by anyone.
if [[ "${DISTRIBUTABLE}" == "1" ]]; then
    echo "  Status:  signed, notarised, Gatekeeper accepted. Distributable."
else
    echo
    echo "  Status:  NOT DISTRIBUTABLE (unsigned or un-notarised)."
    echo "           Local testing only. Run from the primary repo folder,"
    echo "           where .env provides DEVELOPER_ID and NOTARY_PROFILE."
    if [[ "${REQUIRE_DISTRIBUTABLE}" == "1" ]]; then
        echo
        echo "ERROR: --require-distributable was passed and this build is not" >&2
        echo "       distributable. Refusing to hand it to the release pipeline." >&2
        echo "       Nothing has been published, tagged or pushed." >&2
        exit 1
    fi
fi
