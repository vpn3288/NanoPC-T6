#!/bin/bash
# ==============================================================================
# NanoPC-T6 (16GB) 代理主路由专用优化脚本 v20.0
# ------------------------------------------------------------------------------
# 硬件: RK3588 8核心 / 16GB 内存 / 64GB 存储 / 2x 2.5G 网口
# 场景: 主路由 + 代理软件（OpenClash/HomeProxy/PassWall）
# 特性: 高并发连接、低延迟、多核优化、代理友好
# 修正: 彻底修复 RPS 持久化失效、变量语法错误、Cron 守护补刀
# ==============================================================================

# 移除 set -e，改用更灵活的错误处理，防止脚本中途因为非致命错误退出
set +e

# --- 全局变量 ---
LOG_FILE="/tmp/optimization_v20_$(date +%Y%m%d).log"
BACKUP_DIR="/etc/config_backup_$(date +%Y%m%d_%H%M%S)"
CPU_GOVERNOR="schedutil"  # 负载感应
TX_QUEUE_LEN="5000"
RPS_MASK="ff"             # 8核心全开

# --- 日志函数 ---
log_info() { echo -e "\033[32m[INFO] [$(date +'%H:%M:%S')] $1\033[0m" | tee -a "$LOG_FILE"; }
log_warn() { echo -e "\033[33m[WARN] [$(date +'%H:%M:%S')] $1\033[0m" | tee -a "$LOG_FILE"; }
log_err()  { echo -e "\033[31m[ERROR] [$(date +'%H:%M:%S')] $1\033[0m" | tee -a "$LOG_FILE"; }

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
    log_warn "⚠️ 网络可能异常，尝试继续执行..."
}

uci_delete_all() {
    while uci -q delete "$1" 2>/dev/null; do :; done
}

# --- 主流程 ---
log_info "🚀 NanoPC-T6 代理主路由优化 v20.0"

DEVICE_MODEL=$(tr -d '\0' < /proc/device-tree/model 2>/dev/null || echo 'RK3588 Device')
log_info "设备: $DEVICE_MODEL"
TOTAL_MEM=$(free -m | awk 'NR==2 {print $2}')
log_info "内存: ${TOTAL_MEM}MB"

[ "$(id -u)" -eq 0 ] || { log_err "需要 root 权限"; exit 1; }
check_network

# ==================== 阶段 1: 环境清理 ====================
log_info ""
log_info "🧹 [1/7] 环境清理..."

if opkg list-installed 2>/dev/null | grep -q "smartdns"; then
    log_warn "检测到 SmartDNS，正在移除..."
    /etc/init.d/smartdns stop 2>/dev/null || true
    /etc/init.d/smartdns disable 2>/dev/null || true
    opkg remove luci-app-smartdns smartdns --force-removal-of-dependent-packages >/dev/null 2>&1 || true
    rm -rf /etc/config/smartdns /etc/smartdns 2>/dev/null
    log_info "✅ SmartDNS 已移除"
fi

log_info "重置 dnsmasq 配置..."
backup_file "/etc/config/dhcp"
uci_delete_all "dhcp.@dnsmasq[0].server"
uci set dhcp.@dnsmasq[0].noresolv='0'
uci set dhcp.@dnsmasq[0].cachesize='5000'
uci set dhcp.@dnsmasq[0].min_cache_ttl='600'
uci commit dhcp

# 安全重启 dnsmasq
/etc/init.d/dnsmasq restart >/dev/null 2>&1 || true
log_info "✅ dnsmasq 已重置"

# ==================== 阶段 2: 软件包安装 ====================
log_info ""
log_info "📦 [2/7] 核心组件安装..."
opkg update >/dev/null 2>&1 || log_warn "软件源更新失败"

PKG_LIST="irqbalance ethtool ip-full kmod-tcp-bbr kmod-sched-core bind-host coreutils-stat"
for pkg in $PKG_LIST; do
    if opkg list-installed 2>/dev/null | grep -q "^$pkg "; then
        log_info "   ⏭️  $pkg"
    else
        log_info "   ⬇️  安装 $pkg..."
        opkg install "$pkg" >> "$LOG_FILE" 2>&1 || true
    fi
done

# ==================== 阶段 3: 硬件加速 ====================
log_info ""
log_info "⚡ [3/7] 硬件流量卸载..."

if uci -q get firewall.@defaults[0] >/dev/null; then
    uci set firewall.@defaults[0].flow_offloading='1'
    uci set firewall.@defaults[0].flow_offloading_hw='1' 2>/dev/null || true
    
    # 遍历 Zone 开启 FullCone NAT
    for i in $(seq 0 9); do
        z_name=$(uci -q get firewall.@zone[$i].name 2>/dev/null)
        [ -z "$z_name" ] && break
        [ "$z_name" = "wan" ] && uci set firewall.@zone[$i].fullcone4='1' 2>/dev/null || true
    done
    
    uci set firewall.@defaults[0].drop_invalid='1' 2>/dev/null || true
    uci set firewall.@defaults[0].syn_flood='1' 2>/dev/null || true
    uci commit firewall
    /etc/init.d/firewall restart >/dev/null 2>&1 || true
    log_info "✅ 硬件卸载与 FullCone 已激活"
fi

# ==================== 阶段 4: 内核参数（16GB RAM 满血版）====================
log_info ""
log_info "🛠️ [4/7] 内核参数优化（代理场景）..."
backup_file "/etc/sysctl.conf"

cat > /etc/sysctl.conf <<'EOF'
# ============================================================
# NanoPC-T6 代理主路由专用内核参数 (16GB RAM 满血版)
# ============================================================
net.core.default_qdisc=fq_codel
net.ipv4.tcp_congestion_control=bbr
net.ipv4.ip_forward=1
net.ipv6.conf.all.forwarding=1
net.ipv6.conf.default.forwarding=1

# 连接跟踪 (52万)
net.netfilter.nf_conntrack_max=524288
net.netfilter.nf_conntrack_buckets=131072
net.netfilter.nf_conntrack_tcp_timeout_established=7200
net.netfilter.nf_conntrack_tcp_timeout_time_wait=30
net.netfilter.nf_conntrack_udp_timeout=180
net.netfilter.nf_conntrack_udp_timeout_stream=300

# 网络缓冲区 (32MB)
net.core.rmem_max=33554432
net.core.wmem_max=33554432
net.core.rmem_default=262144
net.core.wmem_default=262144
net.ipv4.tcp_rmem=4096 131072 33554432
net.ipv4.tcp_wmem=4096 131072 33554432
net.core.netdev_max_backlog=16384
net.core.somaxconn=8192

# TCP 优化
net.ipv4.tcp_fastopen=3
net.ipv4.tcp_slow_start_after_idle=0
net.ipv4.tcp_notsent_lowat=16384
net.ipv4.tcp_window_scaling=1
net.ipv4.tcp_timestamps=1
net.ipv4.tcp_sack=1
net.ipv4.tcp_fack=1
net.ipv4.tcp_ecn=0
net.ipv4.tcp_mtu_probing=1
net.ipv4.tcp_syncookies=1
net.ipv4.tcp_tw_reuse=1

# 系统限制
fs.file-max=2097152
fs.inotify.max_user_instances=8192
fs.inotify.max_user_watches=524288
net.core.rps_sock_flow_entries=32768
EOF

sysctl -p >/dev/null 2>&1 || true
log_info "✅ 内核参数已加载"

# ==================== 阶段 5: RPS/RFS（三重锁定逻辑）====================
log_info ""
log_info "🔥 [5/7] 部署多核 RPS 三重锁定机制..."

# 1. Hotplug 锁定
cat > /etc/hotplug.d/net/40-rps-rfs <<EOF
#!/bin/sh
[ "\$ACTION" = "add" ] || [ "\$ACTION" = "ifup" ] || exit 0
for queue in /sys/class/net/\$INTERFACE/queues/rx-*/rps_cpus; do
    [ -f "\$queue" ] && echo "$RPS_MASK" > "\$queue"
done
EOF
chmod +x /etc/hotplug.d/net/40-rps-rfs

# 2. Cron 定时守护 (每分钟强制写回)
(crontab -l 2>/dev/null | grep -v "rps_cpus"; echo "* * * * * for q in /sys/class/net/eth*/queues/rx-*/rps_cpus; do echo '$RPS_MASK' > \"\$q\"; done") | crontab -
/etc/init.d/cron enable && /etc/init.d/cron restart

# 3. 立即应用
for dev in $(ls /sys/class/net | grep -E 'eth|enp|lan|wan'); do
    for q in /sys/class/net/$dev/queues/rx-*/rps_cpus; do
        [ -f "$q" ] && echo "$RPS_MASK" > "$q" 2>/dev/null || true
    done
done

log_info "✅ RPS/RFS 锁定已建立 (掩码: $RPS_MASK)"

# ==================== 阶段 6: 启动项优化 ====================
log_info ""
log_info "🔋 [6/7] 启动项与 CPU 调度..."
backup_file "/etc/rc.local"

cat > /etc/rc.local <<EOF
#!/bin/sh
# NanoPC-T6 优化启动脚本 v20.0
(
    sleep 30
    # 强制补刀 RPS
    for q in /sys/class/net/eth*/queues/rx-*/rps_cpus; do echo "$RPS_MASK" > "\$q" 2>/dev/null; done
    # CPU 调频策略
    for i in \$(seq 0 7); do
        echo "$CPU_GOVERNOR" > "/sys/devices/system/cpu/cpu\$i/cpufreq/scaling_governor" 2>/dev/null
    done
    # 队列长度
    for dev in \$(ls /sys/class/net | grep -E 'eth|enp|lan|wan'); do
        ip link set "\$dev" txqueuelen $TX_QUEUE_LEN 2>/dev/null
    done
) &
/etc/init.d/irqbalance start 2>/dev/null || true
exit 0
EOF

chmod +x /etc/rc.local
log_info "✅ 启动项已配置 | 调频: $CPU_GOVERNOR"

# ==================== 阶段 7: irqbalance ====================
log_info ""
log_info "⚖️ [7/7] 中断平衡服务..."
/etc/init.d/irqbalance enable >/dev/null 2>&1
/etc/init.d/irqbalance restart >/dev/null 2>&1
log_info "✅ irqbalance 已激活"

# ==================== 最终验证 ====================
log_info ""
log_info "================ 配置验证 ================"
log_info "✅ BBR: $(sysctl -n net.ipv4.tcp_congestion_control)"
log_info "✅ CPU 调频: $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null)"
log_info "🌡️  温度: $(($(cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null || echo 0) / 1000))°C"

RPS_VAL=$(cat /sys/class/net/eth1/queues/rx-0/rps_cpus 2>/dev/null || echo "N/A")
log_info "🔥 RPS 状态 (eth1): $RPS_VAL (目标: $RPS_MASK)"

log_info "==========================================="
log_info ""
log_info "🎉 优化完成！脚本 v20.0 已修正持久化问题。"
log_info "🔧 重启后请等待 60 秒，定时任务会自动锁定 RPS 为 ff。"
log_info "==========================================="
