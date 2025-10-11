#!/bin/bash

# MCP服务器清理监控脚本（支持引用计数）
# 当所有MCP客户端都退出时，自动清理server进程

# 获取脚本所在目录的绝对路径
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

SERVER_PID_FILE="$SCRIPT_DIR/logs/browser-tools-shared-server.pid"
STOP_LOG_FILE="$SCRIPT_DIR/logs/browser-tools-stop.log"
MCP_MONITOR_PID_FILE="$SCRIPT_DIR/logs/browser-tools-mcp-monitor.pid"
MCP_MONITOR_LOCK_FILE="$SCRIPT_DIR/logs/browser-tools-mcp-monitor.lock"
REF_COUNT_MANAGER="$SCRIPT_DIR/mcp_ref_count_manager.sh"

# 监控脚本启动，等待获取server PID后再记录到monitor PID文件
# 这里不再记录监控脚本自身的PID，而是等待获取到实际的server PID

log_cleanup() {
    echo "$(date '+%Y-%m-%d %H:%M:%S.%3N') [cleanup] $1" >> "$STOP_LOG_FILE"
}

# 检查是否已有monitor进程在运行
check_existing_monitor() {
    if [ -f "$MCP_MONITOR_PID_FILE" ]; then
        local existing_pid=$(cat "$MCP_MONITOR_PID_FILE" 2>/dev/null)
        if [ -n "$existing_pid" ] && ps -p "$existing_pid" > /dev/null 2>&1; then
            # 检查进程是否真的是monitor进程
            local process_cmd=$(ps -p "$existing_pid" -o args= 2>/dev/null || echo "")
            if echo "$process_cmd" | grep -q "mcp_cleanup_monitor"; then
                log_cleanup "发现现有monitor进程 (PID: $existing_pid)，退出当前实例"
                return 0  # 返回0表示已有monitor在运行
            else
                log_cleanup "PID文件中的进程不是monitor进程，清理PID文件"
                rm -f "$MCP_MONITOR_PID_FILE"
            fi
        else
            log_cleanup "PID文件中的进程不存在，清理PID文件"
            rm -f "$MCP_MONITOR_PID_FILE"
        fi
    fi
    return 1  # 返回1表示没有现有monitor
}

# 获取monitor锁
acquire_monitor_lock() {
    local timeout=50  # 50次尝试，每次100ms，总计5秒
    local count=0
    
    while [ $count -lt $timeout ]; do
        if (set -C; echo $$ > "$MCP_MONITOR_LOCK_FILE") 2>/dev/null; then
            return 0
        fi
        
        # 检查锁文件中的PID是否还存在
        if [ -f "$MCP_MONITOR_LOCK_FILE" ]; then
            local lock_pid=$(cat "$MCP_MONITOR_LOCK_FILE" 2>/dev/null)
            if [ -n "$lock_pid" ] && ! ps -p "$lock_pid" > /dev/null 2>&1; then
                log_cleanup "清理无效的monitor锁文件，PID $lock_pid 已不存在"
                rm -f "$MCP_MONITOR_LOCK_FILE"
                continue
            fi
        fi
        
        sleep 0.1  # 100毫秒
        count=$((count + 1))
    done
    
    log_cleanup "获取monitor锁超时，退出"
    return 1
}

# 释放monitor锁
release_monitor_lock() {
    rm -f "$MCP_MONITOR_LOCK_FILE"
}

# 选择性终止server相关进程
kill_server_process_tree() {
    local pid=$1
    local signal=${2:-TERM}
    
    if [ -z "$pid" ] || ! ps -p "$pid" > /dev/null 2>&1; then
        return 0
    fi
    
    # 获取当前进程的命令
    local process_cmd=$(ps -p "$pid" -o args= 2>/dev/null || echo "")
    
    # 检查是否是server相关进程
    local is_server_process=false
    if echo "$process_cmd" | grep -q "browser-tools-server"; then
        is_server_process=true
    fi
    
    # 获取所有直接子进程
    local children=$(pgrep -P "$pid" 2>/dev/null | xargs)
    
    # 对每个子进程进行检查和处理
    for child in $children; do
        if [ -n "$child" ]; then
            local child_cmd=$(ps -p "$child" -o args= 2>/dev/null || echo "")
            # 如果子进程是server相关的，递归终止
            if echo "$child_cmd" | grep -q "browser-tools-server"; then
                log_cleanup "递归终止server子进程: $child"
                kill_server_process_tree "$child" "$signal"
            fi
        fi
    done
    
    # 如果当前进程是server相关进程，则终止它
    if [ "$is_server_process" = true ]; then
        log_cleanup "终止server进程: $pid (信号: $signal)"
        
        kill -"$signal" "$pid" 2>/dev/null || true
        
        # 如果是TERM信号，等待一下再检查
        if [ "$signal" = "TERM" ]; then
            sleep 1
            if ps -p "$pid" > /dev/null 2>&1; then
                log_cleanup "server进程 $pid 未响应TERM信号，使用KILL信号"
                kill -KILL "$pid" 2>/dev/null || true
            fi
        fi
    fi
}

# 清理server进程
cleanup_server_processes() {
    log_cleanup "===== 开始清理server进程 ====="
    
    # 首先查找所有实际运行的server进程
    local all_server_pids=$(ps -ef | grep "browser-tools-server" | grep -v grep | awk '{print $2}' | tr '\n' ' ')
    
    if [ -n "$all_server_pids" ]; then
        log_cleanup "发现实际运行的server进程: $all_server_pids"
        
        # 终止所有server进程
        for pid in $all_server_pids; do
            if ps -p "$pid" > /dev/null 2>&1; then
                local process_cmd=$(ps -p "$pid" -o args= 2>/dev/null || echo "未知命令")
                log_cleanup "终止server进程: $pid"
                log_cleanup "命令: $process_cmd"
                
                # 使用选择性进程树终止
                kill_server_process_tree "$pid" "TERM"
            fi
        done
        
        sleep 2
        
        # 检查是否还有server进程在运行
        local remaining_server_processes=$(ps -ef | grep "browser-tools-server" | grep -v grep | wc -l | tr -d ' ')
        if [ "$remaining_server_processes" -eq 0 ]; then
            log_cleanup "✅ 所有server进程已成功终止"
        else
            log_cleanup "⚠️ 仍有 $remaining_server_processes 个server进程在运行，使用强制终止"
            # 强制终止剩余的server进程
            ps -ef | grep "browser-tools-server" | grep -v grep | awk '{print $2}' | xargs kill -KILL 2>/dev/null || true
            sleep 1
            local final_count=$(ps -ef | grep "browser-tools-server" | grep -v grep | wc -l | tr -d ' ')
            log_cleanup "强制终止后剩余进程数: $final_count"
        fi
    else
        log_cleanup "未发现运行中的server进程"
    fi
    
    # 处理PID文件（如果存在）
    if [ -f "$SERVER_PID_FILE" ]; then
        SERVER_PID=$(cat "$SERVER_PID_FILE" 2>/dev/null)
        log_cleanup "清理PID文件: $SERVER_PID_FILE (PID: $SERVER_PID)"
        rm -f "$SERVER_PID_FILE"
    fi
    
    # 清理其他记录文件
    rm -f "$SCRIPT_DIR/logs/browser-tools-all-pids.txt"
    rm -f "$SCRIPT_DIR/logs/browser-tools-mcp.pid"
    rm -f "$SCRIPT_DIR/logs/browser-tools-shared-server.pid"
    rm -f "$SCRIPT_DIR/logs/browser-tools-shared.lock"
    
    log_cleanup "===== server进程清理完成 ====="
}

# 主监控逻辑
log_cleanup "MCP清理监控器启动 (PID: $$) - 支持引用计数机制"

# 检查是否已有monitor进程在运行
if check_existing_monitor; then
    log_cleanup "已有monitor进程在运行，退出当前实例 (PID: $$)"
    exit 0
fi

# 获取monitor锁
if ! acquire_monitor_lock; then
    log_cleanup "无法获取monitor锁，退出 (PID: $$)"
    exit 1
fi

# 记录当前monitor进程PID
echo $$ > "$MCP_MONITOR_PID_FILE"
log_cleanup "成功获取monitor锁，记录PID: $$"

# 等待MCP进程启动
sleep 2

# 获取实际的server PID
if [ -f "$SERVER_PID_FILE" ]; then
    SERVER_PID=$(cat "$SERVER_PID_FILE" 2>/dev/null | head -n 1)
    if [ -n "$SERVER_PID" ] && ps -p "$SERVER_PID" > /dev/null 2>&1; then
        log_cleanup "记录被监控的server PID: $SERVER_PID"
    else
        log_cleanup "警告: SERVER_PID_FILE中的PID无效或进程不存在: $SERVER_PID"
    fi
else
    log_cleanup "警告: SERVER_PID_FILE不存在，无法获取server PID"
fi

# 初始化引用计数
if [ ! -f "$SCRIPT_DIR/logs/browser-tools-client-count.txt" ]; then
    echo "0" > "$SCRIPT_DIR/logs/browser-tools-client-count.txt"
    log_cleanup "初始化引用计数为0"
fi

# 监控所有MCP进程
log_cleanup "开始监控所有MCP进程（引用计数模式）"

# 记录服务启动时间（用于动态调整检查间隔）
SERVICE_START_TIME=$(date +%s)
log_cleanup "服务启动时间: $(date '+%Y-%m-%d %H:%M:%S')"

# 获取当前MCP进程列表（改进版本）
get_mcp_processes() {
    # 检测多种类型的MCP客户端进程
    local mcp_processes=""
    
    # 1. 检测 browser-tools-mcp 进程
    local browser_tools_mcp=$(pgrep -f "browser-tools-mcp" 2>/dev/null || echo "")
    if [ -n "$browser_tools_mcp" ]; then
        mcp_processes="$mcp_processes $browser_tools_mcp"
    fi
    
    # 2. 检测通过npm exec启动的MCP进程
    local npm_mcp=$(pgrep -f "npm.*browser-tools.*mcp" 2>/dev/null || echo "")
    if [ -n "$npm_mcp" ]; then
        mcp_processes="$mcp_processes $npm_mcp"
    fi
    
    # 3. 检测端口3025上的连接（作为额外的安全检查）
    local port_connections=$(lsof -ti :3025 2>/dev/null | grep -v "$(cat "$SERVER_PID_FILE" 2>/dev/null || echo '')" || echo "")
    if [ -n "$port_connections" ]; then
        # 检查这些进程是否是MCP相关的
        for pid in $port_connections; do
            local process_cmd=$(ps -p "$pid" -o args= 2>/dev/null || echo "")
            if echo "$process_cmd" | grep -q "browser-tools\|mcp"; then
                mcp_processes="$mcp_processes $pid"
            fi
        done
    fi
    
    # 去重并返回
    echo "$mcp_processes" | tr ' ' '\n' | sort -u | tr '\n' ' ' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

# 监控循环
while true; do
    # 计算服务运行时间
    current_time=$(date +%s)
    elapsed_time=$((current_time - SERVICE_START_TIME))
    elapsed_minutes=$((elapsed_time / 60))
    
    # 根据运行时间决定检查间隔
    if [ $elapsed_minutes -lt 5 ]; then
        check_interval=5  # 前5分钟使用5秒间隔
        interval_desc="5秒"
    else
        check_interval=3600  # 5分钟后使用1小时间隔
        interval_desc="1小时"
    fi
    
    # 获取当前MCP进程
    current_mcp_processes=$(get_mcp_processes)
    current_count=$(echo "$current_mcp_processes" | wc -w | tr -d ' ')
    
    # 如果current_mcp_processes为空，current_count会是1（因为wc -w对空字符串返回1）
    if [ -z "$current_mcp_processes" ]; then
        current_count=0
    fi
    
    # 获取引用计数
    ref_count=$("$REF_COUNT_MANAGER" get)
    
    log_cleanup "监控状态: MCP进程数=$current_count, 引用计数=$ref_count, 运行时间=${elapsed_minutes}分钟, 检查间隔=$interval_desc"
    
    # 检查是否应该清理server
    # 智能清理逻辑：既要防止误停止server，又要避免孤儿进程
    server_exists=$(ps -ef | grep "browser-tools-server" | grep -v grep | wc -l | tr -d ' ')
    
    # 🔧 新增：如果没有MCP进程且引用计数异常高（可能是泄漏），尝试修复引用计数
    if [ "$current_count" -eq 0 ] && [ "$ref_count" -gt 10 ] && [ $elapsed_minutes -ge 1 ]; then
        log_cleanup "⚠️ 检测到引用计数异常 (MCP进程数=0, 引用计数=$ref_count)，可能是计数泄漏"
        log_cleanup "重置引用计数为0"
        "$REF_COUNT_MANAGER" set 0
        ref_count=0
    fi
    
    if [ "$current_count" -eq 0 ] && [ "$ref_count" -eq 0 ]; then
        if [ "$server_exists" -eq 0 ]; then
            # 没有server进程在运行，直接退出监控
            log_cleanup "检测到MCP进程数为0且引用计数为0，且没有server进程在运行，退出监控"
            break
        elif [ "$elapsed_minutes" -ge 10 ]; then
            # server运行超过10分钟，可以安全清理
            # 增加额外的安全检查：等待一段时间确保没有新的客户端连接
            log_cleanup "检测到MCP进程数为0且引用计数为0，等待30秒确认..."
            sleep 30
            
            # 重新检查状态
            current_mcp_processes=$(get_mcp_processes)
            current_count=$(echo "$current_mcp_processes" | wc -w | tr -d ' ')
            if [ -z "$current_mcp_processes" ]; then
                current_count=0
            fi
            ref_count=$("$REF_COUNT_MANAGER" get)
            
            log_cleanup "30秒后重新检查: MCP进程数=$current_count, 引用计数=$ref_count"
            
            if [ "$current_count" -eq 0 ] && [ "$ref_count" -eq 0 ]; then
                log_cleanup "确认所有MCP进程已退出且引用计数为0，开始清理server进程"
                cleanup_server_processes
                
                # 安全地清理引用计数文件
                if "$REF_COUNT_MANAGER" cleanup; then
                    log_cleanup "引用计数文件已安全清理"
                else
                    log_cleanup "引用计数文件清理被跳过（检测到活跃进程）"
                fi
                
                log_cleanup "清理监控器退出"
                break
            else
                log_cleanup "检测到新的MCP进程或引用计数变化，继续监控"
            fi
        else
            # server运行时间不足10分钟，但有server进程存在
            # 检查server进程是否真的在正常工作（通过端口检查）
            server_port_active=$(lsof -ti :3025 2>/dev/null | wc -l | tr -d ' ')
            if [ "$server_port_active" -eq 0 ]; then
                # server进程存在但端口没有监听，可能是僵尸进程，可以清理
                log_cleanup "MCP进程数为0且引用计数为0，server进程存在但端口未监听，可能是僵尸进程，开始清理"
                cleanup_server_processes
                log_cleanup "清理监控器退出"
                break
            else
                log_cleanup "MCP进程数为0且引用计数为0，但server运行时间不足10分钟且端口正常，继续监控"
            fi
        fi
    elif [ "$current_count" -eq 0 ] && [ "$ref_count" -gt 0 ]; then
        log_cleanup "MCP进程已退出但引用计数>0 ($ref_count)，等待其他客户端"
        # 不要立即清理引用计数，给其他客户端时间连接
        # 只有在引用计数持续为0超过5分钟时才清理
    fi
    
    sleep $check_interval
done

# 清理监控器PID文件和锁文件
rm -f "$MCP_MONITOR_PID_FILE"
release_monitor_lock
log_cleanup "monitor进程退出，清理PID文件和锁文件"
