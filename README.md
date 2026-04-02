# Claude Code Installer

> **AI跃迁计划 · ProjectAILeap**
>
> 支持直接下载官方二进制（无需 npm）或 npm 两种安装方式，GitHub 镜像加速，适配中国网络环境。
> Supports both direct binary download (no npm required) and npm install — with mirror acceleration for China.

---

## 平台支持 / Platform Support

| 操作系统 | 架构 | Claude Code | CC Switch |
|---------|------|:-----------:|:---------:|
| Windows | x64  | ✅ | ✅ MSI |
| Windows | ARM64 | ✅ | ✅ MSI |
| macOS   | Apple Silicon (arm64) | ✅ | ✅ Universal |
| macOS   | Intel (x64) | ✅ | ✅ Universal |
| Linux   | x64 (glibc / musl) | ✅ | ✅ AppImage |
| Linux   | ARM64 (glibc / musl) | ✅ | ✅ AppImage |

二进制来源：[ProjectAILeap/claude-code-releases](https://github.com/ProjectAILeap/claude-code-releases)（官方二进制镜像存档，未做任何修改）

---

## 快速安装 / Quick Install

### macOS / Linux

```bash
# 直连（境外网络 / 有代理）
curl -fsSL https://raw.githubusercontent.com/ProjectAILeap/claude-code-installer/main/install.sh | bash

# 镜像加速（中国大陆推荐）
curl -fsSL https://ghfast.top/https://raw.githubusercontent.com/ProjectAILeap/claude-code-installer/main/install.sh | bash
```

安装完成后重启终端，运行 `claude` 即可。脚本会提示选择安装方式：`[1] Direct binary`（推荐）或 `[2] npm`。

### Windows

在 PowerShell 中运行：

```powershell
# 直连（境外网络 / 有代理）
irm https://raw.githubusercontent.com/ProjectAILeap/claude-code-installer/main/install.ps1 | iex

# 镜像加速（中国大陆推荐）
irm https://ghfast.top/https://raw.githubusercontent.com/ProjectAILeap/claude-code-installer/main/install.ps1 | iex
```

也可下载 `install.ps1` 后本地运行：

```powershell
powershell -ExecutionPolicy Bypass -File install.ps1
```

安装过程中会提示选择安装方式：`[1] Native Install`（推荐）、`[2] winget` 或 `[3] npm`。

---

## 安装方式说明

### 方式一：直接下载二进制（推荐）

- 直接下载官方二进制，验证 SHA-256 校验和
- 自动选择最快的 GitHub 镜像源
- 支持 `claude install` 官方路径（含自动更新），不可达时自动降级到 fallback
- **无需 Node.js / npm**

### 方式二：npm（中国大陆备选）

- 通过 `npm install -g @anthropic-ai/claude-code` 从 npmmirror 安装
- 需要 Node.js 18+（脚本自动检测并安装）
- 安装位置：`~/.npm-global/bin/claude`（macOS/Linux）或 `%APPDATA%\npm\claude`（Windows）
- 安装器会仅在自己追加 PATH 时写入标记文件，卸载时据此安全回收 npm PATH
- 升级：`npm update -g @anthropic-ai/claude-code`

---

## 安装模式与超时

- 默认模式：`CLAUDE_INSTALL_MODE=auto`
- 可选模式：`auto` / `force` / `skip`
- 默认超时：`CLAUDE_INSTALL_TIMEOUT=25` 秒

| 模式 | 行为 |
|------|------|
| `auto` | 默认模式。先探测 `api.anthropic.com`，可达时运行 `claude install`；不可达时直接 fallback |
| `force` | 无论网络探测结果如何，都强制尝试 `claude install` |
| `skip` | 直接跳过 `claude install`，使用 fallback 安装 |

示例：

```bash
bash install.sh
CLAUDE_INSTALL_MODE=skip bash install.sh
CLAUDE_INSTALL_MODE=force CLAUDE_INSTALL_TIMEOUT=40 bash install.sh
```

```powershell
powershell -ExecutionPolicy Bypass -File install.ps1
$env:CLAUDE_INSTALL_MODE="skip"; powershell -ExecutionPolicy Bypass -File install.ps1
$env:CLAUDE_INSTALL_MODE="force"; $env:CLAUDE_INSTALL_TIMEOUT="40"; powershell -ExecutionPolicy Bypass -File install.ps1
```

### API 访问配置逻辑

安装脚本会自动探测网络环境并分支处理，**保证安装完成后可直接运行 `claude`**：

| 场景 | 处理方式 |
|------|---------|
| 已有 `ANTHROPIC_API_KEY` | 跳过，保留现有配置 |
| 安装了 CC Switch | 写入占位配置，启动 CC Switch 完成 Provider 选择即可 |
| 可直连 Anthropic API | 提示输入真实 API Key，写入环境变量 |
| 无法直连 + 未装 CC Switch | 提示配置建议，写入 onboarding 跳过标记 |

---

## 镜像加速说明

脚本内置 6 个 GitHub 镜像源，自动并行测速选最快可用源（无需手动配置）：

| 镜像 | 类型 |
|------|------|
| github.com | 官方直连 |
| ghfast.top | 代理镜像 |
| gh-proxy.com | 代理镜像 |
| mirror.ghproxy.com | 代理镜像 |
| ghproxy.net | 代理镜像 |
| hub.gitmirror.com | 代理镜像 |

---

## CC Switch（可选）

[CC Switch](https://github.com/farion1231/cc-switch) 是一个 GUI 工具，支持一键切换 Claude Code 的 API Provider，适合国内用户使用第三方 API（DeepSeek、Kimi、GLM、Aliyun 等）。

安装脚本末尾会询问是否安装，选 `y` 自动下载对应平台版本：

| 平台 | 安装格式 | 位置 |
|------|---------|------|
| Windows | MSI 安装包 | 开始菜单 / 桌面 |
| macOS | tar.gz → .app | `/Applications/CC Switch.app` |
| Linux | AppImage | 与 `claude` 同目录，运行 `cc-switch` |

**使用流程（中国大陆用户推荐）：**
1. 安装时选择安装 CC Switch
2. 安装完成后，脚本自动写入占位 Provider 配置（无需手动设置 Key）
3. 打开 CC Switch，选择 Provider（如 DeepSeek），输入 API Key
4. 运行 `claude` 即可使用

---

## 升级 / Upgrade

重新运行安装脚本即可。脚本自动检测已安装版本（`claude --version`），仅在有新版本时下载。

```bash
# macOS / Linux
curl -fsSL https://ghfast.top/https://raw.githubusercontent.com/ProjectAILeap/claude-code-installer/main/install.sh | bash
```

```powershell
# Windows
irm https://ghfast.top/https://raw.githubusercontent.com/ProjectAILeap/claude-code-installer/main/install.ps1 | iex
```

---

## 卸载 / Uninstall

### macOS / Linux

```bash
# 克隆仓库后运行
bash uninstall.sh

# 或直接运行（需 curl 可访问 raw.githubusercontent.com）
curl -fsSL https://raw.githubusercontent.com/ProjectAILeap/claude-code-installer/main/uninstall.sh | bash
```

### Windows

在 PowerShell 中运行：

```powershell
# 直连
irm https://raw.githubusercontent.com/ProjectAILeap/claude-code-installer/main/uninstall.ps1 | iex

# 镜像加速（中国大陆推荐）
irm https://ghfast.top/https://raw.githubusercontent.com/ProjectAILeap/claude-code-installer/main/uninstall.ps1 | iex
```

也可下载 `uninstall.ps1` 后本地运行：

```powershell
powershell -ExecutionPolicy Bypass -File uninstall.ps1
```

卸载时可交互选择删除：

- Claude Code 二进制及安装目录
- npm 全局安装包（`@anthropic-ai/claude-code`）
- PATH 条目
- `~/.claude/` 配置目录 / `~/.claude.json`
- `~/.claude/downloads` 缓存目录
- CC Switch（若已安装）
- `ANTHROPIC_API_KEY` / `ANTHROPIC_BASE_URL` 环境变量

---

## 安装位置

| 平台 | 二进制方式 | npm 方式 | 下载缓存 |
|------|------------|---------|---------|
| Windows | `%USERPROFILE%\.local\bin\claude.exe` | `%APPDATA%\npm\claude.cmd` | `%USERPROFILE%\.claude\downloads` |
| macOS | `/usr/local/bin/claude` 或 `~/.local/bin/claude` | `~/.npm-global/bin/claude` | `~/.claude/downloads` |
| Linux | `~/.local/bin/claude` | `~/.npm-global/bin/claude` | `~/.claude/downloads` |

---

## 系统要求

| 平台 | 二进制方式 | npm 方式 |
|------|------|------|
| Windows | 64-bit；PowerShell 5.1+；Git 自动安装 | 同左 + Node.js 18+（自动安装） |
| macOS | curl（系统自带） | 同左 + Node.js 18+（自动安装，优先 Homebrew） |
| Linux | curl、bash、Git | 同左 + Node.js 18+（通过系统包管理器自动安装） |

二进制方式无需 Node.js / npm；npm 方式会自动安装 Node.js（无需手动操作）。

---

## 本地安装（无网络）

1. 从 [claude-code-releases](https://github.com/ProjectAILeap/claude-code-releases/releases) 手动下载对应平台二进制
2. 重命名为 `claude`（Linux/macOS）或 `claude.exe`（Windows）
3. 放入 PATH 中的目录，赋予执行权限（Linux/macOS: `chmod +x claude`）

---

## 常见问题

**Q: 直接二进制和 npm 方式哪个更好？**
> 直接二进制方式（默认）更推荐：SHA-256 校验、自动镜像选速、支持官方自动更新路径。npm 方式适合已有 Node.js 环境、或二进制下载受限时使用。两种方式不可同时安装同一版本，建议统一使用一种。

**Q: 需要管理员权限吗？**
> 二进制方式不需要，Windows 的 Git 和 Claude Code 均安装到用户目录，macOS/Linux 默认安装到 `~/.local/bin`。npm 方式若系统未安装 Node.js，脚本会通过 MSI 自动安装并触发 UAC 提权弹窗，选"是"即可；已有 Node.js 18+ 则无需任何权限。

**Q: fallback 安装和 `claude install` 有什么区别？**
> `claude install` 成功时通常保留官方 shell integration 和自动更新能力；fallback 是直接复制二进制，优点是稳定、快，缺点是没有自动更新，需要重新运行安装脚本升级。

**Q: Windows 上没有安装 Git 怎么办？**
> 安装脚本会自动检测并静默安装 Git for Windows（优先从 npmmirror 下载，无需管理员权限），无需手动操作。

**Q: 如何验证二进制完整性？**
> 脚本自动下载 `manifest.json` 并验证 SHA-256 校验和，与二进制使用相同镜像源下载。已缓存的二进制再次安装时也会重新校验。

**Q: 安装完提示无法连接 Anthropic API 怎么办？**
> 中国大陆直连 api.anthropic.com 通常不可用。建议安装 CC Switch 并配置国内 Provider（DeepSeek 等）。

**Q: 支持 Windows ARM64 吗？**
> 支持。脚本自动检测架构，ARM64 设备会下载 `win32-arm64` 版本。

---

## 相关项目

- [claude-code-releases](https://github.com/ProjectAILeap/claude-code-releases) — 官方二进制自动存档（本项目下载源）
- [CC Switch](https://github.com/farion1231/cc-switch) — API Provider 切换工具
- [Claude Code 官方文档](https://docs.anthropic.com/claude/docs/claude-code)

---

## License

MIT © 2026 ProjectAILeap (AI跃迁计划)
