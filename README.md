# ssh-tool (Customer Remote Support)

在 **默认安全** 的前提下，为客户临时开启 SSH 远程支持（默认不对局域网开放，只通过 `bore.pub` 中继），并在结束后自动/手动恢复配置。

## ⬇️ 下载安装（从 Releases）

👉 **直接下载最新版安装包（Releases / Latest）：** [点这里](../../releases/latest)

> 安装包在 Release 页面的 **Assets** 里；不要使用 `Code → Download ZIP`（那是源码，不含 `exe/dmg`）。

### 选哪个安装包？

| 平台 | 推荐（给用户） | 备选（脚本版） |
|---|---|---|
| Windows x64 | `ssh-tool-win.exe` | `ssh-tool-win.zip` |
| Windows ARM64 | `ssh-tool-win-arm64.exe` | `ssh-tool-win.zip` |
| macOS | `ssh-tool-mac.dmg`（内含 `SSH Tool.app`） | `ssh-tool-mac.zip` |

### Windows 快速开始（推荐：单文件 EXE）

1. 下载 `ssh-tool-win.exe`（或 ARM64 用 `ssh-tool-win-arm64.exe`）
2. （可选）把 `support.pub` 放在 exe 同目录（推荐，免密码；留空则走“临时账号 + 随机密码”）
3. 双击运行 → 允许 UAC → 会自动打开本地页面 → 点 `开始会话`
4. 把页面里的 `ssh ...` 命令（以及密码如有）发给支持人员
5. 用完后在页面点 `停止（恢复配置）`

常见提示：

- 如果被 SmartScreen 拦截：点「更多信息」→「仍要运行」。
- 如果提示安装 OpenSSH Server 失败：通常是 Windows Update / BITS 被禁用或无法访问更新源（企业策略/离线环境）。请先让 IT 开启 Windows Update，或在「设置 → 应用 → 可选功能」里手动安装 `OpenSSH Server`。
- 离线/绕过更新安装（推荐给企业/精简系统）：下载 `OpenSSH-Win64.zip`（PowerShell/Win32-OpenSSH），放到 `ssh-tool-win.exe` **同目录**并命名为 `OpenSSH-Win64.zip`，再点 Start 即可。
  - 工具会解压到：`C:\ProgramData\ssh-tool\openssh\` 并执行 `install-sshd.ps1` 注册 `sshd` 服务
  - 也可用环境变量指定 zip 路径：`SSH_TOOL_OPENSSH_ZIP=C:\path\OpenSSH-Win64.zip`

### Windows：离线安装 OpenSSH（详细）

当目标机器 **Windows Update 被禁用/被 WSUS 策略拦截/离线** 时，`Add-WindowsCapability` 可能会失败。这时请按下面方式准备离线包：

1. 在一台可上网的机器下载 `OpenSSH-Win64.zip`（项目：PowerShell/Win32-OpenSSH）
2. 把该 zip 拷贝到目标 Windows 机器，并放到 `ssh-tool-win.exe` 同目录：

```
ssh-tool-win.exe
OpenSSH-Win64.zip
support.pub    (可选)
```

3. 双击运行 `ssh-tool-win.exe`，点 `Start`（工具会自动用 zip 安装并注册 `sshd` 服务）

安装目录说明：

- OpenSSH 解压/安装缓存：`C:\ProgramData\ssh-tool\openssh\`
- 会话状态文件：`C:\ProgramData\ssh-tool\active-session.json`
- 运行时解包目录：`%LOCALAPPDATA%\ssh-tool-win\payload-*`（可用 `SSH_TOOL_PAYLOAD_DIR` 覆盖）

可选环境变量：

- `SSH_TOOL_OPENSSH_ZIP=C:\path\OpenSSH-Win64.zip`（指定离线 zip 位置）
- `SSH_TOOL_OPENSSH_ZIP_URL=...`（自定义下载地址；不建议普通用户使用）

### macOS 快速开始（推荐：DMG）

1. 下载并打开 `ssh-tool-mac.dmg`
2. 把 `SSH Tool.app` 拖到 `Applications`
3. 双击 `SSH Tool.app`：
   - 若当前没有会话：启动 60 分钟的临时会话
   - 若检测到已有会话：执行停止/恢复（兜底清理）
4. 会自动打开会话页面，里面有要发给支持人员的 `ssh ...` 命令；页面里也有 `Stop Session` / `Recover` 按钮

常见提示（无法打开）：

- 右键 `SSH Tool.app` → Open
- 或执行：`sudo xattr -dr com.apple.quarantine "/Applications/SSH Tool.app"`

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

## 安全模型（简述）

- 默认不开放局域网 SSH：Windows 默认把 `sshd` 绑定到 `127.0.0.1`，只通过 `bore.pub` 中继对外提供连接
- 优先公钥认证：若提供 `support.pub`，将禁用密码登录；否则创建临时账号 + 随机密码
- 会话到期自动回收：到期会自动执行 `recover`（恢复配置/清理临时用户/关闭隧道）

## 高级：脚本版（ZIP）使用说明

<details>
<summary>展开</summary>

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

### 打包（开发者）

```bash
./scripts/build-release-zips.sh
```

输出：

- `dist/ssh-tool-win.zip`（仅脚本 + `bore.exe` + `support.pub`）
- `dist/ssh-tool-win.exe`（单文件 EXE，内置脚本 + `bore.exe` + `support.pub`；也支持把 `support.pub` 放在 exe 同目录覆盖）
- `dist/ssh-tool-mac.zip`（脚本 + `bore` + `support.pub`）
- `dist/ssh-tool-mac.dmg`（同上，macOS 常用分发格式）
</details>

## 仓库内容（开发者）

- `packages/ssh-tool-win/remote-support.ps1`：Windows（OpenSSH Server + `bore.exe`）
- `packages/ssh-tool-mac/remote-support.sh`：macOS（Remote Login/sshd + `bore`）
