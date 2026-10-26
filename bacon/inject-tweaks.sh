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
LOOP=""
cleanup() {
    umount "$MNT" 2>/dev/null || true
    if [ -n "$LOOP" ]; then losetup -d "$LOOP" 2>/dev/null || true; fi
    rmdir "$MNT" 2>/dev/null || true
}
trap cleanup EXIT

# pmbootstrap 导出的 <device>.img 是「整盘镜像」：开头是 msdos 分区表，
# 直接 mount -o loop 会报 "wrong fs type, bad option, bad superblock"。
# 正确做法是 losetup -P 让内核解析分区，再挂 root 分区。
LOOP=$(losetup -fP --show "$IMG")
echo "== 镜像 $IMG -> $LOOP"

# 列出候选块设备。
# 注意：pmbootstrap 的分区布局固定是 p1=/boot、p2=/，两个分区都是 ext2/ext4，
# 所以「第一个 ext 分区」= boot 分区，不是我们要写的 rootfs。必须按标签/内容判断。
candidates() {
    local p
    for p in "${LOOP}"p*; do
        [ -b "$p" ] && printf '%s\n' "$p"
    done
    return 0
}

find_root() {
    local p type label size best="" bestsize=0 tmp
    # 情况 A：镜像本身就是裸文件系统（没有分区表）
    type=$(blkid -o value -s TYPE "$LOOP" 2>/dev/null || true)
    case "$type" in
        ext4|ext3|ext2|f2fs|btrfs) printf '%s\n' "$LOOP"; return 0 ;;
    esac

    # 情况 B-1：按标签挑。pmOS 的 root 分区标签默认就是 pmOS_root。
    for p in $(candidates); do
        label=$(blkid -o value -s LABEL "$p" 2>/dev/null || true)
        [ "$label" = "pmOS_root" ] || continue
        printf '%s\n' "$p"; return 0
    done

    # 情况 B-2：标签不可靠时靠内容判断 —— 只读挂一下，看里面是不是真的 postmarketOS 根。
    tmp=$(mktemp -d)
    for p in $(candidates); do
        type=$(blkid -o value -s TYPE "$p" 2>/dev/null || true)
        label=$(blkid -o value -s LABEL "$p" 2>/dev/null || true)
        echo "   分区 $p  fstype=${type:-未知} label=${label:-无}" >&2
        case "$type" in
            ext4|ext3|ext2|f2fs|btrfs) ;;
            *) continue ;;
        esac
        if mount -o ro "$p" "$tmp" 2>/dev/null; then
            if grep -qi '^ID=postmarketos' "$tmp/etc/os-release" 2>/dev/null \
               || { [ -d "$tmp/usr/lib/apk" ] && [ -f "$tmp/sbin/init" ]; }; then
                umount "$tmp" 2>/dev/null || true
                rmdir "$tmp" 2>/dev/null || true
                printf '%s\n' "$p"; return 0
            fi
            umount "$tmp" 2>/dev/null || true
        fi
    done
    rmdir "$tmp" 2>/dev/null || true

    # 情况 B-3：兜底取最大的分区（root 一定远大于 boot）
    for p in $(candidates); do
        size=$(blockdev --getsize64 "$p" 2>/dev/null || echo 0)
        if [ "$size" -gt "$bestsize" ]; then best="$p"; bestsize="$size"; fi
    done
    [ -n "$best" ] || return 1
    echo "   ::warning::靠标签和内容都没认出来，退化为最大分区 $best" >&2
    printf '%s\n' "$best"
}

ROOT=""
for _ in 1 2 3 4 5; do
    partx -u "$LOOP" 2>/dev/null || true
    ROOT=$(find_root) && break
    ROOT=""
    sleep 2
done
if [ -z "$ROOT" ]; then
    echo "ERROR: 在 $IMG 里找不到可挂载的 rootfs 分区" >&2
    lsblk -f "$LOOP" 2>/dev/null || true
    blkid "$LOOP" 2>/dev/null || true
    exit 1
fi

mount -o rw "$ROOT" "$MNT"
echo "== 挂载 $ROOT -> $MNT"

# 最后一道保险：万一挂到了 /boot，宁可直接失败并报错，
# 也不要产出一个「构建成功、定制却没生效」的镜像去浪费时间刷机。
if ! grep -qi '^ID=postmarketos' "$MNT/etc/os-release" 2>/dev/null && [ ! -d "$MNT/usr/lib/apk" ]; then
    echo "ERROR: $ROOT 不像是 postmarketOS 根分区（没有 /etc/os-release，也没有 /usr/lib/apk）" >&2
    echo "       下面列出它的顶层内容，便于判断挂错到了哪个分区：" >&2
    ls -la "$MNT" >&2 || true
    findmnt -no SOURCE,FSTYPE,LABEL,SIZE "$MNT" >&2 || true
    exit 1
fi
echo "   已确认这是 postmarketOS 根分区"

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
losetup -d "$LOOP"
rmdir "$MNT"
trap - EXIT
echo "== 注入完成: $IMG"
