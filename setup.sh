#!/bin/bash
# SSH 截图粘贴助手 · 一键安装向导
# 在任何一台 Mac 上运行一次：自动配置免密（自动探测非默认名密钥）、
# 保存远程地址（支持多台）、安装开机自启
# 之后这台 Mac 就能: 截图 -> 自动同步到远程 Mac 剪贴板 -> 远程 codex 里 Ctrl+V 贴图
set -euo pipefail

# 强制合法的 UTF-8 locale：macOS 自带 bash 3.2 在无效 locale（如 C.UTF-8）下
# 解析「$变量+中文」字符串会报错；en_US.UTF-8 是 macOS 必有的合法 locale
export LC_ALL=en_US.UTF-8

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLIST="$HOME/Library/LaunchAgents/com.local.clip-watch.plist"
SSHOPTS=(-o BatchMode=yes -o ConnectTimeout=5)

echo "════════════════════════════════════════════"
echo "  SSH 截图粘贴助手 · 安装向导"
echo "════════════════════════════════════════════"

# ── ① 询问远程地址（支持多个，空格分隔）────────
REMOTE_HOSTS=()
REMOTE_KEYS=()
REMOTE_HOST=""
# shellcheck disable=SC1091
if [ -f "$DIR/config" ]; then . "$DIR/config"; fi
OLD_LIST=""
if [[ ${#REMOTE_HOSTS[@]} -gt 0 ]]; then OLD_LIST="${REMOTE_HOSTS[*]}"; fi
if [[ -n "${REMOTE_HOST:-}" ]]; then OLD_LIST="${OLD_LIST:+$OLD_LIST }$REMOTE_HOST"; fi
HOSTS_IN=""
if [[ -n "$OLD_LIST" ]]; then
  read -r -p "① 远程 Mac 的 SSH 地址（多个用空格分隔，回车沿用: ${OLD_LIST}）: " HOSTS_IN
  HOSTS_IN="${HOSTS_IN:-$OLD_LIST}"
else
  read -r -p "① 远程 Mac 的 SSH 地址（格式 user@host，多个用空格分隔）: " HOSTS_IN
fi
read -ra HOSTS <<< "$HOSTS_IN"
if [[ ${#HOSTS[@]} -eq 0 ]]; then echo "❌ 地址为空，退出"; exit 1; fi

# ── ② 确保本机有 SSH 密钥 ────────────────────
if ! ls ~/.ssh/id_ed25519.pub >/dev/null 2>&1 && ! ls ~/.ssh/id_rsa.pub >/dev/null 2>&1; then
  echo "② 未发现默认 SSH 密钥，自动生成..."
  ssh-keygen -t ed25519 -N "" -f ~/.ssh/id_ed25519 -q
else
  echo "② SSH 密钥已存在 ✓"
fi

# ── ③④⑤ 逐台: 免密验证(自动探测密钥) + 授权 + 链路测试 ──
TESTPNG="$(find /System/Library/Desktop\ Pictures -name '*.png' 2>/dev/null | head -1)"
FAIL_LIST=" "
HOST_KEYS=()
for idx in "${!HOSTS[@]}"; do
  HOST_IN="${HOSTS[$idx]}"
  echo "── 目标: $HOST_IN ──"

  echo "③ 验证免密登录..."
  KEY_FOUND=""
  if OUT="$(ssh "${SSHOPTS[@]}" "$HOST_IN" true 2>&1)"; then
    echo "   ✅ 免密登录 OK（默认密钥）"
  else
    # 默认密钥不行 -> 自动探测 ~/.ssh 下的所有密钥（含 id_rsa_server 等非默认名）
    echo "   默认方式未通过，自动探测本机可用密钥..."
    for kf in "$HOME"/.ssh/id_*; do
      case "$kf" in *.pub) continue ;; esac
      if [ -f "$kf" ] && ssh -i "$kf" -o IdentitiesOnly=yes "${SSHOPTS[@]}" "$HOST_IN" true >/dev/null 2>&1; then
        KEY_FOUND="$kf"
        echo "   ✅ 找到可用密钥: $kf"
        break
      fi
    done
    if [[ -z "$KEY_FOUND" ]]; then
      # 探测不到 -> 用 ssh-copy-id 安装默认公钥（需要输一次远程密码）
      echo "④ 未找到已授权的密钥，进行免密授权（需要时输入一次远程密码）..."
      ssh-copy-id "$HOST_IN" 2>/dev/null || echo "   （ssh-copy-id 未成功，继续最终验证...）"
      if OUT="$(ssh "${SSHOPTS[@]}" "$HOST_IN" true 2>&1)"; then
        echo "   ✅ 免密登录 OK（已安装默认密钥）"
      else
        echo "❌ 免密登录失败，错误详情:"
        echo "$OUT" | sed 's/^/     /'
        echo "   排查: ① 手动验证: ssh $HOST_IN ② 密钥有密码短语时先执行 ssh-add ~/.ssh/密钥"
        FAIL_LIST="$FAIL_LIST$HOST_IN "
        continue
      fi
    fi
  fi
  HOST_KEYS+=("$KEY_FOUND")

  echo "⑤ 端到端链路测试（会在远程剪贴板放一张测试小图）..."
  SARGS=("${SSHOPTS[@]}")
  if [[ -n "$KEY_FOUND" ]]; then SARGS+=(-i "$KEY_FOUND" -o IdentitiesOnly=yes); fi
  if [[ -n "$TESTPNG" ]]; then
    cat "$TESTPNG" | ssh "${SARGS[@]}" "$HOST_IN" "cat > /tmp/_cliptest.png && osascript -e \"set the clipboard to (read (POSIX file \\\"/tmp/_cliptest.png\\\") as «class PNGf»)\"" >/dev/null 2>&1 || true
    BYTES="$(ssh "${SARGS[@]}" "$HOST_IN" "osascript -e \"set pngData to (the clipboard as «class PNGf»)
return (length of pngData)\"" 2>/dev/null || true)"
    if [[ "$BYTES" =~ ^[0-9]+$ ]] && [[ "$BYTES" -gt 0 ]]; then
      echo "   ✅ 图片链路 OK（远程剪贴板读写正常，$BYTES 字节）"
    else
      echo "   ⚠️ 远程剪贴板读写未通过（远程 Mac 可能未登录/刚重启），可稍后重跑 ./setup.sh"
    fi
  else
    echo "   （跳过：本机未找到测试图片）"
  fi
done

# 剔除验证失败的目标
if [[ "$FAIL_LIST" != " " ]]; then
  echo ""
  echo "⚠️ 以下目标未通过免密验证，已从配置中剔除:${FAIL_LIST}"
  NEW_HOSTS=()
  NEW_KEYS=()
  for i in "${!HOSTS[@]}"; do
    h="${HOSTS[$i]}"
    case "$FAIL_LIST" in *" $h "*) ;; *) NEW_HOSTS+=("$h"); NEW_KEYS+=("${HOST_KEYS[$i]}") ;; esac
  done
  if [[ ${#NEW_HOSTS[@]} -eq 0 ]]; then
    echo "❌ 所有目标均未通过验证，退出。请修复后重跑"
    exit 1
  fi
  HOSTS=()
  HOST_KEYS=()
  for i in "${!NEW_HOSTS[@]}"; do HOSTS+=("${NEW_HOSTS[$i]}"); HOST_KEYS+=("${NEW_KEYS[$i]}"); done
fi

# ── ⑥ 保存配置（地址与密钥一一对应）───────────
CFG="REMOTE_HOSTS=("
for h in "${HOSTS[@]}"; do CFG+=" \"$h\""; done
CFG+=" )"
CFGK="REMOTE_KEYS=("
for k in "${HOST_KEYS[@]}"; do CFGK+=" \"$k\""; done
CFGK+=" )"
{ echo "# clip-sync 配置（由 setup.sh 自动生成；多个地址 = 一张图同步到多台）"
  echo "# REMOTE_KEYS 与 REMOTE_HOSTS 一一对应，\"\" 表示该台用默认密钥"
  echo "$CFG"
  echo "$CFGK"; } > "$DIR/config"
echo "⑥ 已保存 ${#HOSTS[@]} 个地址到 $DIR/config"

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
  else
    echo "   ⚠️ 自启加载失败，可手动执行: launchctl load $PLIST"
  fi
  AUTO_MODE="yes"
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
