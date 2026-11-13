#!/usr/bin/env bash
set -euo pipefail
command -v xcodebuild >/dev/null || { echo 'Requiere un Mac con Xcode instalado' >&2; exit 2; }
command -v xcodegen >/dev/null || { echo 'Instala XcodeGen: brew install xcodegen' >&2; exit 2; }
cd "$(dirname "$0")"
xcodegen generate
xcodebuild -project FlipperControl.xcodeproj -scheme FlipperControl -sdk iphoneos -configuration Release -destination 'generic/platform=iOS' -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build
mkdir -p build/Payload
cp -R build/DerivedData/Build/Products/Release-iphoneos/FlipperControl.app build/Payload/
(cd build && zip -q -r FlipperControl-unsigned.ipa Payload)
echo "IPA sin firmar: $(pwd)/build/FlipperControl-unsigned.ipa"
