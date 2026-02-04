#!/bin/bash
# ==============================================================================
# NanoPC-T6 (16GB) 代理主路由专用优化脚本 v20.0
# ------------------------------------------------------------------------------
# 硬件: RK3588 8核心 / 16GB 内存 / 64GB 存储 / 2x 2.5G 网口
# 场景: 主路由 + 代理软件（OpenClash/HomeProxy/PassWall）
# 特性: 高并发连接、低延迟、多核优化、代理友好
# ==============================================================================

set -e

# --- 全局变量 ---
LOG_FILE="/tmp/optimization_v20_$(date +%Y%m%d).log"
BACKUP_DIR="/etc/config_backup_$(date +%Y%m%d_%H%M%S)"
CPU_GOVERNOR="schedutil"  # 负载感应（推荐）或 performance（极致性能）
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
log_info "🚀 NanoPC-T6 代理主路由优化 v20.0"

DEVICE_MODEL=$(tr -d '\0' < /proc/device-tree/model 2>/dev/null || echo 'RK3588 Device')
log_info "设备: $DEVICE_MODEL"

# 检测内存
TOTAL_MEM=$(free -m | awk 'NR==2 {print $2}')
log_info "内存: ${TOTAL_MEM}MB"

[ "$(id -u)" -eq 0 ] || log_err "需要 root 权限"
check_network

# ==================== 阶段 1: 环境清理 ====================
log_info ""
log_info "🧹 [1/7] 环境清理..."

# SmartDNS 清理（代理软件需要接管 DNS）
if opkg list-installed 2>/dev/null | grep -q "smartdns"; then
    log_warn "检测到 SmartDNS，正在移除（避免与代理冲突）..."
    /etc/init.d/smartdns stop 2>/dev/null || true
    /etc/init.d/smartdns disable 2>/dev/null || true
    opkg remove luci-app-smartdns smartdns --force-removal-of-dependent-packages >/dev/null 2>&1 || true
    rm -rf /etc/config/smartdns /etc/smartdns 2>/dev/null
    log_info "✅ SmartDNS 已移除"
else
    log_info "✅ 环境纯净"
fi

# Dnsmasq 重置（为代理软件准备）
log_info "重置 dnsmasq 配置..."
backup_file "/etc/config/dhcp"

uci_delete_all "dhcp.@dnsmasq[0].server"
uci set dhcp.@dnsmasq[0].noresolv='0'
uci set dhcp.@dnsmasq[0].cachesize='5000'  # 代理场景：适中缓存
uci set dhcp.@dnsmasq[0].min_cache_ttl='600'  # 10分钟
uci commit dhcp

# 安全重启 dnsmasq
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
log_info "✅ dnsmasq 已重置为代理兼容模式"

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
        opkg install "$pkg" >> "$LOG_FILE" 2>&1 || log_warn "   ⚠️  $pkg 安装失败"
    fi
done

# ==================== 阶段 3: 硬件加速 ====================
log_info ""
log_info "⚡ [3/7] 硬件流量卸载..."

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
        
        # FullCone NAT（代理必需）
        if uci -q get firewall.@zone[1] >/dev/null 2>&1; then
            uci set firewall.@zone[1].fullcone4='1' 2>/dev/null || true
        fi
        
        # 安全增强
        uci set firewall.@defaults[0].drop_invalid='1' 2>/dev/null || true
        uci set firewall.@defaults[0].syn_flood='1' 2>/dev/null || true
        
        uci commit firewall
        /etc/init.d/firewall restart 2>&1 | grep -v "unknown option" | grep -v "specifies unknown" || true
        log_info "✅ 硬件卸载已激活"
    fi
fi

# ==================== 阶段 4: 内核参数（代理优化）====================
log_info ""
log_info "🛠️ [4/7] 内核参数优化（代理场景）..."
backup_file "/etc/sysctl.conf"

cat > /etc/sysctl.conf <<'EOF'
# ============================================================
# NanoPC-T6 代理主路由专用内核参数
# 优化目标: 高并发连接 + 低延迟 + 多核利用
# ============================================================

# --- BBR 拥塞控制 ---
net.core.default_qdisc=fq_codel
net.ipv4.tcp_congestion_control=bbr

# --- 路由转发（必须）---
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
# UDP 代理关键
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

# --- MTU 优化 ---
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

# --- 多核网络处理（RPS/RFS）---
net.core.rps_sock_flow_entries=32768
EOF

sysctl -p 2>&1 | grep -v "cannot stat" | grep -v "No such file" || true
log_info "✅ 内核参数已加载"

# ==================== 阶段 5: RPS/RFS（多核优化 + 持久化修正）====================
log_info ""
log_info "🔥 [5/7] 多核网络处理优化与持久化守护..."

# 动态检测 CPU 核心数
CPU_CORES=$(grep -c ^processor /proc/cpuinfo 2>/dev/null || echo "8")
log_info "检测到 $CPU_CORES 个 CPU 核心"

# 计算 RPS 掩码
if [ "$CPU_CORES" -eq 8 ]; then
    RPS_MASK="ff"
elif [ "$CPU_CORES" -eq 6 ]; then
    RPS_MASK="3f"
else
    RPS_MASK="ff"
fi

# 修正 Hotplug 脚本
cat > /etc/hotplug.d/net/40-rps-rfs <<EOF
#!/bin/sh
# RPS/RFS 自动配置与强制锁定
[ "\$ACTION" = "add" ] || [ "\$ACTION" = "ifup" ] || exit 0
case "\$INTERFACE" in
    eth*|lan*|wan*|enp*|br-lan)
        for queue in /sys/class/net/\$INTERFACE/queues/rx-*/rps_cpus; do
            [ -f "\$queue" ] && echo "$RPS_MASK" > "\$queue"
        done
        for queue in /sys/class/net/\$INTERFACE/queues/rx-*/rps_flow_cnt; do
            [ -f "\$queue" ] && echo "4096" > "\$queue"
        done
        ;;
esac
EOF
chmod +x /etc/hotplug.d/net/40-rps-rfs

# 新增：Cron 定时守护（防止系统后期重置）
if ! crontab -l 2>/dev/null | grep -q "rps_cpus"; then
    (crontab -l 2>/dev/null; echo "* * * * * for q in /sys/class/net/eth*/queues/rx-*/rps_cpus; do echo '$RPS_MASK' > \"\$q\"; done") | crontab -
    /etc/init.d/cron restart
    log_info "✅ 已添加定时守护锁定机制"
fi

# 立即应用到现有网卡
for dev in eth0 eth1 eth2 br-lan; do
    if [ -d "/sys/class/net/$dev" ]; then
        for queue in /sys/class/net/$dev/queues/rx-*/rps_cpus; do
            [ -f "$queue" ] && echo "$RPS_MASK" > "$queue" 2>/dev/null || true
        done
    fi
done

log_info "✅ RPS/RFS 已启用（掩码: $RPS_MASK）"

# ==================== 阶段 6: 启动项优化 ====================
log_info ""
log_info "🔋 [6/7] 启动项与 CPU 调度..."
backup_file "/etc/rc.local"

cat > /etc/rc.local <<EOF
#!/bin/sh
# NanoPC-T6 代理主路由启动脚本 (v20.0)

# 核心补刀逻辑：等待驱动完全初始化后再次写入
(
    sleep 30
    # 1. 网卡队列优化
    for dev in eth0 eth1 eth2 br-lan; do
        [ -d "/sys/class/net/\$dev" ] && ip link set "\$dev" txqueuelen $TX_QUEUE_LEN 2>/dev/null
    done

    # 2. CPU 调频策略
    for i in \$(seq 0 $((CPU_CORES - 1))); do
        [ -f "/sys/devices/system/cpu/cpu\$i/cpufreq/scaling_governor" ] && \
        echo "$CPU_GOVERNOR" > "/sys/devices/system/cpu/cpu\$i/cpufreq/scaling_governor" 2>/dev/null
    done

    # 3. RPS/RFS 最终强制应用
    for q in /sys/class/net/eth*/queues/rx-*/rps_cpus; do
        echo "$RPS_MASK" > "\$q" 2>/dev/null
    done
) &

# 4. 确保 irqbalance 运行
/etc/init.d/irqbalance start 2>/dev/null || true

exit 0
EOF

chmod +x /etc/local
log_info "✅ 启动项已配置 | 调频: $CPU_GOVERNOR"

# ==================== 阶段 7: irqbalance ====================
log_info ""
log_info "⚖️ [7/7] 中断平衡服务..."

if [ ! -f /etc/config/irqbalance ]; then
    cat > /etc/config/irqbalance <<'EOF'
config irqbalance
    option enabled '1'
    option interval '10'
EOF
else
    uci set irqbalance.@irqbalance[0].enabled='1'
    uci set irqbalance.@irqbalance[0].interval='10'
    uci commit irqbalance
fi

/etc/init.d/irqbalance enable >/dev/null 2>&1
/etc/init.d/irqbalance restart >/dev/null 2>&1

log_info "✅ irqbalance 配置完成"

# ==================== 最终验证 ====================
log_info ""
log_info "================ 配置验证 ================"

TCP_ALG=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "unknown")
log_info "✅ BBR: $TCP_ALG"

CPU_GOV=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo "unknown")
log_info "✅ CPU 调频: $CPU_GOV"

if [ -f /sys/class/thermal/thermal_zone0/temp ]; then
    TEMP=$(($(cat /sys/class/thermal/thermal_zone0/temp) / 1000))
    log_info "🌡️  温度: ${TEMP}°C"
fi

RPS_STATUS=$(cat /sys/class/net/eth1/queues/rx-0/rps_cpus 2>/dev/null || echo "N/A")
log_info "🔥 RPS 状态 (eth1): $RPS_STATUS (目标: $RPS_MASK)"

log_info "==========================================="
log_info ""
log_info "🎉 优化完成！脚本 v20.0 已部署全量持久化补丁。"
log_info ""
log_info "🔧 重启提示:"
log_info "  - 执行 reboot 重启"
log_info "  - 开机后如果立即检查 cat 仍为 01，请稍等 1 分钟"
log_info "  - Cron 守护任务每分钟会自动纠正该值为 $RPS_MASK"
log_info "==========================================="
