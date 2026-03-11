# ssh-tool (Customer Remote Support)

目标：让顾客运行一个脚本，就能在 **默认安全** 的前提下把 SSH 临时开给支持人员连接（默认不对局域网开放，只通过 `bore` 穿透），并且到期自动回收/恢复配置。

仓库包含两个平台的脚本：

- `packages/ssh-tool-win/remote-support.ps1`：Windows（OpenSSH Server + `bore.exe`）
- `packages/ssh-tool-mac/remote-support.sh`：macOS（Remote Login/sshd + `bore`）

## 顾客侧使用（Windows）

两种分发方式：

### A) ZIP（脚本版）

1. 解压 `dist/ssh-tool-win.zip`
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

1. 下载 `dist/ssh-tool-win.exe`
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

1. 打开 `dist/ssh-tool-mac.dmg`
2. 把 `SSH Tool.app` 拖到 `Applications`
3. 双击 `SSH Tool.app`：

- 若当前没有会话：启动 60 分钟的临时会话
- 若检测到已有会话：执行停止/恢复（脚本内部会自动兜底）

启动后会自动打开一个本地页面，里面有需要发给支持人员的 `ssh ...` 命令。

说明：首次启动会弹出 `sudo` 提示（启用 Remote Login/修改 sshd_config/恢复配置需要 root）。

### B) ZIP（脚本版）

1. 解压 `dist/ssh-tool-mac.zip`
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
