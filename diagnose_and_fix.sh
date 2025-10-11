#!/bin/bash

# Browser Tools 诊断和修复脚本

# 获取脚本所在目录
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REF_COUNT_MANAGER="$SCRIPT_DIR/mcp_ref_count_manager.sh"

echo "=========================================="
echo "Browser Tools 系统诊断"
echo "=========================================="
echo ""

# 1. 检查server进程
echo "1. 检查server进程状态："
server_processes=$(ps aux | grep "browser-tools-server" | grep -v grep)
if [ -n "$server_processes" ]; then
    echo "$server_processes"
    server_count=$(echo "$server_processes" | wc -l | tr -d ' ')
    echo "   找到 $server_count 个server进程"
else
    echo "   ❌ 未发现运行中的server进程"
fi
echo ""

# 2. 检查MCP进程
echo "2. 检查MCP客户端进程状态："
mcp_processes=$(pgrep -f "browser-tools-mcp" 2>/dev/null)
if [ -n "$mcp_processes" ]; then
    mcp_count=$(echo "$mcp_processes" | wc -w)
    echo "   找到 $mcp_count 个MCP进程"
    for pid in $mcp_processes; do
        process_info=$(ps -p "$pid" -o pid,ppid,command 2>/dev/null)
        echo "   $process_info"
    done
else
    echo "   ❌ 未发现运行中的MCP进程"
fi
echo ""

# 3. 检查monitor进程
echo "3. 检查清理监控器状态："
monitor_processes=$(ps aux | grep "mcp_cleanup_monitor.sh" | grep -v grep)
if [ -n "$monitor_processes" ]; then
    echo "$monitor_processes"
else
    echo "   ❌ 未发现运行中的monitor进程"
fi
echo ""

# 4. 检查引用计数
echo "4. 检查引用计数状态："
if [ -f "$REF_COUNT_MANAGER" ]; then
    ref_count=$("$REF_COUNT_MANAGER" get)
    echo "   当前引用计数: $ref_count"
    
    # 判断是否存在引用计数泄漏
    mcp_count=$(pgrep -f "browser-tools-mcp" 2>/dev/null | wc -w | tr -d ' ')
    if [ "$mcp_count" -eq 0 ] && [ "$ref_count" -gt 0 ]; then
        echo "   ⚠️ 警告: 检测到引用计数泄漏！"
        echo "   MCP进程数: $mcp_count, 引用计数: $ref_count"
        echo ""
        echo "=========================================="
        echo "建议执行以下修复操作："
        echo "=========================================="
        echo ""
        echo "选项1: 重置引用计数（推荐）"
        echo "   ./mcp_ref_count_manager.sh set 0"
        echo ""
        echo "选项2: 完全清理并重启"
        echo "   ./diagnose_and_fix.sh --force-cleanup"
        echo ""
    elif [ "$ref_count" -gt "$mcp_count" ] && [ "$mcp_count" -gt 0 ]; then
        echo "   ⚠️ 警告: 引用计数不匹配"
        echo "   MCP进程数: $mcp_count, 引用计数: $ref_count"
        echo "   差异: $((ref_count - mcp_count))"
    else
        echo "   ✅ 引用计数正常"
    fi
else
    echo "   ❌ 引用计数管理器不存在"
fi
echo ""

# 5. 检查端口占用
echo "5. 检查端口3025占用状态："
port_info=$(lsof -i:3025 2>/dev/null)
if [ -n "$port_info" ]; then
    echo "$port_info"
else
    echo "   ❌ 端口3025未被占用"
fi
echo ""

# 6. 检查PID文件
echo "6. 检查PID文件状态："
SERVER_PID_FILE="$SCRIPT_DIR/logs/browser-tools-shared-server.pid"
if [ -f "$SERVER_PID_FILE" ]; then
    server_pid=$(cat "$SERVER_PID_FILE" 2>/dev/null)
    echo "   PID文件存在，记录的PID: $server_pid"
    if ps -p "$server_pid" > /dev/null 2>&1; then
        echo "   ✅ PID文件中的进程正在运行"
    else
        echo "   ⚠️ PID文件中的进程不存在（孤儿PID文件）"
    fi
else
    echo "   ❌ PID文件不存在"
fi
echo ""

# 处理命令行参数
if [ "$1" = "--force-cleanup" ]; then
    echo "=========================================="
    echo "执行强制清理"
    echo "=========================================="
    echo ""
    
    # 终止所有browser-tools相关进程
    echo "1. 终止所有browser-tools进程..."
    
    # 终止MCP客户端
    mcp_pids=$(pgrep -f "browser-tools-mcp" 2>/dev/null)
    if [ -n "$mcp_pids" ]; then
        echo "   终止MCP客户端: $mcp_pids"
        kill -TERM $mcp_pids 2>/dev/null || true
        sleep 1
    fi
    
    # 终止server进程
    server_pids=$(pgrep -f "browser-tools-server" 2>/dev/null)
    if [ -n "$server_pids" ]; then
        echo "   终止server进程: $server_pids"
        kill -TERM $server_pids 2>/dev/null || true
        sleep 1
        # 强制终止仍在运行的进程
        for pid in $server_pids; do
            if ps -p "$pid" > /dev/null 2>&1; then
                kill -KILL "$pid" 2>/dev/null || true
            fi
        done
    fi
    
    # 终止monitor进程
    monitor_pids=$(pgrep -f "mcp_cleanup_monitor" 2>/dev/null)
    if [ -n "$monitor_pids" ]; then
        echo "   终止monitor进程: $monitor_pids"
        kill -TERM $monitor_pids 2>/dev/null || true
    fi
    
    echo ""
    echo "2. 清理PID文件和锁文件..."
    rm -f "$SCRIPT_DIR/logs/browser-tools-shared-server.pid"
    rm -f "$SCRIPT_DIR/logs/browser-tools-mcp.pid"
    rm -f "$SCRIPT_DIR/logs/browser-tools-startup.lock"
    rm -f "$SCRIPT_DIR/logs/browser-tools-mcp-monitor.lock"
    rm -f "$SCRIPT_DIR/logs/browser-tools-mcp-monitor.pid"
    rm -f "$SCRIPT_DIR/logs/browser-tools-all-pids.txt"
    echo "   ✅ 文件清理完成"
    
    echo ""
    echo "3. 重置引用计数..."
    if [ -f "$REF_COUNT_MANAGER" ]; then
        "$REF_COUNT_MANAGER" set 0
        echo "   ✅ 引用计数已重置为0"
    fi
    
    echo ""
    echo "=========================================="
    echo "清理完成！"
    echo "=========================================="
    echo ""
    echo "现在可以重新启动Cursor来使用browser-tools"
    
elif [ "$1" = "--fix-ref-count" ]; then
    echo "=========================================="
    echo "修复引用计数"
    echo "=========================================="
    echo ""
    
    mcp_count=$(pgrep -f "browser-tools-mcp" 2>/dev/null | wc -w | tr -d ' ')
    echo "当前MCP进程数: $mcp_count"
    echo "重置引用计数为: $mcp_count"
    
    if [ -f "$REF_COUNT_MANAGER" ]; then
        "$REF_COUNT_MANAGER" set "$mcp_count"
        echo "✅ 引用计数已修复"
    else
        echo "❌ 引用计数管理器不存在"
    fi
fi

echo ""
echo "=========================================="
echo "诊断完成"
echo "=========================================="






