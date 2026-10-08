# SSH 截图粘贴助手（clip-sync）

解决「本机 SSH 到远程 Mac 用 codex，截图没法 Ctrl+V 粘贴」的问题。

**原理**：SSH 终端只传文本，codex 的 `Ctrl+V` 读的是**远程 Mac** 的剪贴板。
本项目把本机剪贴板里的图片同步到远程 Mac 的剪贴板，之后在远程 codex 里按
`Ctrl+V` 就和在本机操作完全一样。全程只用系统自带工具（ssh + osascript），
**不需要安装任何依赖**。

**前提**（两种方式都需要）：
- 本机、远程都是 macOS
- 远程 Mac 开启「远程登录」：系统设置 → 通用 → 共享 → 远程登录
- 远程 Mac 处于已登录状态（重启后停在锁屏界面时剪贴板服务不可用）

---

## 支持的图片来源（自动/手动都支持）

| 你的操作 | 剪贴板里的内容 | 处理方式 |
|---|---|---|
| 截图 `Cmd+Ctrl+Shift+4` | PNG 数据 | 直接同步 |
| 浏览器/App 内右键「拷贝图像」 | TIFF 数据 | 自动转 PNG 后同步 |
| Finder 右键「拷贝」图片文件 | 文件引用 | 仅图片格式（png/jpg/heic/tiff/gif 等），自动转 PNG 后同步；多选只取第一张 |

纯文本、文件夹、PDF 等非图片内容会被自动忽略，完全不影响正常的复制粘贴。

---

## 方式一：自动模式（推荐，装完零操作）

后台常驻监听，截图后自动同步，之后直接在 codex 里 `Ctrl+V`。

> ⚠️ **位置要求**：项目文件夹**不能放在「桌面 / 文稿 / 下载」里**。
> macOS 隐私保护不允许后台任务访问这些文件夹，放在其中的话自启会一直
> 静默失败（日志全是 `Operation not permitted`），手动模式则不受影响。
> 请放在普通目录，如 `~/clip-sync`。`setup.sh` 会自动检测并跳过自启安装、
> 给出迁移指引。

### 一次性安装

```bash
cd ssh
./setup.sh
```

安装向导会依次做：

1. 询问远程地址（`user@host` 格式，之后写入 `config`）
2. 本机没有 SSH 密钥则自动生成
3. `ssh-copy-id` 免密授权 —— **全程唯一一次输密码**
4. 验证免密登录
5. 端到端链路测试（真实往远程剪贴板放一张测试图并读回验证）
6. 安装 launchd 开机自启并立即启动

### 日常使用（什么都不用做）

1. 本机 `Cmd+Ctrl+Shift+4` 截图（**带 Ctrl** 的组合，图直接进剪贴板）
2. 等 1~2 秒
3. 远程 codex 里按 `Ctrl+V` 贴图

想确认同步状态就看日志：

```bash
tail -f clip-watch.log     # 会看到「✅ 新图片已同步」
```

### 特性

- **重启自动恢复**：launchd 托管，开机自动运行、意外退出自动拉起
- **远程关机/不在网零影响**：空闲时只做本地检测、不发网络请求；出现新图片
  才尝试连接，5 秒内放弃，同一张图每 30 秒重试一次；远程恢复后下一次截图自动续上

---

## 方式二：手动模式（不装后台）

不想常驻后台进程，就在需要时手动同步一条。**不需要跑 setup.sh**。

### 首次准备（一次性，输一次密码）

```bash
ssh-copy-id user@远程主机
```

### 用法 A：一次一贴

```bash
# 1. Cmd+Ctrl+Shift+4 截图（图进剪贴板）
./clip-forward.sh user@远程主机    # 2. 同步这一张
# 3. 到远程 codex 里 Ctrl+V
```

### 用法 B：临时开监听（前台窗口）

打开一个终端窗口跑着，期间和自动模式体验一样；关窗口或 `Ctrl+C` 即停，
不写配置、不装自启：

```bash
./clip-watch.sh user@远程主机     # Ctrl+C 退出
```

> 提示：如果之前跑过 `./setup.sh`，地址已存在 `config` 里，
> 上面两条命令都可以不带 `user@远程主机` 参数。

### 手动模式局限

- 电脑重启后要重新手动运行
- 忘了跑命令就去 Ctrl+V，贴到的是远程剪贴板里的旧图

---

## 两种方式对比

| | 方式一 · 自动 | 方式二 · 手动 |
|---|---|---|
| 安装 | `./setup.sh` 一次 | `ssh-copy-id` 一次 |
| 截图后 | 直接 `Ctrl+V`（自动同步） | 先跑一条命令再 `Ctrl+V` |
| 重启电脑后 | 自动恢复 | 需手动运行 |
| 后台进程 | 有（launchd 托管） | 无 |

两种方式可随时切换，互不冲突；自动模式想停用跑 `./uninstall.sh` 即可。

---

## 文件说明

| 文件 | 作用 |
|---|---|
| `setup.sh` | 一键安装向导（自动模式专用） |
| `clip-watch.sh` | 监听器：剪贴板出现新图片就同步（自启托管 / 也可前台手动跑） |
| `clip-forward.sh` | 手动同步当前剪贴板里的那一张图 |
| `config` | 地址配置：`REMOTE_HOST="user@host"`（**不入库**，由 setup.sh 生成或复制 `config.example`） |
| `clip-watch.log` | 运行日志（自动生成） |
| `uninstall.sh` | 停止并移除开机自启（不删项目文件） |

## 管理命令

```bash
tail -f clip-watch.log                                            # 看同步日志
launchctl list | grep clip-watch                                  # 看运行状态
launchctl unload ~/Library/LaunchAgents/com.local.clip-watch.plist  # 暂停自启
launchctl load   ~/Library/LaunchAgents/com.local.clip-watch.plist  # 恢复自启
./setup.sh                                      # 换远程地址 / 重装（重跑即可）
./clip-watch.sh user@other-host                 # 临时监听另一台（不改配置）
./uninstall.sh                                  # 彻底停用自启
```

## 常见问题

**能把 SSH 密码写进脚本/命令吗？**
不能，SSH 协议禁止命令行携带密码（安全设计）。用 `ssh-copy-id` / `setup.sh`
输**一次**密码完成密钥授权，之后永久免密——这也是后台自动运行的前提。

**截图跑到桌面上了？**
`Cmd+Shift+4` 是存成文件，监听不到。两个办法：
① 改用 `Cmd+Ctrl+Shift+4`（带 Ctrl），图直接进剪贴板；
② 在 Finder 里选中桌面上那张图，右键「拷贝」，同样会同步。

**在 codex 里按哪个键？**
`Ctrl+V`（不是 `Cmd+V`）——这是 codex 贴图的按键。

**远程 Mac 关机期间截的图会补送吗？**
不会，只同步「当前剪贴板里的图」。远程恢复在线后重新截一张即可。

**自动模式不工作 / 日志全是 Operation not permitted？**
项目放在了「桌面 / 文稿 / 下载」等受 macOS 保护的位置，后台 launchd
任务无权访问这些文件夹。把整个文件夹挪到普通目录（如 `~/clip-sync`），
重跑 `./setup.sh` 即可。

**换到另一台 Mac 用？**
把整个文件夹拷过去（AirDrop / U盘 / scp），跑一次 `./setup.sh` 即可，
无需改任何文件。
