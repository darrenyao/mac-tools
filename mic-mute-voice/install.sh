#!/bin/zsh
# 编译 → 装到 ~/Applications → 生成配置（已有则保留）→ 设为登录后自动运行
set -e
cd "${0:A:h}"
LABEL=io.github.darrenyao.mic-mute-voice
APP=~/Applications/MicMuteVoice.app
PLIST=~/Library/LaunchAgents/$LABEL.plist
CONF=~/.config/mic-mute-voice/config.json

./build.sh
launchctl bootout gui/$(id -u)/$LABEL 2>/dev/null || true
mkdir -p ~/Applications && rm -rf $APP && cp -R build/MicMuteVoice.app $APP
mkdir -p ${CONF:h}; [[ -f $CONF ]] || cp config.example.json $CONF
cat > $PLIST <<P
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array><string>$APP/Contents/MacOS/MicMuteVoice</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ProcessType</key><string>Interactive</string>
</dict></plist>
P
launchctl bootstrap gui/$(id -u) $PLIST
echo "已安装并启动。配置文件：$CONF"
echo "第一次安装：请允许麦克风权限，并在 系统设置 → 隐私与安全性 → 辅助功能 里打开 MicMuteVoice，然后运行 ./restart.sh"
