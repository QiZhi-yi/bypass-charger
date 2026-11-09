#!/system/bin/sh
# ============================================================
# KsuWebUI 后端 —— 自动旁路供电 v10.3.5
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
# 充电控制节点写操作的串行化锁（与守护进程共用，杜绝并发写死锁）
. "$MODULE_DIR/common.sh"
# 配置放在模块目录外，更新模块时不会被清空
CONF_FILE="/data/adb/bypass_charger/config.sh"
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
    /sys/class/qcom-battery/night_charging
  do
    for _f in $_p; do
      if [ -e "$_f" ]; then
        echo "$_f" > "$NODE_CACHE" 2>/dev/null
        chmod 644 "$NODE_CACHE" 2>/dev/null
        echo "$_f"; return 0
      fi
    done
  done

  # 3. 兜底全盘搜一次（smart_night 或 night_charging 两种节点名）
  _f=$(find /sys/devices -maxdepth 8 \( -name smart_night -o -name night_charging \) -type f 2>/dev/null | head -1)
  if [ -n "$_f" ]; then
    echo "$_f" > "$NODE_CACHE" 2>/dev/null
    chmod 644 "$NODE_CACHE" 2>/dev/null
    echo "$_f"; return 0
  fi

  return 1
}

# ------------------------------------------------------------
# 配置：所有项统一放在 $CONF_FILE，每行行尾注释标明功能。
# 顺序固定，便于用户直接编辑；缺失项自动补默认值。
# ------------------------------------------------------------
CONF_KEYS="ENABLED ENABLE_THRESHOLD DISABLE_THRESHOLD CHECK_INTERVAL SCHEDULE_ENABLED SCHEDULE_START SCHEDULE_END"

conf_default() {
  case "$1" in
    ENABLED)            echo 1 ;;
    ENABLE_THRESHOLD)   echo 80 ;;
    DISABLE_THRESHOLD)  echo 75 ;;
    CHECK_INTERVAL)     echo 15 ;;
    SCHEDULE_ENABLED)   echo 0 ;;
    SCHEDULE_START)     echo "23:00" ;;
    SCHEDULE_END)       echo "07:00" ;;
  esac
}

conf_comment() {
  case "$1" in
    ENABLED)            echo "模块总开关：1=启用旁路 / 0=关闭（关闭后恢复充电）" ;;
    ENABLE_THRESHOLD)   echo "停止充电阈值(%)：电量升到此值开启旁路" ;;
    DISABLE_THRESHOLD)  echo "恢复充电阈值(%)：电量降到此值恢复充电，须低于停止阈值至少 5" ;;
    CHECK_INTERVAL)     echo "巡检间隔(秒)：插电时多久检查一次电量，5-600" ;;
    SCHEDULE_ENABLED)   echo "定时旁路开关：1=仅在下面时段启用 / 0=全天启用" ;;
    SCHEDULE_START)     echo "定时开始时间(HH:MM)" ;;
    SCHEDULE_END)       echo "定时结束时间(HH:MM)，跨午夜时填小于开始时间的值" ;;
  esac
}

# 取配置值：必须剥掉行尾注释，否则回读校验会带上注释导致误判写入失败
read_key() {
  grep "^$1=" "$CONF_FILE" 2>/dev/null | tail -1 | cut -d= -f2- | cut -d'#' -f1 | tr -d ' \t\r'
}

# 按固定顺序重写整份配置：$1/$2 为本次要写入的键与值（可省略＝仅规范化）
render_conf() {
  _out=""
  for _key in $CONF_KEYS; do
    _val=$(read_key "$_key")
    [ -z "$_val" ] && _val=$(conf_default "$_key")
    [ -n "$1" ] && [ "$_key" = "$1" ] && _val="$2"
    _out="$_out$_key=$_val  # $(conf_comment "$_key")
"
  done
  printf '%s' "$_out" > "$CONF_FILE" 2>/dev/null
  chmod 666 "$CONF_FILE" 2>/dev/null
}

ensure_conf() {
  if [ ! -f "$CONF_FILE" ]; then
    mkdir -p "/data/adb/bypass_charger" 2>/dev/null
    # 迁移旧版：旧配置在模块目录内（先把值读出来，再按新格式重写）
    _OLD_CONF="$MODULE_DIR/config.sh"
    [ -f "$_OLD_CONF" ] && cp "$_OLD_CONF" "$CONF_FILE" 2>/dev/null
  fi
  # 规范化：补齐缺失项、把行上方注释改成行尾注释。
  # 只在不合规时重写一次，之后每次 status 都是纯读，开销可忽略。
  _need=0
  for _key in $CONF_KEYS; do
    [ -z "$(read_key "$_key")" ] && _need=1
  done
  grep -q '  # ' "$CONF_FILE" 2>/dev/null || _need=1
  [ "$_need" = "1" ] && render_conf
}

# 原地重写配置：不用 sed -i（目录不可写会失败），直接整份重写，
# 同时保证顺序、注释、缺失项都正确。
write_conf() {
  render_conf "$1" "$2"
}

set_key() {
  k="$1"; v="$2"
  [ -z "$k" ] && { echo "ERR=no_key"; return 1; }
  # 仅允许已知键
  case "$k" in
    ENABLED|ENABLE_THRESHOLD|DISABLE_THRESHOLD|CHECK_INTERVAL|SCHEDULE_ENABLED|SCHEDULE_START|SCHEDULE_END) ;;
    *) echo "ERR=unknown_key"; return 1 ;;
  esac
  # 时间类型（HH:MM）与数值类型分别校验
  case "$k" in
    SCHEDULE_START|SCHEDULE_END)
      case "$v" in
        [01][0-9]:[0-5][0-9]|2[0-3]:[0-5][0-9]) ;;
        *) echo "ERR=bad_time"; return 1 ;;
      esac
      ;;
    *)
      case "$v" in
        ''|*[!0-9]*) echo "ERR=bad_value"; return 1 ;;
      esac
      ;;
  esac
  case "$k" in
    ENABLED|SCHEDULE_ENABLED) [ "$v" -gt 1 ] && { echo "ERR=bad_value"; return 1; } ;;
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

    # 版本号从 module.prop 动态读取，避免前端硬编码漏更新
    VER=$(sed -n 's/^version=//p' "$MODULE_DIR/module.prop" 2>/dev/null)
    [ -z "$VER" ] && VER="?"

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

    # 定时：判断当前是否在窗口内
    [ -z "$SCHEDULE_ENABLED" ] && SCHEDULE_ENABLED=0
    [ -z "$SCHEDULE_START" ] && SCHEDULE_START="23:00"
    [ -z "$SCHEDULE_END" ] && SCHEDULE_END="07:00"
    SCHED_ACTIVE=0
    if [ "$SCHEDULE_ENABLED" = "1" ]; then
      _now=$(date '+%H:%M')
      if [ "$SCHEDULE_START" \< "$SCHEDULE_END" ]; then
        { [ "$_now" \< "$SCHEDULE_START" ] || [ "$_now" \> "$SCHEDULE_END" ]; } || SCHED_ACTIVE=1
      else
        { [ "$_now" \< "$SCHEDULE_START" ] && [ "$_now" \> "$SCHEDULE_END" ]; } || SCHED_ACTIVE=1
      fi
    fi

    # 有效启用状态：主开关 AND（定时关 或 在窗口内）
    EFF_ENABLED=${ENABLED:-1}
    if [ "$SCHEDULE_ENABLED" = "1" ] && [ "$SCHED_ACTIVE" = "0" ]; then
      EFF_ENABLED=0
    fi

    # 必须输出单行！KernelSU 的同步 exec 只回传一行输出
    printf 'SUPPORTED=%s;NODE=%s;NODE_VAL=%s;CAP=%s;CHARGE_STATUS=%s;CURRENT=%s;TEMP=%s;ENABLED=%s;EFF_ENABLED=%s;ENABLE_THRESHOLD=%s;DISABLE_THRESHOLD=%s;CHECK_INTERVAL=%s;KSU_DISABLED=%s;DAEMON_PID=%s;DAEMON_ALIVE=%s;UID=%s;MODE=%s;VERSION=%s;SCHEDULE_ENABLED=%s;SCHEDULE_START=%s;SCHEDULE_END=%s;SCHEDULE_ACTIVE=%s\n' \
      "$SUP" "${NODE:-none}" "$NODE_VAL" "$CAP" "$PST" "$CUR" "$TMP" \
      "${ENABLED:-1}" "$EFF_ENABLED" "${ENABLE_THRESHOLD:-80}" "${DISABLE_THRESHOLD:-75}" \
      "${CHECK_INTERVAL:-15}" "$KDIS" "$PID" "$ALIVE" "$MYUID" "$MODE" "$VER" \
      "$SCHEDULE_ENABLED" "$SCHEDULE_START" "$SCHEDULE_END" "$SCHED_ACTIVE"
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

  wake)
    # WebUI 打开时调用：唤醒处于长睡的守护进程，立刻裁决一次并刷新状态。
    # status 本身即时读 sysfs，但旁路开关的裁决由守护进程负责，需要唤醒它。
    _dpid=$(cat "$PID_FILE" 2>/dev/null)
    if [ -n "$_dpid" ] && [ -d "/proc/$_dpid" ]; then
      kill -USR1 "$_dpid" 2>/dev/null
      echo "OK=woken"
    else
      echo "ERR=no_daemon"
    fi
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
    if [ -n "$PID" ]; then
      kill "$PID" 2>/dev/null          # TERM：让守护进程走 cleanup 自己释放锁
      i=0
      while [ -d "/proc/$PID" ] && [ "$i" -lt 15 ]; do
        sleep 0.2; i=$((i + 1))
      done
      # 仍活着才强杀，避免留僵尸进程继续写节点
      [ -d "/proc/$PID" ] && kill -9 "$PID" 2>/dev/null
      sleep 0.5
    fi
    # 进程确认退出后再兜底清理，避免误删新实例刚拿到的锁
    NODE=$(find_node)
    if [ -n "$NODE" ]; then
      write_node "$NODE" 0
      # 精确模式：放开 soc_limit，避免上限残留导致不充电
      _sd=$(dirname "$NODE")
      [ -e "$_sd/soc_limit" ] && write_node "$_sd/soc_limit" 100
    fi
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
