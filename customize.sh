SKIPUNZIP=0

# 打印到安装日志（Magisk/KernelSU 都支持 ui_print）
_print() {
  if type ui_print >/dev/null 2>&1; then ui_print "$@"; else echo "$@"; fi
}

# ---------- 打印模块与作者信息 ----------
_print "──────────────────────────────"
_print "  自动旁路供电"
_print "  作者：爱哭的小女孩龍（酷安）"
_print "  原作者：酷安@柳下惠77（原版 v9.9）"
_print "  项目：github.com/QiZhi-yi/bypass-charger"
_print "──────────────────────────────"

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
  # 精确模式还要记录 soc_limit 原始值，卸载时一并还原
  _soc_dir=$(dirname "$NODE")
  if [ -e "$_soc_dir/soc_limit" ]; then
    _soc_file="$_soc_dir/soc_limit"
    _soc_val=$(cat "$_soc_file" 2>/dev/null)
    printf 'ORIG_NODE=%s\nORIG_NIGHT_VAL=%s\nORIG_NIGHT_MODE=%s\nORIG_SOC_FILE=%s\nORIG_SOC_VAL=%s\n' \
      "$NODE" "$_val" "$_mode" "$_soc_file" "$_soc_val" > "$ORIG_ENV" 2>/dev/null
  else
    printf 'ORIG_NODE=%s\nORIG_NIGHT_VAL=%s\nORIG_NIGHT_MODE=%s\n' \
      "$NODE" "$_val" "$_mode" > "$ORIG_ENV" 2>/dev/null
  fi
  _print "✓ 已记录节点原始值，卸载时自动还原"
fi

# ---------- 配置迁移到模块目录外（更新时不会被清空）----------
# 配置统一放在 /data/adb/bypass_charger/config.sh。管理器更新只替换模块目录，
# 不会碰这里，所以阈值、定时等设置都能完整保留。
CONF_DIR="/data/adb/bypass_charger"
OLD_CONF="/data/adb/modules/bypass_charger/config.sh"
if [ ! -f "$CONF_DIR/config.sh" ] && [ -f "$OLD_CONF" ]; then
  mkdir -p "$CONF_DIR" 2>/dev/null
  cp "$OLD_CONF" "$CONF_DIR/config.sh" 2>/dev/null
  chmod 666 "$CONF_DIR/config.sh" 2>/dev/null
  _print "✓ 已迁移并保留你之前的阈值/定时配置"
elif [ -f "$CONF_DIR/config.sh" ]; then
  _print "✓ 已保留现有配置（更新不影响）"
else
  _print "✓ 首次安装，将使用默认阈值（80% 停 / 75% 恢复）"
fi

_print "──────────────────────────────"
