#!/bin/bash

# 手动清理MCP服务进程脚本
# 用于立即清理当前运行的MCP服务进程

# 获取脚本所在目录的绝对路径
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "🧹 开始手动清理MCP服务进程..."

# 查找所有browser-tools-server进程
echo "🔍 查找运行中的browser-tools-server进程..."
server_pids=$(ps -ef | grep "browser-tools-server" | grep -v grep | awk '{print $2}' | tr '\n' ' ')

if [ -n "$server_pids" ]; then
    echo "发现以下server进程: $server_pids"
    
    # 显示进程详情
    echo "进程详情:"
    ps -ef | grep "browser-tools-server" | grep -v grep
    
    echo ""
    echo "🛑 正在终止server进程..."
    
    # 先尝试优雅终止
    for pid in $server_pids; do
        echo "终止进程 $pid..."
        kill -TERM "$pid" 2>/dev/null || true
    done
    
    # 等待2秒
    sleep 2
    
    # 检查是否还有进程在运行
    remaining_pids=$(ps -ef | grep "browser-tools-server" | grep -v grep | awk '{print $2}' | tr '\n' ' ')
    
    if [ -n "$remaining_pids" ]; then
        echo "⚠️ 仍有进程未终止，使用强制终止: $remaining_pids"
        for pid in $remaining_pids; do
            echo "强制终止进程 $pid..."
            kill -KILL "$pid" 2>/dev/null || true
        done
        
        sleep 1
        
        # 最终检查
        final_count=$(ps -ef | grep "browser-tools-server" | grep -v grep | wc -l | tr -d ' ')
        if [ "$final_count" -eq 0 ]; then
            echo "✅ 所有server进程已成功终止"
        else
            echo "❌ 仍有 $final_count 个进程未能终止"
        fi
    else
        echo "✅ 所有server进程已成功终止"
    fi
else
    echo "ℹ️ 未发现运行中的browser-tools-server进程"
fi

echo ""
echo "🧹 清理临时文件..."

# 清理所有相关临时文件
rm -f "$SCRIPT_DIR/logs/browser-tools-shared-server.pid"
rm -f "$SCRIPT_DIR/logs/browser-tools-all-pids.txt"
rm -f "$SCRIPT_DIR/logs/browser-tools-mcp.pid"
rm -f "$SCRIPT_DIR/logs/browser-tools-shared.lock"
rm -f "$SCRIPT_DIR/logs/browser-tools-client-count.txt"
rm -f "$SCRIPT_DIR/logs/browser-tools-ref-count.lock"
rm -f "$SCRIPT_DIR/logs/browser-tools-mcp-monitor.pid"

echo "✅ 临时文件清理完成"

echo ""
echo "📊 最终状态检查:"
server_count=$(ps -ef | grep "browser-tools-server" | grep -v grep | wc -l | tr -d ' ')
echo "当前browser-tools-server进程数: $server_count"

if [ "$server_count" -eq 0 ]; then
    echo "🎉 MCP服务清理完成！"
else
    echo "⚠️ 仍有 $server_count 个进程在运行，请手动检查"
fi
