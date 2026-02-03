# NanoPC-T6

# 优化NanoPC-t6
opkg update && opkg install bash

wget -qO- https://raw.githubusercontent.com/vpn3288/NanoPC-T6/main/YouHua.sh | bash

# 下载安装
# 1. 下载新版本
wget https://raw.githubusercontent.com/vpn3288/NanoPC-T6/main/YouHua.sh -O /tmp/optimize.sh

# 2. 查看内容
cat /tmp/optimize.sh

# 3. 执行
bash /tmp/optimize.sh

# 4. 重启验证（重要！）
reboot

# 5. 重启后检查
host baidu.com 127.0.0.1 -p 6053
ps | grep -E 'smartdns|irqbalance'
