#!/bin/zsh
# Finder launcher; all checks and reporting live in the shared Python entrypoint.
cd "$(dirname "$0")" || exit 1
if (( $# )); then
    exec /usr/bin/python3 scripts/verify.py "$@"
fi
print "Percuscore 本地验收"
print "1. 快速检查（默认）"
print "2. 完整检查（会启动 iPad 模拟器）"
print "3. 发布检查（缺少性能或真机证据时会显示未完成）"
read "choice?选择 1 / 2 / 3，按回车开始快速检查："
case "$choice" in
    2) level=full ;;
    3) level=release ;;
    *) level=quick ;;
esac
/usr/bin/python3 scripts/verify.py --level "$level"
result=$?
print ""
read "answer?检查结束，按回车关闭。"
exit "$result"
