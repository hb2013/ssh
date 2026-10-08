#!/bin/bash
# 后台监听本机剪贴板：一旦出现新图片，自动同步到远程 Mac 的剪贴板
# 用法: ./clip-watch.sh [user@host]    （不带参数则使用 config 里配置的地址）
# 首次使用请先运行: ./setup.sh
#
# 支持的图片来源:
#   ① 截图 Cmd+Ctrl+Shift+4（PNG 数据）
#   ② 浏览器等 App 里右键「拷贝图像」（TIFF 数据，自动转 PNG）
#   ③ Finder 里右键「拷贝」图片文件（文件引用，自动转 PNG；多选只取第一张）
#
# 远程不在线（关机/不在网）时: 本机零影响。空闲时只做本地剪贴板检测、不发网络请求；
# 只有出现新图片才尝试连接，失败后同一张图每 30 秒重试一次，远程恢复后自动续上。
set -uo pipefail

# 强制合法的 UTF-8 locale（launchd 环境无 LANG，bash 3.2 解析中文会出错）
export LC_ALL=en_US.UTF-8

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
if [ -f "$DIR/config" ]; then . "$DIR/config"; fi

HOST="${1:-${REMOTE_HOST:-}}"
if [[ -z "$HOST" ]]; then
  echo "❗ 还没有配置远程地址。请先运行: $DIR/setup.sh"
  exit 1
fi

# 从剪贴板提取图片，保存为 PNG 文件（成功返回 0，失败返回 1）
# 依次尝试: PNG 数据 -> TIFF 数据(sips 转 PNG) -> 图片文件引用(sips 转 PNG)
extract_png() {
  local out="$1" tif src
  # ① PNG 数据（截图、部分 App 拷贝）
  if osascript -e "
    set d to (the clipboard as «class PNGf»)
    set f to open for access (POSIX file \"$out\") with write permission
    write d to f
    close access f" >/dev/null 2>&1; then
    return 0
  fi
  # ② TIFF 数据（浏览器右键「拷贝图像」等），转成 PNG
  tif="${out%.png}.tiff"
  if osascript -e "
    set d to (the clipboard as «class TIFF»)
    set f to open for access (POSIX file \"$tif\") with write permission
    write d to f
    close access f" >/dev/null 2>&1; then
    if sips -s format png "$tif" --out "$out" >/dev/null 2>&1; then
      rm -f "$tif"
      return 0
    fi
    rm -f "$tif"
  fi
  # ③ 文件引用（Finder 右键「拷贝」图片文件），仅接受图片格式，转成 PNG
  src="$(osascript -e 'try
    return POSIX path of (the clipboard as «class furl»)
  on error
    return ""
  end try' 2>/dev/null || true)"
  if [[ -n "$src" && -f "$src" ]]; then
    mime="$(file -b --mime-type "$src" 2>/dev/null || true)"
    if [[ "$mime" == image/* ]] && sips -s format png "$src" --out "$out" >/dev/null 2>&1; then
      return 0
    fi
  fi
  return 1
}

# ConnectTimeout=5: 远程关机时最多等 5 秒就放弃，不会卡住
# ControlMaster 复用连接，每次同步只需几十毫秒；BatchMode 避免卡在密码提示
SSH_OPTS=(-o ControlMaster=auto -o "ControlPath=$HOME/.ssh/cm-%r@%h-%p" -o ControlPersist=10m -o BatchMode=yes -o ConnectTimeout=5)
REMOTE_TMP="/tmp/clip-forwarded.png"
LAST_HASH=""      # 最近一次成功同步的图片(PNG内容)
FAILED_HASH=""    # 最近一次同步失败的图片
FAILED_AT=0       # 上次失败(或重试)的时间戳
RETRY_INTERVAL=30 # 同一张图失败后，每隔 30 秒重试一次
FAILED_STATE=""   # 剪贴板状态指纹: 提取不出图片时(如拷贝了PDF/文件夹)记录，状态不变就不再反复尝试

echo "👀 正在监听本机剪贴板图片（每秒检查，Ctrl+C 退出）"
echo "   目标: $HOST"
echo "   支持: 截图 / App 内右键拷贝图像 / Finder 右键拷贝图片文件"
echo "   远程不在线也没关系: 不影响本机，恢复在线后下一次截图自动续上"

while true; do
  INFO="$(osascript -e 'clipboard info' 2>/dev/null || true)"
  if [[ "$INFO" == *"PNGf"* || "$INFO" == *TIFF* || "$INFO" == *"furl"* ]]; then
    STATE="$(md5 -qs "$INFO")"
    if [[ "$STATE" != "$FAILED_STATE" ]]; then
      TMP="$(mktemp -t clipfwd).png"
      if extract_png "$TMP"; then
        HASH="$(md5 -q "$TMP")"
        NOW="$(date +%s)"
        if [[ "$HASH" != "$LAST_HASH" ]]; then
          SKIP=0
          # 同一张图刚失败过且还没到重试间隔 -> 先跳过，避免每秒重试刷屏
          if [[ "$HASH" == "$FAILED_HASH" && $(( NOW - FAILED_AT )) -lt $RETRY_INTERVAL ]]; then
            SKIP=1
          fi
          if [[ "$SKIP" -eq 0 ]]; then
            if cat "$TMP" | ssh "${SSH_OPTS[@]}" "$HOST" "cat > '$REMOTE_TMP' && osascript -e \"set the clipboard to (read (POSIX file \\\"$REMOTE_TMP\\\") as «class PNGf»)\"" >/dev/null 2>&1; then
              LAST_HASH="$HASH"
              FAILED_HASH=""
              echo "$(date '+%H:%M:%S') ✅ 新图片已同步到 ${HOST}（可以在 codex 里 Ctrl+V 了）"
            else
              FAILED_HASH="$HASH"
              FAILED_AT="$NOW"
              echo "$(date '+%H:%M:%S') ⚠️ 连不上 ${HOST}（远程关机/不在网？）本机不受影响，30 秒后自动重试"
            fi
          fi
        fi
        rm -f "$TMP"
      else
        # 剪贴板里虽然有文件/数据，但不是能转换的图片（如 PDF、文件夹）
        FAILED_STATE="$STATE"
        rm -f "$TMP"
      fi
    fi
  fi
  sleep 1
done
