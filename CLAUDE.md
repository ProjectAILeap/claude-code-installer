# claude-code-installer

多平台 Claude Code 安装脚本，支持 GitHub 镜像加速，面向国内用户，并支持二进制安装与 npm 安装两条路径。

- 仓库：[ProjectAILeap/claude-code-installer](https://github.com/ProjectAILeap/claude-code-installer)
- 二进制存档：[ProjectAILeap/claude-code-releases](https://github.com/ProjectAILeap/claude-code-releases)

## 脚本说明

| 脚本 | 平台 | 说明 |
|------|------|------|
| `install.sh` | macOS / Linux | 主安装脚本，支持 `Direct binary` / `npm` 两种安装方式 |
| `uninstall.sh` | macOS / Linux | 卸载脚本，支持原生安装与 npm 全局安装检测 |
| `install.ps1` | Windows | PowerShell 安装脚本（`irm url \| iex` 或本地 `-ExecutionPolicy Bypass -File`），支持 `Native Install` / `winget` / `npm` |
| `uninstall.ps1` | Windows | PowerShell 卸载脚本（同上），支持原生安装、winget、npm 三类卸载 |

## install.sh 核心流程

```
detect_platform       # 平台检测（含 Rosetta 2 / musl）
get_latest_version    # 从 GitHub API 获取最新版本号
check_installed_version  # claude --version 检查是否已是最新
选择安装方式          # [1] Direct binary / [2] npm
check_git             # 二进制方式下 Linux 检查 Git；npm 方式下检查 Git 可用性
select_mirror         # 二进制方式：并发测速 6 个 GitHub 镜像
download_and_verify   # 二进制方式：按 MIRROR_ORDER 顺序下载，manifest.json 校验
run_claude_install    # 二进制方式：执行 claude install [TARGET]，支持 auto|force|skip，默认 25s 超时后降级
install_via_npm       # npm 方式：确保 Node.js >= 18，配置 npmmirror，全局安装 claude
install_cc_switch_prompt  # 可选：安装 CC Switch（API 提供商切换器）
configure_api_key     # 配置 ANTHROPIC_API_KEY
```

### 镜像策略

- 6 个 GitHub 镜像并发测速，按延迟排序存入 `MIRROR_ORDER[]`，下载时依序尝试
- GCS（`storage.googleapis.com`）**仅定义为变量，不参与测速和下载**（中国大陆被屏蔽）
- CC Switch 始终从 `GITHUB_MIRROR`（最快的非 GCS 镜像）下载

### 二进制来源与校验

- 来源：`$MIRROR/ProjectAILeap/claude-code-releases/releases/download/v$VERSION/claude-$VERSION-$PLATFORM`
- 校验：同一镜像下的 `manifest-$VERSION.json`，字段 `platforms.$PLATFORM.checksum`（SHA-256）

### claude install vs 降级安装

- **正常路径**：`claude install [TARGET]` 完成安装，自动更新机制由此建立
- **降级路径**（跳过 / 超时 / 失败）：直接 `cp` 二进制到 `~/.local/bin/claude`（或 macOS 的 `/usr/local/bin/claude`），无自动更新

### npm 安装路径

- macOS / Linux：固定使用 `~/.npm-global` 作为 npm prefix，安装到 `~/.npm-global/bin/claude`
- Windows：使用 `%APPDATA%\npm\claude.cmd`
- Node.js 要求为 `18+`；不足时脚本会尝试自动安装后再次校验版本
- 安装器只在自己追加 PATH 时写入 marker，卸载时仅回收带 marker 的 npm PATH，避免删除用户原有 npm 环境配置

### 安装模式

- `CLAUDE_INSTALL_MODE=auto`：默认。先探测 `api.anthropic.com`，可达时尝试 `claude install`，不可达时直接 fallback
- `CLAUDE_INSTALL_MODE=force`：无论探测结果如何都强制尝试 `claude install`
- `CLAUDE_INSTALL_MODE=skip`：跳过 `claude install`，直接 fallback
- `CLAUDE_INSTALL_TIMEOUT`：默认 `25` 秒，可覆盖

## install.ps1 核心差异

- 二进制来自 GCS（官方，对中国用户可能超时）或 GitHub Releases（镜像加速），并发测速选最优
- 实际镜像测速使用 GitHub 与代理镜像，`$global:IsGCS` 仅保留为兼容标记，默认初始化为 `$false`
- 校验使用 `manifest.json`（PowerShell 原生 JSON 解析），不用 sha256sums.txt
- 可选 winget 安装路径（`winget install Anthropic.ClaudeCode`），成功后跳过镜像下载流程
- 新增 npm 安装路径（`Install-ViaNpm`），通过 npmmirror 安装 `@anthropic-ai/claude-code`
- 原生路径同样调用 `claude install`，支持 `auto|force|skip`，默认 25s 超时后降级（winget 路径除外）
- 额外功能：自动安装 Git for Windows、CC Switch（MSI）、交互式 API Key 配置

### winget 安装说明

| 对比项 | 原生安装（镜像下载） | winget 安装 |
|--------|---------------------|-------------|
| 安装位置 | `~\.local\bin\claude.exe` | `AppData\Local\Microsoft\WinGet\Links\claude.exe` |
| shell integration | 有（via claude install） | 无 |
| 自动更新 | 有（正常路径） | 无（需 `winget upgrade`） |
| PATH | 脚本写入 | winget 自动管理 |
| 卸载 | uninstall.ps1 | `winget uninstall Anthropic.ClaudeCode` |

**卸载 winget 安装**：`uninstall.ps1` 会自动检测 winget 安装，走独立的 winget 卸载流程。

## 与官网安装脚本的差异

| 项目 | 官网 | 本项目 |
|------|------|--------|
| 二进制来源 | GCS only | GCS + GitHub Releases |
| 镜像加速 | 无 | 5 个 GitHub 镜像 + 并发测速 |
| 安装方式 | 官方单一路径 | 二进制 + npm（Windows 另含 winget） |
| 版本检测 | 不检查本地版本 | `claude --version` 跳过已是最新 |
| Git 检查 | 无 | Linux 有（macOS 跳过） |
| CC Switch | 无 | 可选安装 |
| API Key | 无 | 交互式配置 |
| 自动更新 | 有（via claude install） | 正常路径有，降级路径无 |
| 安装策略 | 固定官方路径 | `claude install` + 自动 fallback，支持 `CLAUDE_INSTALL_MODE` |
| PATH 修复 | 官方脚本处理 | 成功/失败后都补 PATH；macOS 优先写 `~/.zprofile` / `~/.bash_profile` |

## 测试

详见 [`tests/TESTING.md`](tests/TESTING.md)。

- `tests/test.sh`：静态检查、函数级单测、GCS 降级、非法参数、npm 安装模拟、Docker 集成、升级检测、原生卸载、npm 卸载
- `tests/test.ps1`：`install.ps1` / `uninstall.ps1` 语法检查、网络函数单测、逻辑模拟
