#!/bin/bash
# ==============================================================================
# NanoPC-T6 (16GB) 代理主路由优化脚本 v24.0 - 纯净性能版
# ------------------------------------------------------------------------------
# 核心逻辑：完全剔除 RPS 干扰，由系统自动管理网卡队列，专注于 CPU 和内存池优化。
# 适用：ImmortalWrt / OpenWrt 24.xx 及以上版本
# ==============================================================================

set -e

# --- [全局参数配置] ---
LOG_FILE="/tmp/optimization_v24_$(date +%Y%m%d).log"
BACKUP_DIR="/etc/config_backup_v24"

# CPU 频率与模式 (Policy 0/4/6 分别对应 A55 小核, A76 大核簇1, A76 大核簇2)
CPU_GOVERNOR="schedutil"
MIN_FREQ="1008000"
MAX_FREQ="1800000"

log_info() { echo -e "\033[32m[INFO] [$(date +'%H:%M:%S')] $1\033[0m" | tee -a "$LOG_FILE"; }
log_warn() { echo -e "\033[33m[WARN] [$(date +'%H:%M:%S')] $1\033[0m" | tee -a "$LOG_FILE"; }
log_err()  { echo -e "\033[31m[ERROR] [$(date +'%H:%M:%S')] $1\033[0m" | tee -a "$LOG_FILE"; exit 1; }

backup_file() {
    [ -f "$1" ] && { mkdir -p "$BACKUP_DIR"; cp -a "$1" "$BACKUP_DIR/"; log_info "💾 备份: $1"; }
}

[ "$(id -u)" -eq 0 ] || log_err "错误: 必须以 root 权限运行"

log_info "🚀 NanoPC-T6 v24.0 纯净性能版启动..."

# ==================== 阶段 1: 环境清理 ====================
log_info "🧹 [1/6] 清理冗余配置..."

# 彻底清除可能存在的旧脚本遗留
rm -f /etc/hotplug.d/net/99-rps-lock 2>/dev/null
rm -f /usr/bin/rps_enforcer.sh 2>/dev/null
# 清理 crontab 中的 rps 相关行
crontab -l 2>/dev/null | grep -v "rps_cpus" | crontab - 2>/dev/null || true

# 移除 SmartDNS (代理场景建议只用 Dnsmasq + 代理软件自带 DNS)
if opkg list-installed 2>/dev/null | grep -q "smartdns"; then
    /etc/init.d/smartdns stop 2>/dev/null || true
    opkg remove luci-app-smartdns smartdns --force-removal-of-dependent-packages >/dev/null 2>&1 || true
    log_info "✅ SmartDNS 已卸载"
fi

# Dnsmasq 针对 16GB 内存的高速化
backup_file "/etc/config/dhcp"
uci set dhcp.@dnsmasq[0].cachesize='10000'
uci set dhcp.@dnsmasq[0].min_cache_ttl='600'
uci set dhcp.@dnsmasq[0].localservice='0'
uci commit dhcp
/etc/init.d/dnsmasq restart >/dev/null 2>&1
log_info "✅ Dnsmasq 缓存增强完成"

# ==================== 阶段 2: 核心组件检测 ====================
log_info "📦 [2/6] 检查必要工具包 (跳过 irqbalance)..."
opkg update >/dev/null 2>&1 || true
# 只安装网络管理和状态查看工具，不再强行干预中断分配
opkg install ethtool ip-full kmod-tcp-bbr bind-host coreutils-stat >/dev/null 2>&1 || true

# ==================== 阶段 3: 硬件转发与 FullCone ====================
log_info "⚡ [3/6] 激活硬件加速与 FullCone NAT..."

# 遍历 Zone 开启 FullCone
idx=0
while [ -n "$(uci -q get firewall.@zone[$idx])" ]; do
    [ "$(uci -q get firewall.@zone[$idx].name)" = "wan" ] && uci set firewall.@zone[$idx].fullcone4='1'
    idx=$((idx+1))
done

# 开启全局硬件流量卸载
uci set firewall.@defaults[0].flow_offloading='1'
uci set firewall.@defaults[0].flow_offloading_hw='1'
uci commit firewall
/etc/init.d/firewall restart >/dev/null 2>&1
log_info "✅ 硬件转发与 FullCone NAT 已激活"

# ==================== 阶段 4: 16GB 满血内核参数调优 ====================
log_info "🛠️ [4/6] 注入 16GB 内存专属网络栈参数..."
backup_file "/etc/sysctl.conf"

cat > /etc/sysctl.conf <<EOF
# 代理高并发优化
net.ipv4.ip_forward=1
net.ipv6.conf.all.forwarding=1
net.ipv4.tcp_congestion_control=bbr
net.core.default_qdisc=fq_codel

# 16GB 内存专属: 52万连接跟踪
net.netfilter.nf_conntrack_max=524288
net.netfilter.nf_conntrack_buckets=131072
net.netfilter.nf_conntrack_tcp_timeout_established=7200

# 16GB 内存专属: 32MB 缓冲区映射
net.core.rmem_max=33554432
net.core.wmem_max=33554432
net.core.rmem_default=262144
net.core.wmem_default=262144
net.ipv4.tcp_rmem=4096 131072 33554432
net.ipv4.tcp_wmem=4096 131072 33554432
net.core.netdev_max_backlog=16384
net.core.somaxconn=8192

# TCP 极速响应优化
net.ipv4.tcp_fastopen=3
net.ipv4.tcp_tw_reuse=1
net.ipv4.tcp_max_syn_backlog=8192
net.ipv4.tcp_mtu_probing=1
fs.file-max=1000000
EOF

sysctl -p >/dev/null 2>&1
log_info "✅ 内核参数注入完成"

# ==================== 阶段 5: CPU 核心簇性能调优 ====================
log_info "🔋 [5/6] 锁定 CPU 核心频率 (Policy 0/4/6)..."

for policy in 0 4 6; do
    P_PATH="/sys/devices/system/cpu/cpufreq/policy${policy}"
    if [ -d "$P_PATH" ]; then
        echo "$CPU_GOVERNOR" > "$P_PATH/scaling_governor" 2>/dev/null || true
        echo "$MIN_FREQ" > "$P_PATH/scaling_min_freq" 2>/dev/null || true
        echo "$MAX_FREQ" > "$P_PATH/scaling_max_freq" 2>/dev/null || true
        log_info "   - Policy${policy} 已设为 ${CPU_GOVERNOR} (${MIN_FREQ}-${MAX_FREQ})"
    fi
done

# ==================== 阶段 6: 启动项加固 (rc.local) ====================
log_info "🔋 [6/6] 配置启动项自动同步..."
backup_file "/etc/rc.local"

cat > /etc/rc.local <<EOF
#!/bin/sh
# NanoPC-T6 v24.0 启动校准
(
    sleep 30
    # 确保网络队列长度
    for dev in eth0 eth1 eth2; do
        [ -d "/sys/class/net/\$dev" ] && ip link set "\$dev" txqueuelen 5000 2>/dev/null
    done
    # 确保 CPU 频率策略在启动后维持
    for p in 0 4 6; do
        if [ -d "/sys/devices/system/cpu/cpufreq/policy\$p" ]; then
            echo "$CPU_GOVERNOR" > /sys/devices/system/cpu/cpufreq/policy\$p/scaling_governor
            echo "$MIN_FREQ" > /sys/devices/system/cpu/cpufreq/policy\$p/scaling_min_freq
            echo "$MAX_FREQ" > /sys/devices/system/cpu/cpufreq/policy\$p/scaling_max_freq
        fi
    done
) &
exit 0
EOF
chmod +x /etc/rc.local

# ==================== 验证与结束 ====================
log_info ""
log_info "================ [v24.0 纯净性能版报告] ================"
log_info "✅ CPU 性能锁定: 已应用 (Policy 0/4/6)"
log_info "✅ 16GB 网络栈: 已满血开启 (32MB Buffer)"
log_info "✅ 硬件加速: Flow Offloading + FullCone 已开启"
log_info "✅ RPS 管理: 已交还给系统内核 (原生、稳定)"
log_info "========================================================"
log_info "🎉 脚本运行完成！重启后将获得最稳定的 RK3588 体验。"
log_info "========================================================"
