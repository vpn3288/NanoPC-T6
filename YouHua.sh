#!/bin/bash
# ==============================================================================
# NanoPC-T6 (16GB) 代理主路由专用优化脚本 v19.3
# ------------------------------------------------------------------------------
# 硬件: RK3588 8核心 / 16GB 内存 / 64GB 存储 / 2x 2.5G 网口
# 修复: 移除严格错误退出模式，增强防火墙操作兼容性，自动适配 eth1/eth2
# ==============================================================================

# --- 全局变量 ---
LOG_FILE="/tmp/optimization_v19_$(date +%Y%m%d).log"
BACKUP_DIR="/etc/config_backup_$(date +%Y%m%d_%H%M%S)"
CPU_GOVERNOR="schedutil"
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
    log_warn "⚠️ 网络检查未通过，尝试继续运行..."
}

uci_delete_all() {
    while uci -q delete "$1" 2>/dev/null; do :; done
}

# --- 主流程 ---
log_info "🚀 NanoPC-T6 代理主路由优化 v19.3"

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

log_info "重置 dnsmasq 配置..."
backup_file "/etc/config/dhcp"
uci_delete_all "dhcp.@dnsmasq[0].server"
uci set dhcp.@dnsmasq[0].noresolv='0'
uci set dhcp.@dnsmasq[0].cachesize='5000'
uci set dhcp.@dnsmasq[0].min_cache_ttl='600'
uci commit dhcp

/etc/init.d/dnsmasq restart >/dev/null 2>&1 || true
sleep 1
log_info "✅ dnsmasq 已重置"

# ==================== 阶段 2: 软件包安装 ====================
log_info ""
log_info "📦 [2/7] 核心组件安装..."
opkg update >/dev/null 2>&1 || log_warn "软件源更新失败，尝试直接安装..."

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

if [ -f /etc/config/turboacc ] || opkg list-installed 2>/dev/null | grep -q "turboacc"; then
    log_info "启用 TurboACC..."
    uci set turboacc.config.enabled='1' 2>/dev/null || true
    uci set turboacc.config.sfe_flow='1' 2>/dev/null || true
    uci set turboacc.config.fullcone_nat='1' 2>/dev/null || true
    uci commit turboacc 2>/dev/null || true
    /etc/init.d/turboacc restart 2>/dev/null || true
    log_info "✅ TurboACC 已提交"
else
    log_info "启用原生硬件卸载..."
    if uci -q get firewall.@defaults[0] >/dev/null; then
        uci set firewall.@defaults[0].flow_offloading='1' 2>/dev/null || true
        uci set firewall.@defaults[0].flow_offloading_hw='1' 2>/dev/null || true
        
        # 稳健遍历 Zone 开启 FullCone
        for i in $(seq 0 9); do
            z_name=$(uci -q get firewall.@zone[$i].name 2>/dev/null)
            [ -z "$z_name" ] && break
            if [ "$z_name" = "wan" ]; then
                uci set firewall.@zone[$i].fullcone4='1' 2>/dev/null || true
            fi
        done
        
        uci commit firewall 2>/dev/null || true
        /etc/init.d/firewall restart >/dev/null 2>&1 || true
        log_info "✅ 硬件卸载指令执行完毕"
    else
        log_warn "⚠️ 无法找到标准防火墙 defaults[0] 配置"
    fi
fi

# ==================== 阶段 4: 内核参数（代理优化）====================
log_info ""
log_info "🛠️ [4/7] 内核参数优化（代理场景）..."
backup_file "/etc/sysctl.conf"

cat > /etc/sysctl.conf <<'EOF'
# NanoPC-T6 16GB 专用内核参数
net.core.default_qdisc = fq_codel
net.ipv4.tcp_congestion_control = bbr
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
net.ipv6.conf.default.forwarding = 1
net.netfilter.nf_conntrack_max = 524288
net.netfilter.nf_conntrack_buckets = 131072
net.netfilter.nf_conntrack_tcp_timeout_established = 7200
net.netfilter.nf_conntrack_tcp_timeout_time_wait = 30
net.netfilter.nf_conntrack_udp_timeout = 180
net.netfilter.nf_conntrack_udp_timeout_stream = 300
net.core.rmem_max = 33554432
net.core.wmem_max = 33554432
net.core.rmem_default = 262144
net.core.wmem_default = 262144
net.ipv4.tcp_rmem = 4096 131072 33554432
net.ipv4.tcp_wmem = 4096 131072 33554432
net.core.netdev_max_backlog = 16384
net.core.somaxconn = 8192
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_notsent_lowat = 16384
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_sack = 1
net.ipv4.tcp_fack = 1
net.ipv4.tcp_ecn = 0
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_tw_reuse = 1
fs.file-max = 2097152
fs.inotify.max_user_instances = 8192
fs.inotify.max_user_watches = 524288
net.core.rps_sock_flow_entries = 32768
EOF

sysctl -p >/dev/null 2>&1 || true
log_info "✅ 内核参数已注入"

# ==================== 阶段 5: RPS/RFS（多核优化）====================
log_info ""
log_info "🔥 [5/7] 多核网络处理优化..."

CPU_CORES=$(grep -c ^processor /proc/cpuinfo 2>/dev/null || echo "8")
RPS_MASK="ff" # 8核全开

for dev in $(ls /sys/class/net | grep -E 'eth|enp|lan|wan'); do
    [ -d "/sys/class/net/$dev/queues" ] || continue
    log_info "正在配置接口: $dev"
    for q in /sys/class/net/$dev/queues/rx-*/rps_cpus; do
        [ -f "$q" ] && echo "$RPS_MASK" > "$q" 2>/dev/null || true
    done
    for q in /sys/class/net/$dev/queues/rx-*/rps_flow_cnt; do
        [ -f "$q" ] && echo "4096" > "$q" 2>/dev/null || true
    done
done

cat > /etc/hotplug.d/net/40-rps-rfs <<EOF
#!/bin/sh
[ "\$ACTION" = "add" ] || exit 0
case "\$INTERFACE" in
    eth*|lan*|wan*|enp*)
        for q in /sys/class/net/\$INTERFACE/queues/rx-*/rps_cpus; do
            [ -f "\$q" ] && echo "$RPS_MASK" > "\$q"
        done
        for q in /sys/class/net/\$INTERFACE/queues/rx-*/rps_flow_cnt; do
            [ -f "\$q" ] && echo "4096" > "\$q"
        done
        ;;
esac
EOF
chmod +x /etc/hotplug.d/net/40-rps-rfs
log_info "✅ RPS/RFS 动态分流已就绪"

# ==================== 阶段 6: 启动项优化 ====================
log_info ""
log_info "🔋 [6/7] 启动项与 CPU 调度..."
backup_file "/etc/rc.local"

cat > /etc/rc.local <<EOF
#!/bin/sh
# NanoPC-T6 代理加速启动项
sleep 5
for dev in \$(ls /sys/class/net | grep -E 'eth|enp|lan|wan'); do
    [ -d "/sys/class/net/\$dev" ] && ip link set "\$dev" txqueuelen $TX_QUEUE_LEN 2>/dev/null
    for q in /sys/class/net/\$dev/queues/rx-*/rps_cpus; do
        [ -f "\$q" ] && echo "$RPS_MASK" > "\$q" 2>/dev/null
    done
done
for i in \$(seq 0 $((CPU_CORES - 1))); do
    CPU_P="/sys/devices/system/cpu/cpu\$i/cpufreq/scaling_governor"
    [ -f "\$CPU_P" ] && echo "$CPU_GOVERNOR" > "\$CPU_P" 2>/dev/null
done
/etc/init.d/irqbalance start 2>/dev/null || true
exit 0
EOF
chmod +x /etc/rc.local
log_info "✅ 启动项已持久化"

# ==================== 阶段 7: irqbalance ====================
log_info ""
log_info "⚖️ [7/7] 中断平衡服务..."
/etc/init.d/irqbalance enable 2>/dev/null || true
/etc/init.d/irqbalance restart 2>/dev/null || true
log_info "✅ irqbalance 已尝试启动"

# ==================== 最终验证 ====================
log_info ""
log_info "================ 配置验证 ================"
log_info "✅ BBR: $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo '未知')"
log_info "✅ CPU 调度: $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo 'N/A')"
log_info "🌡️  温度: $(($(cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null || echo 0) / 1000))°C"

RPS_V="N/A"
for d in eth1 eth2 eth0; do
    [ -f /sys/class/net/$d/queues/rx-0/rps_cpus ] && { RPS_V=$(cat /sys/class/net/$d/queues/rx-0/rps_cpus); break; }
done
log_info "🔥 RPS 验证: $RPS_V"
log_info "==========================================="
log_info "🎉 脚本执行完毕！请运行 reboot 重启系统。"
