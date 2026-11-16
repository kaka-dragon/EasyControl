#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build/EasyControl.app/Contents/MacOS build/EasyControl.app/Contents/Resources
swiftc -O Sources/main.swift -o build/EasyControl.app/Contents/MacOS/EasyControl -framework Cocoa -framework ApplicationServices
cp Resources/AppIcon.icns build/EasyControl.app/Contents/Resources/AppIcon.icns
cat > build/EasyControl.app/Contents/Info.plist <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>local.easycontrol.app</string><key>CFBundleName</key><string>EasyControl</string><key>CFBundleExecutable</key><string>EasyControl</string><key>CFBundleIconFile</key><string>AppIcon</string><key>CFBundleVersion</key><string>1.0.0</string><key>CFBundleShortVersionString</key><string>1.0.0</string><key>LSUIElement</key><true/><key>NSHighResolutionCapable</key><true/></dict></plist>
PLIST
codesign --force --sign - build/EasyControl.app
