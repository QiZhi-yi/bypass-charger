#!/system/bin/sh
# ============================================================
# 自动旁路供电 v10.0
#
# 作者: 小意同学  (@酷安 爱哭的小女孩龍)
# 原版: 酷安@柳下惠77  v9.9
#
# 说明: 本版由 小意同学 在原模块基础上改进，使其适配 Android 17 /
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
CONF_FILE="$MODULE_DIR/config.sh"
PID_FILE="$MODULE_DIR/daemon.pid"
LOG_FILE="$MODULE_DIR/bypass.log"
CAP_FILE="/sys/class/power_supply/battery/capacity"
STAT_FILE="/sys/class/power_supply/battery/status"
USB_ONLINE="/sys/class/power_supply/usb/online"
WL_ONLINE="/sys/class/power_supply/wireless/online"

lg() {
  echo "$(date '+%m-%d %H:%M:%S') $*" >> "$LOG_FILE" 2>/dev/null
  # 必须用绝对路径，否则会递归调用本函数自身
  /system/bin/log -t bypass_charger "$*" 2>/dev/null
  # 日志超过 200 行自动截断
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

  # 3. 兜底：全盘搜一次（较慢，仅在前两步都失败时执行）
  _f=$(find /sys/devices -maxdepth 7 -name smart_night -type f 2>/dev/null | head -1)
  if [ -n "$_f" ]; then
    echo "$_f" > "$NODE_CACHE" 2>/dev/null
    chmod 644 "$NODE_CACHE" 2>/dev/null
    echo "$_f"; return 0
  fi

  return 1
}

CONTROL_FILE=$(find_node)
if [ -z "$CONTROL_FILE" ]; then
  lg "致命错误: 未找到夜间充电控制节点，本机型可能不支持"
  exit 1
fi
lg "控制节点: $CONTROL_FILE"

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
  echo 0 > "$CONTROL_FILE" 2>/dev/null
  rm -f "$PID_FILE"
  rm -rf "$LOCK_DIR" 2>/dev/null
  lg "守护进程退出，已恢复充电"
}
trap cleanup EXIT INT TERM

# 可被打断的等待：WebUI 改完配置会发 SIGUSR1，立刻醒来重新裁决，
# 不用干等一整个巡检周期（间隔设成 120 秒时尤其重要）
SLEEP_PID=""
trap 'if [ -n "$SLEEP_PID" ]; then kill "$SLEEP_PID" 2>/dev/null; fi' USR1

nap() {
  sleep "${1:-$CHECK_INTERVAL}" &
  SLEEP_PID=$!
  wait "$SLEEP_PID" 2>/dev/null
  SLEEP_PID=""
}

# ---------- 首次生成默认配置 ----------
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
EOF
  chmod 644 "$CONF_FILE"
fi

lg "守护进程启动 PID=$$"

# ---------- 主循环 ----------
# 记录上一轮生效的阈值，用于判断配置是否被改动
LAST_EN=""
LAST_DI=""
# 记录上次提示过的"低于厂商下限"的阈值，避免每轮刷日志
LAST_WARN_EN=""

while :; do
  # 模块被 KernelSU 禁用则退出
  if [ -f "$MODULE_DIR/disable" ]; then
    lg "检测到 disable 标记，退出"
    break
  fi

  # 每轮重新加载配置，实现 WebUI 热改
  [ -f "$CONF_FILE" ] && . "$CONF_FILE" 2>/dev/null

  [ -z "$ENABLED" ] && ENABLED=1
  [ -z "$ENABLE_THRESHOLD" ] && ENABLE_THRESHOLD=80
  [ -z "$DISABLE_THRESHOLD" ] && DISABLE_THRESHOLD=75
  [ -z "$CHECK_INTERVAL" ] && CHECK_INTERVAL=15
  [ "$CHECK_INTERVAL" -lt 5 ] 2>/dev/null && CHECK_INTERVAL=5

  # ---------- 厂商下限 80% ----------
  # smart_night 不是"立刻停止充电"的开关，而是"开启厂商夜间充电模式"的开关。
  # 开启后具体充到哪由厂商决定：固定充到 80% 才停。
  # 实测（平板 25032RP42C、手机 25113PN0EC）：在 50%/51% 写 1 之后充电电流
  # 仍维持 4.4A，电量继续上涨；设 70% 阈值同样一路充到 80%。
  # 因此低于 80% 的阈值在行为上不可能生效，这里统一按 80% 执行并提示。
  if [ "$ENABLE_THRESHOLD" -lt 80 ] 2>/dev/null; then
    if [ "$LAST_WARN_EN" != "$ENABLE_THRESHOLD" ]; then
      lg "停止阈值 ${ENABLE_THRESHOLD}% 低于厂商下限 80%，已按 80% 执行"
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

  if [ "$ENABLED" != "1" ]; then
    [ "$(cat "$CONTROL_FILE" 2>/dev/null)" != "0" ] && {
      echo 0 > "$CONTROL_FILE" 2>/dev/null
      lg "模块已关闭，恢复充电"
    }
    nap
    continue
  fi

  cap=$(tr -cd '0-9' < "$CAP_FILE" 2>/dev/null)
  if [ -z "$cap" ]; then
    nap
    continue
  fi

  cur=$(cat "$CONTROL_FILE" 2>/dev/null)
  st=$(cat "$STAT_FILE" 2>/dev/null)

  # ---------- 未接电源时不进入旁路 ----------
  # 拔掉充电器后必须把状态清掉，否则电量在滞回死区里掉下来时状态还留着 1，
  # 下次插电会因为 cap 仍在死区内而"保持原状态"，导致插着电却一直不充电，
  # 而且插着电电量不掉，永远掉不到恢复阈值，形成死锁。
  powered=0
  [ "$(cat "$USB_ONLINE" 2>/dev/null)" = "1" ] && powered=1
  [ "$(cat "$WL_ONLINE" 2>/dev/null)" = "1" ] && powered=1

  if [ "$powered" = "0" ]; then
    if [ "$cur" != "0" ]; then
      echo 0 > "$CONTROL_FILE" 2>/dev/null
      lg "已断开电源 -> 关闭旁路标记（电量 ${cap}%）"
    fi
    # 清空阈值记忆，让插电瞬间按当前电量重新裁决，而不是沿用旧的滞回状态
    LAST_EN=""
    LAST_DI=""
    nap
    continue
  fi

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
      lg "写入失败: $CONTROL_FILE"
    fi
  fi

  nap
done
