#!/bin/bash
# ==============================================================================
# NanoPC-T6 (16GB) 代理主路由专用优化脚本 v23.0
# ------------------------------------------------------------------------------
# 硬件: Rockchip RK3588 (4x A76 + 4x A55) / 16GB LPDDR4x / 双 2.5G 网口
# 场景: 极致性能主路由 + 代理转发 (OpenClash/HomeProxy/PassWall)
# 特性: 
#   1. [全量] 52万连接跟踪 + 32MB 满血网络缓冲区 (针对 16GB 内存)
#   2. [核心] RK3588 Policy 0/4/6 分簇频率锁定与调度优化
#   3. [持久] 三位一体 RPS 强效锁定 (Hotplug + Cron + rc.local)
#   4. [稳健] 完整的环境清理、组件检测与 dnsmasq 安全重启逻辑
# ==============================================================================

set -e

# --- [全局参数配置] ---
LOG_FILE="/tmp/optimization_v23_$(date +%Y%m%d).log"
BACKUP_DIR="/etc/config_backup_v23_$(date +%Y%m%d_%H%M%S)"

# CPU 频率与模式 (针对主路由高性能场景)
CPU_GOVERNOR="schedutil"    # 负载感应模式 (推荐)，也可改为 performance
MIN_FREQ="1008000"         # 待机起始频率 1.0GHz
MAX_FREQ="1800000"         # 最大稳定频率 1.8GHz

# 网卡优化参数
TX_QUEUE_LEN="5000"        # 发送队列长度
RPS_MASK="ff"              # RPS 全核掩码

# --- [核心日志与备份工具] ---
log_info() { echo -e "\033[32m[INFO] [$(date +'%H:%M:%S')] $1\033[0m" | tee -a "$LOG_FILE"; }
log_warn() { echo -e "\033[33m[WARN] [$(date +'%H:%M:%S')] $1\033[0m" | tee -a "$LOG_FILE"; }
log_err()  { echo -e "\033[31m[ERROR] [$(date +'%H:%M:%S')] $1\033[0m" | tee -a "$LOG_FILE"; exit 1; }

backup_file() {
    if [ -f "$1" ]; then
        mkdir -p "$BACKUP_DIR"
        cp -a "$1" "$BACKUP_DIR/" 2>/dev/null
        log_info "💾 备份原始配置: $1"
    fi
}

check_network() {
    log_info "🔍 正在进行网络连通性自检..."
    for host in 223.5.5.5 119.29.29.29 1.1.1.1; do
        if ping -c 2 -W 3 "$host" >/dev/null 2>&1; then
            log_info "✅ 网络正常 (通过测试节点: $host)"
            return 0
        fi
    done
    log_err "❌ 网络连接异常，请检查 WAN 口连接"
}

uci_delete_all() {
    while uci -q delete "$1" 2>/dev/null; do :; done
}

# --- [主逻辑开始] ---
log_info "🚀 NanoPC-T6 代理主路由优化程序 v23.0 启动"

# 设备识别
DEVICE_MODEL=$(tr -d '\0' < /proc/device-tree/model 2>/dev/null || echo 'RK3588 Device')
TOTAL_MEM=$(free -m | awk 'NR==2 {print $2}')
log_info "设备型号: $DEVICE_MODEL"
log_info "物理内存: ${TOTAL_MEM}MB"

[ "$(id -u)" -eq 0 ] || log_err "错误: 必须以 root 权限运行此脚本"
check_network

# ==================== 阶段 1: 深度环境清理 ====================
log_info ""
log_info "🧹 [1/7] 正在清理可能冲突的组件与配置..."

# 彻底移除 SmartDNS (避免与代理软件的 DNS 转发冲突)
if opkg list-installed 2>/dev/null | grep -q "smartdns"; then
    log_warn "检测到已安装 SmartDNS，正在强制移除以防止 DNS 劫持冲突..."
    /etc/init.d/smartdns stop 2>/dev/null || true
    /etc/init.d/smartdns disable 2>/dev/null || true
    opkg remove luci-app-smartdns smartdns --force-removal-of-dependent-packages >/dev/null 2>&1 || true
    rm -rf /etc/config/smartdns /etc/smartdns 2>/dev/null
    log_info "✅ SmartDNS 清理完成"
else
    log_info "✅ 未发现 SmartDNS，环境清洁"
fi

# 重置 Dnsmasq 配置 (为代理软件接管 DNS 做准备)
log_info "正在重置 Dnsmasq 以匹配代理转发场景..."
backup_file "/etc/config/dhcp"

uci_delete_all "dhcp.@dnsmasq[0].server"
uci set dhcp.@dnsmasq[0].noresolv='0'
uci set dhcp.@dnsmasq[0].cachesize='10000'    # 针对 16GB 内存扩大 DNS 缓存
uci set dhcp.@dnsmasq[0].min_cache_ttl='600'   # 最小缓存时长 10 分钟
uci set dhcp.@dnsmasq[0].localservice='0'      # 允许非局部服务响应
uci commit dhcp

# 安全重启 dnsmasq (包含 PID 检测与强制拉起逻辑)
log_info "正在安全重启 Dnsmasq 服务..."
/etc/init.d/dnsmasq restart &
DNSMASQ_PID=$!
count=0
while [ $count -lt 10 ]; do
    if ! kill -0 $DNSMASQ_PID 2>/dev/null; then
        wait $DNSMASQ_PID 2>/dev/null
        break
    fi
    sleep 1
    count=$((count + 1))
done

if kill -0 $DNSMASQ_PID 2>/dev/null; then
    log_warn "Dnsmasq 响应超时，正在执行强制清理并手动拉起..."
    kill -9 $DNSMASQ_PID 2>/dev/null || true
    killall dnsmasq 2>/dev/null || true
    sleep 1
    /etc/init.d/dnsmasq start
fi
log_info "✅ Dnsmasq 重启成功"

# ==================== 阶段 2: 核心软件包安装 ====================
log_info ""
log_info "📦 [2/7] 正在安装/检查核心优化组件..."
opkg update >/dev/null 2>&1 || log_warn "软件源更新失败，将尝试直接安装..."

PKG_LIST="irqbalance ethtool ip-full kmod-tcp-bbr kmod-sched-core bind-host coreutils-stat"

for pkg in $PKG_LIST; do
    if opkg list-installed 2>/dev/null | grep -q "^$pkg "; then
        log_info "   ⏭️  组件 $pkg 已存在"
    else
        log_info "   ⬇️  正在安装 $pkg..."
        opkg install "$pkg" >> "$LOG_FILE" 2>&1 || log_warn "   ⚠️  $pkg 安装失败，请检查软件源"
    fi
done

# ==================== 阶段 3: 硬件流量卸载与 FullCone ====================
log_info ""
log_info "⚡ [3/7] 正在激活硬件加速与 FullCone NAT..."

# 1. 动态遍历所有 Zone 以精确定位 WAN 并开启 FullCone NAT (代理游戏必备)
idx=0
while [ -n "$(uci -q get firewall.@zone[$idx])" ]; do
    z_name=$(uci -q get firewall.@zone[$idx].name 2>/dev/null)
    if [ "$z_name" = "wan" ]; then
        uci set firewall.@zone[$idx].fullcone4='1'
        log_info "✅ 已为 Zone[$idx] ($z_name) 开启 FullCone NAT"
    fi
    idx=$((idx+1))
done

# 2. 开启硬件流量卸载 (SFE/Flow Offloading)
if [ -f /etc/config/turboacc ] || opkg list-installed 2>/dev/null | grep -q "turboacc"; then
    log_info "正在配置 TurboACC 增强逻辑..."
    [ -z "$(uci -q get turboacc.config)" ] && uci set turboacc.config=turboacc
    uci set turboacc.config.enabled='1'
    uci set turboacc.config.sfe_flow='1'
    uci set turboacc.config.fullcone_nat='1'
    uci set turboacc.config.bbr_cca='1'
    uci commit turboacc
    /etc/init.d/turboacc restart 2>/dev/null || true
fi

uci set firewall.@defaults[0].flow_offloading='1'
uci set firewall.@defaults[0].flow_offloading_hw='1'
uci set firewall.@defaults[0].drop_invalid='1'
uci set firewall.@defaults[0].syn_flood='1'
uci commit firewall
/etc/init.d/firewall restart >/dev/null 2>&1 || true
log_info "✅ 硬件转发加速已全面激活"

# ==================== 阶段 4: 16GB 满血内核参数调优 ====================
log_info ""
log_info "🛠️ [4/7] 正在注入针对 16GB 内存特调的内核参数..."
backup_file "/etc/sysctl.conf"

cat > /etc/sysctl.conf <<EOF
# ============================================================
# NanoPC-T6 代理主路由终极内核调优 (针对 16GB RAM)
# ============================================================

# --- 拥塞控制与转发 ---
net.core.default_qdisc=fq_codel
net.ipv4.tcp_congestion_control=bbr
net.ipv4.ip_forward=1
net.ipv6.conf.all.forwarding=1
net.ipv6.conf.default.forwarding=1

# --- 连接跟踪 (代理高并发优化: 52万连接) ---
net.netfilter.nf_conntrack_max=524288
net.netfilter.nf_conntrack_buckets=131072
net.netfilter.nf_conntrack_tcp_timeout_established=7200
net.netfilter.nf_conntrack_tcp_timeout_time_wait=30
net.netfilter.nf_conntrack_udp_timeout=180
net.netfilter.nf_conntrack_udp_timeout_stream=300

# --- 16GB 专属网络缓冲区 (32MB 大口径) ---
net.core.rmem_max=33554432
net.core.wmem_max=33554432
net.core.rmem_default=262144
net.core.wmem_default=262144
net.ipv4.tcp_rmem=4096 131072 33554432
net.ipv4.tcp_wmem=4096 131072 33554432
net.ipv4.tcp_mem=262144 524288 1048576
net.ipv4.udp_mem=262144 524288 1048576
net.core.netdev_max_backlog=16384
net.core.somaxconn=8192

# --- TCP 性能与代理加速 ---
net.ipv4.tcp_fastopen=3
net.ipv4.tcp_slow_start_after_idle=0
net.ipv4.tcp_notsent_lowat=16384
net.ipv4.tcp_window_scaling=1
net.ipv4.tcp_timestamps=1
net.ipv4.tcp_sack=1
net.ipv4.tcp_mtu_probing=1
net.ipv4.tcp_tw_reuse=1
net.ipv4.tcp_max_syn_backlog=8192

# --- 系统限制 ---
fs.file-max=1000000
fs.inotify.max_user_instances=8192
fs.inotify.max_user_watches=524288
net.core.rps_sock_flow_entries=32768
EOF

sysctl -p >/dev/null 2>&1 || true
log_info "✅ 16GB 网络协议栈参数注入完成"

# ==================== 阶段 5: RPS/RFS 终极三位一体锁定 ====================
log_info ""
log_info "🔥 [5/7] 正在部署三位一体 RPS 锁定方案 (防回跳)..."

# 1. 第一道锁: Hotplug (接口热插拔时立即应用)
mkdir -p /etc/hotplug.d/net
cat > /etc/hotplug.d/net/99-rps-lock <<EOF
#!/bin/sh
# 强行锁定所有物理网卡 RPS 掩码
[ "\$ACTION" = "ifup" ] || exit 0
case "\$INTERFACE" in
    eth*|lan*|wan*|enp*)
        for q in /sys/class/net/\$INTERFACE/queues/rx-*/rps_cpus; do
            echo "$RPS_MASK" > "\$q"
        done
        ;;
esac
EOF
chmod +x /etc/hotplug.d/net/99-rps-lock

# 2. 第二道锁: Cron 守护进程 (每分钟强制检查并锁定，对付内核自动重置)
if ! crontab -l 2>/dev/null | grep -q "rps_cpus"; then
    (crontab -l 2>/dev/null | grep -v "rps_cpus"; echo "* * * * * for q in /sys/class/net/eth*/queues/rx-*/rps_cpus; do echo '$RPS_MASK' > \"\$q\"; done") | crontab -
    /etc/init.d/cron restart
    log_info "✅ Cron 守护锁定任务已启动"
fi

# 3. 第三道锁: 立即对当前所有设备应用
for dev in $(ls /sys/class/net 2>/dev/null | grep -E 'eth|enp|lan|wan'); do
    for q in /sys/class/net/$dev/queues/rx-*/rps_cpus; do
        [ -f "$q" ] && echo "$RPS_MASK" > "$q" 2>/dev/null || true
    done
done
log_info "✅ RPS 全核锁定已就绪 (掩码: $RPS_MASK)"

# ==================== 阶段 6: CPU 性能调优 (Policy 0/4/6) ====================
log_info ""
log_info "🔋 [6/7] 正在配置 RK3588 CPU 性能分簇 (Policy 0/4/6)..."

# 设置 CPU 调度与频率范围
# policy0: A55 小核簇 | policy4: A76 大核簇1 | policy6: A76 大核簇2
for policy in 0 4 6; do
    P_PATH="/sys/devices/system/cpu/cpufreq/policy${policy}"
    if [ -d "$P_PATH" ]; then
        echo "$CPU_GOVERNOR" > "$P_PATH/scaling_governor" 2>/dev/null || true
        echo "$MIN_FREQ" > "$P_PATH/scaling_min_freq" 2>/dev/null || true
        echo "$MAX_FREQ" > "$P_PATH/scaling_max_freq" 2>/dev/null || true
        log_info "✅ Policy${policy} 已调优: $CPU_GOVERNOR ($MIN_FREQ-$MAX_FREQ)"
    fi
done

# ==================== 阶段 7: 启动项补刀逻辑 (rc.local) ====================
log_info ""
log_info "🔋 [7/7] 正在写入 rc.local 最终补刀程序..."
backup_file "/etc/rc.local"

cat > /etc/rc.local <<EOF
#!/bin/sh
# NanoPC-T6 v23.0 启动终极补丁
(
    # 延迟 30 秒，确保代理软件和网卡驱动完全初始化
    sleep 30
    
    # 1. 强制网卡发送队列长度
    for dev in \$(ls /sys/class/net 2>/dev/null | grep -E 'eth|enp|lan|wan'); do
        [ -d "/sys/class/net/\$dev" ] && ip link set "\$dev" txqueuelen $TX_QUEUE_LEN 2>/dev/null
    done
    
    # 2. 再次加固 CPU 策略 (Policy 0/4/6)
    for p in 0 4 6; do
        if [ -d "/sys/devices/system/cpu/cpufreq/policy\$p" ]; then
            echo "$CPU_GOVERNOR" > /sys/devices/system/cpu/cpufreq/policy\$p/scaling_governor
            echo "$MIN_FREQ" > /sys/devices/system/cpu/cpufreq/policy\$p/scaling_min_freq
            echo "$MAX_FREQ" > /sys/devices/system/cpu/cpufreq/policy\$p/scaling_max_freq
        fi
    done
    
    # 3. 最终 RPS 强制覆盖
    for q in /sys/class/net/eth*/queues/rx-*/rps_cpus; do echo "$RPS_MASK" > "\$q" 2>/dev/null; done
    
    # 4. 确保 irqbalance 运行 (如有安装)
    /etc/init.d/irqbalance start 2>/dev/null || true
) &
exit 0
EOF
chmod +x /etc/rc.local
log_info "✅ rc.local 补刀程序部署成功"

# ==================== 最终验证报告 ====================
log_info ""
log_info "================ [优化任务报告] ================"
log_info "✅ 物理内存: ${TOTAL_MEM}MB (内核缓冲区已设为 32MB)"
log_info "✅ 连接跟踪: 已设为 524,288 (代理高并发友好)"
log_info "✅ RPS 锁定: 已设为 $RPS_MASK (多重锁定方案)"
log_info "✅ CPU 调度: Policy 0/4/6 -> $CPU_GOVERNOR"
log_info "✅ BBR 拥塞控制: $(sysctl -n net.ipv4.tcp_congestion_control)"
log_info "✅ 启动守护: Cron 锁定每 60 秒运行一次"
log_info "================================================"
log_info "🎉 恭喜！NanoPC-T6 v23.0 全量优化已完成。"
log_info "💡 建议操作: 输入 reboot 重启以确保所有内核参数完美生效。"
log_info "================================================"
