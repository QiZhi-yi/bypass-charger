SKIPUNZIP=0

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
