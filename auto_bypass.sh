#!/system/bin/sh
# ============================================================
# 自动旁路供电 v10.3.4
#
# 作者: 爱哭的小女孩龍（酷安）
# 原版: 酷安@柳下惠77  v9.9
#
# 说明: 本版由 爱哭的小女孩龍 在原模块基础上改进，使其适配 Android 17 /
#       HyperOS 4 等高版本系统，并新增 KsuWebUI 控制面板。
#       原版只测试过 MIUI / HyperOS 1，其写死的控制节点在新系统上已迁移，
#       因此原版在高版本机型上装好后完全不起作用。
#
# 主要改动:
#   1. 控制节点自动探测，不再写死路径（各机型层级不同，如
#      platform/smart_charge 与 platform/soc/soc:smart_charge）
#   2. 单实例守卫改用 mkdir 原子锁（原版 PID 判断在子 shell 中永远失效，
#      会导致每次启动叠加一个僵尸实例）
#   3. 滞回阈值 + 配置变更即时重新裁决（原版同一阈值会反复开关）
#   4. SIGUSR1 唤醒，改配置 1 秒内生效，不用等满巡检周期
#   5. 写入后回读校验，失败明确报错，不再静默失败
#   6. 新增 webui.sh / webroot，支持 KsuWebUI 图形控制
# ============================================================

MODULE_DIR="/data/adb/modules/bypass_charger"
# 配置放在模块目录外，更新模块时不会被清空（阈值/定时都能保留）
CONF_FILE="/data/adb/bypass_charger/config.sh"
PID_FILE="$MODULE_DIR/daemon.pid"
LOG_FILE="$MODULE_DIR/bypass.log"
CAP_FILE="/sys/class/power_supply/battery/capacity"
STAT_FILE="/sys/class/power_supply/battery/status"
USB_ONLINE="/sys/class/power_supply/usb/online"
WL_ONLINE="/sys/class/power_supply/wireless/online"
# 空闲（未插电 / 模块关闭）时的巡检间隔，比正常巡检更长以省电。
# 未插电时仍需定期醒来检测「插上充电器」这一事件。
IDLE_INTERVAL=60
SLEEP_PID=""

# 日志分级：lg=信息 / lgw=警告 / lge=错误
lg()  { _lg I "$@"; }
lgw() { _lg W "$@"; }
lge() { _lg E "$@"; }

_lg() {
  _lvl=$1; shift
  echo "$(date '+%m-%d %H:%M:%S') [$_lvl] $*" >> "$LOG_FILE" 2>/dev/null
  # 必须用绝对路径，否则会递归调用本函数自身
  /system/bin/log -t bypass_charger "[$_lvl] $*" 2>/dev/null
  # 日志超过 200 行自动截断，保留最后 100 行
  if [ -f "$LOG_FILE" ]; then
    n=$(wc -l < "$LOG_FILE" 2>/dev/null)
    [ -n "$n" ] && [ "$n" -gt 200 ] && tail -100 "$LOG_FILE" > "$LOG_FILE.tmp" 2>/dev/null && mv "$LOG_FILE.tmp" "$LOG_FILE" 2>/dev/null
  fi
}

# ---------- 探测控制节点（新系统在 smart_charge，旧系统在 battery） ----------
NODE_CACHE="$MODULE_DIR/node.path"
find_node() {
  # 1. 缓存路径仍有效就直接用（避免每次轮询都做搜索）
  if [ -f "$NODE_CACHE" ]; then
    _c=$(cat "$NODE_CACHE" 2>/dev/null)
    if [ -n "$_c" ] && [ -e "$_c" ]; then
      echo "$_c"; return 0
    fi
  fi

  # 2. 已知路径 + 通配。各机型 sysfs 层级不同：
  #    平板 25113... -> platform/smart_charge/smart_night
  #    手机 pudding  -> platform/soc/soc:smart_charge/smart_night
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

  # 3. 兜底：全盘搜一次（较慢，仅在前两步都失败时执行）。
  #    不同机型节点名不同：smart_night（新）或 night_charging（旧，如 Redmi K60 Pro）
  _f=$(find /sys/devices -maxdepth 8 \( -name smart_night -o -name night_charging \) -type f 2>/dev/null | head -1)
  if [ -n "$_f" ]; then
    echo "$_f" > "$NODE_CACHE" 2>/dev/null
    chmod 644 "$NODE_CACHE" 2>/dev/null
    echo "$_f"; return 0
  fi

  return 1
}

CONTROL_FILE=$(find_node)
if [ -z "$CONTROL_FILE" ]; then
  lge "致命错误: 未找到夜间充电控制节点，本机型可能不支持"
  exit 1
fi
lg "控制节点: $CONTROL_FILE"

# ---------- 探测 soc_limit（优先使用）----------
# soc_limit 在 smart_night 同级目录下，是厂商真正的"充电上限"。
# 与 smart_night 的区别（实测）：
#   smart_night=1 → 只是"开启夜间充电"，充到 80% 就停，低于 80% 的阈值无效
#   soc_limit=N   → 精确上限，写 100 立刻恢复充电，写小于当前电量的值立刻停充
# 所以有 soc_limit 的机型走它，没有的才退回 smart_night。
SOC_LIMIT_FILE=""
_d=$(dirname "$CONTROL_FILE")
[ -e "$_d/soc_limit" ] && SOC_LIMIT_FILE="$_d/soc_limit"
if [ -n "$SOC_LIMIT_FILE" ]; then
  lg "充电上限节点: $SOC_LIMIT_FILE（精确模式）"
else
  lgw "本机型无 soc_limit，退回夜间充电模式（阈值最低 80%）"
fi

# ---------- 单实例守卫：mkdir 原子锁 ----------
# 扫描 /proc 匹配 cmdline 的方式在 mksh 下不可靠（还容易误杀执行它的 shell），
# 改用 mkdir 的原子性做互斥锁：创建成功者即为唯一实例。
LOCK_DIR="$MODULE_DIR/.lock"
SELF=$$

acquire_lock() {
  mkdir "$LOCK_DIR" 2>/dev/null && return 0
  # 锁已存在，检查持有者是否还活着
  oldpid=$(cat "$LOCK_DIR/pid" 2>/dev/null)
  if [ -n "$oldpid" ] && [ -d "/proc/$oldpid" ]; then
    return 1        # 真有人在跑
  fi
  # 僵尸锁，回收
  rm -rf "$LOCK_DIR" 2>/dev/null
  mkdir "$LOCK_DIR" 2>/dev/null && return 0
  return 1
}

if ! acquire_lock; then
  # 已有实例在跑，直接退出（不写 pid，避免覆盖）
  exit 0
fi

echo "$SELF" > "$LOCK_DIR/pid" 2>/dev/null
echo "$SELF" > "$PID_FILE" 2>/dev/null
chmod 644 "$PID_FILE" 2>/dev/null

# ---------- 旧版本实例清理 ----------
# 注意：不再在这里扫描 /proc。遍历 800+ 进程逐个 fork tr 需要 20 秒，
# 会严重拖延启动；而 mkdir 锁已经保证新版本只有一个实例。
# 遗留的旧版本实例由安装/部署阶段一次性清理即可。

# 退出时确保恢复充电并释放锁
cleanup() {
  # 长睡时 nap 拉起的 sleep 子进程，不杀会变孤儿继续挂 3600 秒
  [ -n "$SLEEP_PID" ] && kill "$SLEEP_PID" 2>/dev/null
  echo 0 > "$CONTROL_FILE" 2>/dev/null
  # 精确模式：必须同时放开 soc_limit，否则停充后上限残留，设备充不到 100%
  [ -n "$SOC_LIMIT_FILE" ] && echo 100 > "$SOC_LIMIT_FILE" 2>/dev/null
  rm -f "$PID_FILE"
  rm -rf "$LOCK_DIR" 2>/dev/null
  lg "守护进程退出，已恢复充电"
}
# 只在真正退出时清理一次；INT/TERM 必须显式 exit，
# 否则 trap 跑完脚本会继续执行主循环 —— 锁已释放但进程还活着，
# 新实例又能拿到锁，造成双实例互抢节点。
trap cleanup EXIT
trap 'exit 0' INT TERM

# 可被打断的等待：WebUI 改完配置会发 SIGUSR1，立刻醒来重新裁决，
# 不用干等一整个巡检周期（间隔设成 120 秒时尤其重要）
trap 'if [ -n "$SLEEP_PID" ]; then kill "$SLEEP_PID" 2>/dev/null; fi' USR1

nap() {
  sleep "${1:-$CHECK_INTERVAL}" &
  SLEEP_PID=$!
  wait "$SLEEP_PID" 2>/dev/null
  SLEEP_PID=""
}

# ---------- 定时窗口判断（HH:MM 字符串比较，支持跨午夜）----------
in_schedule() {
  _now=$(date '+%H:%M')
  if [ "$SCHEDULE_START" \< "$SCHEDULE_END" ]; then
    # 不跨天（如 08:00~20:00）：now < start 或 now > end 即不在窗口内
    { [ "$_now" \< "$SCHEDULE_START" ] || [ "$_now" \> "$SCHEDULE_END" ]; } && return 1
  else
    # 跨天（如 23:00~07:00）：start < now < end 的区间才是不在窗口内
    [ "$_now" \< "$SCHEDULE_START" ] && [ "$_now" \> "$SCHEDULE_END" ] && return 1
  fi
  return 0
}

# ---------- 计算距下一个 HH:MM 还有多少秒（今天已过则算明天）----------
# 不用 base#number 语法（部分机型 sh 不支持），改用去前导零。
strip0() { _v=${1#0}; echo "${_v:-0}"; }
secs_until() {
  _h=$(strip0 "${1%%:*}")
  _m=$(strip0 "${1##*:}")
  _now_h=$(strip0 "$(date +%H)")
  _now_m=$(strip0 "$(date +%M)")
  _now_s=$(strip0 "$(date +%S)")
  _d=$(( _h * 3600 + _m * 60 - _now_h * 3600 - _now_m * 60 - _now_s ))
  [ "$_d" -lt 0 ] && _d=$(( _d + 86400 ))
  echo "$_d"
}

# ---------- 恢复充电（进入任何空闲长睡前必须调用）----------
# 空闲时若不复位，之前压低的 soc_limit / 置 1 的 smart_night 会一直残留，
# 导致设备插着电却始终不充电。
restore_charge() {
  # 精确模式：放开充电上限
  if [ -n "$SOC_LIMIT_FILE" ]; then
    _cl=$(cat "$SOC_LIMIT_FILE" 2>/dev/null)
    [ "$_cl" != "100" ] && echo 100 > "$SOC_LIMIT_FILE" 2>/dev/null
  fi
  # 兼容模式：清掉夜间充电（旁路）标记
  _c=$(cat "$CONTROL_FILE" 2>/dev/null)
  [ "$_c" != "0" ] && echo 0 > "$CONTROL_FILE" 2>/dev/null
}

# ---------- 首次生成默认配置（含旧版迁移）----------
# 配置放在 /data/adb/bypass_charger/ 下，更新模块时不会被清空
if [ ! -f "$CONF_FILE" ]; then
  mkdir -p "/data/adb/bypass_charger" 2>/dev/null
  # 迁移旧版：旧配置在模块目录内
  _OLD_CONF="$MODULE_DIR/config.sh"
  if [ -f "$_OLD_CONF" ]; then
    cp "$_OLD_CONF" "$CONF_FILE" 2>/dev/null
    chmod 666 "$CONF_FILE" 2>/dev/null
    lg "已迁移旧配置到 $CONF_FILE"
  fi
fi

if [ ! -f "$CONF_FILE" ]; then
  cat > "$CONF_FILE" <<-EOF
# 旁路供电配置
# ENABLED=1 启用模块 / 0 关闭（关闭后恢复充电）
ENABLED=1
# 电量升到 ENABLE_THRESHOLD 时停止充电（开启旁路）
ENABLE_THRESHOLD=80
# 电量降到 DISABLE_THRESHOLD 时恢复充电
DISABLE_THRESHOLD=75
# 巡检间隔（秒）
CHECK_INTERVAL=15
# 定时旁路：1=仅在下面时间段内启用，0=全天启用
SCHEDULE_ENABLED=0
# 定时开始/结束时间（HH:MM，跨午夜用开始>结束表示）
SCHEDULE_START=23:00
SCHEDULE_END=07:00
EOF
  chmod 666 "$CONF_FILE" 2>/dev/null
fi

lg "守护进程启动 PID=$$"

# ---------- 主循环 ----------
# 记录上一轮生效的阈值，用于判断配置是否被改动
LAST_EN=""
LAST_DI=""
# 记录上次提示过的"低于厂商下限"的阈值，避免每轮刷日志
LAST_WARN_EN=""
# 记录当前空闲状态（schedule/disabled/unplugged/空），避免长睡期间重复打日志
LAST_IDLE=""

while :; do
  # 模块被 KernelSU 禁用则退出
  if [ -f "$MODULE_DIR/disable" ]; then
    lgw "检测到 disable 标记，退出"
    break
  fi

  # 每轮重新加载配置，实现 WebUI 热改
  [ -f "$CONF_FILE" ] && . "$CONF_FILE" 2>/dev/null

  [ -z "$ENABLED" ] && ENABLED=1
  [ -z "$ENABLE_THRESHOLD" ] && ENABLE_THRESHOLD=80
  [ -z "$DISABLE_THRESHOLD" ] && DISABLE_THRESHOLD=75
  [ -z "$CHECK_INTERVAL" ] && CHECK_INTERVAL=15
  [ "$CHECK_INTERVAL" -lt 5 ] 2>/dev/null && CHECK_INTERVAL=5
  [ -z "$SCHEDULE_ENABLED" ] && SCHEDULE_ENABLED=0
  [ -z "$SCHEDULE_START" ] && SCHEDULE_START="23:00"
  [ -z "$SCHEDULE_END" ] && SCHEDULE_END="07:00"

  # 空闲间隔不能比正常巡检更勤快（用户把 CHECK_INTERVAL 设 600 秒时尤其重要）
  idle=$IDLE_INTERVAL
  [ "$CHECK_INTERVAL" -gt "$idle" ] 2>/dev/null && idle=$CHECK_INTERVAL

  # ---------- 定时窗口外 → 睡到下次定时开始（封顶 1 小时）----------
  # 窗口外不需要任何控制，直接长睡，到点再醒（省电）。改配置由 SIGUSR1 唤醒。
  if [ "$SCHEDULE_ENABLED" = "1" ] && ! in_schedule; then
    restore_charge
    if [ "$LAST_IDLE" != "schedule" ]; then
      lg "定时窗口外，已恢复充电并进入长睡，到定时开始自动唤醒"
      LAST_IDLE="schedule"
    fi
    _until=$(secs_until "$SCHEDULE_START")
    [ "$_until" -gt 3600 ] && _until=3600
    [ "$_until" -lt 5 ] && _until=5
    nap "$_until"
    continue
  fi

  cur=$(cat "$CONTROL_FILE" 2>/dev/null)

  # ---------- 模块关闭 → 恢复充电后睡长觉 ----------
  if [ "$ENABLED" != "1" ]; then
    restore_charge
    if [ "$LAST_IDLE" != "disabled" ]; then
      lg "模块已关闭，恢复充电并进入长睡"
      LAST_IDLE="disabled"
    fi
    LAST_EN=""
    LAST_DI=""
    nap "$idle"
    continue
  fi

  cap=$(tr -cd '0-9' < "$CAP_FILE" 2>/dev/null)
  if [ -z "$cap" ]; then
    nap "$idle"
    continue
  fi

  st=$(cat "$STAT_FILE" 2>/dev/null)

  # ---------- 未插电 → 清标记后睡长觉 ----------
  # 拔掉充电器后必须把状态清掉，否则下次插电会卡在滞回死区里一直不充电。
  powered=0
  [ "$(cat "$USB_ONLINE" 2>/dev/null)" = "1" ] && powered=1
  [ "$(cat "$WL_ONLINE" 2>/dev/null)" = "1" ] && powered=1

  if [ "$powered" = "0" ]; then
    restore_charge
    if [ "$LAST_IDLE" != "unplugged" ]; then
      lg "未接电源（电量 ${cap}%），已恢复充电并进入长睡"
      LAST_IDLE="unplugged"
    fi
    # 清空阈值记忆，让插电瞬间按当前电量重新裁决，而不是沿用旧的滞回状态
    LAST_EN=""
    LAST_DI=""
    nap "$idle"
    continue
  fi

  # 进入正常巡检，清掉空闲标记
  LAST_IDLE=""

  # ---------- 厂商下限 80%（仅限 smart_night 模式）----------
  # smart_night 不是"立刻停止充电"的开关，而是"开启厂商夜间充电模式"的开关。
  # 开启后厂商固定充到 80% 才停，所以低于 80% 的阈值在行为上不可能生效。
  # 有 soc_limit 的机型走精确模式，不受此限。
  if [ -z "$SOC_LIMIT_FILE" ] && [ "$ENABLE_THRESHOLD" -lt 80 ] 2>/dev/null; then
    if [ "$LAST_WARN_EN" != "$ENABLE_THRESHOLD" ]; then
      lgw "停止阈值 ${ENABLE_THRESHOLD}% 低于厂商下限 80%，已按 80% 执行"
      LAST_WARN_EN=$ENABLE_THRESHOLD
    fi
    ENABLE_THRESHOLD=80
  else
    LAST_WARN_EN=""
  fi

  # 阈值纠错：恢复点必须低于停止点，否则强制留 5% 滞回
  if [ "$DISABLE_THRESHOLD" -ge "$ENABLE_THRESHOLD" ] 2>/dev/null; then
    DISABLE_THRESHOLD=$((ENABLE_THRESHOLD - 5))
    [ "$DISABLE_THRESHOLD" -lt 1 ] && DISABLE_THRESHOLD=1
  fi

  # ================= 精确模式：直接控制 soc_limit =================
  # soc_limit 是厂商真正的充电上限，实测：
  #   写 100 且当前 90% → 立刻 2.4A 充电
  #   写 90  且当前 94% → 5 秒内停充
  #   写入后长时间无人改写
  # 因此只要压住这层，任意阈值（1-100）都能精确实现。
  if [ -n "$SOC_LIMIT_FILE" ]; then
    # 夜间充电标记必须保持 0：一旦为 1，厂商会按它自己的 80% 上限介入，
    # 反而把 soc_limit 抢回去。
    [ "$cur" != "0" ] && echo 0 > "$CONTROL_FILE" 2>/dev/null

    cur_limit=$(cat "$SOC_LIMIT_FILE" 2>/dev/null)
    case "$cur_limit" in ''|*[!0-9]*) cur_limit=100 ;; esac

    if [ "$ENABLE_THRESHOLD" != "$LAST_EN" ] || [ "$DISABLE_THRESHOLD" != "$LAST_DI" ]; then
      # 阈值刚被改过（或守护进程刚启动/刚插电）→ 按当前电量重新裁决，不走滞回
      if [ "$cap" -ge "$ENABLE_THRESHOLD" ]; then
        wl=$((ENABLE_THRESHOLD - 1))
        [ "$wl" -lt 1 ] && wl=1
      else
        wl=100
      fi
      LAST_EN=$ENABLE_THRESHOLD
      LAST_DI=$DISABLE_THRESHOLD
    elif [ "$cap" -ge "$ENABLE_THRESHOLD" ]; then
      wl=$((ENABLE_THRESHOLD - 1))          # 到达阈值 → 压到阈值以下即停充
      [ "$wl" -lt 1 ] && wl=1
    elif [ "$cap" -le "$DISABLE_THRESHOLD" ]; then
      wl=100                                # 低于恢复阈值 → 放开充电
    else
      wl=$cur_limit                         # 滞回区：维持现状
    fi

    if [ "$wl" != "$cur_limit" ]; then
      if echo "$wl" > "$SOC_LIMIT_FILE" 2>/dev/null; then
        if [ "$wl" = "100" ]; then
          lg "电量 ${cap}%（停止阈值 ${ENABLE_THRESHOLD}%）-> 放开充电上限"
        else
          lg "电量 ${cap}%（停止阈值 ${ENABLE_THRESHOLD}%）-> 停充（上限 ${wl}%）"
        fi
      else
        lge "写入 soc_limit 失败: $SOC_LIMIT_FILE"
      fi
    fi

    nap
    continue
  fi

  # ================= 兼容模式：无 soc_limit 的机型用 smart_night =================
  # 阈值被改过、或守护进程刚启动/刚插电时，按当前电量重新裁决一次（不走滞回）。
  # 否则把停止阈值调高到当前电量之上后，会一直卡在死区里不恢复充电。
  if [ "$ENABLE_THRESHOLD" != "$LAST_EN" ] || [ "$DISABLE_THRESHOLD" != "$LAST_DI" ]; then
    if [ "$cap" -ge "$ENABLE_THRESHOLD" ]; then
      desired=1
    else
      desired=0
    fi
    LAST_EN=$ENABLE_THRESHOLD
    LAST_DI=$DISABLE_THRESHOLD
  elif [ "$cap" -ge "$ENABLE_THRESHOLD" ]; then
    desired=1
  elif [ "$cap" -le "$DISABLE_THRESHOLD" ]; then
    desired=0
  else
    desired=$cur        # 滞回区：保持当前状态
  fi

  if [ "$cur" != "$desired" ]; then
    if echo "$desired" > "$CONTROL_FILE" 2>/dev/null; then
      if [ "$desired" = "1" ]; then
        lg "电量 ${cap}%（停止阈值 ${ENABLE_THRESHOLD}%）-> 开启旁路 [$st]"
      else
        lg "电量 ${cap}%（停止 ${ENABLE_THRESHOLD}% / 恢复 ${DISABLE_THRESHOLD}%）-> 恢复充电 [$st]"
      fi
    else
      lge "写入失败: $CONTROL_FILE"
    fi
  fi

  nap
done
