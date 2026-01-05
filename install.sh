#!/usr/bin/env sh
# ==============================================================================
# SiteProxy Easy Installer
# 一键部署脚本，支持 Linux (Debian/Ubuntu/CentOS/Alpine) + FreeBSD/Serv00/HostUno
# ==============================================================================
set -eu

# =========================
# 颜色定义
# =========================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# =========================
# 全局变量
# =========================
SITEPROXY_DIR="${HOME}/siteproxy"
CONFIG_FILE="${SITEPROXY_DIR}/config.json"
BUNDLE_FILE="${SITEPROXY_DIR}/bundle.cjs"
LOG_FILE="${SITEPROXY_DIR}/siteproxy.log"
PID_FILE="${SITEPROXY_DIR}/siteproxy.pid"

DEFAULT_PORT=5006
REPO_OWNER="netptop"
REPO_NAME="siteproxy"

OS_FAMILY="unknown"      # debian|rhel|alpine|freebsd|unknown
INIT_SYSTEM="none"       # systemd|openrc|freebsd|serv00|none
PKG_MGR="none"           # apt|dnf|yum|apk|pkg|none
IS_SERV00="0"

# =========================
# 日志函数
# =========================
info()  { printf "${GREEN}[INFO]${NC} %s\n" "$*"; }
warn()  { printf "${YELLOW}[WARN]${NC} %s\n" "$*"; }
error() { printf "${RED}[ERR ]${NC} %s\n" "$*" >&2; }

have_cmd() { command -v "$1" >/dev/null 2>&1; }

# =========================
# 权限处理
# =========================
is_root() { [ "$(id -u)" -eq 0 ]; }

as_root() {
  if is_root; then
    "$@"
  elif have_cmd sudo; then
    sudo "$@"
  else
    error "需要 root/sudo 权限执行：$*"
    return 1
  fi
}

# =========================
# 系统检测
# =========================
detect_os() {
  if [ "$(uname -s)" = "FreeBSD" ]; then
    OS_FAMILY="freebsd"
    return 0
  fi

  if [ -f /etc/alpine-release ]; then
    OS_FAMILY="alpine"
  elif [ -f /etc/debian_version ]; then
    OS_FAMILY="debian"
  elif [ -f /etc/redhat-release ] || [ -f /etc/centos-release ] || [ -f /etc/fedora-release ]; then
    OS_FAMILY="rhel"
  else
    OS_FAMILY="unknown"
  fi
}

detect_init_system() {
  IS_SERV00="0"
  if [ "$OS_FAMILY" = "freebsd" ]; then
    if have_cmd devil; then
      # Serv00/HostUno 类环境：FreeBSD + devil
      IS_SERV00="1"
      INIT_SYSTEM="serv00"
    else
      INIT_SYSTEM="freebsd"
    fi
    return 0
  fi

  # Linux
  if have_cmd systemctl && [ -d /run/systemd/system ]; then
    INIT_SYSTEM="systemd"
  elif have_cmd rc-service || [ -d /run/openrc ] || have_cmd openrc-run; then
    INIT_SYSTEM="openrc"
  else
    INIT_SYSTEM="none"
  fi
}

detect_package_manager() {
  if [ "$OS_FAMILY" = "freebsd" ]; then
    if have_cmd pkg; then PKG_MGR="pkg"; else PKG_MGR="none"; fi
    return 0
  fi

  if have_cmd apt-get; then PKG_MGR="apt"
  elif have_cmd dnf; then PKG_MGR="dnf"
  elif have_cmd yum; then PKG_MGR="yum"
  elif have_cmd apk; then PKG_MGR="apk"
  else PKG_MGR="none"
  fi
}

show_env_summary() {
  info "检测结果：OS_FAMILY=${OS_FAMILY}, INIT_SYSTEM=${INIT_SYSTEM}, PKG_MGR=${PKG_MGR}, IS_SERV00=${IS_SERV00}"
}

# =========================
# 包管理
# =========================
pkg_install() {
  [ "$PKG_MGR" != "none" ] || return 0

  case "$PKG_MGR" in
    apt)
      as_root apt-get update -y
      as_root apt-get install -y "$@"
      ;;
    dnf)
      as_root dnf install -y "$@"
      ;;
    yum)
      as_root yum install -y "$@"
      ;;
    apk)
      as_root apk add --no-cache "$@"
      ;;
    pkg)
      as_root pkg install -y "$@"
      ;;
    *)
      return 0
      ;;
  esac
}

ensure_base_tools() {
  if ! have_cmd curl; then
    warn "缺少 curl，尝试安装..."
    pkg_install curl ca-certificates
  fi

  if ! have_cmd tar; then
    warn "缺少 tar，尝试安装..."
    pkg_install tar
  fi

  if ! have_cmd xz; then
    warn "缺少 xz，尝试安装..."
    case "$PKG_MGR" in
      apt) pkg_install xz-utils ;;
      dnf|yum) pkg_install xz ;;
      apk) pkg_install xz ;;
      pkg) pkg_install xz ;;
      *) : ;;
    esac
  fi

  if [ "$OS_FAMILY" = "alpine" ]; then
    if ! have_cmd bash; then
      warn "Alpine 未安装 bash（NVM 可能需要），尝试安装 bash..."
      pkg_install bash
    fi
  fi

  if [ "$OS_FAMILY" = "freebsd" ]; then
    if ! have_cmd bash; then
      warn "FreeBSD 未安装 bash（NVM 可能需要），尝试安装 bash..."
      pkg_install bash
    fi
  fi
}

# =========================
# Node.js 安装
# =========================
node_major() {
  if ! have_cmd node; then
    printf ""
    return 0
  fi
  v="$(node -v 2>/dev/null || true)"
  v="${v#v}"
  printf "%s" "$v" | awk -F. '{print $1}'
}

check_nodejs() {
  m="$(node_major)"
  if [ -n "$m" ] && [ "$m" -ge 22 ] 2>/dev/null; then
    info "Node.js 已满足要求：$(node -v)"
    return 0
  fi
  return 1
}

install_nodejs_pkg_freebsd() {
  info "尝试通过 FreeBSD pkg 安装 Node.js 22..."
  if as_root pkg install -y node22 >/dev/null 2>&1; then
    return 0
  fi
  if as_root pkg install -y npm-node22 >/dev/null 2>&1; then
    return 0
  fi
  warn "pkg 安装 node22 失败，将尝试其他方式（NVM/二进制）"
  return 1
}

install_nodejs_pkg_alpine() {
  info "尝试通过 apk 安装 nodejs-current..."
  if as_root apk add --no-cache nodejs-current npm >/dev/null 2>&1; then
    return 0
  fi
  warn "apk 安装 nodejs-current 失败，将尝试 NVM/二进制方案"
  return 1
}

install_nodejs_nvm() {
  if ! have_cmd bash; then
    warn "系统缺少 bash，尝试安装 bash..."
    pkg_install bash
  fi
  if ! have_cmd bash; then
    error "仍未检测到 bash，无法使用 NVM 安装 Node.js。"
    return 1
  fi

  export NVM_DIR="${HOME}/.nvm"
  if [ -s "${NVM_DIR}/nvm.sh" ]; then
    info "检测到已安装 NVM：${NVM_DIR}"
  else
    info "安装 NVM..."
    bash -c "curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.3/install.sh | bash"
  fi

  info "通过 NVM 安装 Node.js v22..."
  # 使用 login shell 确保加载完整环境
  bash -lc ". \"${NVM_DIR}/nvm.sh\" && nvm install v22 && nvm use v22 && nvm alias default v22"
  
  # 从 bash 子进程获取 node 绝对路径，注入到当前 sh 的 PATH
  nodep="$(bash -lc ". \"$NVM_DIR/nvm.sh\" >/dev/null 2>&1 && nvm which v22" 2>/dev/null || true)"
  if [ -n "$nodep" ] && [ -x "$nodep" ]; then
    export PATH="$(dirname "$nodep"):$PATH"
    info "已将 NVM 的 Node 注入 PATH：$nodep"
  fi
}

install_nodejs_binary() {
  # 使用 /dist/ 目录更稳定（有完整的 index listing）
  BASE_URL="https://nodejs.org/dist/latest-v22.x"

  uname_s="$(uname -s)"
  uname_m="$(uname -m)"

  # FreeBSD 不支持 Linux 二进制，直接返回失败
  if [ "$uname_s" = "FreeBSD" ]; then
    warn "FreeBSD 不支持 Linux 二进制，请使用 pkg 或 NVM 安装 Node.js"
    return 1
  fi

  plat="linux"

  case "$uname_m" in
    x86_64|amd64) arch="x64" ;;
    aarch64|arm64) arch="arm64" ;;
    armv7l|armv7) arch="armv7l" ;;
    *) arch="x64" ;;
  esac

  info "尝试通过 Node.js 官方二进制安装（${plat}-${arch}）..."
  html="$(curl -fsSL "${BASE_URL}/" || true)"
  if [ -z "$html" ]; then
    error "无法访问 ${BASE_URL}，二进制安装失败。"
    return 1
  fi

  ver="$(printf "%s" "$html" | sed -n "s/.*node-v\([0-9.]*\)-${plat}-${arch}\.tar\.xz.*/\1/p" | head -n 1)"
  if [ -z "$ver" ]; then
    error "未能从 ${BASE_URL} 解析出适配包版本号。"
    return 1
  fi

  file="node-v${ver}-${plat}-${arch}.tar.xz"
  url="${BASE_URL}/${file}"

  tmpdir="$(mktemp -d 2>/dev/null || mktemp -d -t spx)"

  info "下载：${url}"
  if ! curl -fL "${url}" -o "${tmpdir}/${file}"; then
    rm -rf "$tmpdir" 2>/dev/null || true
    error "下载失败：${url}"
    return 1
  fi

  install_root="${HOME}/.local"
  mkdir -p "${install_root}"
  tar -xJf "${tmpdir}/${file}" -C "${install_root}"

  ln -snf "${install_root}/node-v${ver}-${plat}-${arch}" "${install_root}/node"
  mkdir -p "${HOME}/.local/bin"
  ln -sf "${install_root}/node/bin/node" "${HOME}/.local/bin/node"
  ln -sf "${install_root}/node/bin/npm"  "${HOME}/.local/bin/npm"  || true
  ln -sf "${install_root}/node/bin/npx"  "${HOME}/.local/bin/npx"  || true

  # 清理临时目录
  rm -rf "$tmpdir" 2>/dev/null || true

  profile="${HOME}/.profile"
  if ! grep -q 'HOME/.local/bin' "$profile" 2>/dev/null; then
    printf '\n# Added by SiteProxy installer\nexport PATH="$HOME/.local/bin:$PATH"\n' >> "$profile"
    warn "已将 \$HOME/.local/bin 写入 ~/.profile；请重新登录或执行：. ~/.profile"
  fi

  export PATH="${HOME}/.local/bin:${PATH}"
  info "二进制安装完成：node $(node -v 2>/dev/null || true)"
}

install_nodejs() {
  if check_nodejs; then return 0; fi

  ensure_base_tools

  # Serv00/HostUno：优先使用已有 node，否则二进制兜底
  if [ "$INIT_SYSTEM" = "serv00" ]; then
    warn "检测到 Serv00/HostUno 环境：优先使用系统自带 Node.js；若缺失则尝试二进制兜底。"
    if check_nodejs; then return 0; fi
    install_nodejs_binary || true
    check_nodejs && return 0
    error "Serv00 环境未能安装到 Node.js v22+。请确认是否允许在用户目录运行自带二进制。"
    return 1
  fi

  if [ "$OS_FAMILY" = "freebsd" ]; then
    if is_root || have_cmd sudo; then
      install_nodejs_pkg_freebsd || true
      check_nodejs && return 0
    fi
    install_nodejs_nvm || true
    check_nodejs && return 0
    # FreeBSD 不使用 Linux 二进制兜底
    error "FreeBSD 上 Node.js 安装失败。请确保 pkg 源有 node22 或手动安装 NVM。"
    return 1
  fi

  if [ "$OS_FAMILY" = "alpine" ]; then
    if is_root || have_cmd sudo; then
      install_nodejs_pkg_alpine || true
      check_nodejs && return 0
    fi
    install_nodejs_nvm || true
    check_nodejs && return 0
    install_nodejs_binary || true
    check_nodejs && return 0
    return 1
  fi

  # Debian/RHEL/其他 Linux：优先 NVM
  install_nodejs_nvm || true
  check_nodejs && return 0

  # 兜底二进制
  install_nodejs_binary || true
  check_nodejs && return 0

  return 1
}

# =========================
# SiteProxy 下载
# =========================
get_latest_tag() {
  loc="$(curl -fsSLI "https://github.com/${REPO_OWNER}/${REPO_NAME}/releases/latest" \
    | awk 'BEGIN{IGNORECASE=1} /^location:/{print $2}' \
    | tr -d '\r' \
    | tail -n 1 || true)"

  if [ -n "$loc" ]; then
    tag="${loc##*/}"
    printf "%s" "$tag"
    return 0
  fi

  printf "%s" "master"
}

download_siteproxy() {
  ensure_base_tools
  mkdir -p "$SITEPROXY_DIR"

  tag="$(get_latest_tag)"
  tmpdir="$(mktemp -d 2>/dev/null || mktemp -d -t spx)"

  if [ "$tag" = "master" ]; then
    warn "未能解析到最新 release tag，改用 master 分支打包下载。"
    tar_url="https://codeload.github.com/${REPO_OWNER}/${REPO_NAME}/tar.gz/refs/heads/master"
  else
    info "检测到最新 release：${tag}"
    tar_url="https://codeload.github.com/${REPO_OWNER}/${REPO_NAME}/tar.gz/refs/tags/${tag}"
  fi

  info "下载 SiteProxy 源码包：${tar_url}"
  if ! curl -fL "$tar_url" -o "${tmpdir}/siteproxy.tar.gz"; then
    rm -rf "$tmpdir" 2>/dev/null || true
    error "下载失败：${tar_url}"
    return 1
  fi

  tar -xzf "${tmpdir}/siteproxy.tar.gz" -C "${tmpdir}"

  srcdir="$(find "${tmpdir}" -maxdepth 1 -type d -name "${REPO_NAME}-*" | head -n 1 || true)"
  if [ -z "$srcdir" ]; then
    rm -rf "$tmpdir" 2>/dev/null || true
    error "解压失败，未找到源码目录。"
    return 1
  fi

  if [ ! -f "${srcdir}/bundle.cjs" ] || [ ! -f "${srcdir}/config.json" ]; then
    rm -rf "$tmpdir" 2>/dev/null || true
    error "源码包中未找到 bundle.cjs 或 config.json。"
    return 1
  fi

  cp -f "${srcdir}/bundle.cjs" "${BUNDLE_FILE}"
  cp -f "${srcdir}/config.json" "${SITEPROXY_DIR}/config.json.dist"

  # 清理临时目录
  rm -rf "$tmpdir" 2>/dev/null || true

  info "SiteProxy 下载完成：${SITEPROXY_DIR}"
}

# =========================
# 配置管理
# =========================
normalize_token_prefix() {
  t="$1"
  # 不设密码：返回空字符串（项目 README 规定为空表示不设密码）
  [ -z "$t" ] && { printf ""; return 0; }

  case "$t" in
    /*) : ;;
    *)  t="/$t" ;;
  esac
  case "$t" in
    */) : ;;
    *)  t="$t/" ;;
  esac
  printf "%s" "$t"
}

configure_siteproxy() {
  mkdir -p "$SITEPROXY_DIR"

  printf "请输入代理域名（必须 https，例如 https://your-proxy.domain）: "
  read -r proxy_url || proxy_url=""
  if [ -z "$proxy_url" ]; then
    warn "proxy_url 为空，使用示例值（请稍后修改）。"
    proxy_url="https://your-proxy.domain.name"
  fi
  case "$proxy_url" in
    https://*) : ;;
    *)
      warn "根据项目说明，proxy_url 应为 https:// 开头。已自动补全 https://"
      proxy_url="https://${proxy_url#http://}"
      ;;
  esac
  # 去除末尾斜杠，避免与 token_prefix 拼接时出现双斜杠
  proxy_url="${proxy_url%/}"

  printf "请输入访问密码（token_prefix，不含首尾斜杠也可；直接回车表示不设密码）: "
  read -r token_in || token_in=""
  token_prefix="$(normalize_token_prefix "$token_in")"

  printf "请输入本地监听端口（默认 %s）: " "$DEFAULT_PORT"
  read -r port_in || port_in=""
  if [ -z "$port_in" ]; then
    local_port="$DEFAULT_PORT"
  else
    # 端口校验：必须为纯数字且范围 1-65535
    case "$port_in" in
      *[!0-9]*)
        warn "端口必须为纯数字，使用默认值 ${DEFAULT_PORT}"
        local_port="$DEFAULT_PORT"
        ;;
      *)
        if [ "$port_in" -ge 1 ] && [ "$port_in" -le 65535 ] 2>/dev/null; then
          local_port="$port_in"
        else
          warn "端口范围应为 1-65535，使用默认值 ${DEFAULT_PORT}"
          local_port="$DEFAULT_PORT"
        fi
        ;;
    esac
  fi

  cat > "$CONFIG_FILE" <<EOF
{
  "proxy_url": "${proxy_url}",
  "token_prefix": "${token_prefix}",
  "local_listen_port": ${local_port},
  "description": "注意：token_prefix 相当于网站密码，请谨慎设置。proxy_url 和 token_prefix 合起来就是访问网址。"
}
EOF

  # 保护配置文件权限（包含密码）
  chmod 600 "$CONFIG_FILE" 2>/dev/null || true

  info "配置已写入：${CONFIG_FILE}"
  # 根据是否有密码显示不同的访问示例
  if [ -n "$token_prefix" ]; then
    info "访问形式示例：${proxy_url}${token_prefix}https://www.google.com"
  else
    info "访问形式示例：${proxy_url}/https://www.google.com"
  fi
}

# =========================
# 服务管理
# =========================
node_path_resolve() {
  if have_cmd node; then
    command -v node
  else
    printf ""
  fi
}

ensure_bundle_present() {
  if [ ! -f "$BUNDLE_FILE" ]; then
    error "未找到 ${BUNDLE_FILE}；请先执行 \"安装 SiteProxy\"。"
    return 1
  fi
  if [ ! -f "$CONFIG_FILE" ]; then
    warn "未找到 ${CONFIG_FILE}；将进入配置向导。"
    configure_siteproxy
  fi
  return 0
}

create_systemd_service_system() {
  ensure_bundle_present || return 1
  nodep="$(node_path_resolve)"
  [ -n "$nodep" ] || { error "未找到 node 可执行文件"; return 1; }

  svc="/etc/systemd/system/siteproxy.service"
  user="$(id -un)"
  
  # 获取用户的 NVM 路径（如果存在）
  nvm_dir="${HOME}/.nvm"
  env_path="/usr/local/bin:/usr/bin:/bin"
  if [ -d "$nvm_dir" ]; then
    env_path="${nvm_dir}/versions/node/$(node -v)/bin:${env_path}"
  fi
  if [ -d "${HOME}/.local/bin" ]; then
    env_path="${HOME}/.local/bin:${env_path}"
  fi

  # 使用 tee 写入系统文件（解决 sudo 重定向权限问题）
  cat <<EOF | as_root tee "$svc" >/dev/null
[Unit]
Description=SiteProxy Web Proxy Service
After=network.target

[Service]
Type=simple
User=${user}
WorkingDirectory=${SITEPROXY_DIR}
ExecStart=${nodep} ${BUNDLE_FILE}
Restart=on-failure
RestartSec=3
Environment=NODE_ENV=production
Environment=PATH=${env_path}

[Install]
WantedBy=multi-user.target
EOF

  as_root systemctl daemon-reload
  as_root systemctl enable --now siteproxy
  info "systemd 服务已创建并启动：siteproxy"
}

create_systemd_service_user() {
  ensure_bundle_present || return 1
  nodep="$(node_path_resolve)"
  [ -n "$nodep" ] || { error "未找到 node 可执行文件"; return 1; }

  dir="${HOME}/.config/systemd/user"
  mkdir -p "$dir"
  svc="${dir}/siteproxy.service"

  cat > "$svc" <<EOF
[Unit]
Description=SiteProxy Web Proxy Service (user)
After=network.target

[Service]
Type=simple
WorkingDirectory=${SITEPROXY_DIR}
ExecStart=${nodep} ${BUNDLE_FILE}
Restart=on-failure
RestartSec=3
Environment=NODE_ENV=production

[Install]
WantedBy=default.target
EOF

  systemctl --user daemon-reload
  systemctl --user enable --now siteproxy || true
  info "user systemd 服务已创建并尝试启动：siteproxy（提示：user service 自启动可能需要 enable-linger）"
}

create_openrc_service() {
  ensure_bundle_present || return 1
  nodep="$(node_path_resolve)"
  [ -n "$nodep" ] || { error "未找到 node 可执行文件"; return 1; }

  svc="/etc/init.d/siteproxy"
  
  # 使用 tee 写入系统文件（解决 sudo 重定向权限问题）
  cat <<EOF | as_root tee "$svc" >/dev/null
#!/sbin/openrc-run
# OpenRC service script for SiteProxy

name="siteproxy"
description="SiteProxy Web Proxy Service"
command="${nodep}"
command_args="${BUNDLE_FILE}"
directory="${SITEPROXY_DIR}"
pidfile="/run/\${name}.pid"
command_background="yes"
output_log="${LOG_FILE}"
error_log="${LOG_FILE}"

depend() {
  need net
}

start_pre() {
  checkpath --directory --owner root:root --mode 0755 /run
}
EOF

  as_root chmod +x "$svc"
  as_root rc-update add siteproxy default || true
  as_root rc-service siteproxy restart || as_root rc-service siteproxy start
  info "OpenRC 服务已创建并启动：siteproxy"
}

create_freebsd_service() {
  ensure_bundle_present || return 1
  nodep="$(node_path_resolve)"
  [ -n "$nodep" ] || { error "未找到 node 可执行文件"; return 1; }

  svc="/usr/local/etc/rc.d/siteproxy"
  
  # 使用 tee 写入系统文件（解决 sudo 重定向权限问题）
  cat <<EOF | as_root tee "$svc" >/dev/null
#!/bin/sh
# PROVIDE: siteproxy
# REQUIRE: NETWORKING
# KEYWORD: shutdown

. /etc/rc.subr

name="siteproxy"
rcvar=siteproxy_enable

load_rc_config \$name

: \${siteproxy_enable:="NO"}

pidfile="/var/run/\${name}.pid"
command="/usr/sbin/daemon"
command_args="-f -p \${pidfile} -o ${LOG_FILE} ${nodep} ${BUNDLE_FILE}"

run_rc_command "\$1"
EOF

  as_root chmod +x "$svc"

  if ! grep -q '^siteproxy_enable=' /etc/rc.conf 2>/dev/null; then
    warn "将写入 /etc/rc.conf：siteproxy_enable=\"YES\""
    printf '\nsiteproxy_enable="YES"\n' | as_root tee -a /etc/rc.conf >/dev/null
  fi

  as_root service siteproxy restart || as_root service siteproxy start
  info "FreeBSD rc.d 服务已创建并启动：siteproxy"
}

create_serv00_service() {
  ensure_bundle_present || return 1
  nodep="$(node_path_resolve)"
  [ -n "$nodep" ] || { error "未找到 node 可执行文件"; return 1; }

  # 获取端口
  port="$(awk -F: '/local_listen_port/ {gsub(/[^0-9]/,"",$2); print $2}' "$CONFIG_FILE" 2>/dev/null | head -n 1 || true)"
  [ -n "$port" ] || port="$DEFAULT_PORT"

  # Serv00/HostUno 端口管理
  if have_cmd devil; then
    warn "Serv00/HostUno：尝试开启执行权限与端口（如失败请到面板手动配置）"
    devil binexec on >/dev/null 2>&1 || true
    devil port add tcp "$port" >/dev/null 2>&1 || true
  fi

  runsh="${SITEPROXY_DIR}/run.sh"
  keep="${SITEPROXY_DIR}/keepalive.sh"

  cat > "$runsh" <<EOF
#!/bin/sh
cd "${SITEPROXY_DIR}" || exit 1
nohup "${nodep}" "${BUNDLE_FILE}" >> "${LOG_FILE}" 2>&1 &
echo \$! > "${PID_FILE}"
EOF
  chmod +x "$runsh"

  cat > "$keep" <<EOF
#!/bin/sh
# 每分钟检查一次进程，不在则拉起
# 停机闸门：如果存在 .stop 文件则不启动
STOP_FLAG="${SITEPROXY_DIR}/.stop"
[ -f "\$STOP_FLAG" ] && exit 0

# 加入随机延迟避免瞬时抖动导致重复拉起
sleep \$(awk 'BEGIN{srand();print int(rand()*3)}')

# 再次检查停机闸门
[ -f "\$STOP_FLAG" ] && exit 0

if [ -f "${PID_FILE}" ]; then
  pid=\$(cat "${PID_FILE}" 2>/dev/null || true)
  if [ -n "\$pid" ] && kill -0 "\$pid" >/dev/null 2>&1; then
    exit 0
  fi
fi
# 再次确认进程不存在后启动
sleep 1
if [ -f "${PID_FILE}" ]; then
  pid=\$(cat "${PID_FILE}" 2>/dev/null || true)
  if [ -n "\$pid" ] && kill -0 "\$pid" >/dev/null 2>&1; then
    exit 0
  fi
fi
"${runsh}" >/dev/null 2>&1
EOF
  chmod +x "$keep"

  # 加入 crontab（避免重复）
  (crontab -l 2>/dev/null || true) | grep -v "${keep}" > "${SITEPROXY_DIR}/.crontab.tmp" || true
  printf "*/1 * * * * %s >/dev/null 2>&1\n" "$keep" >> "${SITEPROXY_DIR}/.crontab.tmp"
  crontab "${SITEPROXY_DIR}/.crontab.tmp" || true
  rm -f "${SITEPROXY_DIR}/.crontab.tmp" || true

  sh "$runsh"
  info "Serv00/HostUno 后台启动完成（nohup + cron 保活）。日志：${LOG_FILE}"
}

create_service() {
  case "$INIT_SYSTEM" in
    systemd)
      if is_root || have_cmd sudo; then
        create_systemd_service_system
      else
        create_systemd_service_user
      fi
      ;;
    openrc)
      create_openrc_service
      ;;
    freebsd)
      create_freebsd_service
      ;;
    serv00)
      create_serv00_service
      ;;
    *)
      warn "未检测到可用服务管理器，将使用 nohup 后台方式启动。"
      ensure_bundle_present || return 1
      nodep="$(node_path_resolve)"
      [ -n "$nodep" ] || { error "未找到 node 可执行文件"; return 1; }
      (cd "$SITEPROXY_DIR" && nohup "$nodep" "$BUNDLE_FILE" >> "$LOG_FILE" 2>&1 & echo $! > "$PID_FILE")
      info "已后台启动（nohup）。PID：$(cat "$PID_FILE" 2>/dev/null || true) 日志：${LOG_FILE}"
      ;;
  esac
}

start_service() {
  case "$INIT_SYSTEM" in
    systemd)
      if is_root || have_cmd sudo; then as_root systemctl start siteproxy
      else systemctl --user start siteproxy || true
      fi
      ;;
    openrc) as_root rc-service siteproxy start ;;
    freebsd) as_root service siteproxy start ;;
    serv00)
      # 移除停机闸门
      rm -f "${SITEPROXY_DIR}/.stop" 2>/dev/null || true
      sh "${SITEPROXY_DIR}/run.sh" || true
      ;;
    *)
      ensure_bundle_present || return 1
      nodep="$(node_path_resolve)"
      (cd "$SITEPROXY_DIR" && nohup "$nodep" "$BUNDLE_FILE" >> "$LOG_FILE" 2>&1 & echo $! > "$PID_FILE")
      ;;
  esac
  info "启动命令已执行。"
}

stop_service() {
  case "$INIT_SYSTEM" in
    systemd)
      if is_root || have_cmd sudo; then as_root systemctl stop siteproxy
      else systemctl --user stop siteproxy || true
      fi
      ;;
    openrc) as_root rc-service siteproxy stop ;;
    freebsd) as_root service siteproxy stop ;;
    serv00)
      # 创建停机闸门，阻止 cron 重新拉起
      : > "${SITEPROXY_DIR}/.stop"
      if [ -f "$PID_FILE" ]; then
        pid="$(cat "$PID_FILE" 2>/dev/null || true)"
        if [ -n "$pid" ]; then kill "$pid" >/dev/null 2>&1 || true; fi
      fi
      ;;
    none|*)
      if [ -f "$PID_FILE" ]; then
        pid="$(cat "$PID_FILE" 2>/dev/null || true)"
        if [ -n "$pid" ]; then kill "$pid" >/dev/null 2>&1 || true; fi
      fi
      ;;
  esac
  info "停止命令已执行。"
}

restart_service() {
  stop_service || true
  sleep 1
  start_service || true
}

show_status() {
  case "$INIT_SYSTEM" in
    systemd)
      if is_root || have_cmd sudo; then as_root systemctl status siteproxy --no-pager || true
      else systemctl --user status siteproxy --no-pager || true
      fi
      ;;
    openrc) as_root rc-service siteproxy status || true ;;
    freebsd) as_root service siteproxy status || true ;;
    serv00|none|*)
      if [ -f "$PID_FILE" ]; then
        pid="$(cat "$PID_FILE" 2>/dev/null || true)"
        if [ -n "$pid" ] && kill -0 "$pid" >/dev/null 2>&1; then
          info "运行中：PID=$pid"
        else
          warn "未运行（PID 文件存在但进程不存在）"
        fi
      else
        warn "未运行（无 PID 文件）"
      fi
      ;;
  esac
}

view_logs() {
  case "$INIT_SYSTEM" in
    systemd)
      if have_cmd journalctl; then
        if is_root || have_cmd sudo; then as_root journalctl -u siteproxy -n 200 --no-pager || true
        else journalctl --user -u siteproxy -n 200 --no-pager || true
        fi
      else
        warn "未找到 journalctl，尝试读取文件日志：${LOG_FILE}"
        tail -n 200 "$LOG_FILE" 2>/dev/null || true
      fi
      ;;
    *)
      tail -n 200 "$LOG_FILE" 2>/dev/null || true
      ;;
  esac
}

uninstall_siteproxy() {
  warn "开始卸载 SiteProxy..."
  stop_service || true

  case "$INIT_SYSTEM" in
    systemd)
      if is_root || have_cmd sudo; then
        as_root systemctl disable siteproxy >/dev/null 2>&1 || true
        as_root rm -f /etc/systemd/system/siteproxy.service || true
        as_root systemctl daemon-reload || true
      else
        systemctl --user disable siteproxy >/dev/null 2>&1 || true
        rm -f "${HOME}/.config/systemd/user/siteproxy.service" || true
        systemctl --user daemon-reload || true
      fi
      ;;
    openrc)
      as_root rc-update del siteproxy default >/dev/null 2>&1 || true
      as_root rm -f /etc/init.d/siteproxy || true
      ;;
    freebsd)
      as_root rm -f /usr/local/etc/rc.d/siteproxy || true
      ;;
    serv00)
      keep="${SITEPROXY_DIR}/keepalive.sh"
      (crontab -l 2>/dev/null || true) | grep -v "$keep" | crontab - 2>/dev/null || true
      ;;
    *)
      : ;;
  esac

  rm -rf "$SITEPROXY_DIR" || true
  info "卸载完成。"
}

# =========================
# 反向代理模板
# =========================
print_reverse_proxy_templates() {
  port="$(awk -F: '/local_listen_port/ {gsub(/[^0-9]/,"",$2); print $2}' "$CONFIG_FILE" 2>/dev/null | head -n 1 || true)"
  [ -n "$port" ] || port="$DEFAULT_PORT"

  printf "\n${CYAN}===========================================\n"
  printf "          Nginx 配置模板（示例）\n"
  printf "===========================================${NC}\n"
  cat <<EOF
# HTTP 版本（需要配合 certbot 签发 SSL 证书）
server {
    listen 80;
    server_name your-domain.com;

    location / {
        proxy_pass http://127.0.0.1:${port};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}

# HTTPS 版本（证书由 certbot --nginx 自动配置）
# 执行: sudo certbot --nginx -d your-domain.com
EOF

  printf "\n${CYAN}===========================================\n"
  printf "          Caddy 配置模板（示例）\n"
  printf "===========================================${NC}\n"
  cat <<EOF
# Caddy 自动签发 HTTPS 证书
your-domain.com {
    reverse_proxy 127.0.0.1:${port}
}
EOF
  printf "\n"
}

# =========================
# HTTPS 证书配置向导
# =========================
print_https_guide() {
  printf "\n${CYAN}===========================================\n"
  printf "          HTTPS 证书配置指南\n"
  printf "===========================================${NC}\n"
  
  printf "\n${YELLOW}SiteProxy 要求 proxy_url 必须为 https://，请根据你的情况选择证书方案：${NC}\n\n"
  
  printf "${GREEN}[方案 A] 有公网 IP 且 80/443 端口可用${NC}\n"
  cat <<'EOF'
  ┗━ 使用 certbot HTTP-01 验证（最简单）
     # Debian/Ubuntu:
     sudo apt install certbot python3-certbot-nginx
     sudo certbot --nginx -d your-domain.com
     
     # CentOS/RHEL:
     sudo dnf install certbot python3-certbot-nginx
     sudo certbot --nginx -d your-domain.com

EOF

  printf "\n${GREEN}[方案 B] NAT VPS 无 80 端口，但可以管理 DNS${NC}\n"
  cat <<'EOF'
  ┗━ 使用 DNS-01 验证（不需要 80 端口）
     # 安装 acme.sh:
     curl https://get.acme.sh | sh
     
     # 使用 DNS API 签发证书 (以 Cloudflare 为例):
     export CF_Token="your-api-token"
     export CF_Zone_ID="your-zone-id"
     ~/.acme.sh/acme.sh --issue -d your-domain.com --dns dns_cf
     
     # 安装证书到 Nginx:
     ~/.acme.sh/acme.sh --install-cert -d your-domain.com \
       --key-file /etc/nginx/ssl/key.pem \
       --fullchain-file /etc/nginx/ssl/cert.pem \
       --reloadcmd "systemctl reload nginx"

EOF

  printf "\n${GREEN}[方案 C] 无公网入站（纯 NAT/内网）${NC}\n"
  cat <<'EOF'
  ┗━ 使用 Cloudflare Tunnel（无需开放端口）
     # 安装 cloudflared:
     # Debian: curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg | sudo tee /usr/share/keyrings/cloudflare-main.gpg
     # 然后: sudo apt install cloudflared
     
     # 登录并创建隧道:
     cloudflared tunnel login
     cloudflared tunnel create siteproxy
     cloudflared tunnel route dns siteproxy your-domain.com
     
     # 创建配置文件 ~/.cloudflared/config.yml:
     tunnel: <TUNNEL_ID>
     credentials-file: ~/.cloudflared/<TUNNEL_ID>.json
     ingress:
       - hostname: your-domain.com
         service: http://localhost:5006
       - service: http_status:404
     
     # 启动:
     cloudflared tunnel run siteproxy

EOF

  printf "\n${YELLOW}提示：方案 C 无需签发证书，Cloudflare 自动提供 SSL 终结${NC}\n"
}

# =========================
# 端口检测
# =========================
check_port_available() {
  port="$1"
  if have_cmd ss; then
    ss -tuln 2>/dev/null | grep -q ":${port} " && return 1
  elif have_cmd netstat; then
    netstat -tuln 2>/dev/null | grep -q ":${port} " && return 1
  elif have_cmd sockstat; then
    # FreeBSD
    sockstat -l 2>/dev/null | grep -q ":${port}" && return 1
  fi
  return 0
}

print_port_status() {
  port="$(awk -F: '/local_listen_port/ {gsub(/[^0-9]/,"",$2); print $2}' "$CONFIG_FILE" 2>/dev/null | head -n 1 || true)"
  [ -n "$port" ] || port="$DEFAULT_PORT"
  
  printf "\n${CYAN}端口状态检测${NC}\n"
  printf "────────────────────\n"
  
  if check_port_available "$port"; then
    printf "${GREEN}✓${NC} 端口 ${port} 可用\n"
  else
    printf "${YELLOW}⚠${NC} 端口 ${port} 已被占用\n"
    if have_cmd ss; then
      ss -tlnp 2>/dev/null | grep ":${port} " | head -n 3
    fi
  fi
  
  # 检测 80/443 可用性（用于证书签发）
  if check_port_available 80; then
    printf "${GREEN}✓${NC} 端口 80 可用 (可使用 HTTP-01 验证签发证书)\n"
  else
    printf "${YELLOW}⚠${NC} 端口 80 已被占用或不可用 (建议使用 DNS-01 或 Tunnel)\n"
  fi
  
  if check_port_available 443; then
    printf "${GREEN}✓${NC} 端口 443 可用\n"
  else
    printf "${YELLOW}⚠${NC} 端口 443 已被占用\n"
  fi
  
  printf "\n${YELLOW}提示：本检测仅代表本机端口占用情况，不代表公网可达；${NC}\n"
  printf "${YELLOW}      NAT/安全组/运营商封锁仍可能导致外部无法访问。${NC}\n"
}

# =========================
# 公网入口向导
# =========================
read_listen_port() {
  p="$(awk -F: '/local_listen_port/ {gsub(/[^0-9]/,"",$2); print $2}' "$CONFIG_FILE" 2>/dev/null | head -n 1 || true)"
  [ -n "$p" ] || p="$DEFAULT_PORT"
  printf "%s" "$p"
}

read_domain_input() {
  printf "请输入你的域名（例如 example.com）: "
  read -r d || d=""
  d="${d#http://}"
  d="${d#https://}"
  d="${d%/}"
  if [ -z "$d" ]; then
    error "域名不能为空"
    return 1
  fi
  printf "%s" "$d"
}

install_nginx_and_certbot() {
  info "安装 Nginx + Certbot（公网 HTTPS 模式）"
  case "$PKG_MGR" in
    apt)
      pkg_install nginx certbot python3-certbot-nginx
      ;;
    dnf)
      pkg_install nginx certbot python3-certbot-nginx || true
      ;;
    yum)
      # CentOS 7 可能需要 EPEL
      as_root yum install -y epel-release 2>/dev/null || true
      pkg_install nginx certbot python3-certbot-nginx || pkg_install nginx certbot certbot-nginx || true
      ;;
    apk)
      pkg_install nginx certbot certbot-nginx || true
      ;;
    pkg)
      pkg_install nginx py39-certbot py39-certbot-nginx || pkg_install nginx py-certbot py-certbot-nginx || true
      ;;
    *)
      warn "未知包管理器，请手动安装 Nginx 和 Certbot"
      return 1
      ;;
  esac

  # 启动 Nginx
  if [ "$INIT_SYSTEM" = "systemd" ]; then
    as_root systemctl enable --now nginx || true
  elif [ "$INIT_SYSTEM" = "openrc" ]; then
    as_root rc-update add nginx default || true
    as_root rc-service nginx start || true
  elif [ "$OS_FAMILY" = "freebsd" ]; then
    as_root sysrc nginx_enable="YES" 2>/dev/null || true
    as_root service nginx start || true
  fi
  
  info "Nginx 安装完成"
}

write_nginx_siteproxy_conf() {
  domain="$1"
  port="$2"

  info "写入 Nginx 反向代理配置..."

  # 兼容常见发行版路径
  if [ "$OS_FAMILY" = "debian" ]; then
    conf="/etc/nginx/sites-available/siteproxy.conf"
    enable_dir="/etc/nginx/sites-enabled"
    cat <<EOF | as_root tee "$conf" >/dev/null
server {
    listen 80;
    server_name ${domain};

    location / {
        proxy_pass http://127.0.0.1:${port};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF
    as_root mkdir -p "$enable_dir"
    as_root ln -sf "$conf" "${enable_dir}/siteproxy.conf"
    as_root rm -f "${enable_dir}/default" 2>/dev/null || true
  elif [ "$OS_FAMILY" = "alpine" ]; then
    conf="/etc/nginx/http.d/siteproxy.conf"
    cat <<EOF | as_root tee "$conf" >/dev/null
server {
    listen 80;
    server_name ${domain};
    
    location / {
        proxy_pass http://127.0.0.1:${port};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF
  else
    # RHEL/FreeBSD 等使用 conf.d
    conf="/etc/nginx/conf.d/siteproxy.conf"
    cat <<EOF | as_root tee "$conf" >/dev/null
server {
    listen 80;
    server_name ${domain};

    location / {
        proxy_pass http://127.0.0.1:${port};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF
  fi

  # 测试并重载
  if as_root nginx -t; then
    if [ "$INIT_SYSTEM" = "systemd" ]; then
      as_root systemctl reload nginx
    elif [ "$INIT_SYSTEM" = "openrc" ]; then
      as_root rc-service nginx reload || as_root rc-service nginx restart
    elif [ "$OS_FAMILY" = "freebsd" ]; then
      as_root service nginx reload || as_root service nginx restart
    fi
    info "Nginx 配置已写入并重载"
  else
    error "Nginx 配置测试失败，请检查配置"
    return 1
  fi
}

issue_cert_with_certbot() {
  domain="$1"
  
  printf "请输入 Let's Encrypt 通知邮箱（用于证书到期提醒）: "
  read -r email || email=""

  printf "\n${YELLOW}注意：HTTP-01 验证需要 80 端口公网可达！${NC}\n"
  printf "${YELLOW}如果你是 NAT VPS，80 端口不可达，签发会失败。${NC}\n"
  printf "确认继续？[y/N]: "
  read -r confirm || confirm="n"
  case "$confirm" in
    [Yy]*) : ;;
    *) warn "已取消"; return 1 ;;
  esac

  info "正在签发 SSL 证书..."
  
  if [ -n "$email" ]; then
    as_root certbot --nginx -d "$domain" --redirect --agree-tos -m "$email" --non-interactive || {
      error "证书签发失败。可能原因：80 端口公网不可达、域名未解析到本机、防火墙阻挡"
      return 1
    }
  else
    as_root certbot --nginx -d "$domain" --redirect --agree-tos --register-unsafely-without-email --non-interactive || {
      error "证书签发失败"
      return 1
    }
  fi

  info "证书签发完成！现在可以通过 https://${domain} 访问"
}

install_cloudflared() {
  info "安装 cloudflared..."
  
  case "$PKG_MGR" in
    apt)
      # Debian/Ubuntu 使用 Cloudflare 官方仓库
      if ! have_cmd cloudflared; then
        curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg | as_root tee /usr/share/keyrings/cloudflare-main.gpg >/dev/null
        echo "deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared $(lsb_release -cs 2>/dev/null || echo stable) main" | as_root tee /etc/apt/sources.list.d/cloudflared.list >/dev/null
        as_root apt-get update -y
        as_root apt-get install -y cloudflared
      fi
      ;;
    dnf|yum)
      if ! have_cmd cloudflared; then
        # 使用官方 RPM
        as_root curl -fsSL https://pkg.cloudflare.com/cloudflared-ascii.repo -o /etc/yum.repos.d/cloudflared.repo 2>/dev/null || true
        as_root dnf install -y cloudflared 2>/dev/null || as_root yum install -y cloudflared 2>/dev/null || {
          # 备用：直接下载二进制
          warn "从官方仓库安装失败，尝试下载二进制..."
          arch="$(uname -m)"
          case "$arch" in
            x86_64|amd64) arch="amd64" ;;
            aarch64|arm64) arch="arm64" ;;
            *) arch="amd64" ;;
          esac
          curl -fsSL "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${arch}" -o /tmp/cloudflared
          as_root install -m 755 /tmp/cloudflared /usr/local/bin/cloudflared
          rm -f /tmp/cloudflared
        }
      fi
      ;;
    apk)
      # Alpine：下载二进制
      if ! have_cmd cloudflared; then
        arch="$(uname -m)"
        case "$arch" in
          x86_64|amd64) arch="amd64" ;;
          aarch64|arm64) arch="arm64" ;;
          *) arch="amd64" ;;
        esac
        curl -fsSL "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${arch}" -o /tmp/cloudflared
        as_root install -m 755 /tmp/cloudflared /usr/local/bin/cloudflared
        rm -f /tmp/cloudflared
      fi
      ;;
    pkg)
      # FreeBSD
      if ! have_cmd cloudflared; then
        as_root pkg install -y cloudflared 2>/dev/null || {
          warn "FreeBSD pkg 安装失败，请手动安装 cloudflared"
          return 1
        }
      fi
      ;;
    *)
      if ! have_cmd cloudflared; then
        warn "请手动安装 cloudflared: https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/downloads/"
        return 1
      fi
      ;;
  esac
  
  if have_cmd cloudflared; then
    info "cloudflared 安装完成：$(cloudflared --version 2>/dev/null | head -n 1)"
  else
    error "cloudflared 安装失败"
    return 1
  fi
}

setup_cloudflare_tunnel() {
  port="$1"
  domain="$2"

  install_cloudflared || return 1

  info "Cloudflare Tunnel（Argo）模式配置"
  printf "\n${YELLOW}接下来需要登录 Cloudflare 账号授权（会打开浏览器或显示 URL）${NC}\n"
  printf "按回车继续..."
  read -r _ || true

  cloudflared tunnel login || {
    error "Cloudflare 登录失败。请确保能访问显示的 URL 并完成授权"
    return 1
  }

  printf "请输入 tunnel 名称（默认 siteproxy）: "
  read -r tname || tname=""
  [ -n "$tname" ] || tname="siteproxy"

  # 检查是否已存在
  if cloudflared tunnel list 2>/dev/null | grep -q "$tname"; then
    warn "Tunnel '$tname' 已存在，将使用现有 tunnel"
  else
    cloudflared tunnel create "$tname" || {
      error "创建 tunnel 失败"
      return 1
    }
  fi

  # 绑定 DNS
  info "绑定域名 ${domain} 到 tunnel..."
  cloudflared tunnel route dns "$tname" "$domain" || {
    warn "DNS 绑定可能失败，请到 Cloudflare 控制台手动添加 CNAME 记录"
  }

  # 获取 tunnel UUID
  tid="$(cloudflared tunnel list 2>/dev/null | awk -v n="$tname" '$2 == n {print $1; exit}')"
  if [ -z "$tid" ]; then
    warn "未能自动获取 tunnel UUID，请手动编辑 config.yml"
    tid="YOUR_TUNNEL_ID"
  fi

  # 写 config.yml
  mkdir -p "${HOME}/.cloudflared"
  cat > "${HOME}/.cloudflared/config.yml" <<EOF
tunnel: ${tid}
credentials-file: ${HOME}/.cloudflared/${tid}.json

ingress:
  - hostname: ${domain}
    service: http://localhost:${port}
  - service: http_status:404
EOF

  info "config.yml 已生成：${HOME}/.cloudflared/config.yml"

  # 创建 systemd 服务（如果支持）
  if [ "$INIT_SYSTEM" = "systemd" ]; then
    info "创建 cloudflared systemd 服务..."
    cloudflared service install 2>/dev/null || {
      # 手动创建
      cat <<EOF | as_root tee /etc/systemd/system/cloudflared.service >/dev/null
[Unit]
Description=Cloudflare Tunnel
After=network.target

[Service]
Type=simple
User=$(id -un)
ExecStart=$(command -v cloudflared) tunnel --config ${HOME}/.cloudflared/config.yml run
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
      as_root systemctl daemon-reload
    }
    as_root systemctl enable --now cloudflared || true
    info "cloudflared 服务已启动"
  else
    # 其他系统：手动启动
    info "请手动启动 cloudflared："
    printf "  cloudflared tunnel --config ~/.cloudflared/config.yml run\n"
  fi

  info "Cloudflare Tunnel 配置完成！"
  info "现在可以通过 https://${domain} 访问（Cloudflare 自动提供 SSL）"
}

# 随机隧道（trycloudflare）- 无需账号，临时测试用
setup_quick_tunnel() {
  port="$1"
  
  install_cloudflared || return 1

  info "启动随机隧道（trycloudflare）模式..."
  printf "\n${YELLOW}注意：随机隧道每次重启后 URL 会变化，仅适合临时测试！${NC}\n"
  printf "${YELLOW}生产环境请使用固定隧道（需要 Cloudflare 账号和域名）${NC}\n\n"

  # 启动隧道并捕获 URL
  info "正在启动隧道..."
  
  if [ "$INIT_SYSTEM" = "systemd" ]; then
    # 创建 systemd 服务运行随机隧道
    cat <<EOF | as_root tee /etc/systemd/system/cloudflared-quick.service >/dev/null
[Unit]
Description=Cloudflare Quick Tunnel (trycloudflare)
After=network.target siteproxy.service

[Service]
Type=simple
User=$(id -un)
ExecStart=$(command -v cloudflared) tunnel --url http://localhost:${port}
Restart=on-failure
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
    as_root systemctl daemon-reload
    as_root systemctl enable --now cloudflared-quick || true
    
    info "cloudflared-quick 服务已启动"
    info "等待隧道 URL 生成..."
    sleep 5
    
    # 从日志获取 URL
    tunnel_url="$(journalctl -u cloudflared-quick --no-pager -n 50 2>/dev/null | grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' | head -n 1 || true)"
    
    if [ -n "$tunnel_url" ]; then
      printf "\n${GREEN}===========================================\n"
      printf "          随机隧道已启动！\n"
      printf "===========================================${NC}\n"
      printf "\n${CYAN}隧道 URL：${NC}${tunnel_url}\n"
      printf "\n${YELLOW}注意：此 URL 在服务重启后会变化${NC}\n"
      
      # 更新 config.json
      if [ -f "$CONFIG_FILE" ]; then
        tmpf="${CONFIG_FILE}.tmp"
        sed "s|\"proxy_url\":.*|\"proxy_url\": \"${tunnel_url}\",|" "$CONFIG_FILE" > "$tmpf"
        mv -f "$tmpf" "$CONFIG_FILE"
        chmod 600 "$CONFIG_FILE" 2>/dev/null || true
        info "已更新 config.json 中的 proxy_url"
        restart_service
      fi
      
      # 显示完整访问示例
      token_prefix="$(awk -F'"' '/token_prefix/{print $4}' "$CONFIG_FILE" 2>/dev/null || true)"
      if [ -n "$token_prefix" ] && [ "$token_prefix" != "" ]; then
        printf "\n${CYAN}访问示例：${NC}${tunnel_url}${token_prefix}https://www.google.com\n"
      else
        printf "\n${CYAN}访问示例：${NC}${tunnel_url}/https://www.google.com\n"
      fi
    else
      warn "未能自动获取隧道 URL，请手动查看日志："
      printf "  journalctl -u cloudflared-quick -f\n"
    fi
  else
    # 非 systemd：前台运行并手动获取 URL
    info "在后台启动隧道..."
    nohup cloudflared tunnel --url "http://localhost:${port}" > "${SITEPROXY_DIR}/cloudflared.log" 2>&1 &
    cf_pid=$!
    echo "$cf_pid" > "${SITEPROXY_DIR}/cloudflared.pid"
    
    sleep 5
    tunnel_url="$(grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' "${SITEPROXY_DIR}/cloudflared.log" 2>/dev/null | head -n 1 || true)"
    
    if [ -n "$tunnel_url" ]; then
      printf "\n${GREEN}隧道 URL：${NC}${tunnel_url}\n"
      printf "${YELLOW}注意：此 URL 在进程重启后会变化${NC}\n"
      
      # 更新 config.json
      if [ -f "$CONFIG_FILE" ]; then
        tmpf="${CONFIG_FILE}.tmp"
        sed "s|\"proxy_url\":.*|\"proxy_url\": \"${tunnel_url}\",|" "$CONFIG_FILE" > "$tmpf"
        mv -f "$tmpf" "$CONFIG_FILE"
        chmod 600 "$CONFIG_FILE" 2>/dev/null || true
        restart_service
      fi
    else
      warn "未能获取隧道 URL，请查看日志：${SITEPROXY_DIR}/cloudflared.log"
    fi
  fi
}

setup_public_entry_wizard() {
  ensure_bundle_present || return 1

  port="$(read_listen_port)"
  
  printf "\n${CYAN}===========================================\n"
  printf "          公网入口配置向导\n"
  printf "===========================================${NC}\n"
  
  printf "\n请选择你的 VPS 类型：\n"
  printf "  ${YELLOW}1)${NC} 公网 VPS（有独立公网 IP，80/443 端口可入站）\n"
  printf "     └─ 使用 Nginx + Certbot 自动签发 HTTPS 证书\n"
  printf "  ${YELLOW}2)${NC} NAT VPS - 固定隧道（推荐/生产环境）\n"
  printf "     └─ 需要 Cloudflare 账号 + 域名，URL 永久固定\n"
  printf "  ${YELLOW}3)${NC} NAT VPS - 随机隧道（临时测试）\n"
  printf "     └─ 无需账号，URL 随机且重启会变\n"
  printf "\n请选择 [1-3]: "
  read -r mode || mode="1"

  case "$mode" in
    1)
      domain="$(read_domain_input)" || return 1
      install_nginx_and_certbot || return 1
      write_nginx_siteproxy_conf "$domain" "$port" || return 1
      issue_cert_with_certbot "$domain" || return 1
      
      # 更新 config.json 中的 proxy_url
      if [ -f "$CONFIG_FILE" ]; then
        tmpf="${CONFIG_FILE}.tmp"
        sed "s|\"proxy_url\":.*|\"proxy_url\": \"https://${domain}\",|" "$CONFIG_FILE" > "$tmpf"
        mv -f "$tmpf" "$CONFIG_FILE"
        chmod 600 "$CONFIG_FILE" 2>/dev/null || true
        info "已更新 config.json 中的 proxy_url 为 https://${domain}"
        restart_service
      fi
      
      info "公网入口配置完成：Nginx + HTTPS"
      ;;
    2)
      domain="$(read_domain_input)" || return 1
      setup_cloudflare_tunnel "$port" "$domain" || return 1
      
      # 更新 config.json 中的 proxy_url
      if [ -f "$CONFIG_FILE" ]; then
        tmpf="${CONFIG_FILE}.tmp"
        sed "s|\"proxy_url\":.*|\"proxy_url\": \"https://${domain}\",|" "$CONFIG_FILE" > "$tmpf"
        mv -f "$tmpf" "$CONFIG_FILE"
        chmod 600 "$CONFIG_FILE" 2>/dev/null || true
        info "已更新 config.json 中的 proxy_url 为 https://${domain}"
        restart_service
      fi
      
      info "NAT 入口配置完成：固定 Cloudflare Tunnel"
      ;;
    3)
      setup_quick_tunnel "$port" || return 1
      info "NAT 入口配置完成：随机 Cloudflare Tunnel（trycloudflare）"
      ;;
    *)
      warn "无效选项"
      return 1
      ;;
  esac
}

# =========================
# 安装流程
# =========================
install_all() {
  detect_os
  detect_init_system
  detect_package_manager
  show_env_summary

  info "1) 安装/检查 Node.js v22+（项目要求）"
  if ! install_nodejs; then
    error "Node.js 安装失败或版本不足（需要 v22+）。"
    return 1
  fi

  info "2) 下载 SiteProxy..."
  download_siteproxy

  info "3) 配置 SiteProxy..."
  configure_siteproxy

  info "4) 创建并启动服务..."
  create_service

  printf "\n"
  info "=========================================="
  info "        安装完成！"
  info "=========================================="
  info "安装目录：${SITEPROXY_DIR}"
  info "配置文件：${CONFIG_FILE}"
  info "日志文件：${LOG_FILE}"
  
  # 检测端口状态
  print_port_status
  
  printf "\n${YELLOW}下一步操作：${NC}\n"
  printf "────────────────────\n"
  printf "1. 配置 HTTPS 反向代理（菜单选项 9 查看模板）\n"
  printf "2. 签发 SSL 证书（菜单选项 10 查看指南）\n"
  printf "3. 将 config.json 中的 proxy_url 改为你的实际域名\n"
  
  if [ "$INIT_SYSTEM" = "serv00" ]; then
    printf "\n${CYAN}Serv00/HostUno 特别提示：${NC}\n"
    printf "• 已尝试通过 devil 开放端口，如失败请到控制面板手动配置\n"
    printf "• 服务已配置 cron 保活，每分钟检查\n"
  fi
  
  printf "\n"
}

# =========================
# 菜单
# =========================
show_menu() {
  printf "\n"
  printf "${CYAN}╔═══════════════════════════════════════════════════╗${NC}\n"
  printf "${CYAN}║${NC}        ${GREEN}SiteProxy 一键部署管理脚本${NC}               ${CYAN}║${NC}\n"
  printf "${CYAN}╠═══════════════════════════════════════════════════╣${NC}\n"
  printf "${CYAN}║${NC}  ${YELLOW}1.${NC} 安装 SiteProxy                              ${CYAN}║${NC}\n"
  printf "${CYAN}║${NC}  ${YELLOW}2.${NC} 卸载 SiteProxy                              ${CYAN}║${NC}\n"
  printf "${CYAN}║${NC}  ${YELLOW}3.${NC} 启动服务                                    ${CYAN}║${NC}\n"
  printf "${CYAN}║${NC}  ${YELLOW}4.${NC} 停止服务                                    ${CYAN}║${NC}\n"
  printf "${CYAN}║${NC}  ${YELLOW}5.${NC} 重启服务                                    ${CYAN}║${NC}\n"
  printf "${CYAN}║${NC}  ${YELLOW}6.${NC} 查看状态                                    ${CYAN}║${NC}\n"
  printf "${CYAN}║${NC}  ${YELLOW}7.${NC} 查看日志                                    ${CYAN}║${NC}\n"
  printf "${CYAN}║${NC}  ${YELLOW}8.${NC} 修改配置                                    ${CYAN}║${NC}\n"
  printf "${CYAN}╠═══════════════════════════════════════════════════╣${NC}\n"
  printf "${CYAN}║${NC}  ${YELLOW}9.${NC} 反向代理模板 (Nginx/Caddy)                  ${CYAN}║${NC}\n"
  printf "${CYAN}║${NC}  ${YELLOW}10.${NC} HTTPS 证书配置指南                         ${CYAN}║${NC}\n"
  printf "${CYAN}║${NC}  ${YELLOW}11.${NC} 端口状态检测                               ${CYAN}║${NC}\n"
  printf "${CYAN}║${NC}  ${YELLOW}12.${NC} 一键配置公网入口 (HTTPS/Argo)              ${CYAN}║${NC}\n"
  printf "${CYAN}╠═══════════════════════════════════════════════════╣${NC}\n"
  printf "${CYAN}║${NC}  ${YELLOW}0.${NC} 退出                                        ${CYAN}║${NC}\n"
  printf "${CYAN}╚═══════════════════════════════════════════════════╝${NC}\n"
}

menu() {
  detect_os
  detect_init_system
  detect_package_manager

  while true; do
    show_menu
    printf "请选择 [0-12]: "
    read -r choice || choice="0"

    case "$choice" in
      1) install_all ;;
      2) uninstall_siteproxy ;;
      3) start_service ;;
      4) stop_service ;;
      5) restart_service ;;
      6) show_status ;;
      7) view_logs ;;
      8) configure_siteproxy ;;
      9) print_reverse_proxy_templates ;;
      10) print_https_guide ;;
      11) print_port_status ;;
      12) setup_public_entry_wizard ;;
      0) 
        info "再见！"
        exit 0 
        ;;
      *) warn "无效选项，请输入 0-12" ;;
    esac
  done
}

# =========================
# 入口
# =========================
menu
