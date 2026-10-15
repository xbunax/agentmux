#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT/ios"
xcodegen generate
# Direct target build requires the device SDK but not a simulator runtime/destination.
xcodebuild -skipPackagePluginValidation -project AgentMux.xcodeproj -target AgentMux -configuration Release -sdk iphoneos SYMROOT="$ROOT/build/direct" CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build
mkdir -p "$ROOT/dist"
STAGING=$(mktemp -d)
trap 'rm -rf "$STAGING"' EXIT
mkdir -p "$STAGING/Payload"
cp -R "$ROOT/build/direct/Release-iphoneos/AgentMux.app" "$STAGING/Payload/"
rm -f "$ROOT/dist/AgentMux-unsigned.ipa"
(cd "$STAGING" && /usr/bin/zip -qry "$ROOT/dist/AgentMux-unsigned.ipa" Payload)
(cd "$ROOT/dist" && shasum -a 256 AgentMux-unsigned.ipa > AgentMux-unsigned.ipa.sha256)
printf '\nUnsigned IPA: %s\n' "$ROOT/dist/AgentMux-unsigned.ipa"
