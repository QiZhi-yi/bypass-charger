SKIPUNZIP=0

# 打印到安装日志（Magisk/KernelSU 都支持 ui_print）
_print() {
  if type ui_print >/dev/null 2>&1; then ui_print "$@"; else echo "$@"; fi
}

set_perm_recursive() {
  chown -R $2:$3 $1 2>/dev/null
  chmod -R $4 $1 2>/dev/null
}

# 模块主体
set_perm_recursive $MODPATH 0 0 0755

# 可执行脚本
for f in auto_bypass.sh service.sh webui.sh uninstall.sh; do
  [ -f "$MODPATH/$f" ] && chmod 0755 "$MODPATH/$f"
done

# WebUI 静态资源需要可读
[ -d "$MODPATH/webroot" ] && chmod -R 0755 "$MODPATH/webroot"

# ---------- 安装时探测机型模式，打印到安装日志 ----------
_print "──────────────────────────────"
_print "自动旁路供电 · 机型适配检测"

NODE=""
for _p in \
  /sys/devices/platform/smart_charge/smart_night \
  /sys/devices/platform/*/smart_night \
  /sys/devices/platform/*/*/smart_night \
  /sys/class/power_supply/battery/night_charging \
  /sys/class/qcom-battery/night_charging
do
  for _f in $_p; do
    [ -e "$_f" ] && { NODE="$_f"; break 2; }
  done
done
[ -z "$NODE" ] && NODE=$(find /sys/devices -maxdepth 8 \( -name smart_night -o -name night_charging \) -type f 2>/dev/null | head -1)

if [ -z "$NODE" ]; then
  _print "✗ 未找到 smart_night 节点，本机型可能不支持"
  _print "  手动确认：find /sys/devices -maxdepth 7 -name smart_night"
else
  _print "✓ 控制节点：$NODE"
  _d=$(dirname "$NODE")
  if [ -e "$_d/soc_limit" ]; then
    _print "✓ 检测到 soc_limit → 【精确模式】"
    _print "  充电阈值 1-100% 全部可用"
  else
    _print "✓ 未检测到 soc_limit → 【兼容模式】"
    _print "  充电阈值最低 80%（厂商夜间充电上限）"
  fi
fi

# ---------- 保存节点原始值/权限，供卸载时还原 ----------
# 只在首次安装时记录一次（更新时已存在则跳过），确保记录的是系统出厂默认值，
# 而不是模块自己写进去的值。
DATA_DIR=/data/adb/bypass_charger
ORIG_ENV="$DATA_DIR/orig.env"
if [ -n "$NODE" ] && [ ! -f "$ORIG_ENV" ]; then
  mkdir -p "$DATA_DIR" 2>/dev/null
  _val=$(cat "$NODE" 2>/dev/null)
  _mode=$(stat -c '%a' "$NODE" 2>/dev/null)
  [ -z "$_val" ] && _val=0
  [ -z "$_mode" ] && _mode=644
  printf 'ORIG_NODE=%s\nORIG_NIGHT_VAL=%s\nORIG_NIGHT_MODE=%s\n' "$NODE" "$_val" "$_mode" > "$ORIG_ENV" 2>/dev/null
  _print "✓ 已记录节点原始值 $_val（权限 $_mode），卸载时自动还原"
fi

# ---------- 更新时保留用户自定义阈值 ----------
# 管理器更新模块会整体替换模块目录，导致 config.sh 被清空。
# 这里在更新（旧模块目录仍存在）时把旧配置复制到新模块目录，实现「保留阈值」。
OLD_CONF="/data/adb/modules/bypass_charger/config.sh"
if [ -f "$OLD_CONF" ] && [ "$OLD_CONF" != "$MODPATH/config.sh" ]; then
  cp "$OLD_CONF" "$MODPATH/config.sh" 2>/dev/null
  chmod 666 "$MODPATH/config.sh" 2>/dev/null
  _print "✓ 已保留你之前的阈值配置"
else
  _print "✓ 首次安装，将使用默认阈值（80% 停 / 75% 恢复）"
fi

_print "──────────────────────────────"
