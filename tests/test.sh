#!/usr/bin/env bash
# ════════════════════════════════════════════════════════════════════════════
#  install.sh 测试脚本 — ProjectAILeap/claude-code-installer
#
#  用法:
#    bash test.sh          # 运行所有层（第四层需要 Docker）
#    bash test.sh 1        # 只运行第一层
#    bash test.sh 1 2 3    # 运行指定层
# ════════════════════════════════════════════════════════════════════════════
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
INSTALL_SH="${REPO_DIR}/install.sh"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

pass() { printf "${GREEN}  [PASS]${NC}  %s\n" "$*"; }
fail() { printf "${RED}  [FAIL]${NC}  %s\n" "$*"; FAILURES=$((FAILURES + 1)); }
info() { printf "${CYAN}  [INFO]${NC}  %s\n" "$*"; }
step() { printf "\n${BOLD}${CYAN}▶ %s${NC}\n" "$*"; }

FAILURES=0

# ── 第一层：静态检查 ──────────────────────────────────────────────────────
layer1() {
    step "第一层：静态检查"

    if bash -n "${INSTALL_SH}" 2>&1; then
        pass "bash -n 语法检查"
    else
        fail "bash -n 语法检查"
    fi

    if command -v shellcheck &>/dev/null; then
        if shellcheck "${INSTALL_SH}" 2>&1; then
            pass "shellcheck"
        else
            fail "shellcheck（见上方输出）"
        fi
    else
        info "shellcheck 未安装，跳过（brew install shellcheck 或 apt install shellcheck）"
    fi
}

# ── 第二层：函数级单测 ────────────────────────────────────────────────────
layer2() {
    step "第二层：函数级单测"

    # detect_platform
    local platform
    platform="$(bash -c "source '${INSTALL_SH}'; detect_platform; echo \$PLATFORM" 2>/dev/null | tail -1)"
    if [[ "$platform" =~ ^(darwin|linux)-(x64|arm64)(-musl)?$ ]]; then
        pass "detect_platform → ${platform}"
    else
        fail "detect_platform 返回非预期值: '${platform}'"
    fi

    # get_latest_version
    local version
    version="$(bash -c "source '${INSTALL_SH}'; get_latest_version; echo \$VERSION" 2>/dev/null | tail -1)"
    if [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        pass "get_latest_version → v${version}"
    else
        fail "get_latest_version 返回非预期值: '${version}'"
    fi

    # check_installed_version（预期已安装且是最新，脚本 exit 0）
    local cv_out
    cv_out="$(bash -c "
        source '${INSTALL_SH}'
        get_latest_version
        check_installed_version
        echo 'needs_install'
    " 2>/dev/null || true)"
    if echo "$cv_out" | grep -q "up to date\|needs_install"; then
        pass "check_installed_version 运行正常"
    else
        fail "check_installed_version 异常输出: '${cv_out}'"
    fi

    # select_mirror
    local mirror_out
    mirror_out="$(bash -c "
        source '${INSTALL_SH}'
        get_latest_version
        select_mirror
        echo \"BEST=\${MIRROR_ORDER[0]}\"
        echo \"GITHUB=\${GITHUB_MIRROR}\"
    " 2>/dev/null)"
    if echo "$mirror_out" | grep -q "^BEST=https://"; then
        local best github
        best="$(echo "$mirror_out" | grep '^BEST=' | cut -d= -f2-)"
        github="$(echo "$mirror_out" | grep '^GITHUB=' | cut -d= -f2-)"
        pass "select_mirror → BEST=${best}"
        if [[ -n "$github" ]]; then
            pass "GITHUB_MIRROR → ${github}"
        else
            fail "GITHUB_MIRROR 未设置"
        fi
    else
        fail "select_mirror 未返回有效镜像: '${mirror_out}'"
    fi

    # _mirror_label（验证代理镜像标签正确）
    local label_out
    label_out="$(bash -c "
        source '${INSTALL_SH}'
        _mirror_label 'https://ghfast.top/https://github.com'
    " 2>/dev/null)"
    if [[ "$label_out" == "ghfast.top" ]]; then
        pass "_mirror_label 代理镜像标签正确 → ${label_out}"
    else
        fail "_mirror_label 返回非预期标签: '${label_out}'（期望 ghfast.top）"
    fi
}

# ── 第三层：关键逻辑模拟 ──────────────────────────────────────────────────
layer3() {
    step "第三层：关键逻辑模拟"

    # 模拟：第一个源（GCS）不可达，自动降级到第二个
    local fallback_out
    fallback_out="$(bash -c "
        source '${INSTALL_SH}'
        MIRROR_ORDER=('https://unreachable.example.com/gcs' 'https://github.com')
        GCS_BUCKET='https://unreachable.example.com/gcs'
        detect_platform; VERSION='2.1.85'
        TMP_DIR=\$(mktemp -d); trap 'rm -rf \$TMP_DIR' EXIT
        for mirror in \"\${MIRROR_ORDER[@]}\"; do
            if [[ \"\$mirror\" == \"\$GCS_BUCKET\" ]]; then
                _download_from_gcs \"\$TMP_DIR/bin\" 2>/dev/null && { echo 'gcs_ok'; break; }
            else
                echo \"fallback:\$mirror\"; break
            fi
            true
        done
    " 2>/dev/null)"
    if echo "$fallback_out" | grep -q "^fallback:https://github.com"; then
        pass "GCS 失败 → 自动降级到下一个源"
    else
        fail "GCS 失败降级异常: '${fallback_out}'"
    fi

    # 模拟：所有源都不可达，期望文件不存在（download_and_verify 会 die）
    local all_fail_out
    all_fail_out="$(bash -c "
        source '${INSTALL_SH}'
        MIRROR_ORDER=('https://unreachable1.example.com' 'https://unreachable2.example.com')
        GITHUB_MIRROR='https://unreachable1.example.com'
        GCS_BUCKET='https://unreachable_gcs.example.com'
        detect_platform; VERSION='2.1.85'
        TMP_DIR=\$(mktemp -d); trap 'rm -rf \$TMP_DIR' EXIT
        set +e
        for mirror in \"\${MIRROR_ORDER[@]}\"; do
            _download_from_github \"\$TMP_DIR/bin\" \"\$mirror\" 2>/dev/null || true
        done
        [[ -f \"\$TMP_DIR/bin\" ]] && echo 'unexpected_file' || echo 'no_file_as_expected'
    " 2>/dev/null)"
    if echo "$all_fail_out" | grep -q "no_file_as_expected"; then
        pass "全部源失败 → 文件不存在（die 路径正确）"
    else
        fail "全部源失败时行为异常: '${all_fail_out}'"
    fi

    # 模拟：TARGET 参数校验（非法值应拒绝）
    local target_out
    target_out="$(bash "${INSTALL_SH}" invalid-target 2>&1 || true)"
    if echo "$target_out" | grep -q "Usage:"; then
        pass "非法 TARGET 参数 → 输出 Usage 提示"
    else
        fail "非法 TARGET 参数未被拒绝: '${target_out}'"
    fi
}

# ── 第四层：Docker 隔离（Linux/macOS bash） ───────────────────────────────
layer4() {
    step "第四层：Docker 隔离环境"

    if ! command -v docker &>/dev/null; then
        info "Docker 未安装，跳过第四层"
        return
    fi

    # Ubuntu 24.04 - glibc
    info "启动 Ubuntu 24.04 容器..."
    local ubuntu_out
    ubuntu_out="$(docker run --rm \
        -v "${INSTALL_SH}:/install.sh" \
        ubuntu:24.04 bash -c '
            apt-get update -q && apt-get install -q -y curl git 2>/dev/null
            bash -c "source /install.sh; detect_platform; echo PLATFORM=\$PLATFORM"
            bash -c "source /install.sh; get_latest_version; echo VERSION=\$VERSION"
            bash -c "source /install.sh; detect_platform; check_git; echo GIT_OK"
        ' 2>/dev/null)"

    if echo "$ubuntu_out" | grep -q "PLATFORM=linux-x64"; then
        pass "Ubuntu: detect_platform → linux-x64"
    else
        fail "Ubuntu: detect_platform 异常: '${ubuntu_out}'"
    fi
    if echo "$ubuntu_out" | grep -qE "VERSION=[0-9]+\.[0-9]+\.[0-9]+"; then
        pass "Ubuntu: get_latest_version 正常"
    else
        fail "Ubuntu: get_latest_version 异常"
    fi
    if echo "$ubuntu_out" | grep -q "GIT_OK"; then
        pass "Ubuntu: check_git 正常"
    else
        fail "Ubuntu: check_git 异常"
    fi

    # Alpine - musl
    info "启动 Alpine 容器（musl 检测）..."
    local alpine_out
    alpine_out="$(docker run --rm \
        -v "${INSTALL_SH}:/install.sh" \
        alpine:latest sh -c '
            apk add --no-cache bash curl git 2>/dev/null
            bash -c "source /install.sh; detect_platform; echo PLATFORM=\$PLATFORM"
            bash -c "source /install.sh; get_latest_version; echo VERSION=\$VERSION"
        ' 2>/dev/null)"

    if echo "$alpine_out" | grep -q "PLATFORM=linux-x64-musl"; then
        pass "Alpine: detect_platform → linux-x64-musl（musl 正确检测）"
    else
        fail "Alpine: detect_platform 异常: '${alpine_out}'"
    fi
    if echo "$alpine_out" | grep -qE "VERSION=[0-9]+\.[0-9]+\.[0-9]+"; then
        pass "Alpine: get_latest_version 正常"
    else
        fail "Alpine: get_latest_version 异常"
    fi
}

# ── 第五层：PowerShell 脚本测试（Docker）─────────────────────────────────
layer5() {
    step "第五层：PowerShell 脚本测试（Docker）"

    if ! command -v docker &>/dev/null; then
        info "Docker 未安装，跳过第五层"
        return
    fi

    info "拉取 PowerShell 镜像并运行 test.ps1 第 1-3 层..."
    local exit_code=0
    docker run --rm \
        -v "${REPO_DIR}:/scripts" \
        mcr.microsoft.com/powershell \
        pwsh -NonInteractive -File /scripts/tests/test.ps1 1 2 3 \
        2>&1 | sed 's/^/    /' || exit_code=$?

    if [[ $exit_code -eq 0 ]]; then
        pass "PowerShell 测试全部通过"
    else
        fail "PowerShell 测试存在失败项（exit $exit_code，见上方输出）"
    fi
}

# ── 第六层：升级检测（Docker）────────────────────────────────────────────
layer6() {
    step "第六层：升级检测（Docker）"

    if ! command -v docker &>/dev/null; then
        info "Docker 未安装，跳过第六层"
        return
    fi

    local out
    out="$(docker run --rm \
        -v "${REPO_DIR}:/installer" \
        ubuntu:24.04 bash -c '
            apt-get update -q && apt-get install -y curl git 2>/dev/null

            export HOME=/tmp/testhome
            mkdir -p "$HOME/.local/bin"
            export PATH="$HOME/.local/bin:$PATH"

            # 伪装旧版本
            printf "#!/bin/sh\necho claude 0.0.1\n" > "$HOME/.local/bin/claude"
            chmod +x "$HOME/.local/bin/claude"

            source /installer/install.sh
            get_latest_version

            # check_installed_version：0.0.1 != latest → 继续（不 exit 0），打印 Upgrading
            check_installed_version
            echo "UPGRADE_NEEDED: $INSTALLED_VERSION"
        ' 2>/dev/null)"

    if echo "$out" | grep -q "^UPGRADE_NEEDED: 0\.0\.1$"; then
        pass "旧版本检测 → 输出 Upgrading，继续安装流程"
    else
        fail "旧版本检测异常: '${out}'"
    fi

    # 已是最新版：check_installed_version 应 exit 0
    local uptodate_out
    uptodate_out="$(docker run --rm \
        -v "${REPO_DIR}:/installer" \
        ubuntu:24.04 bash -c '
            apt-get update -q && apt-get install -y curl git 2>/dev/null

            export HOME=/tmp/testhome
            mkdir -p "$HOME/.local/bin"
            export PATH="$HOME/.local/bin:$PATH"

            source /installer/install.sh
            get_latest_version

            # 伪装已安装最新版
            printf "#!/bin/sh\necho claude %s\n" "$VERSION" > "$HOME/.local/bin/claude"
            chmod +x "$HOME/.local/bin/claude"

            set +e
            check_installed_version
            echo "EXIT_STATUS:$?"
        ' 2>/dev/null)"

    if echo "$uptodate_out" | grep -q "already up to date"; then
        pass "已是最新版 → 输出 already up to date，exit 0"
    else
        fail "已是最新版检测异常: '${uptodate_out}'"
    fi
}

# ── 第七层：卸载（Docker）────────────────────────────────────────────────
layer7() {
    step "第七层：卸载（Docker）"

    if ! command -v docker &>/dev/null; then
        info "Docker 未安装，跳过第七层"
        return
    fi

    # 7a：正常卸载 — fake 安装后全量清理
    local uninstall_out
    uninstall_out="$(docker run --rm \
        -v "${REPO_DIR}:/installer" \
        ubuntu:24.04 bash -c '
            export HOME=/tmp/testhome

            # 建立 fake 安装
            mkdir -p "$HOME/.local/bin" "$HOME/.local/share/claude-code" "$HOME/.claude"
            printf "#!/bin/sh\necho claude 2.1.85\n" > "$HOME/.local/bin/claude"
            chmod +x "$HOME/.local/bin/claude"
            echo "2.1.85" > "$HOME/.local/share/claude-code/version"
            echo "{}" > "$HOME/.claude.json"
            # ANTHROPIC_API_KEY 写入 .bashrc
            echo "export ANTHROPIC_API_KEY=test-key" >> "$HOME/.bashrc"

            # 加载 uninstall.sh（去掉最后一行 main "$@"），再覆盖 ask() 为 yes
            head -n -1 /installer/uninstall.sh > /tmp/uninstall_nomain.sh
            source /tmp/uninstall_nomain.sh
            ask() { return 0; }

            main 2>/dev/null

            # 验证清理结果
            [[ ! -f "$HOME/.local/bin/claude"              ]] && echo "PASS: binary removed"       || echo "FAIL: binary still exists"
            [[ ! -d "$HOME/.local/share/claude-code"       ]] && echo "PASS: data dir removed"     || echo "FAIL: data dir still exists"
            [[ ! -d "$HOME/.claude"                        ]] && echo "PASS: config dir removed"   || echo "FAIL: config dir still exists"
            [[ ! -f "$HOME/.claude.json"                   ]] && echo "PASS: config file removed"  || echo "FAIL: config file still exists"
            grep -q "ANTHROPIC_API_KEY" "$HOME/.bashrc" \
                && echo "FAIL: ANTHROPIC_API_KEY still in .bashrc" \
                || echo "PASS: ANTHROPIC_API_KEY removed from .bashrc"
        ' 2>/dev/null)"

    local ok_count fail_count
    ok_count="$(echo "$uninstall_out" | grep -c "^PASS:" || true)"
    fail_count="$(echo "$uninstall_out" | grep -c "^FAIL:" || true)"

    if [[ $fail_count -eq 0 ]] && [[ $ok_count -ge 5 ]]; then
        pass "卸载：binary / data / config / ANTHROPIC_* 全部清理（${ok_count} 项）"
    else
        echo "$uninstall_out" | while IFS= read -r line; do printf "    %s\n" "$line"; done
        fail "卸载清理不完整（PASS=${ok_count} FAIL=${fail_count}）"
    fi

    # 7b：未安装时运行卸载 → exit 0 + "not installed"
    local notinstalled_out
    notinstalled_out="$(docker run --rm \
        -v "${REPO_DIR}:/installer" \
        ubuntu:24.04 bash -c '
            export HOME=/tmp/emptyhome
            mkdir -p "$HOME"
            bash /installer/uninstall.sh 2>/dev/null
            echo "EXIT:$?"
        ' 2>/dev/null)"

    if echo "$notinstalled_out" | grep -qi "does not appear to be installed"; then
        pass "未安装时卸载 → 正确提示未安装，exit 0"
    else
        fail "未安装时卸载行为异常: '${notinstalled_out}'"
    fi
}

# ── 主入口 ────────────────────────────────────────────────────────────────
main() {
    printf "\n${BOLD}${CYAN}━━━ install.sh 测试 ━━━${NC}  ProjectAILeap/claude-code-installer\n\n"

    local layers=("${@:-1 2 3 4}")
    # 无参数时运行全部
    if [[ $# -eq 0 ]]; then
        layers=(1 2 3 4 5 6 7)
    else
        layers=("$@")
    fi

    for l in "${layers[@]}"; do
        case "$l" in
            1) layer1 ;;
            2) layer2 ;;
            3) layer3 ;;
            4) layer4 ;;
            5) layer5 ;;
            6) layer6 ;;
            7) layer7 ;;
            *) printf "${YELLOW}  未知层: %s，跳过${NC}\n" "$l" ;;
        esac
    done

    printf "\n${BOLD}━━━ 结果 ━━━${NC}\n"
    if [[ $FAILURES -eq 0 ]]; then
        printf "${GREEN}${BOLD}  全部通过${NC}\n\n"
        exit 0
    else
        printf "${RED}${BOLD}  失败: %d 项${NC}\n\n" "$FAILURES"
        exit 1
    fi
}

main "$@"
