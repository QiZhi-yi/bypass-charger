#!/system/bin/sh
# 启动器 —— 自动旁路供电 v10.1.3
# 作者: 爱哭的小女孩龍（酷安）
# 开机后等待系统就绪，再拉起守护进程；单实例由守护进程的 mkdir 锁保证。
MODDIR=${0%/*}

(
  # 等待开机完成
  i=0
  while [ "$(getprop sys.boot_completed)" != "1" ] && [ $i -lt 120 ]; do
    sleep 2
    i=$((i + 1))
  done
  sleep 10

  # 直接交给守护进程，单实例由它的 mkdir 锁保证
  exec sh "$MODDIR/auto_bypass.sh"
) &
