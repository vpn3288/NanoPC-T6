#!/bin/bash
# =========================================================
# NanoPC-T6 (RK3588) OpenWrt 终极优化脚本 v7.0
# 适用: ImmortalWrt 21.02 / 23.05 / 24.10 (fw4/nftables)
# 特点: 自动安装核心、强制锁频、中断平衡、SmartDNS加密闭环
# =========================================================

# 颜色定义
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log() { echo -e "${GREEN}[INFO] $1${NC}"; }
warn() { echo -e "${YELLOW}[WARN] $1${NC}"; }
error() { echo -e "${RED}[ERROR] $1${NC}"; }

# 1. 基础环境自检与 Bash 补全
if [ -z "$BASH_VERSION" ]; then
    warn "当前不是 Bash 环境，正在尝试安装并切换..."
    opkg update && opkg install bash
    exec bash "$0" "$@"
    exit
fi

log "🚀 开始 NanoPC-T6 极致性能调优..."

# 2. 软件源同步与核心组件补全 (包含全量解析工具)
log "📦 步骤 1: 安装核心组件与增强型探测工具..."
opkg update
# 增加 bind-host 以支持标准的 DNS 探测语法
PACKAGES="smartdns luci-app-smartdns irqbalance ethtool ip-full kmod-tcp-bbr kmod-sched-core coreutils-stat bind-host"
for pkg in $PACKAGES; do
    if opkg list-installed | grep -q "^$pkg "; then
        log "  ⏭️  $pkg 已安装"
    else
        log "  ⬇️  正在安装 $pkg..."
        opkg install "$pkg" || warn "  ⚠️  $pkg 安装失败，请检查网络"
    fi
done

# 3. 内核极致传输参数注入 (BBR & 2.5G 网口缓冲)
log "⚡ 步骤 2: 注入内核极致传输参数..."
cat > /etc/sysctl.conf <<EOF
# TCP BBR 加速
net.core.default_qdisc=fq_codel
net.ipv4.tcp_congestion_control=bbr
# 链接跟踪与并发优化
net.netfilter.nf_conntrack_max=1048576
net.netfilter.nf_conntrack_tcp_timeout_established=3600
# 2.5G 网口高宽带缓冲区优化
net.core.rmem_max=16777216
net.core.wmem_max=16777216
net.ipv4.tcp_rmem=4096 87380 16777216
net.ipv4.tcp_wmem=4096 65536 16777216
net.core.netdev_max_backlog=5000
net.ipv4.tcp_fastopen=3
fs.file-max=1000000
EOF
sysctl -p >/dev/null 2>&1

# 4. SmartDNS 极致配置 (加密查询 + 域名预取)
log "🌐 步骤 3: 自动化配置 SmartDNS 解析引擎..."
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
/etc/init.d/smartdns restart

# 5. DNS 闭环：接管 dnsmasq 流量
log "🔗 步骤 4: 打通 DNS 解析闭环 (dnsmasq -> SmartDNS)..."
uci -q batch <<EOF
  del_list dhcp.@dnsmasq[0].server='127.0.0.1#6053'
  del dhcp.@dnsmasq[0].server
  add_list dhcp.@dnsmasq[0].server='127.0.0.1#6053'
  set dhcp.@dnsmasq[0].noresolv='1'
  set dhcp.@dnsmasq[0].cachesize='0'
  commit dhcp
EOF
/etc/init.d/dnsmasq restart

# 6. 中断平衡 (irqbalance) 强制启动优化
log "⚖️  步骤 5: 强制激活 irqbalance 与防火墙加速..."
uci -q batch <<EOF
  set irqbalance.@irqbalance[0].enabled='1'
  commit irqbalance
EOF
/etc/init.d/irqbalance enable
/etc/init.d/irqbalance restart
# 防火墙加速
uci set firewall.@defaults[0].flow_offloading='1'
uci -q set firewall.@zone[1].fullcone4='1'
uci commit firewall
/etc/init.d/firewall restart

# 7. CPU 狂暴模式持久化 (锁定 8 核最高主频)
log "🔥 步骤 6: 锁定 RK3588 狂暴模式 & 网卡队列加速..."
cat > /etc/rc.local <<'EOF'
#!/bin/sh
# 优化网卡队列
for dev in $(ls /sys/class/net | grep -E 'eth|enp|lan|wan'); do
    ip link set $dev txqueuelen 5000 2>/dev/null
done
# 锁定 8 核主频
for i in $(seq 0 7); do
    CPU_PATH="/sys/devices/system/cpu/cpu$i/cpufreq"
    if [ -d "$CPU_PATH" ]; then
        MAX_FREQ=$(cat "$CPU_PATH/scaling_max_freq" 2>/dev/null)
        echo "performance" > "$CPU_PATH/scaling_governor" 2>/dev/null
        [ -n "$MAX_FREQ" ] && echo "$MAX_FREQ" > "$CPU_PATH/scaling_min_freq" 2>/dev/null
    fi
done
/etc/init.d/smartdns start
/etc/init.d/irqbalance start
exit 0
EOF
chmod +x /etc/rc.local
/etc/rc.local

# 8. 状态校验 (全自动化)
log "\n🔍 终极状态校验:"
# 校验 SmartDNS 端口
if netstat -tunlp | grep -q 6053; then
    log "  ✅ SmartDNS (6053): 正常监听"
else
    error "  ❌ SmartDNS: 监听异常"
fi
# 校验 irqbalance
pgrep irqbalance >/dev/null && log "  ✅ irqbalance: 运行中" || warn "  ⚠️  irqbalance: 未能启动"
# 校验 DNS 解析速度 (使用安装好的 host 工具)
log "  ⚡ 正在进行本地解析延迟测试..."
host_res=$(host -W 2 baidu.com 127.0.0.1 -p 6053 | head -n 1)
[ -n "$host_res" ] && log "  ✅ DNS 解析测试: 成功 ($host_res)" || error "  ❌ DNS 解析测试: 失败"

log "\n=========================================="
log "🎉 恭喜！您的 NanoPC-T6 已彻底进化为满血版。"
log "当前温度: $(($(cat /sys/class/thermal/thermal_zone0/temp) / 1000))°C"
log "=========================================="
