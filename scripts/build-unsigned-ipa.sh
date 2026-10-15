#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT/ios"
xcodegen generate
# Prefer a scheme build so Swift package host tools are built automatically.
# DIRECT_SDK supports Xcode installations with an SDK but no platform runtime.
if [ "${AGENTMUX_DIRECT_SDK:-0}" = 1 ]; then
    xcodebuild -resolvePackageDependencies -project AgentMux.xcodeproj -clonedSourcePackagesDirPath "$ROOT/build/device/SourcePackages"
    mkdir -p "$ROOT/build/device-direct/Release"
    swiftc -parse-as-library -module-cache-path "$ROOT/build/swift-module-cache" \
        "$ROOT/build/device/SourcePackages/checkouts/SwiftTerm/Sources/SwiftTermBuildInfoGenerator/BuildInfoGenerator.swift" \
        -o "$ROOT/build/device-direct/Release/SwiftTermBuildInfoGenerator"
    xcodebuild -skipPackagePluginValidation -project AgentMux.xcodeproj -target AgentMux -configuration Release -sdk iphoneos \
        SYMROOT="$ROOT/build/device-direct" CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build
    APP="$ROOT/build/device-direct/Release-iphoneos/AgentMux.app"
else
    xcodebuild -skipPackagePluginValidation -project AgentMux.xcodeproj -scheme AgentMux -configuration Release -destination generic/platform=iOS -derivedDataPath "$ROOT/build/device" CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build
    APP="$ROOT/build/device/Build/Products/Release-iphoneos/AgentMux.app"
fi
mkdir -p "$ROOT/dist"
STAGING=$(mktemp -d)
trap 'rm -rf "$STAGING"' EXIT
mkdir -p "$STAGING/Payload"
cp -R "$APP" "$STAGING/Payload/"
rm -f "$ROOT/dist/AgentMux-unsigned.ipa"
(cd "$STAGING" && /usr/bin/zip -qry "$ROOT/dist/AgentMux-unsigned.ipa" Payload)
(cd "$ROOT/dist" && shasum -a 256 AgentMux-unsigned.ipa > AgentMux-unsigned.ipa.sha256)
printf '\nUnsigned IPA: %s\n' "$ROOT/dist/AgentMux-unsigned.ipa"
