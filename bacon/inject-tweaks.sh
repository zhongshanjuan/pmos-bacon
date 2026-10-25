#!/usr/bin/env bash
# 把定制内容直接注入到已生成的 rootfs 镜像里。
#
# 为什么不改 pmaports 的包：上游 device-oneplus-bacon 的 APKBUILD 内容会随版本变化，
# 盲改 package() 很容易把构建搞坏。挂载镜像往里放文件是最稳的做法 ——
# 文件没放进去最差也只是没生效，不会让镜像变得无法启动。
#
# 用法: sudo ./inject-tweaks.sh out/oneplus-bacon.img
set -euo pipefail

IMG=${1:?用法: inject-tweaks.sh <rootfs.img>}
HERE=$(cd "$(dirname "$0")" && pwd)

[ -f "$IMG" ] || { echo "ERROR: 找不到镜像 $IMG" >&2; exit 1; }
[ "$(id -u)" -eq 0 ] || { echo "ERROR: 需要 root 才能 loop mount" >&2; exit 1; }

MNT=$(mktemp -d)
cleanup() { umount "$MNT" 2>/dev/null || true; rmdir "$MNT" 2>/dev/null || true; }
trap cleanup EXIT

mount -o loop,rw "$IMG" "$MNT"
echo "== 挂载 $IMG -> $MNT"

# usr-merge 兼容：新镜像里 /lib 是指向 /usr/lib 的符号链接
if [ -d "$MNT/usr/lib" ]; then
    FW="$MNT/usr/lib/firmware"
else
    FW="$MNT/lib/firmware"
fi
mkdir -p "$FW/brcm"

# ---------------------------------------------------------------------------
# 1. 首启动调整脚本
# ---------------------------------------------------------------------------
install -Dm755 "$HERE/bacon-firstboot.sh" "$MNT/usr/local/bin/bacon-firstboot"
echo "   + /usr/local/bin/bacon-firstboot"

mkdir -p "$MNT/etc/bacon"
: > "$MNT/etc/bacon/.keep"
echo "   + /etc/bacon/"

# ---------------------------------------------------------------------------
# 2. systemd 单元（pmOS edge 默认 systemd）
# ---------------------------------------------------------------------------
if [ -d "$MNT/etc/systemd/system" ]; then
    cat > "$MNT/etc/systemd/system/bacon-firstboot.service" <<'EOF'
[Unit]
Description=OnePlus One (bacon) first boot tweaks
After=local-fs.target
ConditionPathExists=!/var/lib/bacon/firstboot.done

[Service]
Type=oneshot
ExecStart=/usr/local/bin/bacon-firstboot
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
    mkdir -p "$MNT/etc/systemd/system/multi-user.target.wants"
    ln -sf ../bacon-firstboot.service \
        "$MNT/etc/systemd/system/multi-user.target.wants/bacon-firstboot.service"
    echo "   + bacon-firstboot.service（已 enabled）"
fi

# ---------------------------------------------------------------------------
# 3. openrc 兜底（老镜像仍是 openrc）
# openrc 的 local 服务会顺序执行 /etc/local.d/*.start
# ---------------------------------------------------------------------------
if [ -d "$MNT/etc/local.d" ] && [ -f "$MNT/etc/init.d/local" ]; then
    printf '#!/bin/sh\n/usr/local/bin/bacon-firstboot\n' > "$MNT/etc/local.d/10-bacon.start"
    chmod 755 "$MNT/etc/local.d/10-bacon.start"
    mkdir -p "$MNT/etc/runlevels/default"
    ln -sf /etc/init.d/local "$MNT/etc/runlevels/default/local"
    echo "   + /etc/local.d/10-bacon.start（local 已加入 default runlevel）"
fi

# ---------------------------------------------------------------------------
# 4. WiFi / 蓝牙固件（可选）
#    把 extract-firmware.sh 抽出来的文件放到 bacon/firmware/ 即可自动打进去。
#    brcmfmac 会去 /lib/firmware/brcm/ 找 brcmfmac4339-sdio.bin + .txt
# ---------------------------------------------------------------------------
if [ -d "$HERE/firmware" ] && [ -n "$(ls -A "$HERE/firmware" 2>/dev/null)" ]; then
    cp -f "$HERE"/firmware/* "$FW/brcm/"
    # 常见命名映射：原厂 fw_bcmdhd.bin 就是 BCM4339 的 chip firmware
    [ -f "$FW/brcm/fw_bcmdhd.bin" ] && cp -f "$FW/brcm/fw_bcmdhd.bin" "$FW/brcm/brcmfmac4339-sdio.bin"
    [ -f "$FW/brcm/nvram.txt" ] && cp -f "$FW/brcm/nvram.txt" "$FW/brcm/brcmfmac4339-sdio.txt"
    echo "   + 固件 -> $FW/brcm/"
    ls -1 "$FW/brcm/" | sed 's/^/     /'
else
    echo "   - 没有 bacon/firmware/，跳过固件（WiFi 将不可用）"
fi

# ---------------------------------------------------------------------------
# 5. 写一份设备须知，登录后 /etc/motd 会显示
# ---------------------------------------------------------------------------
cat > "$MNT/etc/motd" <<'EOF'

  OnePlus One (bacon) - postmarketOS (testing)
  ------------------------------------------------------------
  可用   : 屏幕 / 触摸 / 电池 / WiFi(需固件) / 蓝牙 / 短信 / 移动数据
  不可用 : 通话 / 相机 / GPS / 加速度计 / OTG / 全盘加密
  提示   : 不要开 FDE；boot 分区仅 16MB，别轻易换更大的内核。
           首启动日志: /var/log/bacon-firstboot.log
  ------------------------------------------------------------

EOF

sync
umount "$MNT"
rmdir "$MNT"
trap - EXIT
echo "== 注入完成: $IMG"
