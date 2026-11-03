#!/system/bin/sh
# ============================================================
# KsuWebUI 后端 —— 自动旁路供电 v10.1.1
#
# 作者: 爱哭的小女孩龍（酷安）
# 原版: 酷安@柳下惠77  v9.9（原版无 WebUI，本文件为新增）
#
# 所有读写逻辑集中在这里，前端只负责展示。
# 用法:
#   sh webui.sh status              输出单行状态（; 分隔的 KV）
#   sh webui.sh set KEY VALUE       写配置并回读校验
#   sh webui.sh log                 输出日志（换行转义为 \n）
#   sh webui.sh start|stop          启停守护进程
#
# 注意: KernelSU 的 ksu.exec 同步接口只回传一行输出，
#       所以这里所有命令都必须只输出单行。
# ============================================================

MODULE_DIR="/data/adb/modules/bypass_charger"
CONF_FILE="$MODULE_DIR/config.sh"
PID_FILE="$MODULE_DIR/daemon.pid"
LOG_FILE="$MODULE_DIR/bypass.log"
CAP_FILE="/sys/class/power_supply/battery/capacity"
STAT_FILE="/sys/class/power_supply/battery/status"
CUR_FILE="/sys/class/power_supply/battery/current_now"
TEMP_FILE="/sys/class/power_supply/battery/temp"

NODE_CACHE="$MODULE_DIR/node.path"

find_node() {
  # 1. 缓存路径仍有效就直接用
  if [ -f "$NODE_CACHE" ]; then
    _c=$(cat "$NODE_CACHE" 2>/dev/null)
    if [ -n "$_c" ] && [ -e "$_c" ]; then
      echo "$_c"; return 0
    fi
  fi

  # 2. 已知路径 + 通配（各机型 sysfs 层级不同）
  for _p in \
    /sys/devices/platform/smart_charge/smart_night \
    /sys/devices/platform/*/smart_night \
    /sys/devices/platform/*/*/smart_night \
    /sys/class/power_supply/battery/night_charging \
    /sys/class/power_supply/battery/night_charging_mode \
    /sys/class/power_supply/battery/charge_control_end_threshold
  do
    for _f in $_p; do
      if [ -e "$_f" ]; then
        echo "$_f" > "$NODE_CACHE" 2>/dev/null
        chmod 644 "$NODE_CACHE" 2>/dev/null
        echo "$_f"; return 0
      fi
    done
  done

  # 3. 兜底全盘搜一次
  _f=$(find /sys/devices -maxdepth 7 -name smart_night -type f 2>/dev/null | head -1)
  if [ -n "$_f" ]; then
    echo "$_f" > "$NODE_CACHE" 2>/dev/null
    echo "$_f"; return 0
  fi

  return 1
}

ensure_conf() {
  [ -f "$CONF_FILE" ] && return
  cat > "$CONF_FILE" <<-EOF
ENABLED=1
ENABLE_THRESHOLD=80
DISABLE_THRESHOLD=75
CHECK_INTERVAL=15
EOF
  # 666：WebUI 的执行身份未必是 root，放开写权限让配置文件能被改
  chmod 666 "$CONF_FILE" 2>/dev/null
}

# 原地重写配置：不用 sed -i（它需要在目录里建临时文件，目录不可写就失败），
# 也不需要目录写权限，只要文件本身可写即可。
write_conf() {
  _k="$1"; _v="$2"
  _new=""
  _found=0
  while IFS= read -r _line || [ -n "$_line" ]; do
    case "$_line" in
      "$_k="*)
        _new="$_new$_k=$_v
"
        _found=1
        ;;
      *)
        _new="$_new$_line
"
        ;;
    esac
  done < "$CONF_FILE"
  [ "$_found" = "0" ] && _new="$_new$_k=$_v
"
  printf '%s' "$_new" > "$CONF_FILE" 2>/dev/null
}

read_key() {
  grep "^$1=" "$CONF_FILE" 2>/dev/null | tail -1 | cut -d= -f2-
}

set_key() {
  k="$1"; v="$2"
  [ -z "$k" ] && { echo "ERR=no_key"; return 1; }
  # 仅允许已知键
  case "$k" in
    ENABLED|ENABLE_THRESHOLD|DISABLE_THRESHOLD|CHECK_INTERVAL) ;;
    *) echo "ERR=unknown_key"; return 1 ;;
  esac
  # 数值校验
  case "$v" in
    ''|*[!0-9]*) echo "ERR=bad_value"; return 1 ;;
  esac
  case "$k" in
    ENABLED) [ "$v" -gt 1 ] && { echo "ERR=bad_value"; return 1; } ;;
    ENABLE_THRESHOLD|DISABLE_THRESHOLD)
      [ "$v" -lt 1 ] || [ "$v" -gt 100 ] && { echo "ERR=out_of_range"; return 1; }
      ;;
    CHECK_INTERVAL) { [ "$v" -lt 5 ] || [ "$v" -gt 600 ]; } && { echo "ERR=out_of_range"; return 1; } ;;
  esac

  ensure_conf
  write_conf "$k" "$v"

  # 回读校验：写不进去就放开权限再试一次
  if [ "$(read_key "$k")" != "$v" ]; then
    chmod 666 "$CONF_FILE" 2>/dev/null
    write_conf "$k" "$v"
  fi

  if [ "$(read_key "$k")" = "$v" ]; then
    echo "OK=$k=$v"
  else
    # 把失败原因一并返回，前端会显示出来
    echo "ERR=write_failed:$k uid=$(id -u 2>/dev/null)"
  fi
}

case "$1" in
  status)
    # 诊断：把执行身份与工作目录打到 logcat，方便排查权限问题
    MYUID=$(id -u 2>/dev/null)
    /system/bin/log -t bypass_webui "status uid=$MYUID cwd=$(pwd 2>/dev/null)" 2>/dev/null

    ensure_conf
    . "$CONF_FILE" 2>/dev/null

    NODE=$(find_node)
    [ -z "$NODE" ] && SUP=0 || SUP=1

    # 有 soc_limit 走精确模式（任意阈值），否则退回夜间充电模式（最低 80%）
    MODE=compat
    if [ -n "$NODE" ] && [ -e "$(dirname "$NODE")/soc_limit" ]; then MODE=precise; fi

    NODE_VAL=$(cat "$NODE" 2>/dev/null);      [ -z "$NODE_VAL" ] && NODE_VAL=-1
    CAP=$(cat "$CAP_FILE" 2>/dev/null);       [ -z "$CAP" ] && CAP=0
    PST=$(cat "$STAT_FILE" 2>/dev/null);      [ -z "$PST" ] && PST=unknown
    CUR=$(cat "$CUR_FILE" 2>/dev/null);       [ -z "$CUR" ] && CUR=0
    TMP=$(cat "$TEMP_FILE" 2>/dev/null);      [ -z "$TMP" ] && TMP=0

    PID=$(cat "$PID_FILE" 2>/dev/null)
    if [ -n "$PID" ] && [ -d "/proc/$PID" ]; then
      ALIVE=1
    else
      ALIVE=0
      [ -z "$PID" ] && PID=none
    fi

    [ -f "$MODULE_DIR/disable" ] && KDIS=1 || KDIS=0

    # 必须输出单行！KernelSU 的同步 exec 只回传一行输出
    printf 'SUPPORTED=%s;NODE=%s;NODE_VAL=%s;CAP=%s;CHARGE_STATUS=%s;CURRENT=%s;TEMP=%s;ENABLED=%s;ENABLE_THRESHOLD=%s;DISABLE_THRESHOLD=%s;CHECK_INTERVAL=%s;KSU_DISABLED=%s;DAEMON_PID=%s;DAEMON_ALIVE=%s;UID=%s;MODE=%s\n' \
      "$SUP" "${NODE:-none}" "$NODE_VAL" "$CAP" "$PST" "$CUR" "$TMP" \
      "${ENABLED:-1}" "${ENABLE_THRESHOLD:-80}" "${DISABLE_THRESHOLD:-75}" \
      "${CHECK_INTERVAL:-15}" "$KDIS" "$PID" "$ALIVE" "$MYUID" "$MODE"
    ;;

  set)
    _old=$(read_key "$2")
    _r=$(set_key "$2" "$3")
    # 记录真实执行情况，便于排查"设置不生效"
    /system/bin/log -t bypass_webui "set $2=$3 old=$_old result=$_r uid=$(id -u 2>/dev/null)" 2>/dev/null
    # 同时写文件：logcat 环形缓冲会被冲掉，文件不会，排查时更可靠
    _wl="$MODULE_DIR/webui.log"
    echo "$(date '+%m-%d %H:%M:%S') set $2=$3 old=$_old result=$_r uid=$(id -u 2>/dev/null)" >> "$_wl" 2>/dev/null
    _n=$(wc -l < "$_wl" 2>/dev/null)
    [ -n "$_n" ] && [ "$_n" -gt 300 ] && tail -150 "$_wl" > "$_wl.tmp" 2>/dev/null && mv "$_wl.tmp" "$_wl" 2>/dev/null
    # 通知守护进程立刻重新裁决，不必等满一个巡检周期
    _dpid=$(cat "$PID_FILE" 2>/dev/null)
    [ -n "$_dpid" ] && kill -USR1 "$_dpid" 2>/dev/null
    echo "$_r"
    ;;

  start)
    # 手动拉起守护进程（配置里 ENABLED 保持原样）
    if [ -n "$(cat "$PID_FILE" 2>/dev/null)" ] && [ -d "/proc/$(cat "$PID_FILE" 2>/dev/null)" ] 2>/dev/null; then
      echo "OK=already_running"
    else
      ( sh "$MODULE_DIR/auto_bypass.sh" >/dev/null 2>&1 & )
      sleep 1
      echo "OK=started"
    fi
    ;;

  stop)
    PID=$(cat "$PID_FILE" 2>/dev/null)
    [ -n "$PID" ] && kill "$PID" 2>/dev/null
    sleep 1
    rm -rf "$MODULE_DIR/.lock" "$PID_FILE"
    NODE=$(find_node)
    [ -n "$NODE" ] && echo 0 > "$NODE" 2>/dev/null
    echo "OK=stopped"
    ;;

  log)
    # 同样输出单行：换行用字面量 \n 转义，前端再还原
    if [ -f "$LOG_FILE" ]; then
      printf 'LOG='
      tail -n 40 "$LOG_FILE" | awk '{printf "%s\\n", $0}'
      printf '\n'
    else
      echo 'LOG=(暂无日志)'
    fi
    ;;

  *)
    echo "ERR=unknown_command"
    ;;
esac
