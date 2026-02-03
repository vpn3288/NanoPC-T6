#!/bin/bash

# =========================================================
# NanoPC-T6 (RK3588) 终极优化脚本 v2.1
# 更新日志：自动补全 SmartDNS 核心、强化 CPU 锁定逻辑、修复 FW4 语法
# =========================================================

echo "🚀 正在为您的 NanoPC-T6 注入狂暴性能..."

# 1. 软件包环境一键补全 (包含核心程序)
echo "📦 正在同步软件源并安装核心组件..."
opkg update
# 同时安装 smartdns (核心) 和 luci-app-smartdns (界面)
opkg install smartdns luci-app-smartdns
# 安装网络与性能工具
opkg install kmod-tcp-bbr kmod-sched-core irqbalance htop ethtool coreutils-stat ip-full

# 2. 兼容性纠错：创建代理插件所需的 include 文件
mkdir -p /var/etc && touch /var/etc/passwall_server.include /var/etc/openclash.include

# 3. 内核加速：TCP BBR + 高并发优化
echo "⚡ 优化内核传输协议栈 (BBR)..."
cat > /etc/sysctl.conf <<EOF
# TCP BBR 拥塞控制
net.core.default_qdisc=fq_codel
net.ipv4.tcp_congestion_control=bbr

# 网络并发上限 (针对 RK3588 内存优化)
net.netfilter.nf_conntrack_max=1048576
net.netfilter.nf_conntrack_tcp_timeout_established=3600

# 2.5G 网口缓冲区优化
net.core.rmem_max=16777216
net.core.wmem_max=16777216
net.ipv4.tcp_rmem=4096 87380 16777216
net.ipv4.tcp_wmem=4096 65536 16777216

# 系统文件上限
fs.file-max=1000000
EOF
sysctl -p

# 4. SmartDNS 极致配置 (自动纠正 Entry not found 错误)
echo "🌐 自动化配置 SmartDNS 解析引擎..."
# 先卸载旧配置以保证 UCI 索引正确
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

# 5. DNS 闭环：让 dnsmasq 默认通过 SmartDNS 解析
uci del_list dhcp.@dnsmasq[0].server='127.0.0.1#6053' 2>/dev/null
uci add_list dhcp.@dnsmasq[0].server='127.0.0.1#6053'
uci set dhcp.@dnsmasq[0].noresolv='1'
uci commit dhcp
/etc/init.d/dnsmasq restart

# 6. 防火墙 FW4 (nftables) 性能卸载
echo "🛡️ 开启防火墙硬件加速与 FullCone..."
uci set firewall.@defaults[0].flow_offloading='1'
uci set firewall.@zone[1].fullcone4='1'
uci commit firewall
/etc/init.d/firewall restart

# 7. 写入持久化脚本：解决重启后 CPU 降频问题
cat > /etc/rc.local <<EOF
# 适配网卡队列
for dev in \$(ls /sys/class/net | grep -E 'eth|enp|lan|wan'); do
    ip link set \$dev txqueuelen 5000 2>/dev/null || ifconfig \$dev txqueuelen 5000 2>/dev/null
done

# 锁定 RK3588 8核最高主频
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

echo "----------------------------------------------------"
echo "✨ 优化完成！您的 NanoPC-T6 已进入最强状态。"
echo "当前温度: $(($(cat /sys/class/thermal/thermal_zone0/temp) / 1000))°C"
echo "BBR 状态: $(sysctl -n net.ipv4.tcp_congestion_control)"
echo "----------------------------------------------------"
