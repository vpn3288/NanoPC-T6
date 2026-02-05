#!/bin/bash
# ==============================================================================
# NanoPC-T6 (16GB) 代理主路由优化脚本 v21.0 (精简版)
# ------------------------------------------------------------------------------
# 硬件: RK3588 8核心 / 16GB 内存 / 64GB 存储 / 2x 2.5G 网口
# 场景: 主路由 + 代理软件（OpenClash/HomeProxy/PassWall）
# 特性: 核心优化、无冲突、简洁高效
# v21.0: 移除 irqbalance 和 RPS（网卡驱动已优化）
# ==============================================================================

set -e

# --- 全局变量 ---
LOG_FILE="/tmp/optimization_v21_$(date +%Y%m%d).log"
BACKUP_DIR="/etc/config_backup_$(date +%Y%m%d_%H%M%S)"
CPU_GOVERNOR="schedutil"
TX_QUEUE_LEN="5000"

# --- 日志函数 ---
log_info() { echo -e "\033[32m[INFO] [$(date +'%H:%M:%S')] $1\033[0m" | tee -a "$LOG_FILE"; }
log_warn() { echo -e "\033[33m[WARN] [$(date +'%H:%M:%S')] $1\033[0m" | tee -a "$LOG_FILE"; }
log_err()  { echo -e "\033[31m[ERROR] [$(date +'%H:%M:%S')] $1\033[0m" | tee -a "$LOG_FILE"; exit 1; }

# --- 工具函数 ---
backup_file() {
    if [ -f "$1" ]; then
        mkdir -p "$BACKUP_DIR"
        cp -a "$1" "$BACKUP_DIR/" 2>/dev/null
        log_info "💾 备份: $1"
    fi
}

check_network() {
    log_info "🔍 网络自检..."
    for host in 223.5.5.5 119.29.29.29 1.1.1.1; do
        if ping -c 2 -W 3 "$host" >/dev/null 2>&1; then
            log_info "✅ 网络正常 (测试节点: $host)"
            return 0
        fi
    done
    log_err "❌ 网络异常，请检查 WAN 口"
}

uci_delete_all() {
    while uci -q delete "$1" 2>/dev/null; do :; done
}

# --- 主流程 ---
log_info "🚀 NanoPC-T6 代理主路由优化 v21.0 (精简版)"

DEVICE_MODEL=$(tr -d '\0' < /proc/device-tree/model 2>/dev/null || echo 'RK3588 Device')
log_info "设备: $DEVICE_MODEL"

TOTAL_MEM_KB=$(free | awk 'NR==2 {print $2}')
TOTAL_MEM_MB=$((TOTAL_MEM_KB / 1024))
log_info "内存: ${TOTAL_MEM_MB}MB"

[ "$(id -u)" -eq 0 ] || log_err "需要 root 权限"
check_network

# ==================== 阶段 1: 环境清理 ====================
log_info ""
log_info "🧹 [1/6] 环境清理..."

# SmartDNS 清理
if opkg list-installed 2>/dev/null | grep -q "smartdns"; then
    log_warn "检测到 SmartDNS，正在移除..."
    /etc/init.d/smartdns stop 2>/dev/null || true
    /etc/init.d/smartdns disable 2>/dev/null || true
    opkg remove luci-app-smartdns smartdns --force-removal-of-dependent-packages >/dev/null 2>&1 || true
    rm -rf /etc/config/smartdns /etc/smartdns 2>/dev/null
    log_info "✅ SmartDNS 已移除"
else
    log_info "✅ 环境纯净"
fi

# Dnsmasq 重置
log_info "重置 dnsmasq 配置..."
backup_file "/etc/config/dhcp"

uci_delete_all "dhcp.@dnsmasq[0].server"
uci set dhcp.@dnsmasq[0].noresolv='0'
uci set dhcp.@dnsmasq[0].cachesize='5000'
uci set dhcp.@dnsmasq[0].min_cache_ttl='600'
uci commit dhcp

/etc/init.d/dnsmasq restart &
DNSMASQ_PID=$!
count=0
while [ $count -lt 10 ]; do
    if ! kill -0 $DNSMASQ_PID 2>/dev/null; then
        wait $DNSMASQ_PID 2>/dev/null
        break
    fi
    sleep 1
    count=$((count + 1))
done

if kill -0 $DNSMASQ_PID 2>/dev/null; then
    log_warn "dnsmasq 重启超时，强制处理..."
    kill -9 $DNSMASQ_PID 2>/dev/null || true
    killall dnsmasq 2>/dev/null || true
    sleep 1
    /etc/init.d/dnsmasq start
fi

sleep 2
log_info "✅ dnsmasq 已重置"

# ==================== 阶段 2: 核心组件安装 ====================
log_info ""
log_info "📦 [2/6] 核心组件安装..."
opkg update >/dev/null 2>&1 || log_warn "软件源更新失败"

# 只安装必要的包（不包含 irqbalance）
PKG_LIST="ethtool ip-full kmod-tcp-bbr kmod-sched-core bind-host coreutils-stat"

for pkg in $PKG_LIST; do
    if opkg list-installed 2>/dev/null | grep -q "^$pkg "; then
        log_info "  ⏭️  $pkg"
    else
        log_info "  ⬇️  安装 $pkg..."
        opkg install "$pkg" >> "$LOG_FILE" 2>&1 || log_warn "  ⚠️  $pkg 安装失败"
    fi
done

# ==================== 阶段 3: 硬件加速 ====================
log_info ""
log_info "⚡ [3/6] 硬件流量卸载..."

if [ -f /etc/config/turboacc ] || opkg list-installed 2>/dev/null | grep -q "turboacc"; then
    log_info "启用 TurboACC..."
    if ! uci -q get turboacc.config >/dev/null 2>&1; then
        uci set turboacc.config=turboacc
    fi
    uci set turboacc.config.enabled='1'
    uci set turboacc.config.sfe_flow='1' 2>/dev/null || true
    uci set turboacc.config.fullcone_nat='1' 2>/dev/null || true
    uci set turboacc.config.bbr_cca='1' 2>/dev/null || true
    uci commit turboacc
    /etc/init.d/turboacc restart 2>/dev/null || true
    log_info "✅ TurboACC 已激活"
else
    log_info "启用原生硬件卸载..."
    if uci -q get firewall.@defaults[0] >/dev/null 2>&1; then
        uci set firewall.@defaults[0].flow_offloading='1'
        uci set firewall.@defaults[0].flow_offloading_hw='1' 2>/dev/null || true
        
        if uci -q get firewall.@zone[1] >/dev/null 2>&1; then
            uci set firewall.@zone[1].fullcone4='1' 2>/dev/null || true
        fi
        
        uci set firewall.@defaults[0].drop_invalid='1' 2>/dev/null || true
        uci set firewall.@defaults[0].syn_flood='1' 2>/dev/null || true
        
        uci commit firewall
        /etc/init.d/firewall restart 2>&1 | grep -v "unknown option" | grep -v "specifies unknown" || true
        log_info "✅ 硬件卸载已激活"
    fi
fi

# ==================== 阶段 4: 内核参数优化 ====================
log_info ""
log_info "🛠️ [4/6] 内核参数优化（代理场景）..."
backup_file "/etc/sysctl.conf"

cat > /etc/sysctl.conf <<'EOF'
# ============================================================
# NanoPC-T6 代理主路由专用内核参数 v21.0
# 优化目标: 高并发连接 + 低延迟 + 代理友好
# ============================================================

# --- BBR 拥塞控制 ---
net.core.default_qdisc=fq_codel
net.ipv4.tcp_congestion_control=bbr

# --- 路由转发 ---
net.ipv4.ip_forward=1
net.ipv6.conf.all.forwarding=1
net.ipv6.conf.default.forwarding=1

# --- 连接跟踪（代理优化：52万连接）---
net.netfilter.nf_conntrack_max=524288
net.netfilter.nf_conntrack_buckets=131072
net.netfilter.nf_conntrack_tcp_timeout_established=7200
net.netfilter.nf_conntrack_tcp_timeout_time_wait=30
net.netfilter.nf_conntrack_tcp_timeout_close_wait=15
net.netfilter.nf_conntrack_tcp_timeout_fin_wait=30
net.netfilter.nf_conntrack_udp_timeout=180
net.netfilter.nf_conntrack_udp_timeout_stream=300

# --- 网络缓冲区（16GB 内存：32MB）---
net.core.rmem_max=33554432
net.core.wmem_max=33554432
net.core.rmem_default=262144
net.core.wmem_default=262144
net.ipv4.tcp_rmem=4096 131072 33554432
net.ipv4.tcp_wmem=4096 131072 33554432
net.core.netdev_max_backlog=16384
net.core.somaxconn=8192

# --- TCP 性能优化 ---
net.ipv4.tcp_fastopen=3
net.ipv4.tcp_slow_start_after_idle=0
net.ipv4.tcp_notsent_lowat=16384
net.ipv4.tcp_window_scaling=1
net.ipv4.tcp_timestamps=1
net.ipv4.tcp_sack=1
net.ipv4.tcp_fack=1
net.ipv4.tcp_ecn=0
net.ipv4.tcp_mtu_probing=1

# --- 安全防护 ---
net.ipv4.tcp_syncookies=1
net.ipv4.tcp_syn_retries=2
net.ipv4.tcp_synack_retries=2
net.ipv4.tcp_max_syn_backlog=8192
net.ipv4.tcp_tw_reuse=1
net.ipv4.conf.default.rp_filter=1
net.ipv4.conf.all.rp_filter=1
net.ipv4.icmp_echo_ignore_broadcasts=1
net.ipv4.icmp_ignore_bogus_error_responses=1

# --- 文件描述符 ---
fs.file-max=2097152
fs.inotify.max_user_instances=8192
fs.inotify.max_user_watches=524288
EOF

sysctl -p 2>&1 | grep -v "cannot stat" | grep -v "No such file" || true
log_info "✅ 内核参数已加载"

# ==================== 阶段 5: CPU 调度 ====================
log_info ""
log_info "🔋 [5/6] CPU 调度与网卡队列..."

CPU_CORES=$(grep -c ^processor /proc/cpuinfo 2>/dev/null || echo "8")
log_info "检测到 $CPU_CORES 个 CPU 核心"

backup_file "/etc/rc.local"

cat > /etc/rc.local <<EOF
#!/bin/sh
# NanoPC-T6 代理主路由启动脚本 (v21.0)

# 等待系统稳定
sleep 5

# 1. 网卡队列优化
for dev in \$(ls /sys/class/net 2>/dev/null | grep -E 'eth|enp|lan|wan'); do
    [ -d "/sys/class/net/\$dev" ] && ip link set "\$dev" txqueuelen $TX_QUEUE_LEN 2>/dev/null
done

# 2. CPU 调频策略（$CPU_CORES 核心）
for i in \$(seq 0 $((CPU_CORES - 1))); do
    CPU_PATH="/sys/devices/system/cpu/cpu\$i/cpufreq"
    if [ -d "\$CPU_PATH" ]; then
        if grep -q "$CPU_GOVERNOR" "\$CPU_PATH/scaling_available_governors" 2>/dev/null; then
            echo "$CPU_GOVERNOR" > "\$CPU_PATH/scaling_governor" 2>/dev/null
        elif grep -q "ondemand" "\$CPU_PATH/scaling_available_governors" 2>/dev/null; then
            echo "ondemand" > "\$CPU_PATH/scaling_governor" 2>/dev/null
        fi
    fi
done

# 注意: 网卡驱动已自动优化多核分发，无需手动配置

exit 0
EOF

chmod +x /etc/rc.local
/etc/rc.local >/dev/null 2>&1 || log_warn "部分配置未立即生效（重启后完整生效）"
log_info "✅ 启动项已配置 | 调频: $CPU_GOVERNOR"

# ==================== 阶段 6: 清理冲突组件 ====================
log_info ""
log_info "🗑️ [6/6] 清理冲突组件..."

# 确保 irqbalance 被禁用（如果存在）
if opkg list-installed 2>/dev/null | grep -q "^irqbalance "; then
    log_warn "检测到 irqbalance，正在移除..."
    /etc/init.d/irqbalance stop 2>/dev/null || true
    /etc/init.d/irqbalance disable 2>/dev/null || true
    opkg remove irqbalance --force-removal-of-dependent-packages >/dev/null 2>&1 || true
    log_info "✅ irqbalance 已移除（避免冲突）"
else
    log_info "✅ 无冲突组件"
fi

# ==================== 最终验证 ====================
log_info ""
log_info "================ 配置验证 ================"

# BBR
TCP_ALG=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "unknown")
if [ "$TCP_ALG" = "bbr" ]; then
    log_info "✅ BBR: 已启用"
else
    log_warn "⚠️  BBR: $TCP_ALG（重启后生效）"
fi

# CPU
CPU_GOV=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo "unknown")
log_info "✅ CPU 调频: $CPU_GOV"

# 温度
if [ -f /sys/class/thermal/thermal_zone0/temp ]; then
    TEMP=$(($(cat /sys/class/thermal/thermal_zone0/temp) / 1000))
    log_info "🌡️  温度: ${TEMP}°C"
fi

# 连接跟踪
CONNTRACK_MAX=$(sysctl -n net.netfilter.nf_conntrack_max 2>/dev/null || echo "0")
CONNTRACK_CUR=$(cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null || echo "0")
if [ "$CONNTRACK_MAX" -gt 0 ]; then
    CONNTRACK_PCT=$((CONNTRACK_CUR * 100 / CONNTRACK_MAX))
    log_info "📊 连接跟踪: $CONNTRACK_CUR / $CONNTRACK_MAX (${CONNTRACK_PCT}%)"
fi

# 网卡队列
NICS=$(ls /sys/class/net 2>/dev/null | grep -E '^eth[0-9]' | head -2 | tr '\n' ' ')
if [ -n "$NICS" ]; then
    log_info "🔥 网卡队列: $NICS(驱动已自动优化)"
fi

# 网络
if ping -c 1 -W 2 223.5.5.5 >/dev/null 2>&1; then
    log_info "✅ 网络: 正常"
else
    log_warn "⚠️  网络: 异常"
fi

log_info "========================================="
log_info ""
log_info "🎉 优化完成！NanoPC-T6 已配置为高性能代理主路由。"
log_info ""
log_info "📋 配置摘要:"
log_info "  • 连接跟踪: 52万（代理优化）"
log_info "  • 网络缓冲: 32MB（16GB 内存优化）"
log_info "  • BBR 加速: 已启用 + 代理参数"
log_info "  • FullCone NAT: 已启用"
log_info "  • 无冲突组件: 已清理"
log_info ""
log_info "🔧 下一步操作:"
log_info "  1. 【建议】重启系统: reboot"
log_info "  2. 安装代理软件:"
log_info "     - OpenClash: opkg install luci-app-openclash"
log_info "     - HomeProxy: opkg install luci-app-homeproxy"
log_info "     - PassWall: opkg install luci-app-passwall"
log_info "  3. 验证优化效果:"
log_info "     sysctl net.ipv4.tcp_congestion_control"
log_info "     cat /proc/sys/net/netfilter/nf_conntrack_max"
log_info ""
log_info "📁 备份位置: $BACKUP_DIR"
log_info "📋 详细日志: $LOG_FILE"
log_info ""
log_info "⚠️  提示:"
log_info "  • 本脚本已为代理场景优化，无需额外调整"
log_info "  • 网卡驱动已自动优化多核分发"
log_info "  • 如需恢复: cp -r $BACKUP_DIR/* /etc/ && reboot"
log_info "  • 支持重复运行，配置错误时可重新执行"
log_info "========================================="
