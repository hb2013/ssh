#!/bin/bash
# 停止监听并移除开机自启（项目文件保留，重装只需再跑 ./setup.sh）
set -uo pipefail
PLIST="$HOME/Library/LaunchAgents/com.local.clip-watch.plist"
launchctl unload "$PLIST" >/dev/null 2>&1 || true
rm -f "$PLIST"
pkill -f "clip-watch\.sh" >/dev/null 2>&1 || true
echo "✅ 已停止并移除开机自启。项目文件保留在 $(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
