#!/usr/bin/env bash
# 从一加一代的原厂分区里抽出 WiFi / 蓝牙固件，放进 bacon/firmware/
#
# 为什么要这么做：这些是博通（WCN3680 / BCM4339）的闭源固件，postmarketOS
# 不能打包分发，wiki 上明确写了「固件还没打包，你得从设备分区里自己取」。
#
# 前置条件（三选一）：
#   A. 手机还跑着能 root 的 Android（LineageOS/CyanogenMod + adb root 或 su）
#   B. 手机在 TWRP 里，adb shell 有 root
#   C. 你自己把 modem/system 分区 dump 出来挂到电脑上
#
# 用法: ./extract-firmware.sh
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
OUT="$HERE/firmware"
mkdir -p "$OUT"

command -v adb >/dev/null || { echo "ERROR: 没装 adb（platform-tools）" >&2; exit 1; }
adb start-server >/dev/null 2>&1 || true

if [ -z "$(adb devices | awk 'NR>1 && $2=="device" {print $1}')" ]; then
    echo "ERROR: 没有检测到设备，先开 USB 调试 / 进 TWRP 再跑" >&2
    adb devices
    exit 1
fi
echo "== 设备已连接"

adb root >/dev/null 2>&1 || echo "   (adb root 不可用，稍后尝试 su)"
adb wait-for-device

# 候选目录：/system/etc/firmware（部分 ROM）与 /firmware/image（modem 分区挂载点）
CANDIDATE_DIRS="/system/etc/firmware /firmware/image /vendor/firmware"
FILES="fw_bcmdhd.bin bcmdhd.cal nvram.txt BCM4339A0.hcd wcnss.mdt wcnss.b00 wcnss.b01 wcnss.b02 wcnss.b04 wcnss.b06 wcnss.b09 wcnss.b10 wcnss.b11"

echo "== 扫描候选目录"
FOUND=0
for d in $CANDIDATE_DIRS; do
    n=$(adb shell "ls $d 2>/dev/null | wc -l" | tr -d '\r')
    [ "${n:-0}" -gt 0 ] && { echo "   $d ($n 项)"; FOUND=1; }
done
[ "$FOUND" -eq 1 ] || { echo "ERROR: 三个候选目录都是空的，检查是否已挂载 system" >&2; exit 1; }

for d in $CANDIDATE_DIRS; do
    for f in $FILES; do
        if adb shell "test -f $d/$f" 2>/dev/null; then
            adb pull "$d/$f" "$OUT/$f" >/dev/null 2>&1 && echo "   + $f <- $d"
        fi
    done
done

# 兜底：用 su 复制到 /sdcard 再拉（部分 ROM 的 adb pull 没权限）
if [ -z "$(ls -A "$OUT")" ]; then
    echo "== 直接 pull 失败，尝试 su 转存"
    adb shell "su -c 'mkdir -p /sdcard/baconfw && cp /system/etc/firmware/* /sdcard/baconfw/ 2>/dev/null; cp /firmware/image/wcnss* /sdcard/baconfw/ 2>/dev/null'" || true
    adb pull /sdcard/baconfw/ "$OUT/" >/dev/null 2>&1 || true
fi

echo
echo "== 结果: $OUT"
ls -lh "$OUT" || true
cat <<'EOF'

下一步：
  1. 让 inject-tweaks.sh 自动打进镜像（它会放到 /lib/firmware/brcm/，
     并把 fw_bcmdhd.bin 额外复制成 brcmfmac4339-sdio.bin、nvram.txt 复制成
     brcmfmac4339-sdio.txt，因为 mainline 的 brcmfmac 认这个名字）。
  2. 刷机后验证：
       dmesg | grep -i -E 'brcmfmac|firmware'
     看到 "Firmware: BCM4339" 之类的字样才算真的加载成功；
     报 "Direct firmware load ... failed" 说明文件名或格式不对，
     这里只能靠真机 dmesg 迭代，没法离线猜。
  3. 有些 ROM 的 fw_bcmdhd.bin 前面多一个 4 字节长度头，brcmfmac 不认。
     遇到这种情况可以只保留 wcnss.* 走 bcmdhd 无线扩展，或者换 ROM 版本再抽一次。
EOF
