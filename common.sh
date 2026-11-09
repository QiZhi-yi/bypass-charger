#!/system/bin/sh
# ============================================================
# 公共函数：充电控制节点写操作的串行化锁
#
# auto_bypass.sh（守护进程）与 webui.sh（KsuWebUI 后端）共用本文件，
# 确保它们写 soc_limit / smart_night 时拿的是同一把 flock 锁，
# 从根上杜绝两者并发写触发厂商充电驱动内核死锁。
#
# 死锁教训（2026-11-10）：测试脚本与守护进程并发写 soc_limit，
# 导致厂商充电驱动内部死锁，守护进程卡在 D 状态、杀不掉、插电不充。
# flock 串行化后，同一时刻只有一个进程在写节点。
# flock 用 -n 非阻塞：拿不到锁就立即放弃本次写入（守护进程下一轮巡检重试），
# 绝不阻塞等待，避免任何进程因等锁而卡死。
# 注意：Android（toybox）的 flock 不支持 -w 超时，故必须用 -n。
# ============================================================

MODULE_DIR="${MODULE_DIR:-/data/adb/modules/bypass_charger}"
NODE_LOCK="$MODULE_DIR/.node_lock"

# $1=节点路径 $2=待写值
# 返回 0 成功 / 非0 失败（节点不存在 或 拿锁失败 或 写失败）
write_node() {
  [ -z "$1" ] && return 1
  [ ! -e "$1" ] && return 1
  (
    flock -n 9 || return 1
    echo "$2" > "$1" 2>/dev/null
  ) 9>"$NODE_LOCK"
}
