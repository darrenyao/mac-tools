#!/bin/zsh
# 停止并删除：程序、登录启动项、配置、日志、权限记录（源码目录保留）
LABEL=io.github.darrenyao.mic-mute-voice
launchctl bootout gui/$(id -u)/$LABEL 2>/dev/null
rm -rf ~/Applications/MicMuteVoice.app ~/.config/mic-mute-voice
rm -f ~/Library/LaunchAgents/$LABEL.plist ~/Library/Logs/MicMuteVoice.log
tccutil reset All $LABEL >/dev/null 2>&1
echo "MicMuteVoice 已卸载"
