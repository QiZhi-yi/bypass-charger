#!/system/bin/sh
# ============================================================
# 卸载清理：还原充电节点原始值/权限，删除配置与运行数据
# ============================================================

# 管理器用绝对路径调用；兼容手工相对路径调用的情况
case "$0" in
  */*) MODDIR=${0%/*} ;;
  *)   MODDIR=/data/adb/modules/bypass_charger ;;
esac
DATA=/data/adb/bypass_charger
ORIG_ENV="$DATA/orig.env"

# 1. 停止守护进程并确认真的退出，否则它会继续写节点、把下面的还原值覆盖回去
PIDFILE="$MODDIR/daemon.pid"
PID=$(cat "$PIDFILE" 2>/dev/null)
if [ -n "$PID" ]; then
  kill "$PID" 2>/dev/null
  i=0
  while [ -d "/proc/$PID" ] && [ "$i" -lt 15 ]; do
    sleep 0.2; i=$((i + 1))
  done
  [ -d "/proc/$PID" ] && kill -9 "$PID" 2>/dev/null
  sleep 0.5
fi

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
  # 精确模式：还原 soc_limit 原始值，避免卸载后充电上限残留
  SOC_FILE=$(grep -m1 '^ORIG_SOC_FILE=' "$ORIG_ENV" | cut -d= -f2-)
  SOC_VAL=$(grep -m1 '^ORIG_SOC_VAL=' "$ORIG_ENV" | cut -d= -f2-)
  if [ -n "$SOC_FILE" ] && [ -e "$SOC_FILE" ] && [ -n "$SOC_VAL" ]; then
    echo "$SOC_VAL" > "$SOC_FILE" 2>/dev/null
    echo "- 已还原充电上限 $SOC_FILE = $SOC_VAL"
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
  # 精确模式：放开 soc_limit，避免上限残留导致卸载后充不满
  for s in \
    /sys/devices/platform/smart_charge/soc_limit \
    /sys/devices/platform/soc/soc:smart_charge/soc_limit
  do
    [ -e "$s" ] && echo 100 > "$s" 2>/dev/null
  done
  echo "- 无原始记录，已按默认值复位充电节点与上限"
fi

# 3. 删除配置与运行数据
rm -rf "$DATA"
echo "- 配置与运行数据已删除"
