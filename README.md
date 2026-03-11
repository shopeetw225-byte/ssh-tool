# ssh-tool (Customer Remote Support)

目标：让顾客运行一个脚本，就能在 **默认安全** 的前提下把 SSH 临时开给支持人员连接（默认不对局域网开放，只通过 `bore` 穿透），并且到期自动回收/恢复配置。

仓库包含两个平台的脚本：

- `packages/ssh-tool-win/remote-support.ps1`：Windows（OpenSSH Server + `bore.exe`）
- `packages/ssh-tool-mac/remote-support.sh`：macOS（Remote Login/sshd + `bore`）

## 下载与安装（给用户）

请从 GitHub Releases 下载对应平台的安装包（不要直接下载仓库源码压缩包）：

- Windows x64（推荐）：`ssh-tool-win.exe`
- Windows ARM64：`ssh-tool-win-arm64.exe`
- Windows 脚本版：`ssh-tool-win.zip`
- macOS（推荐）：`ssh-tool-mac.dmg`（内含 `SSH Tool.app`）
- macOS 脚本版：`ssh-tool-mac.zip`

常见提示：

- Windows：如果被 SmartScreen 拦截，点「更多信息」→「仍要运行」。
- macOS：如果提示“Apple 无法验证/已损坏/无法打开”，可右键 `SSH Tool.app` → Open，或执行：`sudo xattr -dr com.apple.quarantine "/Applications/SSH Tool.app"`

## 安全关闭（务必做）

远程支持结束后，请按下面顺序“彻底关闭并恢复配置”（仅断开 SSH 连接**不会**自动关闭隧道/服务）。

✅ 一、先关闭「远程连接窗口」（支持人员这边）

在你当前的 SSH 窗口输入：

```bash
exit
```

👉 这一步只是断开远程控制，不会关闭服务。

✅ 二、去被支持的那台电脑关闭会话（最重要 ⭐）

### Windows（被支持端）

在 SSH Tool 页面点击：

- `停止（恢复配置）`

点击后工具会自动：

- 删除临时用户 `support_****`
- 停止 `sshd`
- 关闭 `bore` 隧道
- 恢复 `sshd_config` / `authorized_keys` 等配置

日志出现类似：

`Session stopped and configuration restored.`

表示已彻底关闭。

如果页面卡住 / 按钮点不了：

- 先点：`Recover（兜底清理）`
- 或在管理员 PowerShell 执行：`.\ssh-tool-win.exe recover`

最极端情况（手动关闭，管理员 PowerShell）：

```powershell
Stop-Service sshd -ErrorAction SilentlyContinue
taskkill /f /im bore.exe
# 把 support_**** 换成页面/日志里显示的临时用户名
net user support_**** /delete
```

### macOS（被支持端）

优先使用会话页面里的按钮：

- `Stop Session`（立即停止并恢复）
- `Recover`（兜底清理）

如果按钮不可用：

- 再打开一次 `SSH Tool.app`（检测到有会话会执行停止/恢复）
- 或脚本版运行：`./remote-support.sh stop`（失败再 `./remote-support.sh recover`）

✅ 三、最终确认（推荐）

支持人员再尝试连接一次刚才的命令（例如 `ssh ...`），如果返回 `Connection refused/closed` 等错误，说明远程支持已完全关闭。

## 顾客侧使用（Windows）

两种分发方式：

### A) ZIP（脚本版）

1. 下载并解压 `ssh-tool-win.zip`
2. 可选：在 `support.pub` 放入你们支持团队的公钥（推荐，免密码）。如果留空，脚本会自动走“临时账号+随机密码”模式。
3. 右键用 PowerShell 运行：

```powershell
.\remote-support.ps1 start -Minutes 60
```

脚本会：

- 若提供 `support.pub`：只允许公钥登录（禁用密码/交互式认证）
- 若 `support.pub` 为空：创建临时账号 + 随机密码
- 默认把 sshd 绑定到 `127.0.0.1`（不开放局域网 22）
- 启动 `bore`，并把可用的 `ssh ...` 命令复制到剪贴板
- 到期自动执行 `recover` 恢复配置

立即停止：

```powershell
.\remote-support.ps1 stop
```

如果提示找不到会话状态（比如脚本运行中途被强制关闭导致），可用恢复命令做兜底清理：

```powershell
.\remote-support.ps1 recover
```

### B) 单文件 EXE

1. 下载 `ssh-tool-win.exe`（或 `ssh-tool-win-arm64.exe`）
2. 可选：把 `support.pub` 放在 exe 同目录（推荐，免密码）。如果留空，会自动走“临时账号+随机密码”模式。
3. 双击运行（会请求管理员权限），会自动打开本地页面，在页面里点“开始会话”（注意：运行期间请不要关闭弹出的黑色窗口）；也可以在 PowerShell 直接运行：

```powershell
.\ssh-tool-win.exe start --minutes 60
```

立即停止 / 恢复：

```powershell
.\ssh-tool-win.exe stop
.\ssh-tool-win.exe recover
```

说明：exe 会把内置的 `remote-support.ps1`/`bore.exe` 解包到 `%LOCALAPPDATA%\\ssh-tool-win\\payload-*` 后执行；如需自定义解包目录，可设置环境变量 `SSH_TOOL_PAYLOAD_DIR`。

## 顾客侧使用（macOS）

两种分发方式：

### A) DMG（推荐）

1. 下载并打开 `ssh-tool-mac.dmg`
2. 把 `SSH Tool.app` 拖到 `Applications`
3. 双击 `SSH Tool.app`：

- 若当前没有会话：启动 60 分钟的临时会话
- 若检测到已有会话：执行停止/恢复（脚本内部会自动兜底）

启动后会自动打开一个本地页面，里面有需要发给支持人员的 `ssh ...` 命令。
页面里也有 `Stop Session` / `Recover` 按钮，可用于立即关闭并恢复配置（需要已安装并运行过 `SSH Tool.app` 以注册 `ssh-tool://` 协议）。

说明：首次启动会弹出 `sudo` 提示（启用 Remote Login/修改 sshd_config/恢复配置需要 root）。

### B) ZIP（脚本版）

1. 下载并解压 `ssh-tool-mac.zip`
2. 可选：在 `support.pub` 放入你们支持团队的公钥（推荐，免密码）。如果留空，脚本会自动走“临时账号+随机密码”模式。
3. 运行：

```bash
chmod +x ./remote-support.sh
./remote-support.sh start
```

注意：

- 脚本会自动请求 `sudo`（启用 Remote Login/修改 sshd_config/恢复配置需要 root）
- 默认随包附带 `bore`（Apple Silicon/Intel）；如果缺失，脚本会尝试自动下载 `bore`（可通过 `SSH_TOOL_BORE_VERSION` 固定版本）；也可以手动安装：`brew install bore-cli`

立即停止：

```bash
./remote-support.sh stop
```

如果提示找不到会话状态（比如脚本运行中途被强制关闭导致），可用恢复命令做兜底清理：

```bash
./remote-support.sh recover
```

## 打包

```bash
./scripts/build-release-zips.sh
```

输出：

- `dist/ssh-tool-win.zip`（仅脚本 + `bore.exe` + `support.pub`）
- `dist/ssh-tool-win.exe`（单文件 EXE，内置脚本 + `bore.exe` + `support.pub`；也支持把 `support.pub` 放在 exe 同目录覆盖）
- `dist/ssh-tool-mac.zip`（脚本 + `bore` + `support.pub`）
- `dist/ssh-tool-mac.dmg`（同上，macOS 常用分发格式）
