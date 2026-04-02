# NanoPC-T6 优化

适用于 FriendlyARM NanoPC-T6 等 ARM 开发板。

## 脚本说明

### YouHua.sh

核心优化脚本，功能：

- BBR 拥塞控制开启
- 16GB 内存缓冲区优化
- 连接跟踪表扩容（52万连接）
- 防火墙流量卸载（降低 CPU 负载）
- DNS 缓存优化（10000 条）
- CPU 调度策略优化

## 使用方法

```bash
# 一键运行
bash <(curl -fsSL https://raw.githubusercontent.com/vpn3288/NanoPC-T6/main/YouHua.sh)

# 或下载后运行
chmod +x YouHua.sh
sudo ./YouHua.sh
```

## 适用系统

- FriendlyARM NanoPC-T6 (RK3588)
- OpenWrt 系统
- ARM64 架构

## 注意事项

- 需要 root 权限
- 建议在全新系统上运行
- 运行后建议重启以应用所有优化
