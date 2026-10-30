#!/usr/bin/env bash
set -Eeuo pipefail

REPO_RAW=https://raw.githubusercontent.com/zzx327317-creator/hopctl/main
INSTALL_DIR=/usr/local/bin
CONFIG_DIR=/etc/hopctl
SCRIPT_NAME=hopctl

die() { printf '安装失败：%s\n' "$*" >&2; exit 1; }
[[ $EUID -eq 0 ]] || die '请以 root 运行，例如 sudo bash install.sh。'
[[ $(uname -s) == Linux ]] || die '仅支持使用 systemd 的 Linux 服务器。'
command -v systemctl >/dev/null 2>&1 || die '未发现 systemd。'

if ! command -v iptables >/dev/null 2>&1 ||
   ! command -v ip6tables >/dev/null 2>&1 ||
   ! command -v flock >/dev/null 2>&1; then
  printf '正在安装 iptables 与 flock 依赖...\n'
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y iptables util-linux
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y iptables util-linux
  elif command -v yum >/dev/null 2>&1; then
    yum install -y iptables util-linux
  elif command -v apk >/dev/null 2>&1; then
    apk add iptables util-linux
  elif command -v pacman >/dev/null 2>&1; then
    pacman -Sy --noconfirm iptables util-linux
  else
    die '不支持的包管理器；请手动安装 iptables、ip6tables、flock。'
  fi
fi

script_source=''
if [[ -f ${BASH_SOURCE[0]} ]]; then
  script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
  if [[ -f $script_dir/hopctl ]]; then script_source="$script_dir/hopctl"; fi
fi

tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT
if [[ -n $script_source ]]; then
  cp -- "$script_source" "$tmp"
else
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$REPO_RAW/hopctl" -o "$tmp"
  elif command -v wget >/dev/null 2>&1; then
    wget -qO "$tmp" "$REPO_RAW/hopctl"
  else
    die '需要 curl 或 wget 下载 hopctl。'
  fi
fi
bash -n "$tmp" || die '下载的脚本语法检查失败。'
install -D -m 755 "$tmp" "$INSTALL_DIR/$SCRIPT_NAME"
install -d -m 700 "$CONFIG_DIR"
if [[ ! -f $CONFIG_DIR/rules.tsv ]]; then
  install -m 600 /dev/null "$CONFIG_DIR/rules.tsv"
fi

cat > /etc/systemd/system/hopctl.service <<'EOF'
[Unit]
Description=Verify and restore hopctl IPv4/IPv6 port hopping rules
Wants=network-online.target
After=network-online.target netfilter-persistent.service iptables.service ip6tables.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/hopctl apply

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/hopctl.timer <<'EOF'
[Unit]
Description=Recheck hopctl port hopping rules after firewall changes

[Timer]
OnBootSec=1min
OnUnitInactiveSec=5min
Unit=hopctl.service

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable hopctl.service hopctl.timer
systemctl start hopctl.service
systemctl start hopctl.timer

printf '\n安装完成。以后输入 sudo hopctl 即可打开转发面板。\n'
printf '开机自动校验；运行中的规则每 5 分钟复核一次，不会自动删除配置。\n'
if [[ ${1:-} != --no-menu && -t 0 && -t 1 ]]; then
  "$INSTALL_DIR/$SCRIPT_NAME"
fi
