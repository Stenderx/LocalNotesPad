#!/usr/bin/env bash
#
# build_ipa.sh — build an unsigned, SideStore-ready LocalNotes.ipa for iPadOS.
#
# The script has two build paths and picks the best one available on this machine:
#
#   Path A (preferred, spec-compliant)
#     Uses `xcodebuild archive` with signing disabled. This requires the Xcode
#     license to be accepted; on a machine where it is not, `xcodebuild -list`
#     fails with "You have not agreed to the Xcode license agreements" and we
#     fall through to Path B.
#
#   Path B (fallback, works without an accepted Xcode license)
#     Drives the ungated Xcode toolchain binaries directly:
#     swiftc (compile + link), actool (asset catalog) and plutil (Info.plist
#     assembly), producing a signed-ad-hoc .app bundle that is zipped into the
#     Payload/ layout of an .ipa.
#
# Both paths end with the same packaging step: PkgInfo, ad-hoc signature,
# Payload/ zip and a printed summary (absolute path, size, sha256, zip listing).
#
# Usage:
#   bash build_ipa.sh [--fallback]
#
#   --fallback        Skip Path A and always use the toolchain fallback (Path B).
#   -h, --help        Show this help.
#
# Environment:
#   LOCALNOTES_FORCE_FALLBACK=1   Same effect as --fallback.
#
# The script may be invoked from any working directory; all paths are derived
# from the script's own location.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

APP_NAME="LocalNotes"
PROJECT="$APP_NAME.xcodeproj"
SCHEME="$APP_NAME"
BUNDLE_ID="com.stefano.localnotes"
MIN_IOS="17.0"
MARKETING_VERSION="1.0"
BUILD_NUMBER="1"

ARTIFACT="$SCRIPT_DIR/$APP_NAME.ipa"
BUILD_DIR="$SCRIPT_DIR/build"
PAYLOAD_DIR="$BUILD_DIR/Payload"
APP_BUNDLE="$PAYLOAD_DIR/$APP_NAME.app"
TMP_DIR="$BUILD_DIR/tmp"

XCODE_DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
SWIFTC="$XCODE_DEVELOPER_DIR/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc"
SDK="$XCODE_DEVELOPER_DIR/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS.sdk"
ACTOOL="$XCODE_DEVELOPER_DIR/usr/bin/actool"

PLUTIL="/usr/bin/plutil"
ZIP="/usr/bin/zip"
UNZIP="/usr/bin/unzip"
CODESIGN="/usr/bin/codesign"

info()  { printf 'info:  %s\n' "$*" >&2; }
warn()  { printf 'warn:  %s\n' "$*" >&2; }
error() { printf 'error: %s\n' "$*" >&2; }

usage() {
    cat >&2 <<EOF
build_ipa.sh — build unsigned $APP_NAME.ipa (SideStore-ready)

Usage:
  bash build_ipa.sh [--fallback]

Options:
  --fallback       skip the xcodebuild archive path and use the toolchain
                   fallback (swiftc + actool + plutil) even if xcodebuild works.
  -h, --help       show this help.

Outputs:
  $ARTIFACT

Notes:
  Path A (xcodebuild archive) runs only when the Xcode license has been
  accepted. Otherwise the toolchain fallback (Path B) builds the bundle
  without xcodebuild, exactly as it does on a license-gated machine.
EOF
}

FORCE_FALLBACK="${LOCALNOTES_FORCE_FALLBACK:-0}"
while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)
            usage
            exit 0
            ;;
        --fallback)
            FORCE_FALLBACK=1
            ;;
        *)
            error "unknown argument: $1"
            usage
            exit 2
            ;;
    esac
    shift
done

# Returns 0 when `xcodebuild -list` works against the project (license accepted).
xcodebuild_available() {
    [[ "$FORCE_FALLBACK" != "1" ]] || return 1
    command -v xcodebuild >/dev/null 2>&1 || return 1
    DEVELOPER_DIR="$XCODE_DEVELOPER_DIR" xcodebuild -list -project "$PROJECT" >/dev/null 2>&1
}

# plutil setter: inserts `key` as a string, or replaces it when it exists.
set_plist_string() {
    local file="$1" key="$2" value="$3"
    if "$PLUTIL" -extract "$key" xml1 -o "$TMP_DIR/probe.plist" "$file" >/dev/null 2>&1; then
        "$PLUTIL" -replace "$key" -string "$value" "$file"
    else
        "$PLUTIL" -insert "$key" -string "$value" "$file"
    fi
}

# plutil setter: inserts `key` with the XML fragment in `xml`, or replaces it.
set_plist_xml() {
    local file="$1" key="$2" xml="$3"
    if "$PLUTIL" -extract "$key" xml1 -o "$TMP_DIR/probe.plist" "$file" >/dev/null 2>&1; then
        "$PLUTIL" -replace "$key" -xml "$xml" "$file"
    else
        "$PLUTIL" -insert "$key" -xml "$xml" "$file"
    fi
}

# Gives every downstream resigner (SideStore, AltStore, …) a valid bundle.
adhoc_sign() {
    if "$CODESIGN" --force --sign - --timestamp=none "$APP_BUNDLE"; then
        info "ad-hoc signed $APP_BUNDLE"
    else
        warn "codesign failed; leaving the bundle unsigned (resigners replace the signature anyway)"
    fi
}

# ---------------------------------------------------------------------------
# Path A — xcodebuild archive
# ---------------------------------------------------------------------------
build_with_xcodebuild() {
    info "Path A: xcodebuild is available and licensed - archiving scheme '$SCHEME'."
    local archive="$BUILD_DIR/$APP_NAME.xcarchive"
    local built_app="$archive/Products/Applications/$APP_NAME.app"

    DEVELOPER_DIR="$XCODE_DEVELOPER_DIR" xcodebuild \
        -project "$PROJECT" \
        -scheme "$SCHEME" \
        -configuration Release \
        -sdk iphoneos \
        -destination 'generic/platform=iOS' \
        -archivePath "$archive" \
        archive \
        CODE_SIGNING_ALLOWED=NO \
        CODE_SIGN_IDENTITY="" \
        CODE_SIGNING_REQUIRED=NO \
        CODE_SIGN_ENTITLEMENTS=""

    if [[ ! -d "$built_app" ]]; then
        error "Path A: archive did not produce $built_app"
        return 1
    fi

    mkdir -p "$PAYLOAD_DIR"
    cp -R "$built_app" "$APP_BUNDLE"
    info "Path A: copied archived app into $APP_BUNDLE"
}

# ---------------------------------------------------------------------------
# Path B — direct toolchain build (no xcodebuild)
# ---------------------------------------------------------------------------
build_with_toolchain() {
    info "Path B: building with the Xcode toolchain binaries (swiftc + actool + plutil)."

    local tool
    for tool in "$SWIFTC" "$ACTOOL"; do
        if [[ ! -x "$tool" ]]; then
            error "missing toolchain binary: $tool"
            return 1
        fi
    done
    if [[ ! -d "$SDK" ]]; then
        error "missing iPhoneOS SDK: $SDK"
        return 1
    fi

    rm -rf "$BUILD_DIR/Release-iphoneos"
    mkdir -p "$APP_BUNDLE" "$TMP_DIR"

    # 1. Compile + link every Swift source in a single invocation.
    local swift_files_raw
    swift_files_raw="$(find LocalNotes -name '*.swift' -print | sort)"
    if [[ -z "$swift_files_raw" ]]; then
        error "no Swift sources found under LocalNotes/"
        return 1
    fi
    local swift_files
    swift_files=($swift_files_raw)

    info "Path B: compiling ${#swift_files[@]} Swift file(s) for arm64-apple-ios$MIN_IOS …"
    "$SWIFTC" -sdk "$SDK" -target "arm64-apple-ios$MIN_IOS" -swift-version 6 -parse-as-library \
        -O -module-name "$APP_NAME" \
        "${swift_files[@]}" \
        -o "$APP_BUNDLE/$APP_NAME"

    # 2. Asset catalog -> Assets.car + icon PNGs + partial Info.plist.
    info "Path B: compiling asset catalog …"
    "$ACTOOL" LocalNotes/Resources/Assets.xcassets \
        --compile "$APP_BUNDLE" \
        --platform iphoneos \
        --minimum-deployment-target "$MIN_IOS" \
        --app-icon AppIcon \
        --output-partial-info-plist "$BUILD_DIR/icon-partial.plist"

    if [[ ! -f "$APP_BUNDLE/Assets.car" ]]; then
        error "actool did not produce Assets.car"
        return 1
    fi

    # 3. Copy the source Info.plist and merge the icon keys actool produced.
    cp LocalNotes/Info.plist "$APP_BUNDLE/Info.plist"

    local key icon_xml
    for key in CFBundleIcons CFBundleIcons~ipad; do
        if "$PLUTIL" -extract "$key" xml1 -o "$TMP_DIR/$key.plist" "$BUILD_DIR/icon-partial.plist" >/dev/null 2>&1; then
            icon_xml="$(cat "$TMP_DIR/$key.plist")"
            set_plist_xml "$APP_BUNDLE/Info.plist" "$key" "$icon_xml"
            info "Path B: merged $key from the actool partial plist"
        else
            info "Path B: partial plist has no $key; skipping"
        fi
    done

    # 4. Inject the keys Xcode's ProcessInfoPlistFile step normally supplies.
    local plist="$APP_BUNDLE/Info.plist"
    set_plist_string "$plist" CFBundleExecutable "$APP_NAME"
    set_plist_string "$plist" CFBundleIdentifier "$BUNDLE_ID"
    set_plist_string "$plist" CFBundleName "$APP_NAME"
    set_plist_string "$plist" CFBundlePackageType "APPL"
    set_plist_string "$plist" CFBundleInfoDictionaryVersion "6.0"
    set_plist_xml "$plist" CFBundleSupportedPlatforms '<array><string>iPhoneOS</string></array>'
    set_plist_string "$plist" MinimumOSVersion "$MIN_IOS"
    set_plist_xml "$plist" UIDeviceFamily '<array><integer>2</integer></array>'

    # Keep the version keys when present, otherwise supply the project defaults.
    if ! "$PLUTIL" -extract CFBundleShortVersionString xml1 -o "$TMP_DIR/probe.plist" "$plist" >/dev/null 2>&1; then
        set_plist_string "$plist" CFBundleShortVersionString "$MARKETING_VERSION"
    fi
    if ! "$PLUTIL" -extract CFBundleVersion xml1 -o "$TMP_DIR/probe.plist" "$plist" >/dev/null 2>&1; then
        set_plist_string "$plist" CFBundleVersion "$BUILD_NUMBER"
    fi

    info "Path B: Info.plist assembled"
}

# ---------------------------------------------------------------------------
# Packaging — shared by both paths
# ---------------------------------------------------------------------------
package_ipa() {
    printf 'APPL????' > "$APP_BUNDLE/PkgInfo"

    # Strip extended attributes so codesign never trips over Finder detritus.
    xattr -cr "$APP_BUNDLE" 2>/dev/null || true

    adhoc_sign

    rm -f "$ARTIFACT"
    info "packaging Payload/ into $(basename "$ARTIFACT") …"
    ( cd "$BUILD_DIR" && "$ZIP" -q -r -9 "$ARTIFACT" Payload )
}

print_summary() {
    local size sha
    size="$(stat -f%z "$ARTIFACT")"
    sha="$(shasum -a 256 "$ARTIFACT" | cut -d' ' -f1)"

    printf '\n=== build complete ===\n'
    printf 'artifact: %s\n' "$ARTIFACT"
    printf 'size:     %s bytes\n' "$size"
    printf 'sha256:   %s\n' "$sha"
    printf '\n$ unzip -l %s\n' "$ARTIFACT"
    "$UNZIP" -l "$ARTIFACT" | head -30
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

if xcodebuild_available; then
    if ! build_with_xcodebuild; then
        warn "Path A failed - falling back to the toolchain build."
        rm -rf "$PAYLOAD_DIR"
        mkdir -p "$BUILD_DIR"
        build_with_toolchain
    fi
else
    if [[ "$FORCE_FALLBACK" == "1" ]]; then
        info "Path A skipped (--fallback requested)."
    else
        info "Path A unavailable: xcodebuild is gated (Xcode license not accepted) or missing."
    fi
    build_with_toolchain
fi

package_ipa
print_summary
