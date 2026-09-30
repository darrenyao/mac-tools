# mac-tools

我自己在 macOS 上用的小工具，每个工具一个目录，各自带 README 和安装、卸载脚本。

| 工具 | 做什么 |
|---|---|
| [mic-mute-voice](mic-mute-voice/) | 用麦克风的静音键开关语音输入法（比如豆包输入法），不用碰键盘 |

## 约定

- 每个工具装在固定位置：程序放 `~/Applications`，配置放 `~/.config/<工具名>/`，日志放 `~/Library/Logs/`。
- 每个工具目录下都有 `install.sh` 和 `uninstall.sh`。卸载后除了源码，什么都不留。
