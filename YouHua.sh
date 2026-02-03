#!/bin/bash

# =========================================================
# NanoPC-T6 (RK3588) 零手动、全自动优化脚本 v4.0
# 功能：自动安装、自动配置、自动启动 SmartDNS & irqbalance
# =========================================================

echo "🚀 开启全自动性能注入，请稍后..."

# 1. 一键安装组件 (包含核心程序与界面)
echo "📦 正在后台安装 SmartDNS 与 irqbalance..."
opkg update
# 确保安装核心程序 smartdns, 界面 luci-app-smartdns, 以及平衡器 irqbalance
opkg install smartdns luci-app-smartdns irqbalance ethtool ip-full kmod-tcp-bbr

# 2. 【核心】SmartDNS 自动化配置与强制开启
echo "🌐 正在全自动配置 SmartDNS..."
# 停止服务防止占用
/etc/init.d/smartdns stop 2>/dev/null

# 写入配置文件 (直接覆盖，确保索引正确)
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

# 启用服务、提交配置并立即启动
uci commit smartdns
/etc/init.d/smartdns enable
/etc/init.d/smartdns start

# 3. 【核心】irqbalance 自动化安装与立即启用
echo "⚖️ 正在激活 8 核多核中断平衡..."
# 设置为开机启动并立即运行
/etc/init.d/irqbalance enable
/etc/init.d/irqbalance start

# 4. 【核心】内核 BBR 与 2.5G 网口优化
echo "⚡ 正在注入内核加速参数..."
cat > /etc/sysctl.conf <<EOF
net.core.default_qdisc=fq_codel
net.ipv4.tcp_congestion_control=bbr
net.netfilter.nf_conntrack_max=1048576
net.core.rmem_max=16777216
net.core.wmem_max=16777216
net.ipv4.tcp_rmem=4096 87380 16777216
net.ipv4.tcp_wmem=4096 65536 16777216
EOF
sysctl -p

# 5. DNS 闭环：让 dnsmasq 强制跳转到 SmartDNS
echo "🔗 正在打通 DNS 解析闭环..."
uci del_list dhcp.@dnsmasq[0].server='127.0.0.1#6053' 2>/dev/null
uci add_list dhcp.@dnsmasq[0].server='127.0.0.1#6053'
uci set dhcp.@dnsmasq[0].noresolv='1'
uci commit dhcp
/etc/init.d/dnsmasq restart

# 6. 持久化：将“性能模式”写入 rc.local (确保重启后配置不丢)
cat > /etc/rc.local <<EOF
# 满频锁定
for i in \$(seq 0 7); do
    MAX_FREQ=\$(cat /sys/devices/system/cpu/cpu\$i/cpufreq/scaling_max_freq)
    echo "performance" > /sys/devices/system/cpu/cpu\$i/cpufreq/scaling_governor
    echo \$MAX_FREQ > /sys/devices/system/cpu/cpu\$i/cpufreq/scaling_min_freq
done
# 再次确保服务运行
/etc/init.d/smartdns start
/etc/init.d/irqbalance start
exit 0
EOF
chmod +x /etc/rc.local
/etc/rc.local

echo "----------------------------------------------------"
echo "✅ 全部完成！SmartDNS 和 irqbalance 已在后台全速运行。"
echo "您可以执行 'ps | grep smartdns' 验证。无需任何手动操作。"
echo "----------------------------------------------------"
