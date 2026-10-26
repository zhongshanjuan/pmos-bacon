#!/usr/bin/env bash
# 对 pmaports 做 oneplus-bacon 专属定制（幂等，可反复执行）
# 用法: ./customize.sh /path/to/pmaports
set -euo pipefail

APORTS=${1:-$HOME/pmaports}
DEVICE=${DEVICE:-oneplus-bacon}

[ -d "$APORTS/device" ] || { echo "ERROR: $APORTS 不是 pmaports 仓库" >&2; exit 1; }

DEVDIR=$(find "$APORTS/device" -maxdepth 2 -type d -name "device-$DEVICE" | head -n1)
[ -n "$DEVDIR" ] || { echo "ERROR: 在 pmaports 里找不到 device-$DEVICE" >&2; exit 1; }
echo "== 设备包: $DEVDIR"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# ---------------------------------------------------------------------------
# 1. boot 分区只有 16MB
#    bacon 的 boot 分区上限 16384 KiB，mainline 内核 + initramfs 很容易贴边。
#    这是 Wiki 上该设备维护者针对此问题的建议开关。
#    哨兵：workflow 里的「校验镜像」步骤会量 boot.img 大小，
#    如果加上这行反而变大，把它注释掉再跑一次即可，不要盲信。
# ---------------------------------------------------------------------------
if grep -q '^deviceinfo_create_initfs_extra=' "$DEVDIR/deviceinfo"; then
    if grep -q '^deviceinfo_create_initfs_extra="true"' "$DEVDIR/deviceinfo"; then
        echo "== 上游 deviceinfo 已有 create_initfs_extra=\"true\"，无需改动（这是上游修的，不是我们加的）"
    else
        echo "== deviceinfo 里已有该键但值不是 true，改成 true"
        sed -i 's|^deviceinfo_create_initfs_extra=.*|deviceinfo_create_initfs_extra="true"|' \
            "$DEVDIR/deviceinfo"
    fi
else
    printf '\ndeviceinfo_create_initfs_extra="true"\n' >> "$DEVDIR/deviceinfo"
fi

# ---------------------------------------------------------------------------
# 2. 明确关闭本机不具备的能力，避免用户误开导致开机卡死
#    - FDE：bacon 的 unl0kr 解锁明确标注 Broken，开了必然起不来
#    - 这里不写 deviceinfo 键（上游没有对应开关），改为在 install 时不用 --fde，
#      并在镜像里放一个提示文件，详见 inject-tweaks.sh
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# 3. 输出改动，方便 CI 日志里复核
# ---------------------------------------------------------------------------
echo "==== deviceinfo 改动 ===="
git -C "$APORTS" diff --stat || true
git -C "$APORTS" diff -- device || true

echo "== customize 完成"
