#!/bin/bash
# =========================================================
# NanoPC-T6 (RK3588) OpenWrt 终极优化脚本 v8.0
# 适用: ImmortalWrt 21.02 / 23.05 / 24.10 (fw4/nftables)
# 修复: UCI错误、网络中断、配置覆盖等问题
# =========================================================

set -e  # 严格模式：遇到错误立即退出

# 颜色定义
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

log() { echo -e "${GREEN}[INFO] $1${NC}"; }
warn() { echo -e "${YELLOW}[WARN] $1${NC}"; }
error() { echo -e "${RED}[ERROR] $1${NC}"; exit 1; }
info() { echo -e "${BLUE}[DEBUG] $1${NC}"; }

# 全局变量
BACKUP_DIR="/etc/backup_$(date +%Y%m%d_%H%M%S)"
LOGFILE="/tmp/optimization_$(date +%Y%m%d_%H%M%S).log"

# 日志函数（双重输出）
exec > >(tee -a "$LOGFILE") 2>&1

# =====================================================
# 工具函数
# =====================================================

# 备份文件
backup_file() {
    if [ -f "$1" ]; then
        mkdir -p "$BACKUP_DIR"
        cp -a "$1" "$BACKUP_DIR/" 2>/dev/null && log "💾 已备份: $1"
    fi
}

# 检测 CPU 核心数
get_cpu_count() {
    local count=$(grep -c ^processor /proc/cpuinfo 2>/dev/null || echo "4")
    echo "$count"
}

# 检查 BBR 支持
check_bbr_support() {
    if [ -f /proc/sys/net/ipv4/tcp_available_congestion_control ]; then
        grep -q bbr /proc/sys/net/ipv4/tcp_available_congestion_control && return 0
    fi
    return 1
}

# 安全的 UCI 删除（循环删除所有匹配项）
uci_delete_all() {
    local path="$1"
    while uci -q delete "$path" 2>/dev/null; do
        info "删除旧配置: $path"
    done
}

# 检查服务是否运行
check_service() {
    local service="$1"
    if pgrep -x "$service" >/dev/null; then
        return 0
    fi
    return 1
}

# =====================================================
# 1. Bash 环境检查
# =====================================================
if [ -z "$BASH_VERSION" ]; then
    warn "当前不是 Bash 环境，正在尝试安装并切换..."
    opkg update && opkg install bash || error "Bash 安装失败"
    exec bash "$0" "$@"
    exit
fi

log "🚀 开始 NanoPC-T6 极致性能调优..."
log "📅 时间: $(date)"
log "📋 日志文件: $LOGFILE"

# =====================================================
# 2. 环境检查
# =====================================================
log "🔍 步骤 1: 环境自检..."

# Root 权限检查
[ "$(id -u)" -eq 0 ] || error "请使用 root 权限执行"

# 网络检查
if ! ping -c 1 -W 3 mirrors.vsean.net >/dev/null 2>&1; then
    warn "无法连接到软件源，请检查网络"
fi

# CPU 信息
CPU_CORES=$(get_cpu_count)
log "  ✅ 检测到 $CPU_CORES 个 CPU 核心"

# 磁盘空间检查
AVAILABLE_KB=$(df /overlay 2>/dev/null | awk 'NR==2 {print $4}')
if [ -n "$AVAILABLE_KB" ] && [ "$AVAILABLE_KB" -lt 10240 ]; then
    error "可用空间不足 10MB (当前: $((AVAILABLE_KB/1024))MB)"
fi

# =====================================================
# 3. 软件包安装
# =====================================================
log "📦 步骤 2: 更新软件源并安装组件..."

opkg update || warn "软件源更新失败，继续尝试安装"

# 基础包列表
PACKAGES="smartdns luci-app-smartdns irqbalance ethtool ip-full kmod-sched-core coreutils-stat bind-host"

# 检查 BBR 支持
if check_bbr_support || modinfo tcp_bbr >/dev/null 2>&1; then
    PACKAGES="$PACKAGES kmod-tcp-bbr"
    log "  ✅ 系统支持 BBR 加速"
else
    warn "  ⚠️  当前内核不支持 BBR，跳过安装"
fi

# 逐个安装并检查
for pkg in $PACKAGES; do
    if opkg list-installed 2>/dev/null | grep -q "^$pkg "; then
        log "  ⏭️  $pkg 已安装"
    else
        log "  ⬇️  正在安装 $pkg..."
        if ! opkg install "$pkg" 2>&1 | grep -v "^Downloading"; then
            warn "  ⚠️  $pkg 安装失败（非致命）"
        fi
    fi
done

# =====================================================
# 4. 内核参数优化
# =====================================================
log "⚡ 步骤 3: 注入内核优化参数..."

backup_file /etc/sysctl.conf

cat > /etc/sysctl.conf <<'EOF'
# TCP BBR 加速
net.core.default_qdisc=fq_codel
net.ipv4.tcp_congestion_control=bbr

# 连接跟踪优化
net.netfilter.nf_conntrack_max=1048576
net.netfilter.nf_conntrack_tcp_timeout_established=3600
net.netfilter.nf_conntrack_tcp_timeout_time_wait=30

# 2.5G 网口缓冲区优化
net.core.rmem_max=16777216
net.core.wmem_max=16777216
net.core.rmem_default=262144
net.core.wmem_default=262144
net.ipv4.tcp_rmem=4096 87380 16777216
net.ipv4.tcp_wmem=4096 65536 16777216
net.core.netdev_max_backlog=5000

# TCP 性能优化
net.ipv4.tcp_fastopen=3
net.ipv4.tcp_window_scaling=1
net.ipv4.tcp_timestamps=1
net.ipv4.tcp_sack=1

# 安全防护
net.ipv4.tcp_syncookies=1
net.ipv4.tcp_syn_retries=2
net.ipv4.tcp_synack_retries=2
net.ipv4.tcp_max_syn_backlog=4096

# 文件描述符限制
fs.file-max=1000000
EOF

# 应用配置（忽略不支持的参数）
sysctl -p 2>&1 | grep -v "cannot stat" | grep -v "No such file" || true

# =====================================================
# 5. SmartDNS 配置（智能合并）
# =====================================================
log "🌐 步骤 4: 配置 SmartDNS 解析引擎..."

# 停止服务
/etc/init.d/smartdns stop 2>/dev/null || true

# 备份现有配置
backup_file /etc/config/smartdns

# 检查是否已有配置（智能合并）
if uci -q get smartdns.@smartdns[0] >/dev/null 2>&1; then
    log "  🔧 发现现有配置，执行合并..."
    uci set smartdns.@smartdns[0].enabled='1'
    uci set smartdns.@smartdns[0].port='6053'
    uci set smartdns.@smartdns[0].tcp_server='1'
    uci set smartdns.@smartdns[0].ipv6_server='1'
    uci set smartdns.@smartdns[0].dualstack_ip_selection='1'
    uci set smartdns.@smartdns[0].prefetch_domain='1'
    uci set smartdns.@smartdns[0].serve_expired='1'
    uci set smartdns.@smartdns[0].cache_size='10240'
    uci set smartdns.@smartdns[0].redirect='dnsmasq-upstream'
    uci -q set smartdns.@smartdns[0].force_tcp='0'  # 避免强制 TCP 导致性能下降
    uci commit smartdns
else
    log "  📝 创建全新配置..."
    cat > /etc/config/smartdns <<'EOF'
config smartdns
    option enabled '1'
    option port '6053'
    option tcp_server '1'
    option ipv6_server '1'
    option dualstack_ip_selection '1'
    option prefetch_domain '1'
    option serve_expired '1'
    option cache_size '10240'
    option redirect 'dnsmasq-upstream'
    option rr_ttl_min '300'
    option rr_ttl_max '3600'
    option force_tcp '0'

config server
    option name 'alidns'
    option ip '223.5.5.5'
    option type 'udp'
    option enabled '1'

config server
    option name 'dnspod'
    option ip '119.29.29.29'
    option type 'udp'
    option enabled '1'

config server
    option name 'cloudflare'
    option ip '1.1.1.1'
    option type 'udp'
    option enabled '1'

config server
    option name 'ali_doh'
    option ip 'https://223.5.5.5/dns-query'
    option type 'https'
    option enabled '1'
EOF
fi

# 启动服务
/etc/init.d/smartdns enable
/etc/init.d/smartdns start || warn "SmartDNS 启动失败，请检查配置"

# =====================================================
# 6. DNS 转发配置（修复 UCI 错误）
# =====================================================
log "🔗 步骤 5: 配置 DNS 转发到 SmartDNS..."

backup_file /etc/config/dhcp

# 安全删除所有旧的 server 配置
uci_delete_all "dhcp.@dnsmasq[0].server"

# 添加新配置
uci add_list dhcp.@dnsmasq[0].server='127.0.0.1#6053'
uci set dhcp.@dnsmasq[0].noresolv='1'
uci set dhcp.@dnsmasq[0].cachesize='0'
uci commit dhcp

# 重启 dnsmasq（带超时保护）
log "  🔄 重启 dnsmasq 服务..."
timeout 10 /etc/init.d/dnsmasq restart || {
    warn "dnsmasq 重启超时，尝试强制重启"
    killall dnsmasq 2>/dev/null
    /etc/init.d/dnsmasq start
}

# 等待服务稳定
sleep 2

# =====================================================
# 7. IRQ 中断平衡
# =====================================================
log "⚖️  步骤 6: 启用中断平衡..."

# 使用 UCI 配置（如果支持）
if uci -q get irqbalance.@irqbalance[0] >/dev/null 2>&1; then
    uci set irqbalance.@irqbalance[0].enabled='1'
    uci commit irqbalance
fi

/etc/init.d/irqbalance enable
/etc/init.d/irqbalance restart || warn "irqbalance 启动失败"

# =====================================================
# 8. 防火墙优化
# =====================================================
log "🛡️  步骤 7: 优化防火墙设置..."

# 启用流量卸载
if uci -q get firewall.@defaults[0] >/dev/null 2>&1; then
    uci set firewall.@defaults[0].flow_offloading='1'
    uci -q set firewall.@defaults[0].flow_offloading_hw='1' 2>/dev/null || true
fi

# 启用 NAT 全锥（如果支持）
if uci -q get firewall.@zone[1] >/dev/null 2>&1; then
    # 检查是否支持 fullcone4 选项
    if uci -q get firewall.@zone[1].fullcone4 >/dev/null 2>&1 || \
       grep -q fullcone /etc/firewall.user 2>/dev/null; then
        uci -q set firewall.@zone[1].fullcone4='1' 2>/dev/null || true
        log "  ✅ 已启用 NAT 全锥模式"
    else
        info "  当前版本不支持 fullcone4，跳过"
    fi
fi

uci commit firewall
/etc/init.d/firewall restart 2>&1 | grep -v "unknown option" || true

# =====================================================
# 9. CPU 性能模式（动态核心数）
# =====================================================
log "🔥 步骤 8: 配置 CPU 性能模式..."

backup_file /etc/rc.local

# 使用实际检测的核心数
cat > /etc/rc.local <<EOF
#!/bin/sh
# ===== NanoPC-T6 性能优化启动脚本 =====

# 网卡队列优化
for dev in \$(ls /sys/class/net 2>/dev/null | grep -E 'eth|enp|lan|wan'); do
    [ -d "/sys/class/net/\$dev" ] && ip link set "\$dev" txqueuelen 5000 2>/dev/null
done

# CPU 性能模式锁定（检测到 $CPU_CORES 个核心）
for i in \$(seq 0 $((CPU_CORES - 1))); do
    CPU_PATH="/sys/devices/system/cpu/cpu\$i/cpufreq"
    if [ -d "\$CPU_PATH" ]; then
        # 设置性能模式
        echo "performance" > "\$CPU_PATH/scaling_governor" 2>/dev/null || true
        
        # 可选：锁定最小频率（激进优化，可能增加功耗）
        # MAX_FREQ=\$(cat "\$CPU_PATH/scaling_max_freq" 2>/dev/null)
        # [ -n "\$MAX_FREQ" ] && echo "\$MAX_FREQ" > "\$CPU_PATH/scaling_min_freq" 2>/dev/null || true
    fi
done

# 确保服务运行
sleep 3
/etc/init.d/smartdns start 2>/dev/null
/etc/init.d/irqbalance start 2>/dev/null

exit 0
EOF

chmod +x /etc/rc.local

# 立即执行一次
log "  🚀 立即应用 CPU 优化..."
/etc/rc.local 2>&1 | head -5

# =====================================================
# 10. 状态验证
# =====================================================
log "\n🔍 步骤 9: 验证配置状态..."

# 等待服务完全启动
sleep 3

# 检查 SmartDNS
if netstat -tunlp 2>/dev/null | grep -q ":6053"; then
    SMARTDNS_PID=$(pidof smartdns 2>/dev/null || echo "未知")
    log "  ✅ SmartDNS: 运行正常 (PID: $SMARTDNS_PID, 端口: 6053)"
else
    warn "  ⚠️  SmartDNS: 端口未监听，请检查日志"
fi

# 检查 irqbalance
if check_service irqbalance; then
    log "  ✅ irqbalance: 运行中"
else
    warn "  ⚠️  irqbalance: 未运行"
fi

# DNS 解析测试
log "  🔬 DNS 解析测试..."
DNS_TEST=$(timeout 3 host -W 2 baidu.com 127.0.0.1 -p 6053 2>&1 | head -1)
if echo "$DNS_TEST" | grep -q "has address"; then
    log "  ✅ DNS 解析: 正常 ($DNS_TEST)"
else
    warn "  ⚠️  DNS 解析: 测试失败"
    info "     响应: $DNS_TEST"
fi

# BBR 状态
if [ -f /proc/sys/net/ipv4/tcp_congestion_control ]; then
    BBR_STATUS=$(cat /proc/sys/net/ipv4/tcp_congestion_control)
    if [ "$BBR_STATUS" = "bbr" ]; then
        log "  ✅ BBR 加速: 已启用"
    else
        info "  当前拥塞控制: $BBR_STATUS"
    fi
fi

# CPU 调频器状态
GOVERNOR=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo "unknown")
log "  ⚙️  CPU 调频策略: $GOVERNOR"

# 温度检测
if [ -f /sys/class/thermal/thermal_zone0/temp ]; then
    TEMP=$(($(cat /sys/class/thermal/thermal_zone0/temp) / 1000))
    log "  🌡️  CPU 温度: ${TEMP}°C"
fi

# =====================================================
# 完成
# =====================================================
log "\n=========================================="
log "🎉 优化完成！NanoPC-T6 已进入最佳状态"
log "=========================================="
log "📁 配置备份: $BACKUP_DIR"
log "📋 详细日志: $LOGFILE"
log ""
log "🔧 建议操作:"
log "  1. 重启系统确保所有配置生效: reboot"
log "  2. 查看实时日志: logread -f"
log "  3. 检查 SmartDNS: ps | grep smartdns"
log "  4. 验证 DNS: nslookup baidu.com 127.0.0.1 -port=6053"
log ""
log "❗ 如遇问题，可恢复备份: cp -r $BACKUP_DIR/* /etc/"
log "=========================================="
