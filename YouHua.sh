#!/bin/bash
# ==============================================================================
# NanoPC-T6 (16GB) 代理主路由专用优化脚本 v19.6
# ------------------------------------------------------------------------------
# 硬件: RK3588 8核心 / 16GB 内存 / 64GB 存储 / 2x 2.5G 网口
# 场景: 主路由 + 代理软件（OpenClash/HomeProxy/PassWall）
# 特性: 高并发连接、低延迟、多核优化、代理友好
# 修复: 1. 自动识别 eth1/eth2 接口 2. 移除 set -e 防止意外中断 
#       3. 核心修复：通过 Hotplug 彻底解决重启后 RPS 掩码重置为 01 的问题
# ==============================================================================

# --- 全局变量 ---
LOG_FILE="/tmp/optimization_v19_$(date +%Y%m%d).log"
BACKUP_DIR="/etc/config_backup_$(date +%Y%m%d_%H%M%S)"
CPU_GOVERNOR="schedutil"  # 负载感应（推荐）或 performance（极致性能）
TX_QUEUE_LEN="5000"

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
    log_warn "⚠️ 网络检查未通过，脚本将尝试继续执行"
}

uci_delete_all() {
    while uci -q delete "$1" 2>/dev/null; do :; done
}

# --- 主流程 ---
log_info "🚀 NanoPC-T6 代理主路由优化 v19.6"

DEVICE_MODEL=$(tr -d '\0' < /proc/device-tree/model 2>/dev/null || echo 'RK3588 Device')
log_info "设备: $DEVICE_MODEL"

# 检测内存
TOTAL_MEM=$(free -m | awk 'NR==2 {print $2}')
log_info "内存: ${TOTAL_MEM}MB"

[ "$(id -u)" -eq 0 ] || { log_err "需要 root 权限"; exit 1; }
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
/etc/init.d/dnsmasq restart >/dev/null 2>&1 || true
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
        uci set firewall.@defaults[0].flow_offloading='1' 2>/dev/null || true
        uci set firewall.@defaults[0].flow_offloading_hw='1' 2>/dev/null || true
        
        # 稳健地查找并开启 FullCone
        idx=0
        while [ $idx -lt 10 ]; do
            z_name=$(uci -q get firewall.@zone[$idx].name)
            [ -z "$z_name" ] && break
            if [ "$z_name" = "wan" ]; then
                uci set firewall.@zone[$idx].fullcone4='1' 2>/dev/null || true
            fi
            idx=$((idx + 1))
        done
        
        uci set firewall.@defaults[0].drop_invalid='1' 2>/dev/null || true
        uci set firewall.@defaults[0].syn_flood='1' 2>/dev/null || true
        
        uci commit firewall
        /etc/init.d/firewall restart >/dev/null 2>&1 || true
        log_info "✅ 硬件卸载已激活"
    fi
fi

# ==================== 阶段 4: 内核参数（代理优化）====================
log_info ""
log_info "🛠️ [4/7] 内核参数优化（代理场景）..."
backup_file "/etc/sysctl.conf"

cat > /etc/sysctl.conf <<'EOF'
# ============================================================
# NanoPC-T6 代理主路由专用内核参数 (16GB RAM 满血优化版)
# ============================================================

# --- BBR 拥塞控制 ---
net.core.default_qdisc=fq_codel
net.ipv4.tcp_congestion_control=bbr

# --- 路由转发 ---
net.ipv4.ip_forward=1
net.ipv6.conf.all.forwarding=1
net.ipv6.conf.default.forwarding=1

# --- 连接跟踪（针对代理场景扩展至 52 万）---
net.netfilter.nf_conntrack_max=524288
net.netfilter.nf_conntrack_buckets=131072
net.netfilter.nf_conntrack_tcp_timeout_established=7200
net.netfilter.nf_conntrack_tcp_timeout_time_wait=30
net.netfilter.nf_conntrack_udp_timeout=180
net.netfilter.nf_conntrack_udp_timeout_stream=300

# --- 网络缓冲区（32MB 高并发配置）---
net.core.rmem_max=33554432
net.core.wmem_max=33554432
net.core.rmem_default=262144
net.core.wmem_default=262144
net.ipv4.tcp_rmem=4096 131072 33554432
net.ipv4.tcp_wmem=4096 131072 33554432
net.core.netdev_max_backlog=16384
net.core.somaxconn=8192

# --- TCP 性能微调 ---
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

# --- 系统限制 ---
fs.file-max=2097152
fs.inotify.max_user_instances=8192
fs.inotify.max_user_watches=524288
net.core.rps_sock_flow_entries=32768
EOF

sysctl -p >/dev/null 2>&1 || true
log_info "✅ 内核参数已加载"

# ==================== 阶段 5: RPS/RFS（多核优化与持久化锁定）====================
log_info ""
log_info "🔥 [5/7] 多核网络处理优化与持久化..."

CPU_CORES=$(grep -c ^processor /proc/cpuinfo 2>/dev/null || echo "8")
RPS_MASK="ff"

# 核心修复：创建 Hotplug 脚本锁定网卡队列掩码
log_info "正在写入 Hotplug 强制锁定逻辑..."
cat > /etc/hotplug.d/net/40-rps-rfs <<EOF
#!/bin/sh
# NanoPC-T6 RPS/RFS 强制锁定脚本
[ "\$ACTION" = "add" ] || [ "\$ACTION" = "ifup" ] || exit 0
case "\$INTERFACE" in
    eth*|lan*|wan*|enp*)
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

# 立即应用到当前活跃网卡
for dev in $(ls /sys/class/net | grep -E 'eth|enp|lan|wan'); do
    [ -d "/sys/class/net/$dev/queues" ] || continue
    log_info "应用优化到接口: $dev"
    for queue in /sys/class/net/$dev/queues/rx-*/rps_cpus; do
        [ -f "$queue" ] && echo "$RPS_MASK" > "$queue" 2>/dev/null || true
    done
    for queue in /sys/class/net/$dev/queues/rx-*/rps_flow_cnt; do
        [ -f "$queue" ] && echo "4096" > "$queue" 2>/dev/null || true
    done
done

log_info "✅ RPS/RFS 已启用并设置 Hotplug 锁定（掩码: $RPS_MASK）"

# ==================== 阶段 6: 启动项优化 ====================
log_info ""
log_info "🔋 [6/7] 启动项与 CPU 调度..."
backup_file "/etc/rc.local"

cat > /etc/rc.local <<EOF
#!/bin/sh
# NanoPC-T6 代理主路由优化启动脚本 v19.6

# 延迟执行，确保在网络管理服务完全启动后
sleep 10

# 1. 再次强制锁定网卡队列 (二次保险)
for dev in \$(ls /sys/class/net | grep -E 'eth|enp|lan|wan'); do
    [ -d "/sys/class/net/\$dev" ] && ip link set "\$dev" txqueuelen $TX_QUEUE_LEN 2>/dev/null
    for q in \$(ls /sys/class/net/\$dev/queues/rx-*/rps_cpus 2>/dev/null); do
        echo "$RPS_MASK" > "\$q" 2>/dev/null
    done
done

# 2. CPU 调频策略 (所有 8 个核心)
for i in \$(seq 0 $((CPU_CORES - 1))); do
    CPU_PATH="/sys/devices/system/cpu/cpu\$i/cpufreq/scaling_governor"
    [ -f "\$CPU_PATH" ] && echo "$CPU_GOVERNOR" > "\$CPU_PATH" 2>/dev/null
done

# 3. 开启 irqbalance
/etc/init.d/irqbalance start 2>/dev/null || true

exit 0
EOF

chmod +x /etc/rc.local
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
    uci commit irqbalance
fi

/etc/init.d/irqbalance enable >/dev/null 2>&1
/etc/init.d/irqbalance restart >/dev/null 2>&1
log_info "✅ irqbalance 已激活"

# ==================== 最终验证 ====================
log_info ""
log_info "================ 配置验证 ================"

# 验证 BBR
log_info "✅ BBR: $(sysctl -n net.ipv4.tcp_congestion_control)"

# 验证 CPU 调度
log_info "✅ CPU 调频: $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null)"

# 验证温度
log_info "🌡️  温度: $(($(cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null || echo 0) / 1000))°C"

# 验证连接跟踪
CONN_MAX=$(sysctl -n net.netfilter.nf_conntrack_max)
log_info "📊 连接跟踪上限: $CONN_MAX"

# 动态验证 RPS (优先检查 eth1, eth2)
RPS_VAL="N/A"
for d in eth1 eth2 eth0; do
    if [ -f "/sys/class/net/$d/queues/rx-0/rps_cpus" ]; then
        RPS_VAL=$(cat "/sys/class/net/$d/queues/rx-0/rps_cpus")
        log_info "🔥 RPS 状态 ($d): $RPS_VAL (目标: $RPS_MASK)"
        break
    fi
done

log_info "==========================================="
log_info ""
log_info "🎉 优化完成！脚本 v19.6 已应用持久化修复。"
log_info ""
log_info "📋 核心配置确认:"
log_info "   • 52万连接跟踪 (代理高并发)"
log_info "   • 32MB 网络缓冲区 (16GB 内存特调)"
log_info "   • RPS/RFS 全核锁定 (Hotplug 锁定)"
log_info ""
log_info "🔧 下一步: 请运行 reboot 重启系统，重启后 RPS 将永久保持 ff。"
log_info "📁 备份与日志已保存至 $BACKUP_DIR"
log_info "==========================================="
