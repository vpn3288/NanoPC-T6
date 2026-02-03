#!/bin/bash

# =========================================================
# NanoPC-T6 (RK3588) 终极优化脚本 v3.0 (含代理联动版)
# 修订：自动补全 irqbalance、SmartDNS、锁定 8 核主频、适配多 IP 分流
# =========================================================

echo "🚀 正在为您的 NanoPC-T6 注入狂暴性能..."

# 1. 自动补全所有缺失的优化组件
echo "📦 正在安装核心组件 (SmartDNS, irqbalance, BBR)..."
opkg update
# 核心解析：smartdns + luci 界面
opkg install smartdns luci-app-smartdns
# 核心调度：irqbalance (8核均衡) + ethtool
opkg install irqbalance ethtool
# 核心加速：BBR内核模块 + 流量调度
opkg install kmod-tcp-bbr kmod-sched-core
# 辅助工具：htop (监控), ip-full (网络)
opkg install htop ip-full coreutils-stat

# 2. 启动并激活 irqbalance (关键：让 8 个核心平摊 2.5G 流量)
/etc/init.d/irqbalance enable
/etc/init.d/irqbalance start

# 3. 内核加速配置 (BBR + 104万连接数)
echo "⚡ 优化内核传输协议栈..."
cat > /etc/sysctl.conf <<EOF
net.core.default_qdisc=fq_codel
net.ipv4.tcp_congestion_control=bbr
net.netfilter.nf_conntrack_max=1048576
net.netfilter.nf_conntrack_tcp_timeout_established=3600
net.core.rmem_max=16777216
net.core.wmem_max=16777216
net.ipv4.tcp_rmem=4096 87380 16777216
net.ipv4.tcp_wmem=4096 65536 16777216
fs.file-max=1000000
# 针对链式代理优化 UDP 队列
net.core.netdev_max_backlog=5000
EOF
sysctl -p

# 4. SmartDNS 极致配置与 DNS 闭环
echo "🌐 配置 SmartDNS 解析引擎 (端口 6053)..."
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

config server
    option name 'alidns'
    option ip '223.5.5.5'
    option type 'udp'

config server
    option name 'dnspod'
    option ip '119.29.29.29'
    option type 'udp'
EOF
uci commit smartdns
/etc/init.d/smartdns enable
/etc/init.d/smartdns restart

# 联动 dnsmasq
uci del_list dhcp.@dnsmasq[0].server='127.0.0.1#6053' 2>/dev/null
uci add_list dhcp.@dnsmasq[0].server='127.0.0.1#6053'
uci set dhcp.@dnsmasq[0].noresolv='1'
uci commit dhcp
/etc/init.d/dnsmasq restart

# 5. 防火墙 FW4 性能优化 (Flow Offloading)
uci set firewall.@defaults[0].flow_offloading='1'
uci set firewall.@zone[1].fullcone4='1'
uci commit firewall
/etc/init.d/firewall restart

# 6. 持久化：8 核满频锁定 + 网卡队列加速
cat > /etc/rc.local <<EOF
# 适配 2.5G 网口队列
for dev in \$(ls /sys/class/net | grep -E 'eth|enp|lan|wan'); do
    ip link set \$dev txqueuelen 5000 2>/dev/null
done

# 锁定 RK3588 8核高性能 (防止跳频引起的延迟)
for i in \$(seq 0 7); do
    if [ -f /sys/devices/system/cpu/cpu\$i/cpufreq/scaling_max_freq ]; then
        MAX_FREQ=\$(cat /sys/devices/system/cpu/cpu\$i/cpufreq/scaling_max_freq)
        echo "performance" > /sys/devices/system/cpu/cpu\$i/cpufreq/scaling_governor
        echo \$MAX_FREQ > /sys/devices/system/cpu/cpu\$i/cpufreq/scaling_min_freq
    fi
done
exit 0
EOF
chmod +x /etc/rc.local
/etc/rc.local

echo "✅ 优化完成！您可以继续配置 OpenClash 的分流规则了。"
