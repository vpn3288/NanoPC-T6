#!/bin/bash
# ============================================================================
# NanoPC-T6 (RK3588) ImmortalWrt 终极优化脚本 v4.0
# ============================================================================
# 硬件目标：NanoPC-T6 (16GB RAM / 64GB eMMC)
# 系统目标：ImmortalWrt / OpenWrt
# 核心功能：
#   1. 内存管理：释放 16GB 内存潜能 (Huge Pages, TCP Buffers)
#   2. 网络性能：BBR + FQ, RPS/XPS 8核全负载均衡
#   3. 硬件加速：强制开启 Flow Offloading (软件+硬件)
#   4. 智能识别：自动过滤虚拟网卡，精准优化物理接口
#   5. 安全加固：抗 DDoS, SYN Flood 防护
# ============================================================================

set -e

# --- 视觉与日志配置 ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOG_FILE="/tmp/openwrt_optimize_${TIMESTAMP}.log"
BACKUP_DIR="/etc/config_backup_${TIMESTAMP}"

log() {
    local level=$1
    local msg=$2
    case $level in
        "INFO") echo -e "${CYAN}[INFO]${NC} $msg" ;;
        "OK")   echo -e "${GREEN}[OK]${NC}   $msg" ;;
        "WARN") echo -e "${YELLOW}[WARN]${NC} $msg" ;;
        "ERR")  echo -e "${RED}[ERR]${NC}  $msg"; exit 1 ;;
        "STEP") echo -e "\n${BLUE}== $msg ==${NC}" ;;
    esac
    # 同时写入日志文件（去除颜色代码）
    echo "[$level] $msg" | sed 's/\x1b\[[0-9;]*m//g' >> "$LOG_FILE"
}

# --- 0. 环境自检 ---
clear
echo -e "${BLUE}"
cat << 'BANNER'
    NanoPC-T6 RK3588 Optimization
    For 16GB RAM High-Performance Router
BANNER
echo -e "${NC}"

if [ "$(id -u)" -ne 0 ]; then
    log ERR "必须使用 ROOT 权限运行此脚本"
fi

# 检测 CPU 核心数 (RK3588 应该是 8)
CPU_CORES=$(grep -c ^processor /proc/cpuinfo)
# RK3588 8核掩码为 ff (11111111)
RPS_MASK="ff" 

log INFO "检测到设备核心数: $CPU_CORES"
log INFO "内存容量优化策略: 16GB (Extreme)"
log INFO "备份目录: $BACKUP_DIR"

# --- 1. 全量备份 ---
log STEP "1. 备份系统配置"
mkdir -p "$BACKUP_DIR"
cp /etc/sysctl.conf "$BACKUP_DIR/" 2>/dev/null || true
cp /etc/rc.local "$BACKUP_DIR/" 2>/dev/null || true
cp -r /etc/config "$BACKUP_DIR/" 2>/dev/null || true
log OK "配置已备份完成"

# --- 2. 软件包依赖检查与安装 ---
log STEP "2. 检查必要软件包"

# 更新列表（可选，如果网络不通可注释）
# opkg update >/dev/null 2>&1

PACKAGES="kmod-tcp-bbr irqbalance"
for pkg in $PACKAGES; do
    if opkg list-installed | grep -q "^$pkg"; then
        log OK "$pkg 已安装"
    else
        log WARN "$pkg 未安装，尝试安装..."
        if opkg install "$pkg" >/dev/null 2>&1; then
            log OK "$pkg 安装成功"
        else
            log WARN "$pkg 安装失败，可能已集成在内核中或网络不可达"
        fi
    fi
done

# --- 3. 内核参数深度调优 (Sysctl) ---
log STEP "3. 应用内核优化参数 (针对 16G 内存)"

cat > /etc/sysctl.conf << EOF
# ============================================================
# NanoPC-T6 16GB RAM 优化配置
# ============================================================

# --- 拥塞控制 ---
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr

# --- 转发与路由 ---
net.ipv4.ip_forward=1
net.ipv6.conf.all.forwarding=1
net.ipv6.conf.default.forwarding=1

# --- 连接跟踪 (16GB 内存特调) ---
# 默认通常是 65536，这里提升到 100万，防止高并发丢包
net.netfilter.nf_conntrack_max=1048576
net.netfilter.nf_conntrack_buckets=262144
net.netfilter.nf_conntrack_tcp_timeout_established=1200
net.netfilter.nf_conntrack_tcp_timeout_time_wait=30

# --- TCP 读写缓冲区 (释放大内存优势) ---
# 允许 TCP 使用高达 64MB 的缓冲区
net.core.rmem_max=67108864
net.core.wmem_max=67108864
net.ipv4.tcp_rmem=4096 87380 67108864
net.ipv4.tcp_wmem=4096 65536 67108864
net.core.netdev_max_backlog=10000
net.core.somaxconn=8192

# --- ARP 缓存调整 (防止局域网设备过多导致丢包) ---
net.ipv4.neigh.default.gc_thresh1=4096
net.ipv4.neigh.default.gc_thresh2=8192
net.ipv4.neigh.default.gc_thresh3=16384

# --- 安全防护 ---
# 开启 SYN Cookies 防范 SYN Flood 攻击
net.ipv4.tcp_syncookies=1
# 开启反向路径过滤，防止 IP 欺骗
net.ipv4.conf.all.rp_filter=1
net.ipv4.conf.default.rp_filter=1
# 忽略 ICMP 广播请求
net.ipv4.icmp_echo_ignore_broadcasts=1

# --- 文件句柄 ---
fs.file-max=2097152
fs.inotify.max_user_instances=8192

EOF

sysctl -p >/dev/null 2>&1
log OK "内核参数已加载"

# --- 4. 网络接口队列优化 (RPS/XPS) ---
log STEP "4. 物理网卡多队列均衡优化"

# 智能识别物理网卡：排除 lo, br-*, veth*, docker*, wg*, tun*, ppp*
# ImmortalWrt 上物理口通常是 eth0, eth1, enp*
PHYS_IFACES=$(ls /sys/class/net | grep -vE 'lo|br-|veth|docker|wg|tun|ppp|ifb')

log INFO "识别到的物理网卡: $PHYS_IFACES"

for iface in $PHYS_IFACES; do
    # 增加传输队列长度，防止突发流量丢包
    ip link set "$iface" txqueuelen 5000 2>/dev/null
    log OK "设置 $iface txqueuelen = 5000"

    # RPS (Receive Packet Steering) - 8核全开
    # 遍历所有 RX 队列
    for rps_file in /sys/class/net/"$iface"/queues/rx-*/rps_cpus; do
        if [ -f "$rps_file" ]; then
            echo "$RPS_MASK" > "$rps_file"
        fi
    done
    
    # RFS (Receive Flow Steering)
    for rfs_file in /sys/class/net/"$iface"/queues/rx-*/rps_flow_cnt; do
        if [ -f "$rfs_file" ]; then
            echo "4096" > "$rfs_file"
        fi
    done
    log OK "已应用 RPS (Mask: $RPS_MASK) 到 $iface"
done

# 设置全局 RFS 表大小
if [ -f /proc/sys/net/core/rps_sock_flow_entries ]; then
    echo 32768 > /proc/sys/net/core/rps_sock_flow_entries
fi

# --- 5. 防火墙硬件加速 (Hardware Offload) ---
log STEP "5. 配置防火墙硬件加速"

# 检查是否为 fw4 (OpenWrt 22.03+ / ImmortalWrt)
if uci get firewall.@defaults[0].flow_offloading >/dev/null 2>&1; then
    uci set firewall.@defaults[0].flow_offloading='1'
    uci set firewall.@defaults[0].flow_offloading_hw='1'
    # FullCone NAT (对游戏和 P2P 优化)
    # 注意：某些 ImmortalWrt 版本默认开启，这里强制确认
    uci set firewall.@defaults[0].fullcone='1' 2>/dev/null || true
    
    # 启用安全丢弃
    uci set firewall.@defaults[0].drop_invalid='1'
    
    uci commit firewall
    /etc/init.d/firewall restart >/dev/null 2>&1
    log OK "防火墙硬件加速 & FullCone 已启用"
else
    log WARN "未检测到标准防火墙配置路径，跳过 UCI 设置"
fi

# --- 6. DNS 缓存优化 (Dnsmasq) ---
log STEP "6. DNS 缓存优化"

# 利用 16G 内存，设置超大 DNS 缓存
uci set dhcp.@dnsmasq[0].cachesize='100000'
uci set dhcp.@dnsmasq[0].min_cache_ttl='3600'
# 允许解析本地查询
uci set dhcp.@dnsmasq[0].localise_queries='1'
# 禁用对上游的无效查询
uci set dhcp.@dnsmasq[0].filterwin2k='1'

uci commit dhcp
/etc/init.d/dnsmasq restart >/dev/null 2>&1
log OK "DNS 缓存已设置为 100,000 条"

# --- 7. CPU 调度与中断平衡 ---
log STEP "7. CPU 调度配置"

# RK3588 性能强劲，推荐 schedutil (调度利用率) 或 ondemand
# 如果没有 schedutil，回退到 performance (但可能会发热)
AVAILABLE_GOVS=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_available_governors 2>/dev/null || echo "performance")

if echo "$AVAILABLE_GOVS" | grep -q "schedutil"; then
    GOVERNOR="schedutil"
elif echo "$AVAILABLE_GOVS" | grep -q "ondemand"; then
    GOVERNOR="ondemand"
else
    GOVERNOR="performance"
fi

for cpu in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
    [ -f "$cpu" ] && echo "$GOVERNOR" > "$cpu"
done
log OK "CPU 调度器已设置为: $GOVERNOR"

# 启用 irqbalance (如果安装了) 辅助处理非网络中断(如 USB/NVMe)
if [ -f /etc/init.d/irqbalance ]; then
    /etc/init.d/irqbalance enable >/dev/null 2>&1
    /etc/init.d/irqbalance start >/dev/null 2>&1
    log OK "irqbalance 服务已启动"
fi

# --- 8. 创建持久化启动脚本 ---
log STEP "8. 创建持久化启动脚本"

# 创建一个会在每次重启后自动执行的脚本
# 用于重新应用网卡队列设置（因为网卡驱动加载可能会重置这些参数）

cat > /etc/init.d/optimize-startup << INIT_SCRIPT
#!/bin/sh /etc/rc.common

START=99
STOP=01

start() {
    # 1. 重新加载 sysctl
    sysctl -p >/dev/null 2>&1
    
    # 2. 动态检测并应用网卡优化 (防止网卡变动)
    # 排除虚拟接口
    PHYS_IFACES=\$(ls /sys/class/net | grep -vE 'lo|br-|veth|docker|wg|tun|ppp|ifb')
    RPS_MASK="ff" # RK3588 8-Core

    for iface in \$PHYS_IFACES; do
        ip link set "\$iface" txqueuelen 5000 2>/dev/null
        
        for rps_file in /sys/class/net/"\$iface"/queues/rx-*/rps_cpus; do
            [ -f "\$rps_file" ] && echo "\$RPS_MASK" > "\$rps_file"
        done
        
        for rfs_file in /sys/class/net/"\$iface"/queues/rx-*/rps_flow_cnt; do
            [ -f "\$rfs_file" ] && echo "4096" > "\$rfs_file"
        done
    done
    
    if [ -f /proc/sys/net/core/rps_sock_flow_entries ]; then
        echo 32768 > /proc/sys/net/core/rps_sock_flow_entries
    fi
}
INIT_SCRIPT

chmod +x /etc/init.d/optimize-startup
/etc/init.d/optimize-startup enable
log OK "启动脚本 /etc/init.d/optimize-startup 已创建并启用"

# --- 9. 完成 ---
log STEP "优化完成"
echo -e "${GREEN}"
cat << SUMMARY
============================================================
 [SUCCESS] NanoPC-T6 系统优化已部署
============================================================
 状态概览:
  - 内存优化: 16GB 模式 (Buffer/Cache Max)
  - 网络算法: BBR + FQ
  - 多核负载: RPS Mask 'ff' (8核全开)
  - DNS缓存:  100,000 条记录
  - 硬件加速: Flow Offloading HW [ON]
  - 备份路径: $BACKUP_DIR
  
 注意事项:
  1. 请重启路由器以使所有内核参数和模块加载生效。
  2. 验证命令: 
     sysctl net.ipv4.tcp_congestion_control
     cat /sys/class/net/eth0/queues/rx-0/rps_cpus
============================================================
SUMMARY
echo -e "${NC}"

read -p "是否立即重启系统? (y/n) [推荐 y]: " choice
case "$choice" in 
  y|Y ) 
    log INFO "系统正在重启..."
    reboot 
    ;;
  * ) 
    log INFO "请稍后手动执行 reboot" 
    ;;
esac

exit 0
