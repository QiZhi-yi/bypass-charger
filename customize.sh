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
for f in auto_bypass.sh service.sh webui.sh; do
  [ -f "$MODPATH/$f" ] && chmod 0755 "$MODPATH/$f"
done

# WebUI 静态资源需要可读
[ -d "$MODPATH/webroot" ] && chmod -R 0755 "$MODPATH/webroot"

# ---------- 安装时探测机型模式，打印到安装日志 ----------
_print "──────────────────────────────"
_print "自动旁路供电 · 机型适配检测"

NODE=$(find /sys/devices -maxdepth 8 -name smart_night -type f 2>/dev/null | head -1)

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
_print "──────────────────────────────"
