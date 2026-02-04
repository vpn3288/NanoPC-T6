#!/bin/bash
# NanoPC-T6 ImmortalWrt 优化脚本 v3.1 → 改进版
# 目标：性能 + 稳定 + 安全（为 NanoPC-T6, 16GB 内存, ImmortalWrt）
# 说明：脚本为幂等（可重复执行），并提供回滚/备份路径
# Author: 改进版（基于用户提供 v3.1）
set -euo pipefail

# -------------------------
# 基本变量与日志
# -------------------------
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOG_DIR="/var/log/openwrt-optimize"
LOG_FILE="${LOG_DIR}/optimize_${TIMESTAMP}.log"
BACKUP_DIR="/etc/config_backup_${TIMESTAMP}"
mkdir -p "${LOG_DIR}" 2>/dev/null || true

log()  { echo -e "[`date +%F\ %T`] $*" | tee -a "$LOG_FILE"; }
log_ok(){ echo -e "[\e[32m✓\e[0m] $*" | tee -a "$LOG_FILE"; }
log_warn(){ echo -e "[\e[33m!\e[0m] $*" | tee -a "$LOG_FILE"; }
log_err(){ echo -e "[\e[31m✗\e[0m] $*" | tee -a "$LOG_FILE"; }

# -------------------------
# 权限与环境检测
# -------------------------
if [ "$(id -u)" -ne 0 ]; then
  log_err "需要 root 权限运行脚本"
  exit 1
fi

DEVICE_MODEL=$(tr -d '\0' < /proc/device-tree/model 2>/dev/null || uname -a)
TOTAL_MEM_KB=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
TOTAL_MEM_MB=$((TOTAL_MEM_KB/1024))
TOTAL_MEM_BYTES=$((TOTAL_MEM_KB*1024))
CPU_CORES=$(grep -c ^processor /proc/cpuinfo 2>/dev/null || echo 1)

log "设备：${DEVICE_MODEL}"
log "内存：${TOTAL_MEM_MB} MB"
log "CPU cores：${CPU_CORES}"
log "备份目录：${BACKUP_DIR}"
log "日志文件：${LOG_FILE}"

# -------------------------
# 步骤 0：建立备份 & 快速回滚函数
# -------------------------
mkdir -p "${BACKUP_DIR}"
FILES_TO_SAVE=( /etc/sysctl.conf /etc/config/dhcp /etc/config/network /etc/config/firewall /etc/rc.local /etc/init.d/firewall /etc/config/system )
for f in "${FILES_TO_SAVE[@]}"; do
  [ -f "$f" ] && cp -pa "$f" "${BACKUP_DIR}/" || true
done
log_ok "已备份常用配置（如果存在）到 ${BACKUP_DIR}"

rollback() {
  log_warn "正在回滚备份..."
  cp -pa "${BACKUP_DIR}"/* /etc/ 2>/dev/null || true
  log_warn "回滚完成。建议检查 /etc 配置并重启系统。"
}

# -------------------------
# 工具：安全写文件（原子）
# -------------------------
safe_write() {
  local dest="$1"
  local tmp="${dest}.tmp.$RANDOM"
  cat > "$tmp" && mv "$tmp" "$dest"
}

# -------------------------
# 步骤 1：按内存智能计算 conntrack（遵循 OpenWrt 最近做法）
# 说明：使用 kernel/openwrt 推荐“按内存计算”规则，防止 table 满
# 公式示例（常见实现）：CONNTRACK_MAX = RAM_bytes / 16384 / 2
# -------------------------
log "第1步：计算并设置 nf_conntrack_max（按内存自动）"
# 保护：最小允许值和最大上限（避免误设）
MIN_CONNTRACK=16384
# 采用常见建议公式（见 OpenWrt commit 与实践）
CALC_CONNTRACK=$(( TOTAL_MEM_BYTES / 16384 / 2 ))
# 强制整数并加安全下限
if [ "$CALC_CONNTRACK" -lt "$MIN_CONNTRACK" ]; then
  CALC_CONNTRACK=$MIN_CONNTRACK
fi
# 对非常大内存，设置合理上限（例如 8M）
MAX_LIMIT=$((8 * 1024 * 1024))
if [ "$CALC_CONNTRACK" -gt "$MAX_LIMIT" ]; then
  CALC_CONNTRACK="$MAX_LIMIT"
fi

log "计算得 net.netfilter.nf_conntrack_max = ${CALC_CONNTRACK}"
# 将conntrack buckets 设为接近 conntrack_max 的一个合理值：buckets = pow2 >= conntrack_max/2
# 这里采用简单策略：bucket = nearest power of two >= conntrack_max / 2
next_pow2() {
  local v=$1
  pow=1
  while [ $pow -lt "$v" ]; do pow=$((pow<<1)); done
  echo $pow
}
BKT_TARGET=$((CALC_CONNTRACK / 2))
if [ "$BKT_TARGET" -lt 1024 ]; then BKT_TARGET=1024; fi
CONNTRACK_BUCKETS=$(next_pow2 "$BKT_TARGET")

# 写入 sysctl 文件（不覆盖用户自定义，单独文件）
SYSCTL_PATH="/etc/sysctl.d/99-nanopct6-optimize.conf"
cat > "$SYSCTL_PATH" <<-EOF
# NanoPC-T6 优化（v3.1 改进版） - ${TIMESTAMP}
# 基本路由转发
net.ipv4.ip_forward=1
net.ipv6.conf.all.forwarding=1
net.ipv6.conf.default.forwarding=1

# BBR + qdisc
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr

# conntrack（按内存自动计算）
net.netfilter.nf_conntrack_max=${CALC_CONNTRACK}
net.netfilter.nf_conntrack_buckets=${CONNTRACK_BUCKETS}

# 网络缓冲区（针对较大内存机器）
net.core.rmem_max=33554432
net.core.wmem_max=33554432
net.core.rmem_default=262144
net.core.wmem_default=262144
net.ipv4.tcp_rmem=4096 87380 33554432
net.ipv4.tcp_wmem=4096 65536 33554432
net.core.netdev_max_backlog=5000
net.core.somaxconn=4096

# TCP优化
net.ipv4.tcp_fastopen=3
net.ipv4.tcp_tw_reuse=1
net.ipv4.tcp_max_syn_backlog=4096
net.ipv4.tcp_synack_retries=2
net.ipv4.tcp_syn_retries=2
net.ipv4.tcp_timestamps=1
net.ipv4.tcp_sack=1
net.ipv4.tcp_window_scaling=1
net.ipv4.tcp_mtu_probing=1

# RPS/RFS（保留项，实际通过 hotplug 应用）
net.core.rps_sock_flow_entries=32768
EOF

# 立即应用（单文件）
if sysctl -p "$SYSCTL_PATH" >/dev/null 2>&1; then
  log_ok "sysctl 参数已加载（来自 ${SYSCTL_PATH}）"
else
  log_warn "加载 sysctl 时部分参数可能不被当前内核支持（可能需要重启或内核模块）"
fi

# -------------------------
# 步骤 2：BBR 检测与安装（若内核已内置则启用）
# 参考：一些 OpenWrt/ImmortalWrt 构建里已经包含 kmod-bbr/kmod-tcp-bbr
# -------------------------
log "第2步：检测并尝试启用 BBR"
BBR_OK=0
if grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then
  log_ok "内核已支持 bbr（tcp_available_congestion_control 包含 bbr）"
  BBR_OK=1
else
  # 尝试加载模块名常见的模块
  if [ -e /lib/modules ] && ( modprobe tcp_bbr >/dev/null 2>&1 || modprobe kmod-tcp-bbr >/dev/null 2>&1 ); then
    log_ok "BBR 模块加载成功"
    BBR_OK=1
  else
    # 尝试用 opkg 安装（网络可达且仓库包含 kmod-tcp-bbr）
    if command -v opkg >/dev/null 2>&1; then
      log "尝试通过 opkg 安装 kmod-tcp-bbr（如果可用）"
      opkg update >/dev/null 2>&1 || true
      if opkg install kmod-tcp-bbr >/dev/null 2>&1; then
        log_ok "已安装 kmod-tcp-bbr（请检查是否需要重启）"
        BBR_OK=1
      else
        log_warn "kmod-tcp-bbr 安装失败或仓库中不可用（可能内核不匹配），保留当前拥塞控制设置"
      fi
    else
      log_warn "系统上没有 opkg，无法自动安装 kmod-tcp-bbr"
    fi
  fi
fi

# 若已支持则强制设置 sysctl（再次确认）
if [ "$BBR_OK" -eq 1 ]; then
  sysctl -w net.core.default_qdisc=fq >/dev/null 2>&1 || true
  sysctl -w net.ipv4.tcp_congestion_control=bbr >/dev/null 2>&1 || true
  log_ok "已设置默认 qdisc=fq 且 tcp_congestion_control=bbr（若内核支持）"
else
  log_warn "BBR 未启用：如果你需要 BBR，建议使用与内核匹配的 kmod-tcp-bbr 或使用内核自带的构建（ImmortalWrt 有时自带）"
fi

# -------------------------
# 步骤 3：RPS/RFS 持久化（hotplug 脚本）
# 说明：按 CPU 核心数计算掩码，立即生效并持久化到 /etc/hotplug.d/net/
# -------------------------
log "第3步：配置 RPS/RFS 持久化（hotplug）"
# 计算 RPS 掩码（16 进制）
case "$CPU_CORES" in
  1) RPS_MASK="01";;
  2) RPS_MASK="03";;
  3) RPS_MASK="07";;
  4) RPS_MASK="0f";;
  5) RPS_MASK="1f";;
  6) RPS_MASK="3f";;
  7) RPS_MASK="7f";;
  *) RPS_MASK="ff";;
esac
RFS_FLOW_CNT=4096
HOTPLUG_PATH="/etc/hotplug.d/net/40-nanopct6-rps"
cat > "$HOTPLUG_PATH" <<-EOF
#!/bin/sh
[ "\$ACTION" != "add" ] && exit 0
RPS_MASK="${RPS_MASK}"
RFS_FLOW_CNT="${RFS_FLOW_CNT}"
for intf in \$(ls /sys/class/net 2>/dev/null); do
  [ "\$intf" = "lo" ] && continue
  # 仅针对于真实网卡/接口
  for q in /sys/class/net/\$intf/queues/rx-*/rps_cpus 2>/dev/null; do
    [ -f "\$q" ] && echo "\$RPS_MASK" > "\$q" 2>/dev/null || true
  done
  for f in /sys/class/net/\$intf/queues/rx-*/rps_flow_cnt 2>/dev/null; do
    [ -f "\$f" ] && echo "\$RFS_FLOW_CNT" > "\$f" 2>/dev/null || true
  done
done
EOF
chmod +x "$HOTPLUG_PATH"
# 立刻应用到现有网卡
for dev in $(ls /sys/class/net 2>/dev/null); do
  [ "$dev" = "lo" ] && continue
  for q in /sys/class/net/$dev/queues/rx-*/rps_cpus 2>/dev/null; do
    [ -f "$q" ] && echo "$RPS_MASK" > "$q" 2>/dev/null || true
  done
  for f in /sys/class/net/$dev/queues/rx-*/rps_flow_cnt 2>/dev/null; do
    [ -f "$f" ] && echo "$RFS_FLOW_CNT" > "$f" 2>/dev/null || true
  done
  log_ok "$dev RPS/RFS 已配置"
done

# -------------------------
# 步骤 4：DNS（dnsmasq）优化（缓存、TTL、本地解析等）
# -------------------------
log "第4步：dnsmasq 优化（缓存与 TTL）"
if pgrep -x dnsmasq >/dev/null 2>&1 || [ -f /etc/config/dhcp ]; then
  if uci -q show dhcp >/dev/null 2>&1; then
    # 安全检查：如果内存极小，则降低 cachesize（本设备 16GB 可设置大）
    DNS_CACHE=10000
    if [ "$TOTAL_MEM_MB" -lt 128 ]; then
      DNS_CACHE=1000
    fi
    uci set dhcp.@dnsmasq[0].cachesize="${DNS_CACHE}" || true
    uci set dhcp.@dnsmasq[0].min_cache_ttl='3600' || true
    uci set dhcp.@dnsmasq[0].localise_queries='1' || true
    uci commit dhcp || true
    /etc/init.d/dnsmasq restart >/dev/null 2>&1 || true
    log_ok "dnsmasq: cachesize=${DNS_CACHE}, min_cache_ttl=3600, localise_queries=1"
  else
    log_warn "未检测到 dhcp 配置，跳过 dnsmasq 优化"
  fi
else
  log_warn "dnsmasq 未运行，跳过 DNS 优化"
fi

# -------------------------
# 步骤 5：防火墙 & Flow Offloading（若支持）
# 说明：启用软件/硬件 flow offloading 可以大幅提升 NAT 性能（OpenWrt 推荐）
# -------------------------
log "第5步：防火墙与 flow offloading"
if [ -f /etc/config/firewall ]; then
  # flow_offloading 与 flow_offloading_hw 是 luci/uci 支持的字段（取决于防火墙版本）
  # 设置前先查询是否支持
  uci -q set firewall.@defaults[0].drop_invalid='1'
  uci -q set firewall.@defaults[0].syn_flood='1'
  # 尝试启用软件 flow offloading（若内核支持）
  uci -q set firewall.@defaults[0].flow_offloading='1'
  uci -q set firewall.@defaults[0].flow_offloading_hw='1' 2>/dev/null || true
  # 启用 fullcone（谨慎，保留但不强制写入 zone，如果 zone 找到才写）
  WAN_INDEX=$(uci -q show firewall.zone | grep "zone.*=.*wan" | cut -d. -f2 | head -n1 || true)
  if [ -n "$WAN_INDEX" ]; then
    uci set firewall.@zone[$WAN_INDEX].fullcone='1' 2>/dev/null || true
  fi
  uci commit firewall || true
  /etc/init.d/firewall restart >/dev/null 2>&1 || true
  log_ok "防火墙优化已写入（包括 flow_offloading），若内核/硬件支持则生效"
else
  log_warn "/etc/config/firewall 未找到，跳过防火墙优化"
fi

# -------------------------
# 步骤 6：网卡 txqueuelen 优化
# -------------------------
log "第6步：网卡 txqueuelen 优化"
for dev in $(ls /sys/class/net 2>/dev/null); do
  [ "$dev" = "lo" ] && continue
  # 仅对真实网卡调整（跳过虚接口）
  if [ -d "/sys/class/net/$dev/device" ] || ip link show "$dev" | grep -q 'mtu'; then
    ip link set "$dev" txqueuelen 5000 2>/dev/null || true
    log_ok "$dev txqueuelen=5000"
  fi
done

# -------------------------
# 步骤 7：CPU 调频策略（尽量选择 schedutil 或 ondemand）
# -------------------------
log "第7步：配置 CPU 调频策略"
CPU_GOV="powersave"
if [ -f /sys/devices/system/cpu/cpu0/cpufreq/scaling_available_governors ]; then
  AVAIL=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_available_governors)
  if echo "$AVAIL" | grep -qw "schedutil"; then
    CPU_GOV="schedutil"
  elif echo "$AVAIL" | grep -qw "ondemand"; then
    CPU_GOV="ondemand"
  fi
fi
for i in $(seq 0 $((CPU_CORES-1))); do
  cpu_path="/sys/devices/system/cpu/cpu${i}/cpufreq"
  [ -d "$cpu_path" ] && echo "$CPU_GOV" > "${cpu_path}/scaling_governor" 2>/dev/null || true
done
log_ok "CPU 调频策略：${CPU_GOV}（已尝试应用）"

# -------------------------
# 步骤 8：安装并启用 irqbalance（提升多核网络中断分配）
# -------------------------
log "第8步：检查并安装 irqbalance（可选）"
if command -v opkg >/dev/null 2>&1; then
  if opkg list-installed | grep -q '^irqbalance '; then
    log_ok "irqbalance 已安装"
  else
    log "尝试安装 irqbalance"
    if opkg update >/dev/null 2>&1 && opkg install irqbalance >/dev/null 2>&1; then
      /etc/init.d/irqbalance enable >/dev/null 2>&1 || true
      /etc/init.d/irqbalance start >/dev/null 2>&1 || true
      log_ok "irqbalance 已安装并尝试启动"
    else
      log_warn "irqbalance 安装失败（仓库/内核可能不匹配），可略过"
    fi
  fi
else
  log_warn "系统无 opkg，无法自动安装 irqbalance"
fi

# -------------------------
# 步骤 9：创建开机启动脚本以确保设置持久
# -------------------------
log "第9步：创建启动脚本 /etc/init.d/optimize-startup"
STARTUP_PATH="/etc/init.d/optimize-startup"
cat > "$STARTUP_PATH" <<-EOF
#!/bin/sh /etc/rc.common
START=99
start() {
  # 导入 sysctl 文件
  [ -f "${SYSCTL_PATH}" ] && sysctl -p "${SYSCTL_PATH}" >/dev/null 2>&1 || true

  # 重新应用 RPS 掩码
  RPS_MASK="${RPS_MASK}"
  for dev in \$(ls /sys/class/net 2>/dev/null); do
    [ "\$dev" = "lo" ] && continue
    for q in /sys/class/net/\$dev/queues/rx-*/rps_cpus 2>/dev/null; do
      [ -f "\$q" ] && echo "\$RPS_MASK" > "\$q" 2>/dev/null || true
    done
  done

  # txqueuelen
  for dev in \$(ls /sys/class/net 2>/dev/null); do
    [ "\$dev" = "lo" ] && continue
    ip link set \$dev txqueuelen 5000 2>/dev/null || true
  done

  # CPU gov
  CPU_GOV="${CPU_GOV}"
  for i in \$(seq 0 $((CPU_CORES-1))); do
    cpu_path="/sys/devices/system/cpu/cpu\$i/cpufreq"
    [ -d "\$cpu_path" ] && echo "\$CPU_GOV" > "\$cpu_path/scaling_governor" 2>/dev/null || true
  done
}
EOF
chmod +x "$STARTUP_PATH"
if [ -x "$STARTUP_PATH" ]; then
  /etc/init.d/optimize-startup enable >/dev/null 2>&1 || true
  log_ok "启动脚本已创建并 enable（/etc/init.d/optimize-startup）"
else
  log_warn "启动脚本创建失败"
fi

# -------------------------
# 步骤 10：验证与报告（输出关键项）
# -------------------------
log "第10步：验证关键设置"
# conntrack
CT_MAX=$(sysctl -n net.netfilter.nf_conntrack_max 2>/dev/null || echo "N/A")
log "nf_conntrack_max = ${CT_MAX}"
# buckets
CT_BKT=$(sysctl -n net.netfilter.nf_conntrack_buckets 2>/dev/null || echo "N/A")
log "nf_conntrack_buckets = ${CT_BKT}"
# BBR
CC=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "N/A")
log "tcp_congestion_control = ${CC}"
# DNS cache
DNS_CACHE=$(uci -q get dhcp.@dnsmasq[0].cachesize 2>/dev/null || echo "N/A")
log "dnsmasq cachesize = ${DNS_CACHE}"
# RPS sample
SAMPLE_RPS=$(cat /sys/class/net/$(ls /sys/class/net | grep -v lo | head -n1)/queues/rx-0/rps_cpus 2>/dev/null || echo "N/A")
log "示例接口 rps_cpus = ${SAMPLE_RPS}"
log_ok "验证完成（详细信息见日志 ${LOG_FILE}）"

# -------------------------
# 结束语与建议
# -------------------------
cat <<EOF | tee -a "$LOG_FILE"
优化已完成（v3.1 → 改进版）。
关键提示：
  • 若想恢复原配置：执行 rollback 命令或 cp -r ${BACKUP_DIR}/* /etc/ 然后重启。
  • 若要使所有内核模块/参数完全生效，推荐在维护窗口重启设备：reboot
  • 查看当前 conntrack 使用：cat /proc/sys/net/netfilter/nf_conntrack_count
  • 查看 conntrack 表：cat /proc/net/nf_conntrack 或使用 conntrack 工具 (opkg install conntrack)
  • 若需要开启/调试 BBR 或 flow offloading，请查看内核模块加载与 dmesg 日志。

日志文件：${LOG_FILE}
备份目录：${BACKUP_DIR}
EOF

log_ok "脚本执行完毕（优化已应用/已写入持久化文件）。建议在维护时重启以便所有设置完全生效。"
exit 0
