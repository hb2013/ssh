#!/bin/bash
# SSH 截图粘贴助手 · 一键安装向导
# 在任何一台 Mac 上运行一次：自动配置免密登录、保存远程地址、安装开机自启
# 之后这台 Mac 就能: 截图 -> 自动同步到远程 Mac 剪贴板 -> 远程 codex 里 Ctrl+V 贴图
set -euo pipefail

# 强制合法的 UTF-8 locale：macOS 自带 bash 3.2 在无效 locale（如 C.UTF-8）下
# 解析「$变量+中文」相邻的字符串会报错；en_US.UTF-8 是 macOS 必有的合法 locale
export LC_ALL=en_US.UTF-8

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLIST="$HOME/Library/LaunchAgents/com.local.clip-watch.plist"
SSHOPTS=(-o BatchMode=yes -o ConnectTimeout=5)

echo "════════════════════════════════════════════"
echo "  SSH 截图粘贴助手 · 安装向导"
echo "════════════════════════════════════════════"

# ── ① 询问远程地址 ─────────────────────────────
OLD_HOST=""
# shellcheck disable=SC1091
if [ -f "$DIR/config" ]; then . "$DIR/config"; fi
OLD_HOST="${REMOTE_HOST:-}"
if [[ -n "$OLD_HOST" ]]; then
  read -r -p "① 远程 Mac 的 SSH 地址（回车沿用: ${OLD_HOST}）: " HOST_IN
  HOST_IN="${HOST_IN:-$OLD_HOST}"
else
  read -r -p "① 远程 Mac 的 SSH 地址（格式 user@host，如 huangbin@192.168.1.5）: " HOST_IN
fi
if [[ -z "$HOST_IN" ]]; then echo "❌ 地址为空，退出"; exit 1; fi

# ── ② 确保 SSH 密钥存在 ────────────────────────
if ! ls ~/.ssh/id_ed25519.pub >/dev/null 2>&1 && ! ls ~/.ssh/id_rsa.pub >/dev/null 2>&1; then
  echo "② 未发现 SSH 密钥，自动生成..."
  ssh-keygen -t ed25519 -N "" -f ~/.ssh/id_ed25519 -q
else
  echo "② SSH 密钥已存在 ✓"
fi

# ── ③ 免密授权（需要输入一次远程密码）─────────
echo "③ 免密授权（已授权过会直接跳过；需要时输入一次远程密码）..."
ssh-copy-id "$HOST_IN" 2>/dev/null || echo "   （ssh-copy-id 未成功，可能已授权过，继续验证...）"

# ── ④ 验证免密登录 ────────────────────────────
echo "④ 验证免密登录..."
if ! ssh "${SSHOPTS[@]}" "$HOST_IN" true 2>/dev/null; then
  echo "❌ 免密登录失败。请手动执行: ssh-copy-id $HOST_IN 然后重跑 ./setup.sh"
  exit 1
fi
echo "   ✅ 免密登录 OK"

# ── ⑤ 端到端链路测试（真实传一张小图并读回）───
echo "⑤ 端到端链路测试（会在远程剪贴板放一张测试小图）..."
TESTPNG="$(find /System/Library/Desktop\ Pictures -name '*.png' 2>/dev/null | head -1)"
if [[ -n "$TESTPNG" ]]; then
  cat "$TESTPNG" | ssh "${SSHOPTS[@]}" "$HOST_IN" "cat > /tmp/_cliptest.png && osascript -e \"set the clipboard to (read (POSIX file \\\"/tmp/_cliptest.png\\\") as «class PNGf»)\"" >/dev/null 2>&1 || true
  BYTES="$(ssh "${SSHOPTS[@]}" "$HOST_IN" "osascript -e \"set pngData to (the clipboard as «class PNGf»)
return (length of pngData)\"" 2>/dev/null || true)"
  if [[ "$BYTES" =~ ^[0-9]+$ ]] && [[ "$BYTES" -gt 0 ]]; then
    echo "   ✅ 图片链路 OK（远程剪贴板读写正常，$BYTES 字节）"
  else
    echo "   ⚠️ 远程剪贴板读写未通过（远程 Mac 可能未登录/刚重启），可稍后重跑 ./setup.sh"
  fi
else
  echo "   （跳过：本机未找到测试图片）"
fi

# ── ⑥ 保存配置 ────────────────────────────────
echo "REMOTE_HOST=\"$HOST_IN\"" > "$DIR/config"
echo "⑥ 已保存地址到 $DIR/config"

# ── ⑦ 安装开机自启（launchd）─────────────────
# macOS 隐私保护(TCC): 「桌面/文稿/下载」里的文件，后台 launchd 任务无权访问，
# 放在这些位置的脚本装了自启也无法运行（日志会一直报 Operation not permitted）
PROTECTED=""
for _p in "$HOME/Desktop" "$HOME/Documents" "$HOME/Downloads"; do
  if [[ "$DIR" == "$_p" || "$DIR" == "$_p"/* ]]; then PROTECTED="$_p"; break; fi
done

if [[ -n "$PROTECTED" ]]; then
  echo "⑦ ⚠️ 跳过开机自启安装"
  echo "   原因: 项目位于 ${PROTECTED} 下，macOS 不允许后台任务访问该文件夹，"
  echo "         装了自启也不会工作（日志会一直报 Operation not permitted）。"
  echo "   免密/地址/链路测试已配置完成，手动模式(clip-forward.sh)不受影响、可正常使用。"
  echo "   想启用全自动: 把项目挪到非保护目录后重跑本脚本，例如:"
  echo "     mv \"$DIR\" ~/clip-sync && cd ~/clip-sync && ./setup.sh"
  AUTO_MODE="no"
else
  echo "⑦ 安装开机自启..."
  pkill -f "clip-watch\.sh" >/dev/null 2>&1 || true   # 停掉手动跑着的旧实例
  launchctl unload "$PLIST" >/dev/null 2>&1 || true
  mkdir -p "$(dirname "$PLIST")"
  cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.local.clip-watch</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>$DIR/clip-watch.sh</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>$DIR/clip-watch.log</string>
    <key>StandardErrorPath</key>
    <string>$DIR/clip-watch.log</string>
</dict>
</plist>
EOF
  launchctl load "$PLIST"
  sleep 1
  if launchctl list 2>/dev/null | grep -q "com.local.clip-watch"; then
    echo "   ✅ 已启动，并设置为开机自动运行"
    AUTO_MODE="yes"
  else
    echo "   ⚠️ 自启加载失败，可手动执行: launchctl load $PLIST"
    AUTO_MODE="yes"
  fi
fi

echo ""
if [[ "$AUTO_MODE" == "yes" ]]; then
  echo "🎉 安装完成！现在就试试："
  echo "   1. 本机 Cmd+Ctrl+Shift+4 截图（带 Ctrl 的组合，图直接进剪贴板）"
  echo "   2. 等 1~2 秒（可看日志: tail -f $DIR/clip-watch.log）"
  echo "   3. 到远程 codex 里按 Ctrl+V 贴图"
else
  echo "🎉 手动模式配置完成！用法: 截图后运行 $DIR/clip-forward.sh，再到远程 codex 里 Ctrl+V"
fi
