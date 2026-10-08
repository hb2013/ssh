#!/bin/bash
# 手动版：把本机剪贴板里的图片一键同步到远程 Mac 的剪贴板
# 用法: ./clip-forward.sh [user@host]    （不带参数则使用 config 里配置的地址）
# 同步完成后，在远程 codex 里按 Ctrl+V 即可粘贴图片（和本机操作一样）
#
# 支持的图片来源:
#   ① 截图 Cmd+Ctrl+Shift+4（PNG 数据）
#   ② 浏览器等 App 里右键「拷贝图像」（TIFF 数据，自动转 PNG）
#   ③ Finder 里右键「拷贝」图片文件（文件引用，自动转 PNG；多选只取第一张）
set -euo pipefail

# 强制合法的 UTF-8 locale（macOS 自带 bash 3.2 解析中文会出错）
export LC_ALL=en_US.UTF-8

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
if [ -f "$DIR/config" ]; then . "$DIR/config"; fi

HOST="${1:-${REMOTE_HOST:-}}"
if [[ -z "$HOST" ]]; then
  echo "❗ 还没有配置远程地址。请先运行: $DIR/setup.sh （或直接运行: $0 user@远程主机）"
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

LOCAL_TMP="$(mktemp -t clipfwd).png"
REMOTE_TMP="/tmp/clip-forwarded.png"

# 1) 本机剪贴板 -> PNG 文件
if ! extract_png "$LOCAL_TMP"; then
  echo "❌ 本机剪贴板里没有图片。支持: 截图(Cmd+Ctrl+Shift+4) / App内右键拷贝图像 / Finder拷贝图片文件"
  exit 1
fi

# 2) 一条 SSH 通道完成：传输文件 + 设置远程 Mac 剪贴板
if cat "$LOCAL_TMP" | ssh -o BatchMode=yes -o ConnectTimeout=5 "$HOST" "cat > '$REMOTE_TMP' && osascript -e \"set the clipboard to (read (POSIX file \\\"$REMOTE_TMP\\\") as «class PNGf»)\"" 2>/dev/null; then
  rm -f "$LOCAL_TMP"
  echo "✅ 已同步到 ${HOST} 的剪贴板，去 codex 里按 Ctrl+V 粘贴吧"
else
  rm -f "$LOCAL_TMP"
  echo "❌ 同步失败，请检查: ① 远程 Mac 是否在线 ② 能否 ssh $HOST 免密登录"
  exit 1
fi
