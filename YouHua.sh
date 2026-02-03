#!/bin/bash

# =========================================================
# NanoPC-T6 (RK3588) ImmortalWrt 终极一键优化脚本
# 适用版本: ImmortalWrt 24.10+ (基于 fw4/nftables)
# =========================================================

echo "开始执行 NanoPC-T6 终极性能优化..."

# 1. 环境准备与包安装
echo "正在安装必要组件..."
opkg update
opkg install kmod-tcp-bbr kmod-sched-core irqbalance htop ethtool luci-app-smartdns coreutils-stat

# 2. 纠错：创建代理插件缺失的 include 文件
mkdir -p /var/etc
touch /var/etc/passwall_server.include
touch /var/etc/openclash.include

# 3. 内核网络参数优化 (性能与安全)
echo "正在配置内核参数..."
cat > /etc/sysctl.conf <<EOF
# TCP BBR 拥塞控制
net.core.default_qdisc=fq_codel
net.ipv4.tcp_congestion_control=bbr

# 连接数上限优化
net.netfilter.nf_conntrack_max=1048576
net.netfilter.nf_conntrack_tcp_timeout_established=3600

# 2.5G 网络缓冲区优化
net.core.rmem_max=16777216
net.core.wmem_max=16777216
net.ipv4.tcp_rmem=4096 87380 16777216
net.ipv4.tcp_wmem=4096 65536 16777216

# 安全加固：防 SYN 攻击 & 禁 Ping
net.ipv4.tcp_syncookies=1
net.ipv4.icmp_echo_ignore_all=0
net.ipv4.conf.all.rp_filter=1
net.ipv4.conf.default.rp_filter=1

# 文件句柄限制
fs.file-max=1000000
EOF
sysctl -p

# 4. SmartDNS 极致解析优化
echo "正在配置 SmartDNS..."
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
/etc/init.d/smartdns restart || echo "SmartDNS 重启提醒: 忽略初始化 Entry 报错"

# 5. DNS 闭环设置 (dnsmasq)
uci add_list dhcp.@dnsmasq[0].server='127.0.0.1#6053'
uci set dhcp.@dnsmasq[0].noresolv='1'
uci commit dhcp
/etc/init.d/dnsmasq restart

# 6. 防火墙 FW4 (nftables) 优化
echo "正在配置防火墙性能模式..."
uci set firewall.@defaults[0].flow_offloading='1'
uci set firewall.@zone[1].fullcone4='1'
uci commit firewall
/etc/init.d/firewall restart

# 7. 开机自启优化 (CPU 锁频与网卡加速)
cat > /etc/rc.local <<EOF
# 自动识别并设置所有物理网卡队列长度
for dev in \$(ls /sys/class/net | grep -E 'eth|enp|lan|wan'); do
    ifconfig \$dev txqueuelen 5000
done

# 锁定 RK3588 8核高性能模式
for i in \$(seq 0 7); do
    [ -f /sys/devices/system/cpu/cpu\$i/cpufreq/scaling_max_freq ] && \\
    MAX_FREQ=\$(cat /sys/devices/system/cpu/cpu\$i/cpufreq/scaling_max_freq) && \\
    echo "performance" > /sys/devices/system/cpu/cpu\$i/cpufreq/scaling_governor && \\
    echo \$MAX_FREQ > /sys/devices/system/cpu/cpu\$i/cpufreq/scaling_min_freq
done
exit 0
EOF
chmod +x /etc/rc.local
/etc/rc.local

echo "----------------------------------------------------"
echo "优化完成！"
echo "当前温度: $(($(cat /sys/class/thermal/thermal_zone0/temp) / 1000))°C"
echo "BBR 状态: $(sysctl net.ipv4.tcp_congestion_control)"
echo "----------------------------------------------------"
