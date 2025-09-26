#!/bin/bash
# MCP包装脚本 - 用于支持动态路径
# 自动解析HOME环境变量并调用实际的browser-tools.sh脚本

# 获取实际的HOME目录
REAL_HOME="${HOME:-$PWD}"

# 构建实际脚本路径
SCRIPT_PATH="$REAL_HOME/browser-tools/browser-tools.sh"

# 检查脚本是否存在
if [ ! -f "$SCRIPT_PATH" ]; then
    echo "错误: 找不到脚本文件: $SCRIPT_PATH" >&2
    exit 1
fi

# 确保脚本有执行权限
chmod +x "$SCRIPT_PATH"

# 执行实际脚本，传递所有参数
exec "$SCRIPT_PATH" "$@"






