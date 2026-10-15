#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT/ios"
xcodegen generate
# Scheme builds include the host-side Swift package build tools used by SwiftTerm.
# A generic iOS destination needs no attached iPhone or simulator runtime.
xcodebuild -skipPackagePluginValidation -project AgentMux.xcodeproj -scheme AgentMux -configuration Release -destination generic/platform=iOS -derivedDataPath "$ROOT/build/device" CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build
mkdir -p "$ROOT/dist"
STAGING=$(mktemp -d)
trap 'rm -rf "$STAGING"' EXIT
mkdir -p "$STAGING/Payload"
cp -R "$ROOT/build/device/Build/Products/Release-iphoneos/AgentMux.app" "$STAGING/Payload/"
rm -f "$ROOT/dist/AgentMux-unsigned.ipa"
(cd "$STAGING" && /usr/bin/zip -qry "$ROOT/dist/AgentMux-unsigned.ipa" Payload)
(cd "$ROOT/dist" && shasum -a 256 AgentMux-unsigned.ipa > AgentMux-unsigned.ipa.sha256)
printf '\nUnsigned IPA: %s\n' "$ROOT/dist/AgentMux-unsigned.ipa"
