#!/bin/zsh
# 编译并打包成 build/MicMuteVoice.app
set -e
cd "${0:A:h}"
APP=build/MicMuteVoice.app
rm -rf $APP && mkdir -p $APP/Contents/MacOS
cat > $APP/Contents/Info.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>io.github.darrenyao.mic-mute-voice</string>
  <key>CFBundleName</key><string>MicMuteVoice</string>
  <key>CFBundleExecutable</key><string>MicMuteVoice</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSMinimumSystemVersion</key><string>14.2</string>
  <key>LSUIElement</key><true/>
  <key>NSMicrophoneUsageDescription</key><string>检测麦克风是否被静音，用来开关语音输入法。</string>
</dict></plist>
PLIST
swiftc -O main.swift -o $APP/Contents/MacOS/MicMuteVoice
codesign --force --sign - $APP
echo "已编译：$PWD/$APP"
