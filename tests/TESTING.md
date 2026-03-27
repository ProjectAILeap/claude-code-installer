# 测试说明

## 测试脚本

| 文件 | 用途 |
|------|------|
| [`test.sh`](test.sh) | install.sh 测试，7 层（含 Docker 升级/卸载层） |
| [`test.ps1`](test.ps1) | install.ps1 / uninstall.ps1 测试，4 层 |

---

## test.sh 层级说明

| 层 | 名称 | 是否需要网络 | 是否需要 Docker |
|----|------|:---:|:---:|
| 1 | shellcheck 语法检查 | — | — |
| 2 | 函数级单测（source install.sh） | — | — |
| 3 | 下载逻辑模拟（GCS 失败降级） | — | — |
| 4 | 目标参数合法性检查 | — | — |
| 5 | Docker 集成测试（Ubuntu + Alpine） | ✅ | ✅ |
| 6 | 升级检测测试（Docker Ubuntu） | ✅ | ✅ |
| 7 | 卸载测试（Docker Ubuntu） | ✅ | ✅ |

```bash
# 全部层（在仓库根目录运行）
bash tests/test.sh

# 指定层
bash tests/test.sh 1 2 3

# Docker 测试（需提前 pull 镜像）
docker pull ubuntu:24.04
docker pull alpine:latest
bash tests/test.sh 5 6 7
```

---

## test.ps1 层级说明

| 层 | 名称 | 是否需要网络 | 是否需要 Windows |
|----|------|:---:|:---:|
| 1 | PS 语法检查 + PSScriptAnalyzer | — | — |
| 2 | 函数级单测（需网络） | ✅ | — |
| 3 | 逻辑模拟（无需网络） | — | — |
| 4 | 真实安装验证 | ✅ | ✅ |

```bash
# Linux/macOS，通过 Docker（层 1-3）
docker run --rm -v "$PWD:/scripts" mcr.microsoft.com/powershell \
  pwsh -NonInteractive -File /scripts/tests/test.ps1 1 2 3

# Windows 直接运行（全部层）
pwsh -File tests/test.ps1

# Windows，指定层
pwsh -File tests/test.ps1 1 2 3
```

---

## 测试历史记录

| 日期 | 层级 | 平台 | 结果 | 发现的问题 |
|------|------|------|------|-----------|
| 2026-03-27 | 1 | Linux x64 | PASS | shellcheck 3 处需修复：SC2012 disable 位置、SC2088 误报、SC2059 颜色变量 |
| 2026-03-27 | 2 | Linux x64 | PASS | 发现缺少 source guard，`source install.sh` 直接执行 main |
| 2026-03-27 | 2 | Linux x64 | PASS | 发现 `_mirror_label` sed 错误，代理镜像标签显示为 github.com |
| 2026-03-27 | 3 | Linux x64 | PASS | GCS 失败降级逻辑正确；全部失败时文件不存在符合预期 |
| 2026-03-27 | 4 | Ubuntu 24.04 | PASS | linux-x64、版本获取、Git 检查、镜像测速均正常 |
| 2026-03-27 | 4 | Alpine (musl) | PASS | linux-x64-musl 正确检测 |
| 2026-03-27 | PS 1-3 | Docker (pwsh) | PASS | 语法检查通过；Get-LatestVersion v2.1.85；Select-Mirror GCS 优先（境外网络）；Test-Checksum 4 种场景；Invoke-DownloadMirror 全部失败返回 false |
| 2026-03-27 | 6 | Docker Ubuntu | PASS | 旧版本检测继续安装；已是最新版 exit 0 |
| 2026-03-27 | 7 | Docker Ubuntu | PASS | 卸载 5 项清理全通过；发现 uninstall.sh bug：`[[ -n BINARY_PATH ]] && INSTALL_DIR=...` 在空值时被 set -e 提前退出，已修复为 if 语句 |
