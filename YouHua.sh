#!/bin/bash
# =========================================================
# NanoPC-T6 (RK3588) OpenWrt 终极优化脚本 v9.0
# 适用: ImmortalWrt 21.02 / 23.05 / 24.10
# 修复: timeout命令缺失、UCI错误、irqbalance问题
# =========================================================

set -e

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

# 双重日志输出
exec > >(tee -a "$LOGFILE") 2>&1

# =====================================================
# 工具函数
# =====================================================

backup_file() {
    if [ -f "$1" ]; then
        mkdir -p "$BACKUP_DIR"
        cp -a "$1" "$BACKUP_DIR/" 2>/dev/null && log "💾 已备份: $1"
    fi
}

get_cpu_count() {
    grep -c ^processor /proc/cpuinfo 2>/dev/null || echo "4"
}

check_bbr_support() {
    if [ -f /proc/sys/net/ipv4/tcp_available_congestion_control ]; then
        grep -q bbr /proc/sys/net/ipv4/tcp_available_congestion_control && return 0
    fi
    return 1
}

# 安全的 UCI 删除
uci_delete_all() {
    local path="$1"
    while uci -q delete "$path" 2>/dev/null; do
        info "删除旧配置: $path"
    done
}

# 检查服务状态
check_service() {
    pgrep -x "$1" >/dev/null 2>&1
}

# 替代 timeout 命令的函数
run_with_timeout() {
    local timeout_sec=$1
    shift
    local cmd="$@"
    
    # 在后台运行命令
    $cmd &
    local pid=$!
    
    # 等待指定时间
    local count=0
    while [ $count -lt $timeout_sec ]; do
        if ! kill -0 $pid 2>/dev/null; then
            wait $pid
            return $?
        fi
        sleep 1
        count=$((count + 1))
    done
    
    # 超时则杀死进程
    kill -9 $pid 2>/dev/null
    return 124  # timeout 的标准退出码
}

# =====================================================
# 1. Bash 环境检查
# =====================================================
if [ -z "$BASH_VERSION" ]; then
    warn "当前不是 Bash 环境，正在切换..."
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

[ "$(id -u)" -eq 0 ] || error "请使用 root 权限执行"

CPU_CORES=$(get_cpu_count)
log "  ✅ 检测到 $CPU_CORES 个 CPU 核心"

AVAILABLE_KB=$(df /overlay 2>/dev/null | awk 'NR==2 {print $4}')
if [ -n "$AVAILABLE_KB" ] && [ "$AVAILABLE_KB" -lt 10240 ]; then
    warn "可用空间不足 10MB，继续执行但可能失败"
fi

# =====================================================
# 3. 软件包安装
# =====================================================
log "📦 步骤 2: 更新软件源并安装组件..."

opkg update || warn "软件源更新失败"

PACKAGES="smartdns luci-app-smartdns irqbalance ethtool ip-full kmod-sched-core coreutils-stat bind-host"

# BBR 检测
if check_bbr_support || modinfo tcp_bbr >/dev/null 2>&1; then
    PACKAGES="$PACKAGES kmod-tcp-bbr"
    log "  ✅ 系统支持 BBR 加速"
else
    warn "  ⚠️  当前内核不支持 BBR，跳过安装"
fi

# 逐个安装
for pkg in $PACKAGES; do
    if opkg list-installed 2>/dev/null | grep -q "^$pkg "; then
        log "  ⏭️  $pkg 已安装"
    else
        log "  ⬇️  正在安装 $pkg..."
        opkg install "$pkg" 2>&1 | grep -E "Installing|Configuring|Error" || true
    fi
done

# =====================================================
# 4. 内核参数优化
# =====================================================
log "⚡ 步骤 3: 注入内核优化参数..."

backup_file /etc/sysctl.conf

cat > /etc/sysctl.conf <<'EOF'
# TCP 拥塞控制
net.core.default_qdisc=fq_codel
net.ipv4.tcp_congestion_control=bbr

# 连接跟踪
net.netfilter.nf_conntrack_max=1048576
net.netfilter.nf_conntrack_tcp_timeout_established=3600
net.netfilter.nf_conntrack_tcp_timeout_time_wait=30

# 网络缓冲区
net.core.rmem_max=16777216
net.core.wmem_max=16777216
net.core.rmem_default=262144
net.core.wmem_default=262144
net.ipv4.tcp_rmem=4096 87380 16777216
net.ipv4.tcp_wmem=4096 65536 16777216
net.core.netdev_max_backlog=5000

# TCP 优化
net.ipv4.tcp_fastopen=3
net.ipv4.tcp_window_scaling=1
net.ipv4.tcp_timestamps=1
net.ipv4.tcp_sack=1

# 安全防护
net.ipv4.tcp_syncookies=1
net.ipv4.tcp_syn_retries=2
net.ipv4.tcp_synack_retries=2
net.ipv4.tcp_max_syn_backlog=4096

# 文件描述符
fs.file-max=1000000
EOF

sysctl -p 2>&1 | grep -v "cannot stat" | grep -v "No such file" || true

# =====================================================
# 5. SmartDNS 配置
# =====================================================
log "🌐 步骤 4: 配置 SmartDNS 解析引擎..."

/etc/init.d/smartdns stop 2>/dev/null || true
backup_file /etc/config/smartdns

# 检查现有配置（更健壮的方式）
if [ -f /etc/config/smartdns ] && grep -q "config smartdns" /etc/config/smartdns 2>/dev/null; then
    log "  🔧 发现现有配置，执行合并..."
    
    # 只设置存在的选项，避免 UCI 错误
    uci set smartdns.@smartdns[0].enabled='1' 2>/dev/null || true
    uci set smartdns.@smartdns[0].port='6053' 2>/dev/null || true
    uci set smartdns.@smartdns[0].tcp_server='1' 2>/dev/null || true
    uci set smartdns.@smartdns[0].ipv6_server='1' 2>/dev/null || true
    uci set smartdns.@smartdns[0].dualstack_ip_selection='1' 2>/dev/null || true
    uci set smartdns.@smartdns[0].prefetch_domain='1' 2>/dev/null || true
    uci set smartdns.@smartdns[0].serve_expired='1' 2>/dev/null || true
    uci set smartdns.@smartdns[0].cache_size='10240' 2>/dev/null || true
    uci set smartdns.@smartdns[0].redirect='dnsmasq-upstream' 2>/dev/null || true
    uci commit smartdns 2>/dev/null || warn "UCI 提交失败，将重新创建配置"
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

/etc/init.d/smartdns enable
/etc/init.d/smartdns start || warn "SmartDNS 启动失败"

# =====================================================
# 6. DNS 转发配置
# =====================================================
log "🔗 步骤 5: 配置 DNS 转发到 SmartDNS..."

backup_file /etc/config/dhcp

# 安全删除旧配置
uci_delete_all "dhcp.@dnsmasq[0].server"

# 添加新配置
uci add_list dhcp.@dnsmasq[0].server='127.0.0.1#6053'
uci set dhcp.@dnsmasq[0].noresolv='1'
uci set dhcp.@dnsmasq[0].cachesize='0'
uci commit dhcp

# 重启 dnsmasq（不使用 timeout）
log "  🔄 重启 dnsmasq 服务..."
/etc/init.d/dnsmasq restart &
RESTART_PID=$!

# 手动等待最多 10 秒
count=0
while [ $count -lt 10 ]; do
    if ! kill -0 $RESTART_PID 2>/dev/null; then
        wait $RESTART_PID
        break
    fi
    sleep 1
    count=$((count + 1))
done

# 如果还在运行则强制处理
if kill -0 $RESTART_PID 2>/dev/null; then
    warn "dnsmasq 重启超时，尝试强制重启"
    kill -9 $RESTART_PID 2>/dev/null
    killall dnsmasq 2>/dev/null || true
    sleep 1
    /etc/init.d/dnsmasq start
fi

sleep 2

# =====================================================
# 7. IRQ 中断平衡（增强版）
# =====================================================
log "⚖️  步骤 6: 启用中断平衡..."

# 先检查配置文件是否存在
if [ ! -f /etc/config/irqbalance ]; then
    log "  创建 irqbalance 配置..."
    cat > /etc/config/irqbalance <<'EOF'
config irqbalance
    option enabled '1'
EOF
fi

# 使用 UCI 配置
uci -q get irqbalance.@irqbalance[0] >/dev/null 2>&1 || uci add irqbalance irqbalance
uci set irqbalance.@irqbalance[0].enabled='1'
uci commit irqbalance

/etc/init.d/irqbalance enable
/etc/init.d/irqbalance restart

# 验证启动（等待服务稳定）
sleep 2
if ! check_service irqbalance; then
    warn "irqbalance 首次启动失败，尝试重启..."
    killall irqbalance 2>/dev/null || true
    /etc/init.d/irqbalance start
    sleep 1
fi

# =====================================================
# 8. 防火墙优化
# =====================================================
log "🛡️  步骤 7: 优化防火墙设置..."

if uci -q get firewall.@defaults[0] >/dev/null 2>&1; then
    uci set firewall.@defaults[0].flow_offloading='1'
    uci -q set firewall.@defaults[0].flow_offloading_hw='1' 2>/dev/null || true
fi

# fullcone4 支持检测
if uci -q get firewall.@zone[1].fullcone4 >/dev/null 2>&1; then
    uci set firewall.@zone[1].fullcone4='1'
    log "  ✅ 已启用 NAT 全锥模式"
elif grep -q "fullcone" /lib/firewall.include 2>/dev/null; then
    uci -q set firewall.@zone[1].fullcone4='1' 2>/dev/null
    log "  ✅ 已启用 NAT 全锥模式"
else
    info "  当前版本不支持 fullcone4，跳过"
fi

uci commit firewall
/etc/init.d/firewall restart 2>&1 | grep -v "unknown option" | grep -v "specifies unknown option" || true

# =====================================================
# 9. CPU 性能模式
# =====================================================
log "🔥 步骤 8: 配置 CPU 性能模式..."

backup_file /etc/rc.local

cat > /etc/rc.local <<EOF
#!/bin/sh
# ===== NanoPC-T6 性能优化启动脚本 =====

# 网卡队列优化
for dev in \$(ls /sys/class/net 2>/dev/null | grep -E 'eth|enp|lan|wan'); do
    [ -d "/sys/class/net/\$dev" ] && ip link set "\$dev" txqueuelen 5000 2>/dev/null
done

# CPU 性能模式（$CPU_CORES 核心）
for i in \$(seq 0 $((CPU_CORES - 1))); do
    CPU_PATH="/sys/devices/system/cpu/cpu\$i/cpufreq"
    if [ -d "\$CPU_PATH" ]; then
        echo "performance" > "\$CPU_PATH/scaling_governor" 2>/dev/null || true
    fi
done

# 确保服务运行
sleep 3
/etc/init.d/smartdns start 2>/dev/null || true
/etc/init.d/irqbalance start 2>/dev/null || true

exit 0
EOF

chmod +x /etc/rc.local
log "  🚀 立即应用 CPU 优化..."
/etc/rc.local 2>&1 | head -3

# =====================================================
# 10. 状态验证（不使用 timeout）
# =====================================================
log "\n🔍 步骤 9: 验证配置状态..."

sleep 3

# SmartDNS 检查
if netstat -tunlp 2>/dev/null | grep -q ":6053"; then
    SMARTDNS_PID=$(pidof smartdns 2>/dev/null || echo "未知")
    log "  ✅ SmartDNS: 运行正常 (PID: $SMARTDNS_PID, 端口: 6053)"
else
    warn "  ⚠️  SmartDNS: 端口未监听"
fi

# irqbalance 检查
if check_service irqbalance; then
    log "  ✅ irqbalance: 运行中"
else
    warn "  ⚠️  irqbalance: 未运行（非致命，重启后生效）"
fi

# DNS 解析测试（不使用 timeout）
log "  🔬 DNS 解析测试..."

# 使用 host 命令的内置超时
DNS_TEST=$(host -W 3 baidu.com 127.0.0.1 -p 6053 2>&1 | head -1)

if echo "$DNS_TEST" | grep -q "has address"; then
    log "  ✅ DNS 解析: 正常"
    info "     响应: $DNS_TEST"
elif echo "$DNS_TEST" | grep -q "timed out"; then
    warn "  ⚠️  DNS 解析: 超时（SmartDNS 可能需要重启系统后生效）"
else
    warn "  ⚠️  DNS 解析: 异常"
    info "     响应: $DNS_TEST"
fi

# BBR 状态
if [ -f /proc/sys/net/ipv4/tcp_congestion_control ]; then
    BBR_STATUS=$(cat /proc/sys/net/ipv4/tcp_congestion_control)
    if [ "$BBR_STATUS" = "bbr" ]; then
        log "  ✅ BBR 加速: 已启用"
    else
        info "  当前拥塞控制: $BBR_STATUS （重启后可能变为 bbr）"
    fi
fi

# CPU 调频器
GOVERNOR=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo "unknown")
log "  ⚙️  CPU 调频策略: $GOVERNOR"

# 温度
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
log "  2. 重启后验证 DNS: host baidu.com 127.0.0.1 -p 6053"
log "  3. 检查服务状态: ps | grep -E 'smartdns|irqbalance'"
log "  4. 查看系统日志: logread | grep -E 'smartdns|irqbalance'"
log ""
log "⚠️  注意事项:"
log "  • irqbalance 可能需要重启后才能正常运行"
log "  • BBR 需要内核支持，若不可用属正常现象"
log "  • 首次启动 SmartDNS 可能需要几秒钟初始化"
log ""
log "❗ 如遇问题，可恢复备份: cp -r $BACKUP_DIR/* /etc/"
log "=========================================="
