#!/bin/bash
# NanoPC-T6 核心优化脚本 - 纯净稳定版
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "需要 root 权限"; exit 1; }

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info() { echo -e "${GREEN}[✓]${NC} $*"; }

echo "=== NanoPC-T6 优化脚本 ==="

# 1. BBR
info "配置 BBR..."
lsmod | grep -q bbr || opkg update && opkg install kmod-tcp-bbr 2>/dev/null || true

# 2. sysctl
cat > /etc/sysctl.d/99-nanopc-optimization.conf <<'EOF'
net.core.default_qdisc=fq_codel
net.ipv4.tcp_congestion_control=bbr
net.core.rmem_max=33554432
net.core.wmem_max=33554432
net.ipv4.tcp_rmem=4096 87380 33554432
net.ipv4.tcp_wmem=4096 16384 33554432
net.core.netdev_max_backlog=16384
net.netfilter.nf_conntrack_max=524288
net.netfilter.nf_conntrack_buckets=131072
net.ipv4.ip_forward=1
net.ipv4.tcp_fastopen=3
net.ipv4.tcp_tw_reuse=1
EOF
sysctl -p /etc/sysctl.d/99-nanopc-optimization.conf 2>/dev/null || true

# 3. 防火墙
info "配置防火墙..."
command -v uci >/dev/null && {
    uci set firewall.@defaults[0].flow_offloading='1' 2>/dev/null || true
    uci commit firewall 2>/dev/null || true
    /etc/init.d/firewall restart 2>/dev/null || true
}

# 4. DNS
info "优化 DNS..."
command -v uci >/dev/null && {
    uci set dhcp.@dnsmasq[0].cachesize='10000' 2>/dev/null || true
    uci commit dhcp 2>/dev/null || true
    /etc/init.d/dnsmasq restart 2>/dev/null || true
}

info "完成！建议重启。"
