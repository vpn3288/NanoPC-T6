#!/bin/bash
# =========================================================
# NanoPC-T6 (RK3588) OpenWrt 终极优化脚本 v6.0 (完美版)
# 适用环境: ImmortalWrt / OpenWrt (基于 fw4/nftables)
# 优化项: BBR, SmartDNS, irqbalance, 8-Core Performance, 2.5G NIC
# =========================================================

LOGFILE="/tmp/optimization.log"
BACKUP_DIR="/etc/backup_$(date +%Y%m%d_%H%M%S)"

# 日志与显示函数
log() { echo -e "\033[32m$1\033[0m" | tee -a "$LOGFILE"; }
warn() { echo -e "\033[33m$1\033[0m" | tee -a "$LOGFILE"; }
error() { echo -e "\033[31m$1\033[0m" | tee -a "$LOGFILE"; }

# 环境检查
[ "$(id -u)" -eq 0 ] || { error "请使用 root 权限执行！"; exit 1; }

log "🚀 开始 NanoPC-T6 极致性能调优..."

# ==============================
# 1. 软件安装 (补全所有组件)
# ==============================
log "\n📦 步骤 1: 正在同步仓库并安装组件..."
opkg update
PACKAGES="smartdns luci-app-smartdns irqbalance ethtool ip-full kmod-tcp-bbr kmod-sched-core coreutils-stat"
for pkg in $PACKAGES; do
    if opkg list-installed | grep -q "^$pkg "; then
        log "  ⏭️  $pkg 已安装"
    else
        log "  ⬇️  正在安装 $pkg..."
        opkg install "$pkg" || warn "  ⚠️  $pkg 安装失败，请检查网络"
    fi
done

# ==============================
# 2. 内核参数优化 (BBR & 2.5G 缓存)
# ==============================
log "\n⚡ 步骤 2: 注入内核极致传输参数..."
[ -f /etc/sysctl.conf ] && cp /etc/sysctl.conf "$BACKUP_DIR/sysctl.conf.bak" 2>/dev/null
cat > /etc/sysctl.conf <<EOF
# TCP BBR 加速
net.core.default_qdisc=fq_codel
net.ipv4.tcp_congestion_control=bbr

# 并发连接数与超时优化
net.netfilter.nf_conntrack_max=1048576
net.netfilter.nf_conntrack_tcp_timeout_established=3600

# 2.5G 网口高宽带缓冲区优化
net.core.rmem_max=16777216
net.core.wmem_max=16777216
net.ipv4.tcp_rmem=4096 87380 16777216
net.ipv4.tcp_wmem=4096 65536 16777216

# 网络响应优化
net.ipv4.tcp_fastopen=3
net.core.netdev_max_backlog=5000
fs.file-max=1000000
EOF
sysctl -p >/dev/null 2>&1

# ==============================
# 3. SmartDNS 自动化配置 (并联解析+DoH)
# ==============================
log "\n🌐 步骤 3: 自动化配置 SmartDNS 解析引擎..."
/etc/init.d/smartdns stop 2>/dev/null
rm -f /etc/config/smartdns
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
    option force_tcp '1'

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
/etc/init.d/smartdns start

# ==============================
# 4. DNS 闭环设置 (dnsmasq 转发)
# ==============================
log "\n🔗 步骤 4: 打通 DNS 解析闭环 (dnsmasq -> SmartDNS)..."
# 安全清理旧条目
uci -q del_list dhcp.@dnsmasq[0].server='127.0.0.1#6053'
uci -q del dhcp.@dnsmasq[0].server
uci add_list dhcp.@dnsmasq[0].server='127.0.0.1#6053'
uci set dhcp.@dnsmasq[0].noresolv='1'
uci set dhcp.@dnsmasq[0].cachesize='0'
uci commit dhcp
/etc/init.d/dnsmasq restart

# ==============================
# 5. 中断平衡与防火墙优化 (fw4)
# ==============================
log "\n⚖️  步骤 5: 激活 irqbalance 与防火墙加速..."
/etc/init.d/irqbalance enable
/etc/init.d/irqbalance start
uci set firewall.@defaults[0].flow_offloading='1'
uci -q set firewall.@zone[1].fullcone4='1'
uci commit firewall
/etc/init.d/firewall restart

# ==============================
# 6. 持久化：8核满频锁定 & 网卡队列加速
# ==============================
log "\n🔥 步骤 6: 锁定 RK3588 狂暴模式 (持久化)..."
cat > /etc/rc.local <<'EOF'
#!/bin/sh
# 1. 自动适配物理网卡队列长度
for dev in $(ls /sys/class/net | grep -E 'eth|enp|lan|wan'); do
    ip link set $dev txqueuelen 5000 2>/dev/null
done

# 2. 锁定 8 个核心全部运行在最高频率
for i in $(seq 0 7); do
    CPU_PATH="/sys/devices/system/cpu/cpu$i/cpufreq"
    if [ -d "$CPU_PATH" ]; then
        MAX_FREQ=$(cat "$CPU_PATH/scaling_max_freq")
        echo "performance" > "$CPU_PATH/scaling_governor"
        echo "$MAX_FREQ" > "$CPU_PATH/scaling_min_freq"
    fi
done

# 3. 确保核心服务保持运行
/etc/init.d/smartdns start
/etc/init.d/irqbalance start
exit 0
EOF
chmod +x /etc/rc.local
/etc/rc.local

# ==============================
# 7. 最终校验
# ==============================
log "\n🔍 状态校验:"
[ -n "$(pgrep smartdns)" ] && log "  ✅ SmartDNS: 运行中" || error "  ❌ SmartDNS: 启动失败"
[ -n "$(pgrep irqbalance)" ] && log "  ✅ irqbalance: 运行中" || warn "  ⚠️  irqbalance: 未启动"
log "  🌡️  CPU 温度: $(($(cat /sys/class/thermal/thermal_zone0/temp) / 1000))°C"
log "  🏎️  TCP 算法: $(sysctl -n net.ipv4.tcp_congestion_control)"

log "\n=========================================="
log "🎉 恭喜！您的 NanoPC-T6 已完成全链路优化。"
log "=========================================="
