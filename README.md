# LAN SSH Bootstrap

**帮助局域网内的老旧 Windows 电脑准备 SSH 维护入口。**

**简体中文** · [English](README.en.md)

LAN SSH Bootstrap 是一个帮助局域网内老旧 Windows 电脑配置 SSH 的工具，方便后续通过终端排查问题、查看日志和维护系统。它提供网页操作引导，将安装文件准备、服务配置、公钥授权、防火墙设置和实际登录验证串成一次流程。

## 当前支持的方式

- **macOS → Windows：** 在 Mac 上运行工具，为同一可信局域网内的 Windows 电脑配置并验证 SSH 公钥登录。
- **Windows → Windows：** 暂不支持从一台 Windows 电脑发起配置。

发起端选择网卡和 SSH 密钥，Windows 操作者按照中英双语网页引导打开管理员 PowerShell，查看并确认变更。配置完成后，工具实际登录并核对账户身份，给出后续使用的连接命令。

私钥始终留在发起端。已有可检查的 SSH 安装会被复用；变更前保留原配置和恢复入口。

> 当前为 `0.1.0-dev` 开发预览。Windows 11 上“复用已有 SSH → 配置公钥 → 验证登录 → 恢复设置”的路径已实测。全新安装、普通账户隔离和重启保持仍待验收，请先在可恢复的测试机上使用。

## 能帮你做什么

- **集中准备文件：** Mac 下载并缓存固定版本的官方安装包，Windows 运行时只需访问 Mac。
- **引导现场操作：** Windows 页面提供中英文说明、对应语言的截图、命令复制和进度状态。
- **配置连接：** 为现有本地账户配置公钥、sshd 开机启动及限定来源地址的防火墙规则。
- **确认真正可用：** 两端核对主机指纹后，由 Mac 验证真实公钥登录和账户 SID。
- **保留恢复路径：** 备份原配置，记录本次变更，并在恢复时检查是否存在后续修改。

## 典型场景

### 帮长辈或朋友排查老电脑

一台用了多年的 Windows 电脑交到你手里，需要查进程、看日志、检查服务。把它和 Mac 接入同一个可信局域网，用工具准备 SSH 入口，随后就能从熟悉的终端继续排查。

### 为 Windows 准备日常维护入口

家中或办公室有一台需要偶尔维护的 Windows 电脑。首次配置时集中完成公钥授权和连接验证，之后在网络可达时，使用输出的 SSH 命令登录。

### 两个人配合完成配置

你负责 Mac，另一人操作 Windows。把临时网页地址交给对方，让对方按对应语言的截图打开 PowerShell、复制命令并确认计划，减少口述路径和输入长命令的来回沟通。

### Windows 下载不方便，但局域网互通

Windows 访问外网下载较慢，可以由 Mac 取得并缓存官方安装包，再通过局域网提供给 Windows。Windows 无需自行访问外网下载源；首次取得安装包时，Mac 仍需要外网或事先准备好的固定版本文件。

工具完成 SSH 准备后，排查、卸载或系统优化仍由你决定。SSH 提供终端访问，桌面操作需要其他方式。后续连接也需要两台电脑之间的网络可达；工具不包含异地联网或内网穿透功能。

## 使用前准备

| Mac 端 | Windows 端 |
|---|---|
| macOS，系统自带 `ssh` 和 `ssh-keygen` | 目标为 Windows 10 1809 起及 Windows 11，x64 |
| 一对已有 SSH 密钥；没有时会提示创建 | 有权限确认变更的管理员操作者 |
| 与 Windows 相通的可信局域网 | 浏览器、64 位 Windows PowerShell 5.1 |
| 首次取得官方安装包时需要外网 | 运行过程中只需访问 Mac |

当前不支持域账户、Windows ARM 或 32 位系统。目标版本范围不等于已完成全部兼容测试。

## 开始使用

当前从源码构建，需要 Go 1.24 或更新版本：

```sh
git clone https://github.com/ren2019/lan-ssh-bootstrap.git
cd lan-ssh-bootstrap
sh scripts/build.sh
```

Apple Silicon Mac：

```sh
./dist/lan-ssh-bootstrap-darwin-arm64
```

Intel Mac：

```sh
./dist/lan-ssh-bootstrap-darwin-amd64
```

构建后的程序可独立运行，无需额外安装 Go、Python 或 Node。Intel 产物目前仅完成交叉构建，尚未实机运行。

### 1. 你在 Mac 上准备会话

选择与 Windows 相通的网卡和用于登录的 SSH 密钥，确认开始。

工具下载并缓存固定版本的官方 OpenSSH 安装包，每次使用都校验 SHA256，然后显示一个临时局域网地址。把这个地址交给 Windows 操作者。

私钥留在 Mac，Windows 只接收公钥。没有成对密钥时，工具会提示先运行 `ssh-keygen -t ed25519`。

### 2. 对方在 Windows 上照网页操作

网页提供中文 / English，可切换对应语言的截图和说明：

1. 搜索 Windows PowerShell，以管理员身份运行。
2. 复制网页生成的命令，粘贴并执行。
3. 查看账户、安装状态、防火墙范围及拟执行变更，输入 `yes` 后应用；也可以退出。

默认选择当前桌面使用者，可改选其他已启用的本地账户；工具不会新建账户。防火墙默认允许所选局域网网段，也可以收窄到你的 Mac 地址。

Windows 端无需再去外网寻找安装包。

### 3. 两端核对，验证连接

Windows 显示 SSH 主机指纹。你在 Mac 上核对相同指纹并确认，工具再用所选密钥真实登录，核对账户 SID。

已有可检查的 SSH 安装会被复用，保留原认证策略。全新安装的设计流程是在公钥验证成功后关闭密码及 keyboard-interactive 登录，再验证一次；这一新装流程尚未完成实机验收。

成功后，Mac 显示后续连接命令。网页保留 15 秒展示结果，随后临时下载服务关闭。配置好的 SSH 服务会继续运行，供后续维护；结束维护后可使用恢复脚本撤销本次配置。

Mac 会话运行期间可用 `Ctrl+C` 退出。Windows 端等待或回传失败会尝试恢复；无法确认安全恢复时，会保留提示要求人工处理。

## 你能掌握哪些变更

应用前会展示具体计划，主要包括：

- 配置现有账户的公钥登录，保留原公钥来源。
- 启动 sshd，并设为自动启动；应用配置可能重启 sshd、断开已有 SSH 会话。
- 新增限定来源地址的防火墙规则。
- 保留原配置备份和本次恢复记录。

新公钥按所选账户单独配置，不写进管理员共用的公钥文件。已有防火墙放行规则会保留，所以新增一条局域网规则并不代表所有其他入口都已被收窄。

遇到自定义 sshd 启动参数、复杂公钥路径或其他无法可靠处理的现有配置时，工具会停止并提示手工处理。不会自动替换或升级现有 SSH 安装，也不会自动重启电脑。

## 配错了，怎么恢复

Windows 确认变更后，会将原配置和恢复脚本保存在：

```text
%ProgramData%\lan-ssh-bootstrap\sessions\<attempt>\
```

控制台会打印对应的恢复命令。在管理员 PowerShell 中运行：

```powershell
powershell.exe -ExecutionPolicy Bypass -File "<session-directory>\restore.ps1"
```

恢复前会检查配置、公钥文件、规则及服务状态是否又被其他操作修改；存在冲突时停止，避免覆盖后续工作。

恢复会撤销本次创建的公钥文件及规则，并恢复原配置和服务状态。新装的软件包和生成的主机密钥会保留；新装恢复路径仍待实测。安装器尚未结束或服务归属不明确时，可能保留临时端口阻断规则，并提示人工处理。

## 网络与信任边界

请在自己信任的家庭或办公局域网使用。

临时服务使用 HTTP。随机会话路径、来源网段限制和固定文件路由能限制误访问，但不提供传输加密或端到端身份认证。安装包的哈希校验不能证明通过 HTTP 取得的脚本本身可信。不要把服务暴露到互联网，或用于酒店、公共 Wi-Fi 等不可信网络。

新装使用固定的 [Win32-OpenSSH 10.4.0.0p1-Preview](https://github.com/PowerShell/Win32-OpenSSH/releases/tag/10.4.0.0p1-Preview)。上游将其标为 Preview / non-production ready。Windows 安装前还会要求 SHA256 匹配，以及有效的 Microsoft Corporation Authenticode 签名。

## 已验证到哪一步

| 路径 | 状态 |
|---|---|
| Apple Silicon Mac 构建、下载、缓存、启动与退出 | 已实测 |
| Mac 网页中英切换、对应截图及 HTTP 页面复制 | 已实测 |
| Windows 11 x64 已有安装的配置与真实公钥登录 | 已实测，包含账户 SID 核对 |
| 应用前取消、验证中止后恢复、成功后显式恢复 | 已实测，原配置字节及服务状态恢复 |
| 临时授权撤销后拒绝测试密钥 | 已实测 |
| 固定 MSI 的哈希和微软签名 | 已实测 |
| 再次生成同一配置 | 字节一致；第二次完整执行待测 |
| 全新安装、普通账户隔离、重启保持 | 待实测 |
| Windows 10 各版本、Intel Mac、Windows 浏览器人工操作 | 待实测 |

更多范围和验证方法见 [docs/VALIDATION.md](docs/VALIDATION.md)。

## 常用参数

```sh
# 指定现有密钥和服务端口
./dist/lan-ssh-bootstrap-darwin-arm64 -key ~/.ssh/id_ed25519 -port 8765

# 使用已取得的固定版本安装包，仍校验内置 SHA256
./dist/lan-ssh-bootstrap-darwin-arm64 -package /path/to/OpenSSH-Win64-v10.4.0.0.msi
```

`-bind` 可指定本机已启用网卡的私有 IPv4；默认交互选择。网页可加 `?lang=zh` 或 `?lang=en`，默认跟随浏览器语言。Mac 终端提示目前以中文为主。

## 开发检查

```sh
go test -race ./...
go vet ./...
pwsh -NoProfile -NonInteractive -File scripts/check-powershell.ps1
node --check assets/app.js
```

PowerShell 检查使用纯配置和模拟恢复场景，不修改真实 Windows 设置。PowerShell 和 Node 仅用于开发检查。

## 许可

代码采用 [MIT](LICENSE)。第三方截图的来源和许可单独列在 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。
