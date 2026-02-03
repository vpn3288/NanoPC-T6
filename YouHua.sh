#!/bin/bash
# =========================================================
# NanoPC-T6 (RK3588) 终极优化脚本 v9.0
# 融合功能：内核BBR、SmartDNS全效、8核锁频、中断平衡、网络扩容
# 修复：BBR安装逻辑、SmartDNS解析异常、UCI索引报错
# =========================================================

# 基础设置
LOGFILE="/tmp/optimization_$(date +%Y%m%d_%H%M%S).log"
BACKUP_DIR="/etc/backup_$(date +%Y%m%d_%H%M%S)"

log() { echo -e "\033[32m[INFO] $1\033[0m" | tee -a "$LOGFILE"; }
warn() { echo -e "\033[33m[WARN] $1\033[0m" | tee -a "$LOGFILE"; }
error() { echo -e "\033[31m[ERROR] $1\033[0m" | tee -a "$LOGFILE"; }

# 备份函数
backup_config() {
    [ -f "$1" ] && { mkdir -p "$BACKUP_DIR"; cp "$1" "$BACKUP_DIR/"; log "💾 备份: $1"; }
}

# 1. 环境准备
log "🚀 开始 NanoPC-T6 极致性能调优 (v9.0)..."
[ "$(id -u)" -eq 0 ] || { error "请使用 root 运行！"; exit 1; }

# 自动补全 Bash 
if [ -z "$BASH_VERSION" ]; then
    opkg update && opkg install bash
    exec bash "$0" "$@"
fi

# 2. 软件安装 (修正 BBR 逻辑)
log "📦 步骤 1: 正在安装/补全性能组件..."
opkg update
# 强制安装列表，不再做预检测，直接让 opkg 处理依赖
PACKAGES="smartdns luci-app-smartdns irqbalance ethtool ip-full kmod-tcp-bbr kmod-sched-core bind-host coreutils-stat"
for pkg in $PACKAGES; do
    if opkg list-installed | grep -q "^$pkg "; then
        log "  ⏭️  $pkg 已安装"
    else
        log "  ⬇️  正在安装 $pkg..."
        opkg install "$pkg" || warn "  ⚠️  $pkg 安装受阻"
    fi
done

# 3. 强制注入 BBR
log "⚡ 步骤 2: 激活 BBR 拥塞控制算法..."
backup_config /etc/sysctl.conf
modprobe tcp_bbr 2>/dev/null
cat > /etc/sysctl.conf <<EOF
# TCP BBR 优化
net.core.default_qdisc=fq_codel
net.ipv4.tcp_congestion_control=bbr
# 高并发连接优化
net.netfilter.nf_conntrack_max=1048576
net.core.rmem_max=16777216
net.core.wmem_max=16777216
net.ipv4.tcp_rmem=4096 87380 16777216
net.ipv4.tcp_wmem=4096 65536 16777216
net.core.netdev_max_backlog=5000
net.ipv4.tcp_fastopen=3
EOF
sysctl -p >/dev/null 2>&1

# 4. SmartDNS 暴力重构 (核心修复)
log "🌐 步骤 3: 配置 SmartDNS 解析引擎 (6053端口)..."
backup_config /etc/config/smartdns
/etc/init.d/smartdns stop 2>/dev/null
# 直接重写，不再尝试 merge，防止旧配置污染
cat > /etc/config/smartdns <<EOF
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
    option name 'ali_doh'
    option ip 'https://223.5.5.5/dns-query'
    option type 'https'
    option enabled '1'
EOF
uci commit smartdns
/etc/init.d/smartdns enable
/etc/init.d/smartdns restart

# 5. DNS 闭环与 dnsmasq 优化
log "🔗 步骤 4: 打通 DNS 流量闭环..."
backup_config /etc/config/dhcp
# 移除所有旧的 server 定义，防止冲突
uci -q del dhcp.@dnsmasq[0].server
uci -q del_list dhcp.@dnsmasq[0].server
# 强制指定 SmartDNS 为唯一上游
uci add_list dhcp.@dnsmasq[0].server='127.0.0.1#6053'
uci set dhcp.@dnsmasq[0].noresolv='1'
uci set dhcp.@dnsmasq[0].cachesize='0'
uci commit dhcp
/etc/init.d/dnsmasq restart

# 6. 中断平衡 (irqbalance) 逻辑增强
log "⚖️  步骤 5: 激活多核中断平衡 (irqbalance)..."
if ! uci get irqbalance.@irqbalance[0] >/dev/null 2>&1; then
    uci add irqbalance irqbalance
fi
uci set irqbalance.@irqbalance[0].enabled='1'
uci commit irqbalance
/etc/init.d/irqbalance enable
/etc/init.d/irqbalance restart

# 7. CPU 锁频与持久化优化
log "🔥 步骤 6: 锁定 RK3588 狂暴模式 (持久化)..."
backup_config /etc/rc.local
cat > /etc/rc.local <<'EOF'
#!/bin/sh
# 网卡队列优化
for dev in $(ls /sys/class/net | grep -E 'eth|enp|lan|wan'); do
    ip link set $dev txqueuelen 5000 2>/dev/null
done
# 锁定 8 核主频
for i in $(seq 0 7); do
    [ -d /sys/devices/system/cpu/cpu$i/cpufreq ] && {
        echo "performance" > /sys/devices/system/cpu/cpu$i/cpufreq/scaling_governor
        cat /sys/devices/system/cpu/cpu$i/cpufreq/scaling_max_freq > /sys/devices/system/cpu/cpu$i/cpufreq/scaling_min_freq
    }
done
/etc/init.d/smartdns restart
/etc/init.d/irqbalance restart
exit 0
EOF
chmod +x /etc/rc.local
/etc/rc.local 2>/dev/null

# 8. 验证
log "\n🔍 状态验证报告:"
# BBR 验证
sysctl net.ipv4.tcp_congestion_control | grep -q bbr && log " ✅ BBR: 已激活" || error " ❌ BBR: 未能激活"
# SmartDNS 验证
if host -W 2 baidu.com 127.0.0.1 -p 6053 >/dev/null 2>&1; then
    log " ✅ SmartDNS: 解析正常"
else
    error " ❌ SmartDNS: 解析异常"
fi
# CPU 频率验证
log " 🌡️  CPU 温度: $(($(cat /sys/class/thermal/thermal_zone0/temp) / 1000))°C"
log " 🏎️  调频策略: $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor)"

log "\n=========================================="
log "🎉 优化完成！脚本已根据你的版本进行了最终修正。"
log "=========================================="
