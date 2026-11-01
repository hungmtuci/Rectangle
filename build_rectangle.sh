#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="Rectangle"
APP_BUNDLE="${PROJECT_DIR}/${APP_NAME}.app"
WORKSPACE_APP_BUNDLE="$(cd "${PROJECT_DIR}/.." && pwd)/${APP_NAME}.app"
DIST_DIR="${PROJECT_DIR}/dist"
RECTANGLE_VERSION="${RECTANGLE_VERSION:-2.1.2-custom}"
RECTANGLE_BUILD="${RECTANGLE_BUILD:-114}"

SKIP_INSTALL=0
for arg in "$@"; do
    case "${arg}" in
        --skip-install)
            SKIP_INSTALL=1
            ;;
    esac
done

cd "${PROJECT_DIR}"

if [[ -d "/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk" ]]; then
    export SDKROOT="/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk"
fi

echo "=== [1/5] Building ${APP_NAME} v${RECTANGLE_VERSION} (${RECTANGLE_BUILD}) via SwiftPM ==="
if swift build --help 2>&1 | grep -q -- "--build-system"; then
    swift build --build-system native -c release --product "${APP_NAME}"
    BIN_DIR="$(swift build --build-system native -c release --show-bin-path)"
else
    swift build -c release --product "${APP_NAME}"
    BIN_DIR="$(swift build -c release --show-bin-path)"
fi
EXECUTABLE_PATH="${BIN_DIR}/${APP_NAME}"

if [[ ! -f "${EXECUTABLE_PATH}" ]]; then
    echo "Error: Release binary not found at ${EXECUTABLE_PATH}" >&2
    exit 1
fi

echo "=== [2/5] Assembling ${APP_NAME}.app bundle structure ==="
rm -rf "${APP_BUNDLE}"
mkdir -p "${APP_BUNDLE}/Contents/MacOS"
mkdir -p "${APP_BUNDLE}/Contents/Resources"

cp "${EXECUTABLE_PATH}" "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}"
/usr/bin/strip -x "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}" 2>/dev/null || true
chmod +x "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}"

# Copy dynamic frameworks (if any) and SwiftPM resource bundles
for fw in "${BIN_DIR}"/*.framework; do
    if [[ -d "${fw}" ]]; then
        mkdir -p "${APP_BUNDLE}/Contents/Frameworks"
        cp -R "${fw}" "${APP_BUNDLE}/Contents/Frameworks/"
    fi
done

for bundle in "${BIN_DIR}"/*.bundle; do
    if [[ -d "${bundle}" ]]; then
        cp -R "${bundle}" "${APP_BUNDLE}/Contents/Resources/"
    fi
done

# Copy InternetAccessPolicy.plist if present
if [[ -f "${PROJECT_DIR}/Rectangle/InternetAccessPolicy.plist" ]]; then
    cp "${PROJECT_DIR}/Rectangle/InternetAccessPolicy.plist" "${APP_BUNDLE}/Contents/Resources/"
fi

echo "=== [3/5] Extracting Assets.xcassets, AppIcon.icns, and Localizable.xcstrings ==="
python3 - "${PROJECT_DIR}" "${APP_BUNDLE}/Contents/Resources" <<'PYEOF'
import json
import os
import shutil
import subprocess
import sys
import tempfile

project_dir = sys.argv[1]
resources_dir = sys.argv[2]
xcassets_dir = os.path.join(project_dir, "Rectangle", "Assets.xcassets")

# 1. Extract all .imageset assets into Contents/Resources/<name>[@2x|@3x].png
for root, dirs, _ in os.walk(xcassets_dir):
    for d in list(dirs):
        if d.endswith(".imageset"):
            imageset_path = os.path.join(root, d)
            name = d[:-len(".imageset")]
            contents_file = os.path.join(imageset_path, "Contents.json")
            if not os.path.isfile(contents_file):
                continue
            with open(contents_file, "r", encoding="utf-8") as f:
                meta = json.load(f)
            copied_scales = {}
            for img in meta.get("images", []):
                filename = img.get("filename")
                if not filename:
                    continue
                src = os.path.join(imageset_path, filename)
                if not os.path.isfile(src):
                    continue
                scale = img.get("scale", "1x")
                ext = os.path.splitext(filename)[1] or ".png"
                suffix = "" if scale == "1x" else f"@{scale}"
                dst = os.path.join(resources_dir, f"{name}{suffix}{ext}")
                shutil.copy2(src, dst)
                copied_scales[scale] = dst
            # Ensure a base 1x filename also exists if only @2x/@3x was specified
            if "1x" not in copied_scales and copied_scales:
                fallback_src = copied_scales.get("2x") or next(iter(copied_scales.values()))
                ext = os.path.splitext(fallback_src)[1] or ".png"
                shutil.copy2(fallback_src, os.path.join(resources_dir, f"{name}{ext}"))

# 2. Build AppIcon.icns via iconutil
appiconset_dir = os.path.join(xcassets_dir, "AppIcon.appiconset")
appicon_contents = os.path.join(appiconset_dir, "Contents.json")
if os.path.isfile(appicon_contents):
    with open(appicon_contents, "r", encoding="utf-8") as f:
        icon_meta = json.load(f)
    with tempfile.TemporaryDirectory() as tmpdir:
        iconset_dir = os.path.join(tmpdir, "AppIcon.iconset")
        os.makedirs(iconset_dir, exist_ok=True)
        for img in icon_meta.get("images", []):
            filename = img.get("filename")
            size = img.get("size")
            scale = img.get("scale", "1x")
            if not filename or not size:
                continue
            src = os.path.join(appiconset_dir, filename)
            if not os.path.isfile(src):
                continue
            suffix = "" if scale == "1x" else f"@{scale}"
            dst_name = f"icon_{size}{suffix}.png"
            shutil.copy2(src, os.path.join(iconset_dir, dst_name))
        icns_out = os.path.join(resources_dir, "AppIcon.icns")
        subprocess.run(["/usr/bin/iconutil", "-c", "icns", iconset_dir, "-o", icns_out], check=True)

# 3. Compile Localizable.xcstrings into <lang>.lproj/Localizable.strings
xcstrings_path = os.path.join(project_dir, "Rectangle", "Localizable.xcstrings")
if os.path.isfile(xcstrings_path):
    with open(xcstrings_path, "r", encoding="utf-8") as f:
        catalog = json.load(f)

    source_lang = catalog.get("sourceLanguage", "en")
    strings_map = catalog.get("strings", {})
    by_lang = {}

    def escape_strings(val: str) -> str:
        return (
            val.replace("\\", "\\\\")
            .replace('"', '\\"')
            .replace("\n", "\\n")
            .replace("\r", "\\r")
            .replace("\t", "\\t")
        )

    for key, entry in strings_map.items():
        if not key:
            continue
        locs = entry.get("localizations", {})
        by_lang.setdefault(source_lang, {})[key] = key
        for lang, loc_obj in locs.items():
            unit = loc_obj.get("stringUnit")
            if unit and "value" in unit:
                by_lang.setdefault(lang, {})[key] = unit["value"]

    for lang, kv in by_lang.items():
        lproj_dir = os.path.join(resources_dir, f"{lang}.lproj")
        os.makedirs(lproj_dir, exist_ok=True)
        out_file = os.path.join(lproj_dir, "Localizable.strings")
        with open(out_file, "w", encoding="utf-8") as out:
            for k in sorted(kv.keys()):
                out.write(f'"{escape_strings(k)}" = "{escape_strings(kv[k])}";\n')
PYEOF

echo "=== [4/5] Writing Info.plist ==="
cat > "${APP_BUNDLE}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>en</string>
	<key>CFBundleExecutable</key>
	<string>Rectangle</string>
	<key>CFBundleIconFile</key>
	<string>AppIcon</string>
	<key>CFBundleIdentifier</key>
	<string>com.knollsoft.Rectangle</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>Rectangle</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>${RECTANGLE_VERSION}</string>
	<key>CFBundleURLTypes</key>
	<array>
		<dict>
			<key>CFBundleURLSchemes</key>
			<array>
				<string>rectangle</string>
			</array>
		</dict>
	</array>
	<key>CFBundleVersion</key>
	<string>${RECTANGLE_BUILD}</string>
	<key>GitHubRepositoryURL</key>
	<string>https://github.com/hungmtuci/Rectangle</string>
	<key>LSApplicationCategoryType</key>
	<string>public.app-category.productivity</string>
	<key>LSMinimumSystemVersion</key>
	<string>14.0</string>
	<key>LSUIElement</key>
	<true/>
	<key>NSHumanReadableCopyright</key>
	<string>Copyright © 2019-2026 Ryan Hanson. Custom Edition: hungmtuci/Rectangle.</string>
	<key>NSPrincipalClass</key>
	<string>NSApplication</string>
</dict>
</plist>
PLIST

echo "=== [5/5] Code-signing & Packaging ${APP_NAME}.app ==="
TMP_SIGN_DIR="/tmp/rectangle_sign_$$"
rm -rf "${TMP_SIGN_DIR}"
mkdir -p "${TMP_SIGN_DIR}"
cp -R "${APP_BUNDLE}" "${TMP_SIGN_DIR}/${APP_NAME}.app"
chmod -R u+w "${TMP_SIGN_DIR}/${APP_NAME}.app" 2>/dev/null || true
xattr -cr "${TMP_SIGN_DIR}/${APP_NAME}.app" 2>/dev/null || true
codesign --force --deep --sign - "${TMP_SIGN_DIR}/${APP_NAME}.app"
codesign --verify --deep --strict "${TMP_SIGN_DIR}/${APP_NAME}.app"

mkdir -p "${DIST_DIR}"
VERSIONED_ZIP="${DIST_DIR}/${APP_NAME}-v${RECTANGLE_VERSION}-macOS.zip"
LATEST_ZIP="${DIST_DIR}/${APP_NAME}.zip"
rm -f "${VERSIONED_ZIP}" "${LATEST_ZIP}"
/usr/bin/ditto -c -k --norsrc --keepParent "${TMP_SIGN_DIR}/${APP_NAME}.app" "${VERSIONED_ZIP}"
cp -f "${VERSIONED_ZIP}" "${LATEST_ZIP}"

rm -rf "${APP_BUNDLE}"
cp -R -X "${TMP_SIGN_DIR}/${APP_NAME}.app" "${APP_BUNDLE}"

INSTALLED_IN_APPLICATIONS=0
if [[ "${SKIP_INSTALL}" == "0" ]]; then
    rm -rf "${WORKSPACE_APP_BUNDLE}"
    cp -R -X "${TMP_SIGN_DIR}/${APP_NAME}.app" "${WORKSPACE_APP_BUNDLE}"
    sleep 0.5
    xattr -cr "${APP_BUNDLE}" "${WORKSPACE_APP_BUNDLE}" 2>/dev/null || true

    if [[ -w "/Applications" ]]; then
        killall "${APP_NAME}" 2>/dev/null || true
        sleep 0.2
        rm -rf "/Applications/${APP_NAME}.app"
        cp -R -X "${TMP_SIGN_DIR}/${APP_NAME}.app" "/Applications/${APP_NAME}.app"
        xattr -cr "/Applications/${APP_NAME}.app" 2>/dev/null || true
        INSTALLED_IN_APPLICATIONS=1
    fi
else
    xattr -cr "${APP_BUNDLE}" 2>/dev/null || true
fi
rm -rf "${TMP_SIGN_DIR}"

echo "Built successfully:"
echo "  - ${APP_BUNDLE}"
echo "  - ${VERSIONED_ZIP}"
if [[ "${SKIP_INSTALL}" == "0" ]]; then
    echo "  - ${WORKSPACE_APP_BUNDLE}"
    if [[ "${INSTALLED_IN_APPLICATIONS}" == "1" ]]; then
        echo "  - /Applications/${APP_NAME}.app"
    fi
fi
