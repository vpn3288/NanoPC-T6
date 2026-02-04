#!/bin/bash
# ==============================================================================
# NanoPC-T6 (16GB) 代理主路由专用优化脚本 v19.7
# ------------------------------------------------------------------------------
# 硬件: RK3588 8核心 / 16GB 内存 / 64GB 存储 / 2x 2.5G 网口
# 场景: 主路由 + 代理软件（OpenClash/HomeProxy/PassWall）
# 特性: 高并发连接、低延迟、多核优化、代理友好
# 修复: 彻底解决 ImmortalWrt 24.10 重启后 RPS 掩码强制回退到 01 的顽疾
# 机制: [Hotplug 注入] + [Cron 每分钟守护] + [rc.local 延迟补刀]
# ==============================================================================

# --- 全局变量 ---
LOG_FILE="/tmp/optimization_v19_$(date +%Y%m%d).log"
BACKUP_DIR="/etc/config_backup_$(date +%Y%m%d_%H%M%S)"
CPU_GOVERNOR="schedutil"  # 负载感应（推荐），可选 performance
TX_QUEUE_LEN="5000"       # 增大发送队列，减少丢包
RPS_MASK="ff"             # 8核全开掩码

# --- 日志函数 ---
log_info() { echo -e "\033[32m[INFO] [$(date +'%H:%M:%S')] $1\033[0m" | tee -a "$LOG_FILE"; }
log_warn() { echo -e "\033[33m[WARN] [$(date +'%H:%M:%S')] $1\033[0m" | tee -a "$LOG_FILE"; }
log_err()  { echo -e "\033[31m[ERROR] [$(date +'%H:%M:%S')] $1\033[0m" | tee -a "$LOG_FILE"; }

# --- 工具函数 ---
backup_file() {
    if [ -f "$1" ]; then
        mkdir -p "$BACKUP_DIR"
        cp -a "$1" "$BACKUP_DIR/" 2>/dev/null
        log_info "💾 备份: $1"
    fi
}

check_network() {
    log_info "🔍 网络自检..."
    for host in 223.5.5.5 119.29.29.29 1.1.1.1; do
        if ping -c 2 -W 3 "$host" >/dev/null 2>&1; then
            log_info "✅ 网络正常 (测试节点: $host)"
            return 0
        fi
    done
    log_warn "⚠️ 网络检查未通过，脚本将尝试继续运行..."
}

uci_delete_all() {
    while uci -q delete "$1" 2>/dev/null; do :; done
}

# --- 主流程开始 ---
log_info "🚀 NanoPC-T6 代理主路由优化 v19.7"

DEVICE_MODEL=$(tr -d '\0' < /proc/device-tree/model 2>/dev/null || echo 'RK3588 Device')
log_info "设备: $DEVICE_MODEL"

# 检测内存
TOTAL_MEM=$(free -m | awk 'NR==2 {print $2}')
log_info "内存: ${TOTAL_MEM}MB"

# 权限检查
[ "$(id -u)" -eq 0 ] || { log_err "需要 root 权限"; exit 1; }
check_network

# ==================== 阶段 1: 环境清理 ====================
log_info ""
log_info "🧹 [1/7] 环境清理..."

# SmartDNS 清理（代理场景下不建议使用 SmartDNS）
if opkg list-installed 2>/dev/null | grep -q "smartdns"; then
    log_warn "检测到 SmartDNS，正在移除（避免与代理冲突）..."
    /etc/init.d/smartdns stop 2>/dev/null || true
    /etc/init.d/smartdns disable 2>/dev/null || true
    opkg remove luci-app-smartdns smartdns --force-removal-of-dependent-packages >/dev/null 2>&1 || true
    rm -rf /etc/config/smartdns /etc/smartdns 2>/dev/null
    log_info "✅ SmartDNS 已清理"
else
    log_info "✅ 环境纯净"
fi

# Dnsmasq 基础优化
log_info "重置 dnsmasq 配置..."
backup_file "/etc/config/dhcp"
uci_delete_all "dhcp.@dnsmasq[0].server"
uci set dhcp.@dnsmasq[0].noresolv='0'
uci set dhcp.@dnsmasq[0].cachesize='5000'
uci set dhcp.@dnsmasq[0].min_cache_ttl='600'
uci commit dhcp

/etc/init.d/dnsmasq restart >/dev/null 2>&1 || true
log_info "✅ dnsmasq 重置完成"

# ==================== 阶段 2: 软件包安装 ====================
log_info ""
log_info "📦 [2/7] 核心组件安装..."
opkg update >/dev/null 2>&1 || log_warn "软件源更新失败"

PKG_LIST="irqbalance ethtool ip-full kmod-tcp-bbr kmod-sched-core bind-host coreutils-stat"
for pkg in $PKG_LIST; do
    if opkg list-installed 2>/dev/null | grep -q "^$pkg "; then
        log_info "   ⏭️  $pkg"
    else
        log_info "   ⬇️  安装 $pkg..."
        opkg install "$pkg" >> "$LOG_FILE" 2>&1 || log_warn "   ⚠️  $pkg 安装失败"
    fi
done

# ==================== 阶段 3: 硬件加速与防火墙 ====================
log_info ""
log_info "⚡ [3/7] 硬件流量卸载与 FullCone NAT..."

if uci -q get firewall.@defaults[0] >/dev/null; then
    # 开启原生硬件卸载
    uci set firewall.@defaults[0].flow_offloading='1' 2>/dev/null || true
    uci set firewall.@defaults[0].flow_offloading_hw='1' 2>/dev/null || true
    
    # 遍历所有 Zone 开启 FullCone NAT
    idx=0
    while [ $idx -lt 10 ]; do
        z_name=$(uci -q get firewall.@zone[$idx].name 2>/dev/null)
        [ -z "$z_name" ] && break
        if [ "$z_name" = "wan" ]; then
            uci set firewall.@zone[$idx].fullcone4='1' 2>/dev/null || true
        fi
        idx=$((idx + 1))
    done
    
    # 基础防护
    uci set firewall.@defaults[0].drop_invalid='1' 2>/dev/null || true
    uci set firewall.@defaults[0].syn_flood='1' 2>/dev/null || true
    
    uci commit firewall
    /etc/init.d/firewall restart >/dev/null 2>&1 || true
    log_info "✅ 硬件加速与 FullCone 配置完成"
fi

# ==================== 阶段 4: 内核参数 (16GB RAM 满血版) ====================
log_info ""
log_info "🛠️ [4/7] 内核参数优化 (代理场景专用)..."
backup_file "/etc/sysctl.conf"

cat > /etc/sysctl.conf <<EOF
# NanoPC-T6 代理主路由优化参数
net.core.default_qdisc=fq_codel
net.ipv4.tcp_congestion_control=bbr
net.ipv4.ip_forward=1
net.ipv6.conf.all.forwarding=1
net.ipv6.conf.default.forwarding=1

# 连接跟踪: 524288 (16GB 内存从容应对)
net.netfilter.nf_conntrack_max=524288
net.netfilter.nf_conntrack_buckets=131072
net.netfilter.nf_conntrack_tcp_timeout_established=7200
net.netfilter.nf_conntrack_tcp_timeout_time_wait=30
net.netfilter.nf_conntrack_udp_timeout=180
net.netfilter.nf_conntrack_udp_timeout_stream=300

# 网络缓冲区: 32MB 高带宽优化
net.core.rmem_max=33554432
net.core.wmem_max=33554432
net.core.rmem_default=262144
net.core.wmem_default=262144
net.ipv4.tcp_rmem=4096 131072 33554432
net.ipv4.tcp_wmem=4096 131072 33554432
net.core.netdev_max_backlog=16384
net.core.somaxconn=8192

# TCP 性能与代理微调
net.ipv4.tcp_fastopen=3
net.ipv4.tcp_slow_start_after_idle=0
net.ipv4.tcp_notsent_lowat=16384
net.ipv4.tcp_window_scaling=1
net.ipv4.tcp_timestamps=1
net.ipv4.tcp_sack=1
net.ipv4.tcp_fack=1
net.ipv4.tcp_ecn=0
net.ipv4.tcp_mtu_probing=1
net.ipv4.tcp_syncookies=1
net.ipv4.tcp_tw_reuse=1

# 文件描述符与队列
fs.file-max=2097152
fs.inotify.max_user_instances=8192
fs.inotify.max_user_watches=524288
net.core.rps_sock_flow_entries=32768
EOF

sysctl -p >/dev/null 2>&1 || true
log_info "✅ 内核参数加载完成"

# ==================== 阶段 5: 三重锁定 RPS (核心修复机制) ====================
log_info ""
log_info "🔥 [5/7] 部署三重 RPS 锁定机制 (对抗 ImmortalWrt 驱动重置)..."

# 锁定机制 1: Hotplug 自动注入
log_info "正在部署 Hotplug 拦截脚本..."
cat > /etc/hotplug.d/net/40-rps-rfs <<EOF
#!/bin/sh
# 强制锁定网卡队列掩码
[ "\$ACTION" = "add" ] || [ "\$ACTION" = "ifup" ] || exit 0
case "\$INTERFACE" in
    eth*|lan*|wan*|enp*|br-lan)
        for q in /sys/class/net/\$INTERFACE/queues/rx-*/rps_cpus; do
            [ -f "\$q" ] && echo "$RPS_MASK" > "\$q"
        done
        for q in /sys/class/net/\$INTERFACE/queues/rx-*/rps_flow_cnt; do
            [ -f "\$q" ] && echo "4096" > "\$q"
        done
        ;;
esac
EOF
chmod +x /etc/hotplug.d/net/40-rps-rfs

# 锁定机制 2: Cron 定时守护 (每分钟强制重写一次)
log_info "正在部署 Cron 定时守护任务..."
if ! crontab -l 2>/dev/null | grep -q "rps_cpus"; then
    (crontab -l 2>/dev/null; echo "* * * * * for q in /sys/class/net/eth*/queues/rx-*/rps_cpus; do echo '$RPS_MASK' > \"\$q\"; done") | crontab -
    /etc/init.d/cron enable && /etc/init.d/cron restart
    log_info "✅ 已添加 Cron 定时锁定"
fi

# 立即应用到当前所有网卡
for dev in \$(ls /sys/class/net | grep -E 'eth|enp|lan|wan|br-lan'); do
    for q in /sys/class/net/\$dev/queues/rx-*/rps_cpus; do
        [ -f "\$q" ] && echo "$RPS_MASK" > "\$q" 2>/dev/null || true
    done
done
log_info "✅ 即时 RPS 锁定已执行"

# ==================== 阶段 6: 启动项优化与“补刀”逻辑 ====================
log_info ""
log_info "🔋 [6/7] 启动项与 CPU 调度延迟补刀..."
backup_file "/etc/rc.local"

# 锁定机制 3: 启动项延迟补刀 (sleep 30 越过驱动重置期)
cat > /etc/rc.local <<EOF
#!/bin/sh
# NanoPC-T6 优化补刀脚本

(
    # 极晚期注入，确保系统完全稳定后执行
    sleep 30
    # 1. 强制 RPS 全核
    for q in /sys/class/net/eth*/queues/rx-*/rps_cpus; do echo "$RPS_MASK" > "\$q" 2>/dev/null; done
    # 2. 网卡队列长度优化
    for dev in \$(ls /sys/class/net | grep -E 'eth|enp|lan|wan'); do
        [ -d "/sys/class/net/\$dev" ] && ip link set "\$dev" txqueuelen $TX_QUEUE_LEN 2>/dev/null
    done
    # 3. CPU 调频锁定 (所有 8 个核心)
    for i in \$(seq 0 7); do
        echo "$CPU_GOVERNOR" > "/sys/devices/system/cpu/cpu\$i/cpufreq/scaling_governor" 2>/dev/null
    done
) &

# 启动中断平衡
/etc/init.d/irqbalance start 2>/dev/null || true

exit 0
EOF
chmod +x /etc/rc.local
log_info "✅ 启动项补刀逻辑已就绪"

# ==================== 阶段 7: 中断平衡服务 ====================
log_info ""
log_info "⚖️ [7/7] 中断平衡服务 (irqbalance)..."
if [ ! -f /etc/config/irqbalance ]; then
    echo -e "config irqbalance\n\toption enabled '1'\n\toption interval '10'" > /etc/config/irqbalance
else
    uci set irqbalance.@irqbalance[0].enabled='1'
    uci commit irqbalance
fi
/etc/init.d/irqbalance enable >/dev/null 2>&1
/etc/init.d/irqbalance restart >/dev/null 2>&1
log_info "✅ irqbalance 已激活"

# ==================== 总结与验证 ====================
log_info ""
log_info "================ 配置验证 ================"
log_info "✅ BBR 状态: $(sysctl -n net.ipv4.tcp_congestion_control)"
log_info "✅ CPU 调度: $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null)"
log_info "✅ 温度检测: $(($(cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null || echo 0) / 1000))°C"

RPS_VAL="N/A"
for d in eth1 eth2 eth0; do
    if [ -f "/sys/class/net/\$d/queues/rx-0/rps_cpus" ]; then
        RPS_VAL=$(cat "/sys/class/net/\$d/queues/rx-0/rps_cpus")
        log_info "🔥 当前 RPS (核心接口 \$d): \$RPS_VAL (目标: $RPS_MASK)"
        break
    fi
done

log_info "==========================================="
log_info "🎉 优化完成！针对 ImmortalWrt 24.10 部署了【三重锁定机制】。"
log_info ""
log_info "📋 提示:"
log_info "   1. 重启后请务必等待 60 秒，定时任务会自动强制写回 ff。"
log_info "   2. 验证命令: cat /sys/class/net/eth1/queues/rx-0/rps_cpus"
log_info "   3. 备份路径: $BACKUP_DIR"
log_info ""
log_info "🚀 请执行 reboot 重启系统。"
log_info "==========================================="
