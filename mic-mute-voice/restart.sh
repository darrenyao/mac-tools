#!/bin/zsh
# 改完配置或授完权限后运行，让它生效
launchctl kickstart -k gui/$(id -u)/io.github.darrenyao.mic-mute-voice && echo "已重启"
