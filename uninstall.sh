#!/system/bin/sh
# ============================================================
# 卸载清理：还原充电节点原始值/权限，删除配置与运行数据
# ============================================================

MODDIR=${0%/*}
DATA=/data/adb/bypass_charger
ORIG_ENV="$DATA/orig.env"

# 1. 停止守护进程，避免它在我们还原后再写回
PIDFILE="$MODDIR/daemon.pid"
if [ -f "$PIDFILE" ]; then
  kill "$(cat "$PIDFILE" 2>/dev/null)" 2>/dev/null
fi
sleep 1

# 2. 还原节点原始值 + 原始权限
if [ -f "$ORIG_ENV" ]; then
  NODE=$(grep -m1 '^ORIG_NODE=' "$ORIG_ENV" | cut -d= -f2-)
  VAL=$(grep -m1 '^ORIG_NIGHT_VAL=' "$ORIG_ENV" | cut -d= -f2-)
  MODE=$(grep -m1 '^ORIG_NIGHT_MODE=' "$ORIG_ENV" | cut -d= -f2-)
  [ -z "$VAL" ] && VAL=0
  [ -z "$MODE" ] && MODE=644
  if [ -n "$NODE" ] && [ -e "$NODE" ]; then
    chmod 0660 "$NODE" 2>/dev/null
    echo "$VAL" > "$NODE" 2>/dev/null
    chmod "$MODE" "$NODE" 2>/dev/null
    echo "- 已还原充电节点 $NODE = $VAL（权限 $MODE）"
  else
    echo "- 未找到控制节点，跳过还原"
  fi
else
  # 无记录时兜底：把已知节点复位为 0
  for n in \
    /sys/class/power_supply/battery/night_charging \
    /sys/class/qcom-battery/night_charging \
    /sys/devices/platform/smart_charge/smart_night \
    /sys/devices/platform/soc/soc:smart_charge/smart_night
  do
    [ -e "$n" ] && echo 0 > "$n" 2>/dev/null
  done
  echo "- 无原始记录，已按默认值 0 复位充电节点"
fi

# 3. 删除配置与运行数据
rm -rf "$DATA"
echo "- 配置与运行数据已删除"
