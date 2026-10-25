#!/bin/sh
# bacon-firstboot —— 一加一代（oneplus-bacon）在 postmarketOS 上的开机调整
#
# 设计原则：只做「幂等 + 失败无害」的事。任何一步失败都只记日志，
# 绝不允许挡住开进系统（testing 类设备最怕的就是自制定制把 boot 搞挂）。
#
# 由 systemd 的 bacon-firstboot.service 或 openrc 的 /etc/local.d 调用。

LOG=/var/log/bacon-firstboot.log
mkdir -p /var/log /var/lib/bacon 2>/dev/null || true
exec >>"$LOG" 2>&1
echo "=== $(date '+%F %T') bacon-firstboot start ==="

ok()   { echo "  [ok]   $*"; }
skip() { echo "  [skip] $*"; }

# ---------------------------------------------------------------------------
# 1. CPU 调频：把 governor 从 performance 换成 schedutil
#    801 + 3GB 内存，performance 会让待机功耗和发热明显变差
# ---------------------------------------------------------------------------
for g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
    [ -e "$g" ] || { skip "没有 $g"; break; }
    if grep -qw schedutil /sys/devices/system/cpu/cpu0/cpufreq/scaling_available_governors 2>/dev/null; then
        echo schedutil > "$g" 2>/dev/null && ok "governor -> schedutil ($g)" \
            || skip "写入失败 $g"
    else
        skip "内核没提供 schedutil"
        break
    fi
done

# ---------------------------------------------------------------------------
# 2. 内存参数：只在第一次写入，之后尊重用户修改
# ---------------------------------------------------------------------------
if [ ! -f /etc/sysctl.d/90-bacon.conf ]; then
    cat > /etc/sysctl.d/90-bacon.conf <<'EOF'
# 一加一代 3GB 内存 + 慢速 eMMC 的保守取值
vm.swappiness = 100
vm.vfs_cache_pressure = 200
vm.dirty_ratio = 15
vm.dirty_background_ratio = 5
EOF
    ok "写入 /etc/sysctl.d/90-bacon.conf"
    sysctl -p /etc/sysctl.d/90-bacon.conf >/dev/null 2>&1 || true
else
    skip "/etc/sysctl.d/90-bacon.conf 已存在"
fi

# ---------------------------------------------------------------------------
# 3. 屏幕刷新 workaround（默认不启用）
#    bacon 在 mainline 上有「画面不自动刷新」的老问题。真遇到黑屏/画面僵住时，
#    手动创建 /etc/bacon/display-workaround 再重启即可启用，
#    不要默认打开 —— 它会持续占用一点 CPU 并可能干扰正常刷新。
# ---------------------------------------------------------------------------
if [ -e /etc/bacon/display-workaround ]; then
    if [ -e /sys/class/graphics/fb0/modes ]; then
        (
            while true; do
                cat /sys/class/graphics/fb0/modes > /sys/class/graphics/fb0/mode 2>/dev/null
                sleep 10
            done
        ) &
        ok "已启用屏幕刷新 workaround (pid $!)"
    else
        skip "没有 /sys/class/graphics/fb0，workaround 对本内核无效"
    fi
else
    skip "屏幕刷新 workaround 未启用（需要时创建 /etc/bacon/display-workaround）"
fi

# ---------------------------------------------------------------------------
# 4. WiFi/BT 固件自检：只报告，不修改
#    固件是从原厂分区里抠出来的，是否可用只能看 dmesg
# ---------------------------------------------------------------------------
FW_DIR=/usr/lib/firmware/brcm
[ -d "$FW_DIR" ] || FW_DIR=/lib/firmware/brcm
if [ -n "$(ls -A "$FW_DIR" 2>/dev/null)" ]; then
    ok "brcm 固件目录非空: $FW_DIR"
    ls -1 "$FW_DIR" | sed 's/^/         /'
else
    skip "没有 WiFi/BT 固件（WiFi 将不可用，用 extract-firmware.sh 从原厂包里抽）"
fi

date '+%F %T' > /var/lib/bacon/firstboot.done 2>/dev/null || true
echo "=== $(date '+%F %T') bacon-firstboot done ==="
exit 0
