#!/bin/bash
# NanoPC-T6 核心优化脚本 - 纯净稳定版
# 没有任何后台驻留进程，没有任何强制锁核脚本
# 仅针对 16GB 内存和 2.5G 网络进行协议栈扩容

# 1. 安装必要的 BBR 模块 (如果没有安装的话)
echo "正在检查并开启 BBR..."
if ! lsmod | grep -q bbr; then
    opkg update
    opkg install kmod-tcp-bbr
fi

# 2. 系统内核参数优化 (Sysctl)
# 针对 16GB 内存，将网络缓冲区扩大到 32MB，连接数扩大到 52万
cat > /etc/sysctl.d/99-nanopc-optimization.conf <<EOF
# --- 核心网络拥塞控制 ---
net.core.default_qdisc=fq_codel
net.ipv4.tcp_congestion_control=bbr

# --- 16GB 内存专属缓冲区 (解决高并发断流) ---
# 默认值太小，限制了 2.5G 网卡性能，这里将其“撑开”
net.core.rmem_max=33554432
net.core.wmem_max=33554432
net.ipv4.tcp_rmem=4096 87380 33554432
net.ipv4.tcp_wmem=4096 16384 33554432
net.core.netdev_max_backlog=16384

# --- 连接跟踪表 (防止连接数爆满) ---
net.netfilter.nf_conntrack_max=524288
net.netfilter.nf_conntrack_buckets=131072
net.netfilter.nf_conntrack_tcp_timeout_established=7200

# --- 转发与响应优化 ---
net.ipv4.ip_forward=1
net.ipv4.tcp_fastopen=3
net.ipv4.tcp_tw_reuse=1
net.ipv4.tcp_mtu_probing=1
EOF

# 应用内核参数
sysctl -p /etc/sysctl.d/99-nanopc-optimization.conf

# 3. 防火墙优化 (开启硬件/软件流量卸载)
# 这能极大降低 CPU 负载，是 OpenWrt 必开选项
echo "正在配置防火墙流量卸载..."
uci set firewall.@defaults[0].flow_offloading='1'
uci set firewall.@defaults[0].flow_offloading_hw='1' 
# 为 WAN 口开启 FullCone NAT (提升游戏联机体验)
# 自动查找 wan 所在的 zone 并开启 fullcone
idx=0
while [ -n "$(uci -q get firewall.@zone[$idx])" ]; do
    zname=$(uci -q get firewall.@zone[$idx].name)
    if [ "$zname" = "wan" ]; then
        uci set firewall.@zone[$idx].fullcone4='1'
    fi
    idx=$((idx+1))
done
uci commit firewall
/etc/init.d/firewall restart

# 4. Dnsmasq 基础优化
# 利用大内存增加 DNS 缓存，减少重复查询，不涉及任何复杂转发
echo "优化 DNS 缓存大小..."
uci set dhcp.@dnsmasq[0].cachesize='10000'
uci commit dhcp
/etc/init.d/dnsmasq restart

# 5. CPU 频率策略锁定 (写入 rc.local 开机生效)
# 既然不锁核，我们至少要保证核心不睡觉。锁定最低频率为 1.0GHz，保证响应速度。
echo "配置 CPU 性能调度..."
cat > /etc/rc.local <<EOF
#!/bin/sh
# 这里的逻辑仅在开机执行一次，设置完就退出，不占用后台资源
(
    sleep 10
    # 针对 RK3588 的三个核心簇 (Policy 0/4/6)
    # 模式: schedutil (既省电又响应快)
    # 频率: 最低 1.0GHz (拒绝卡顿)
    for p in 0 4 6; do
        if [ -d "/sys/devices/system/cpu/cpufreq/policy\$p" ]; then
            echo "schedutil" > /sys/devices/system/cpu/cpufreq/policy\$p/scaling_governor
            echo "1008000" > /sys/devices/system/cpu/cpufreq/policy\$p/scaling_min_freq
        fi
    done
    
    # 确保网卡队列长度足够 (防止突发流量丢包)
    ip link set eth1 txqueuelen 5000 2>/dev/null
    ip link set eth2 txqueuelen 5000 2>/dev/null
) &
exit 0
EOF
chmod +x /etc/rc.local

# 手动执行一次 CPU 优化确保当前生效
sh /etc/rc.local

echo "========================================================"
echo "✅ 优化已完成！"
echo "✅ 已启用: BBR, 32MB大内存缓冲, Offloading, 1.0GHz低频锁"
echo "❌ 已剔除: irqbalance, 强制RPS锁核, SmartDNS"
echo "💡 建议重启路由器以确保所有内核参数彻底生效。"
echo "========================================================"
