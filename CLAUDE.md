# claude-code-installer

多平台 Claude Code 安装脚本，支持 GitHub 镜像加速，面向国内用户。

- 仓库：[ProjectAILeap/claude-code-installer](https://github.com/ProjectAILeap/claude-code-installer)
- 二进制存档：[ProjectAILeap/claude-code-releases](https://github.com/ProjectAILeap/claude-code-releases)

## 脚本说明

| 脚本 | 平台 | 说明 |
|------|------|------|
| `install.sh` | macOS / Linux | 主安装脚本 |
| `uninstall.sh` | macOS / Linux | 卸载脚本 |
| `install.ps1` | Windows | PowerShell 安装脚本（`irm url \| iex` 或本地 `-ExecutionPolicy Bypass -File`） |
| `uninstall.ps1` | Windows | PowerShell 卸载脚本（同上） |

## install.sh 核心流程

```
detect_platform       # 平台检测（含 Rosetta 2 / musl）
get_latest_version    # 从 GitHub API 获取最新版本号
check_installed_version  # claude --version 检查是否已是最新
check_git             # Linux 检查 Git 是否安装
select_mirror         # 并发测速：GCS + 5 个 GitHub 镜像，按延迟排序
download_and_verify   # 按 MIRROR_ORDER 顺序下载，manifest.json 校验
run_claude_install    # 执行 claude install [TARGET]，90s 超时后降级
install_cc_switch_prompt  # 可选：安装 CC Switch（API 提供商切换器）
configure_api_key     # 配置 ANTHROPIC_API_KEY
```

### 镜像策略

- GCS（官方 Anthropic）和 5 个 GitHub 镜像统一并发测速，按延迟排序存入 `MIRROR_ORDER[]`
- 下载时按顺序尝试，任意一个失败自动换下一个，无特殊优先级
- CC Switch 始终从 `GITHUB_MIRROR`（最快的非 GCS 源）下载

### 二进制来源与校验

| 来源 | 二进制 URL 格式 | 校验文件 |
|------|----------------|----------|
| GCS（官方） | `$GCS_BUCKET/$VERSION/$PLATFORM/claude` | `$GCS_BUCKET/$VERSION/manifest.json` |
| GitHub 镜像 | `$MIRROR/$REPO/releases/download/v$VERSION/claude-$VERSION-$PLATFORM` | `$MIRROR/$REPO/releases/download/v$VERSION/manifest.json` |

两者均使用 `manifest.json`，格式相同：`platforms.$PLATFORM.checksum`（SHA-256）。

### claude install vs 降级安装

- **正常路径**：`claude install [TARGET]` 完成安装，自动更新机制由此建立
- **降级路径**（claude install 超时/失败）：直接 `cp` 二进制到 `~/.local/bin/claude`，无自动更新

## install.ps1 核心差异

- 二进制来自 GCS（官方，对中国用户可能超时）或 GitHub Releases（镜像加速），并发测速选最优
- GCS + 5 个 GitHub 镜像统一并发测速，`$global:IsGCS` 标记来源，`$global:GithubMirror` 记录最快非 GCS 源
- GCS 下载失败自动降级到 `$global:GithubMirror` + 多镜像 fallback
- 校验使用 `manifest.json`（PowerShell 原生 JSON 解析），不用 sha256sums.txt
- 可选 winget 安装路径（`winget install Anthropic.ClaudeCode`），成功后跳过镜像下载流程
- 同样调用 `claude install`，90s 超时后降级（winget 路径除外）
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

## 与官网 install.sh 的差异

| 项目 | 官网 | 本项目 |
|------|------|--------|
| 二进制来源 | GCS only | GCS + GitHub Releases |
| 镜像加速 | 无 | 5 个 GitHub 镜像 + 并发测速 |
| 版本检测 | 不检查本地版本 | `claude --version` 跳过已是最新 |
| Git 检查 | 无 | Linux 有（macOS 跳过） |
| CC Switch | 无 | 可选安装 |
| API Key | 无 | 交互式配置 |
| 自动更新 | 有（via claude install） | 正常路径有，降级路径无 |

## 测试

详见 [`tests/TESTING.md`](tests/TESTING.md)（层级说明、运行命令、历史记录）。
