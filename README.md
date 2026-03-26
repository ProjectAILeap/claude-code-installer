# Claude Code Installer

> **AI跃迁计划 · ProjectAILeap**
>
> 无需 npm，直接下载官方二进制，支持 GitHub 镜像加速，适配中国网络环境。
> Install Claude Code without npm — downloads official binaries with mirror acceleration.

---

## 平台支持 / Platform Support

| 操作系统 | 架构 | 支持 |
|---------|------|------|
| Windows | x64  | ✅ |
| macOS   | Apple Silicon (arm64) | ✅ |
| macOS   | Intel (x64) | ✅ |
| Linux   | x64 (glibc / musl) | ✅ |
| Linux   | ARM64 (glibc / musl) | ✅ |

二进制来源：[ProjectAILeap/claude-code-releases](https://github.com/ProjectAILeap/claude-code-releases)（官方二进制镜像存档，未做任何修改）

---

## 快速安装 / Quick Install

### macOS / Linux

```bash
# 直连（境外网络）
curl -fsSL https://raw.githubusercontent.com/ProjectAILeap/claude-code-installer/main/install.sh | bash

# 镜像加速（中国大陆推荐）
curl -fsSL https://ghfast.top/https://raw.githubusercontent.com/ProjectAILeap/claude-code-installer/main/install.sh | bash
```

安装完成后重启终端，运行 `claude` 即可。

### Windows

1. **方法一（推荐）：** 下载 [`install.bat`](https://github.com/ProjectAILeap/claude-code-installer/releases/latest) 后双击运行
2. **方法二：** 在 PowerShell 中运行：

```powershell
# 直连
irm https://raw.githubusercontent.com/ProjectAILeap/claude-code-installer/main/install.ps1 | iex

# 镜像加速（中国大陆推荐）
irm https://ghfast.top/https://raw.githubusercontent.com/ProjectAILeap/claude-code-installer/main/install.ps1 | iex
```

> **提示：** 安装完成后需重启 PowerShell 窗口，`claude` 命令才会生效。

---

## 镜像加速说明

脚本内置多个 GitHub 镜像，自动测速并选择最快可用源：

| 镜像 | 类型 |
|------|------|
| github.com | 官方直连 |
| ghfast.top | 代理镜像 |
| gh-proxy.com | 代理镜像 |
| mirror.ghproxy.com | 代理镜像 |
| kkgithub.com | 域名镜像 |

无需手动配置，脚本自动检测网络可达性。

---

## 升级 / Upgrade

重新运行安装脚本即可。脚本会自动检测已安装版本，仅在有新版本时才下载。

```bash
# macOS / Linux
curl -fsSL https://ghfast.top/https://raw.githubusercontent.com/ProjectAILeap/claude-code-installer/main/install.sh | bash

# Windows：重新双击 install.bat 或运行 install.ps1
```

---

## 卸载 / Uninstall

### macOS / Linux

```bash
curl -fsSL https://raw.githubusercontent.com/ProjectAILeap/claude-code-installer/main/uninstall.sh | bash
# 或克隆仓库后运行 bash uninstall.sh
```

### Windows

双击 `uninstall.bat`，或在 PowerShell 中运行 `.\uninstall.ps1`。

卸载时可选择保留或删除：
- Claude Code 可执行文件
- 数据/版本目录
- PATH 条目
- `~/.claude/` 配置目录
- CC Switch（若已安装）

---

## CC Switch（可选）

[CC Switch](https://github.com/farion1231/cc-switch) 是一个 GUI 工具，支持一键切换 Claude Code 的 API Provider（DeepSeek、Kimi、GLM 等），适合国内用户使用第三方 API。

- **Windows**：安装脚本末尾会询问是否安装，选 `y` 自动下载 MSI 安装包
- **macOS / Linux**：CC Switch 目前仅提供 Windows 版本，请手动访问 [releases 页面](https://github.com/farion1231/cc-switch/releases)

---

## 安装位置

| 平台 | 路径 |
|------|------|
| Windows | `%LOCALAPPDATA%\Programs\ClaudeCode\claude.exe` |
| macOS | `/usr/local/bin/claude` 或 `~/.local/bin/claude` |
| Linux | `~/.local/bin/claude` |

版本记录：
- Windows: `%LOCALAPPDATA%\Programs\ClaudeCode\version.txt`
- macOS / Linux: `~/.local/share/claude-code/version`

---

## 本地安装（无网络）

1. 从 [claude-code-releases](https://github.com/ProjectAILeap/claude-code-releases/releases) 手动下载二进制
2. 重命名为 `claude`（Linux/macOS）或 `claude.exe`（Windows）
3. 放入 PATH 下的目录并赋予执行权限（Linux/macOS: `chmod +x claude`）

---

## 常见问题

**Q: 与 npm 安装方式冲突吗？**
> 不冲突。本方案安装到独立目录，与 npm 全局安装互不干扰。但建议统一使用一种方式避免版本混乱。

**Q: 需要管理员权限吗？**
> 不需要。Windows 安装到用户目录 `%LOCALAPPDATA%`，macOS/Linux 默认安装到 `~/.local/bin`，均无需 root/管理员。

**Q: 如何验证二进制完整性？**
> 脚本自动下载 `sha256sums.txt` 并验证 SHA-256 校验和。校验文件来源与二进制相同。

---

## 相关项目

- [claude-code-releases](https://github.com/ProjectAILeap/claude-code-releases) — 官方二进制自动存档（本项目下载源）
- [CC Switch](https://github.com/farion1231/cc-switch) — API Provider 切换工具
- [Claude Code 官方文档](https://docs.anthropic.com/claude/docs/claude-code)

---

## License

MIT © 2026 ProjectAILeap (AI跃迁计划)
