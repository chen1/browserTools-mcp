#!/bin/bash

# MCP引用计数管理器
# 用于管理MCP客户端的引用计数，确保server进程在最后一个客户端退出时才被清理

# 获取脚本所在目录的绝对路径
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

REF_COUNT_FILE="$SCRIPT_DIR/logs/browser-tools-client-count.txt"
LOCK_FILE="$SCRIPT_DIR/logs/browser-tools-ref-count.lock"
LOG_FILE="$SCRIPT_DIR/logs/browser-tools-ref-count.log"

# 日志函数
log_ref_count() {
    echo "$(date '+%Y-%m-%d %H:%M:%S.%3N') [ref-count] $1" >> "$LOG_FILE"
}

# 获取文件锁（防止并发操作）- 毫秒级响应优化
acquire_lock() {
    local timeout=200  # 200次尝试：前100次×1ms + 后100次×50ms = 5.1秒总计
    local count=0
    
    while [ $count -lt $timeout ]; do
        if (set -C; echo $$ > "$LOCK_FILE") 2>/dev/null; then
            return 0
        fi
        
        # 检查锁文件中的PID是否还存在（清理死锁）
        if [ -f "$LOCK_FILE" ]; then
            local lock_pid=$(cat "$LOCK_FILE" 2>/dev/null)
            if [ -n "$lock_pid" ] && ! ps -p "$lock_pid" > /dev/null 2>&1; then
                log_ref_count "🧹 清理无效锁文件，PID $lock_pid 已不存在"
                rm -f "$LOCK_FILE"
                continue
            fi
        fi
        
        # 毫秒级等待：前100次尝试用1毫秒，后续用50毫秒
        if [ $count -lt 100 ]; then
            sleep 0.001  # 1毫秒
        else
            sleep 0.05   # 50毫秒
        fi
        count=$((count + 1))
    done
    
    log_ref_count "❌ 获取锁超时"
    return 1
}

# 释放文件锁
release_lock() {
    rm -f "$LOCK_FILE"
}

# 获取当前引用计数
get_ref_count() {
    if [ -f "$REF_COUNT_FILE" ]; then
        cat "$REF_COUNT_FILE" 2>/dev/null || echo "0"
    else
        echo "0"
    fi
}

# 设置引用计数
set_ref_count() {
    local count=$1
    echo "$count" > "$REF_COUNT_FILE"
    log_ref_count "设置引用计数: $count"
}

# 递增引用计数
increment_ref_count() {
    if ! acquire_lock; then
        return 1
    fi
    
    local current_count=$(get_ref_count)
    local new_count=$((current_count + 1))
    set_ref_count "$new_count"
    
    release_lock
    log_ref_count "✅ 引用计数递增: $current_count -> $new_count"
    echo "$new_count"
}

# 递减引用计数
decrement_ref_count() {
    if ! acquire_lock; then
        return 1
    fi
    
    local current_count=$(get_ref_count)
    local new_count=$((current_count - 1))
    
    if [ $new_count -lt 0 ]; then
        new_count=0
        log_ref_count "⚠️ 引用计数不能为负数，重置为0"
    fi
    
    set_ref_count "$new_count"
    release_lock
    log_ref_count "✅ 引用计数递减: $current_count -> $new_count"
    echo "$new_count"
}

# 检查是否应该清理server
should_cleanup_server() {
    local count=$(get_ref_count)
    if [ "$count" -eq 0 ]; then
        log_ref_count "🔍 引用计数为0，应该清理server"
        return 0
    else
        log_ref_count "🔍 引用计数为$count，不应清理server"
        return 1
    fi
}

# 检查服务器是否已经在运行 - 改进版本
is_server_running() {
    # 首先检查端口3025是否被占用
    if lsof -i:3025 -t > /dev/null 2>&1; then
        local port_pid=$(lsof -i:3025 -t | head -1)
        if ps -p "$port_pid" > /dev/null 2>&1; then
            local cmd=$(ps -p "$port_pid" -o args= 2>/dev/null || echo "")
            if echo "$cmd" | grep -q "browser-tools-server"; then
                log_ref_count "🔍 通过端口发现运行中的server进程: $port_pid"
                echo "$port_pid"
                return 0
            fi
        fi
    fi
    
    # 备用方法：通过进程名查找
    local server_pids=$(pgrep -f "node.*browser-tools-server" 2>/dev/null || echo "")
    if [ -n "$server_pids" ]; then
        for pid in $server_pids; do
            if ps -p "$pid" > /dev/null 2>&1; then
                local cmd=$(ps -p "$pid" -o args= 2>/dev/null || echo "")
                if echo "$cmd" | grep -q "node.*browser-tools-server"; then
                    log_ref_count "🔍 通过进程名发现运行中的server进程: $pid"
                    echo "$pid"
                    return 0
                fi
            fi
        done
    fi
    return 1
}

# 获取共享server的PID，如果PID文件中的进程无效则自动修复
get_shared_server_pid() {
    local shared_pid_file="$SCRIPT_DIR/logs/browser-tools-shared-server.pid"
    
    # 确保logs目录存在
    mkdir -p "$SCRIPT_DIR/logs"
    
    # 检查PID文件是否存在且有效
    if [ -f "$shared_pid_file" ]; then
        local pid=$(cat "$shared_pid_file" 2>/dev/null)
        if [ -n "$pid" ] && ps -p "$pid" > /dev/null 2>&1; then
            local cmd=$(ps -p "$pid" -o args= 2>/dev/null || echo "")
            if echo "$cmd" | grep -q "browser-tools-server"; then
                # 简化验证：只检查进程命令，不检查端口（避免lsof卡住）
                log_ref_count "✅ PID文件中的server进程有效，PID: $pid"
                echo "$pid"
                return 0
            else
                log_ref_count "⚠️ PID文件中的进程不是browser-tools-server，PID: $pid"
            fi
        else
            log_ref_count "⚠️ PID文件中记录的进程不存在，PID: $pid"
        fi
    else
        log_ref_count "📋 PID文件不存在，开始搜索现有server进程..."
    fi
    
    # PID文件不存在或无效，搜索有效的server进程并创建/更新PID文件
    log_ref_count "🔍 搜索有效的server进程..."
    
    # 优先通过端口查找
    if lsof -i:3025 -t > /dev/null 2>&1; then
        local port_pid=$(lsof -i:3025 -t | head -1)
        if ps -p "$port_pid" > /dev/null 2>&1; then
            local cmd=$(ps -p "$port_pid" -o args= 2>/dev/null || echo "")
            if echo "$cmd" | grep -q "browser-tools-server"; then
                echo "$port_pid" > "$shared_pid_file"
                log_ref_count "🔄 通过端口发现并更新PID文件，PID: $port_pid"
                echo "$port_pid"
                return 0
            fi
        fi
    fi
    
    # 备用方法：查找node server进程
    local valid_server_pids=$(pgrep -f "node.*browser-tools-server" 2>/dev/null)
    if [ -n "$valid_server_pids" ]; then
        for valid_pid in $valid_server_pids; do
            if ps -p "$valid_pid" > /dev/null 2>&1; then
                local valid_cmd=$(ps -p "$valid_pid" -o args= 2>/dev/null || echo "")
                if echo "$valid_cmd" | grep -q "node.*browser-tools-server"; then
                    echo "$valid_pid" > "$shared_pid_file"
                    log_ref_count "🔄 发现node server进程并更新PID文件，PID: $valid_pid"
                    echo "$valid_pid"
                    return 0
                fi
            fi
        done
    fi
    
    log_ref_count "❌ 未找到有效的server进程"
    return 1
}

# 确保只有一个server实例运行 - 改进版本
ensure_single_server() {
    log_ref_count "🔍 检查server实例状态..."
    
    # 首先通过端口检查是否有server在运行
    local port_based_pid=""
    if lsof -i:3025 -t > /dev/null 2>&1; then
        port_based_pid=$(lsof -i:3025 -t | head -1)
        if ps -p "$port_based_pid" > /dev/null 2>&1; then
            local cmd=$(ps -p "$port_based_pid" -o args= 2>/dev/null || echo "")
            if echo "$cmd" | grep -q "browser-tools-server"; then
                log_ref_count "✅ 通过端口发现单个有效server进程: $port_based_pid"
                echo "$port_based_pid" > "$SCRIPT_DIR/logs/browser-tools-shared-server.pid"
                return 0
            fi
        fi
    fi
    
    # 获取所有真正的node server进程（排除npm父进程）
    local node_server_pids=$(pgrep -f "node.*browser-tools-server" 2>/dev/null || echo "")
    local valid_pids=""
    local pid_count=0
    
    # 验证每个node PID
    for pid in $node_server_pids; do
        if ps -p "$pid" > /dev/null 2>&1; then
            local cmd=$(ps -p "$pid" -o args= 2>/dev/null || echo "")
            if echo "$cmd" | grep -q "node.*browser-tools-server"; then
                valid_pids="$valid_pids $pid"
                pid_count=$((pid_count + 1))
                log_ref_count "✅ 发现有效node server进程: $pid"
            fi
        fi
    done
    
    if [ $pid_count -eq 0 ]; then
        log_ref_count "📋 没有发现运行中的server进程，需要启动新的server"
        return 2  # 返回2表示需要启动新server
    elif [ $pid_count -eq 1 ]; then
        local single_pid=$(echo $valid_pids | xargs)
        log_ref_count "✅ 发现单个node server进程: $single_pid"
        echo "$single_pid" > "$SCRIPT_DIR/logs/browser-tools-shared-server.pid"
        return 0
    else
        log_ref_count "⚠️ 发现多个node server进程 ($pid_count个): $valid_pids"
        
        # 如果有基于端口的PID且在列表中，优先保留它
        local main_pid=""
        if [ -n "$port_based_pid" ]; then
            for pid in $valid_pids; do
                if [ "$pid" = "$port_based_pid" ]; then
                    main_pid="$port_based_pid"
                    log_ref_count "🎯 保留端口监听进程: $main_pid"
                    break
                fi
            done
        fi
        
        # 如果没有端口匹配，选择第一个进程
        if [ -z "$main_pid" ]; then
            main_pid=$(echo $valid_pids | awk '{print $1}')
            log_ref_count "🎯 保留第一个进程: $main_pid"
        fi
        
        echo "$main_pid" > "$SCRIPT_DIR/logs/browser-tools-shared-server.pid"
        
        # 终止其他进程
        for pid in $valid_pids; do
            if [ "$pid" != "$main_pid" ]; then
                log_ref_count "🔄 终止重复server进程: $pid"
                kill -TERM "$pid" 2>/dev/null || true
                
                # 快速检查进程是否已终止（最多等待200毫秒）
                local check_count=0
                while [ $check_count -lt 40 ] && ps -p "$pid" > /dev/null 2>&1; do
                    sleep 0.005  # 5毫秒
                    check_count=$((check_count + 1))
                done
                
                if ps -p "$pid" > /dev/null 2>&1; then
                    log_ref_count "⚡ 强制终止进程: $pid"
                    kill -KILL "$pid" 2>/dev/null || true
                fi
            fi
        done
        
        # 验证主进程仍在运行
        sleep 0.1
        if ps -p "$main_pid" > /dev/null 2>&1; then
            log_ref_count "✅ server进程整合完成，当前主进程: $main_pid"
            return 0
        else
            log_ref_count "❌ 主进程意外终止，需要重新启动"
            return 2
        fi
    fi
}

# 清理引用计数文件（增加安全检查）
cleanup_ref_count() {
    # 检查是否有活跃的MCP进程
    local active_mcp_processes=$(pgrep -f "browser-tools-mcp\|npm.*browser-tools.*mcp" 2>/dev/null | wc -l | tr -d ' ')
    
    if [ "$active_mcp_processes" -gt 0 ]; then
        log_ref_count "⚠️ 检测到 $active_mcp_processes 个活跃的MCP进程，跳过清理引用计数"
        return 1
    fi
    
    # 检查server是否还在运行
    if is_server_running > /dev/null 2>&1; then
        log_ref_count "⚠️ 检测到server仍在运行，跳过清理引用计数"
        return 1
    fi
    
    rm -f "$REF_COUNT_FILE"
    rm -f "$LOCK_FILE"
    log_ref_count "🧹 清理引用计数文件"
    return 0
}

# 显示当前状态
show_status() {
    local count=$(get_ref_count)
    echo "当前MCP客户端引用计数: $count"
    log_ref_count "状态查询: 引用计数 = $count"
}

# 主函数
case "${1:-}" in
    "increment")
        increment_ref_count
        ;;
    "decrement")
        decrement_ref_count
        ;;
    "get")
        get_ref_count
        ;;
    "should-cleanup")
        if should_cleanup_server; then
            echo "true"
            exit 0
        else
            echo "false"
            exit 1
        fi
        ;;
    "cleanup")
        cleanup_ref_count
        ;;
    "status")
        show_status
        ;;
    "ensure-single-server")
        if ensure_single_server; then
            echo "server整合完成"
            exit 0
        else
            echo "没有发现运行中的server"
            exit 1
        fi
        ;;
    "get-server-pid")
        if server_pid=$(get_shared_server_pid); then
            echo "$server_pid"
            exit 0
        else
            echo "没有发现运行中的server"
            exit 1
        fi
        ;;
    *)
        echo "用法: $0 {increment|decrement|get|should-cleanup|cleanup|status|ensure-single-server|get-server-pid}"
        echo ""
        echo "命令说明:"
        echo "  increment           - 递增引用计数"
        echo "  decrement           - 递减引用计数"
        echo "  get                - 获取当前引用计数"
        echo "  should-cleanup     - 检查是否应该清理server (返回true/false)"
        echo "  cleanup            - 清理引用计数文件"
        echo "  status             - 显示当前状态"
        echo "  ensure-single-server - 确保只有一个server实例运行"
        echo "  get-server-pid     - 获取共享server的PID"
        exit 1
        ;;
esac
