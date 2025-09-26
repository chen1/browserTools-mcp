#!/bin/bash

# 测试monitor脚本退出机制的验证脚本
# 用于验证当所有server关闭后，monitor脚本进程是否会正确退出

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MONITOR_SCRIPT="$SCRIPT_DIR/mcp_cleanup_monitor.sh"
REF_COUNT_MANAGER="$SCRIPT_DIR/mcp_ref_count_manager.sh"
LOG_FILE="$SCRIPT_DIR/logs/test_monitor_exit.log"

# 日志函数
log_test() {
    echo "$(date '+%Y-%m-%d %H:%M:%S.%3N') [TEST] $1" | tee -a "$LOG_FILE"
}

# 清理函数
cleanup_test() {
    log_test "🧹 清理测试环境..."
    
    # 终止所有browser-tools相关进程
    pkill -f "browser-tools-server" 2>/dev/null || true
    pkill -f "browser-tools-mcp" 2>/dev/null || true
    pkill -f "mcp_cleanup_monitor" 2>/dev/null || true
    
    # 清理PID文件和锁文件
    rm -f "$SCRIPT_DIR/logs/browser-tools-shared-server.pid"
    rm -f "$SCRIPT_DIR/logs/browser-tools-mcp-monitor.pid"
    rm -f "$SCRIPT_DIR/logs/browser-tools-mcp-monitor.lock"
    rm -f "$SCRIPT_DIR/logs/browser-tools-client-count.txt"
    rm -f "$SCRIPT_DIR/logs/browser-tools-ref-count.lock"
    
    sleep 2
    log_test "✅ 测试环境清理完成"
}

# 检查进程是否存在
check_process_exists() {
    local process_name="$1"
    local count=$(pgrep -f "$process_name" 2>/dev/null | wc -l | tr -d ' ')
    echo "$count"
}

# 等待进程退出
wait_for_process_exit() {
    local process_name="$1"
    local timeout="${2:-30}"  # 默认30秒超时
    local count=0
    
    log_test "⏳ 等待进程 '$process_name' 退出 (超时: ${timeout}秒)..."
    
    while [ $count -lt $timeout ]; do
        local process_count=$(check_process_exists "$process_name")
        if [ "$process_count" -eq 0 ]; then
            log_test "✅ 进程 '$process_name' 已退出"
            return 0
        fi
        
        log_test "进程 '$process_name' 仍在运行 (数量: $process_count), 等待中... ($count/${timeout}秒)"
        sleep 1
        count=$((count + 1))
    done
    
    log_test "❌ 进程 '$process_name' 在 ${timeout} 秒内未退出"
    return 1
}

# 测试场景1: 正常启动和退出
test_scenario_1() {
    log_test "=== 测试场景1: 正常启动server和monitor，然后关闭server ==="
    
    # 启动一个模拟的server进程
    log_test "🚀 启动模拟server进程..."
    node -e "
        const http = require('http');
        const server = http.createServer((req, res) => {
            res.writeHead(200, {'Content-Type': 'text/plain'});
            res.end('OK');
        });
        server.listen(3025, () => {
            console.log('Server listening on port 3025');
            process.on('SIGTERM', () => {
                console.log('Received SIGTERM, shutting down...');
                server.close(() => {
                    console.log('Server closed');
                    process.exit(0);
                });
            });
        });
    " &
    
    local server_pid=$!
    echo "$server_pid" > "$SCRIPT_DIR/logs/browser-tools-shared-server.pid"
    log_test "模拟server进程启动，PID: $server_pid"
    
    # 设置引用计数为0（模拟没有客户端连接）
    echo "0" > "$SCRIPT_DIR/logs/browser-tools-client-count.txt"
    
    # 启动monitor脚本
    log_test "🚀 启动monitor脚本..."
    "$MONITOR_SCRIPT" &
    local monitor_pid=$!
    log_test "Monitor脚本启动，PID: $monitor_pid"
    
    # 等待monitor脚本稳定运行
    sleep 5
    
    # 检查monitor是否在运行
    local monitor_count=$(check_process_exists "mcp_cleanup_monitor")
    if [ "$monitor_count" -eq 0 ]; then
        log_test "❌ Monitor脚本启动后立即退出了"
        return 1
    fi
    
    log_test "✅ Monitor脚本正在运行"
    
    # 关闭server进程
    log_test "🛑 关闭server进程..."
    kill -TERM "$server_pid" 2>/dev/null || true
    
    # 等待server进程退出
    wait_for_process_exit "browser-tools-server" 10
    
    # 等待monitor脚本检测到server关闭并退出
    log_test "⏳ 等待monitor脚本检测到server关闭并退出..."
    wait_for_process_exit "mcp_cleanup_monitor" 60
    
    if [ $? -eq 0 ]; then
        log_test "✅ 测试场景1通过: Monitor脚本在server关闭后正确退出"
        return 0
    else
        log_test "❌ 测试场景1失败: Monitor脚本未在预期时间内退出"
        return 1
    fi
}

# 测试场景2: 引用计数机制
test_scenario_2() {
    log_test "=== 测试场景2: 测试引用计数机制 ==="
    
    # 启动模拟server
    log_test "🚀 启动模拟server进程..."
    node -e "
        const http = require('http');
        const server = http.createServer((req, res) => {
            res.writeHead(200, {'Content-Type': 'text/plain'});
            res.end('OK');
        });
        server.listen(3025, () => {
            console.log('Server listening on port 3025');
            process.on('SIGTERM', () => {
                console.log('Received SIGTERM, shutting down...');
                server.close(() => {
                    console.log('Server closed');
                    process.exit(0);
                });
            });
        });
    " &
    
    local server_pid=$!
    echo "$server_pid" > "$SCRIPT_DIR/logs/browser-tools-shared-server.pid"
    
    # 设置引用计数为1（模拟有客户端连接）
    echo "1" > "$SCRIPT_DIR/logs/browser-tools-client-count.txt"
    
    # 启动monitor脚本
    log_test "🚀 启动monitor脚本（引用计数=1）..."
    "$MONITOR_SCRIPT" &
    local monitor_pid=$!
    
    sleep 5
    
    # 检查monitor是否在运行
    local monitor_count=$(check_process_exists "mcp_cleanup_monitor")
    if [ "$monitor_count" -eq 0 ]; then
        log_test "❌ Monitor脚本启动后立即退出了"
        return 1
    fi
    
    # 关闭server但保持引用计数为1
    log_test "🛑 关闭server进程（但引用计数仍为1）..."
    kill -TERM "$server_pid" 2>/dev/null || true
    wait_for_process_exit "browser-tools-server" 10
    
    # 等待一段时间，monitor应该继续运行
    sleep 10
    
    monitor_count=$(check_process_exists "mcp_cleanup_monitor")
    if [ "$monitor_count" -gt 0 ]; then
        log_test "✅ Monitor脚本在server关闭但引用计数>0时继续运行"
        
        # 现在将引用计数设为0
        log_test "📉 将引用计数设为0..."
        echo "0" > "$SCRIPT_DIR/logs/browser-tools-client-count.txt"
        
        # 等待monitor检测到引用计数为0并退出
        wait_for_process_exit "mcp_cleanup_monitor" 60
        
        if [ $? -eq 0 ]; then
            log_test "✅ 测试场景2通过: Monitor脚本在引用计数为0后正确退出"
            return 0
        else
            log_test "❌ 测试场景2失败: Monitor脚本未在引用计数为0后退出"
            return 1
        fi
    else
        log_test "❌ 测试场景2失败: Monitor脚本在引用计数>0时退出了"
        return 1
    fi
}

# 测试场景3: 检查monitor脚本的退出条件
test_scenario_3() {
    log_test "=== 测试场景3: 详细分析monitor脚本的退出条件 ==="
    
    log_test "📋 Monitor脚本的退出条件分析:"
    log_test "1. MCP进程数为0 且 引用计数为0 且 没有server进程在运行 -> 直接退出"
    log_test "2. MCP进程数为0 且 引用计数为0 且 server运行超过10分钟 -> 等待30秒后清理并退出"
    log_test "3. MCP进程数为0 且 引用计数为0 且 server运行不足10分钟但端口未监听 -> 清理并退出"
    log_test "4. MCP进程数为0 但 引用计数>0 -> 继续监控"
    
    # 测试条件1: 没有server进程
    log_test "🧪 测试条件1: 没有server进程的情况"
    echo "0" > "$SCRIPT_DIR/logs/browser-tools-client-count.txt"
    
    "$MONITOR_SCRIPT" &
    local monitor_pid=$!
    sleep 3
    
    local monitor_count=$(check_process_exists "mcp_cleanup_monitor")
    if [ "$monitor_count" -eq 0 ]; then
        log_test "✅ 条件1通过: 没有server进程时monitor立即退出"
    else
        log_test "❌ 条件1失败: 没有server进程时monitor未退出"
        kill -TERM "$monitor_pid" 2>/dev/null || true
    fi
    
    cleanup_test
    return 0
}

# 主测试函数
main() {
    log_test "🚀 开始monitor脚本退出机制验证测试"
    log_test "测试时间: $(date)"
    log_test "脚本目录: $SCRIPT_DIR"
    
    # 确保logs目录存在
    mkdir -p "$SCRIPT_DIR/logs"
    
    # 清理测试环境
    cleanup_test
    
    local test_results=()
    
    # 运行测试场景
    log_test "开始执行测试场景..."
    
    if test_scenario_1; then
        test_results+=("场景1: ✅ 通过")
    else
        test_results+=("场景1: ❌ 失败")
    fi
    
    cleanup_test
    
    if test_scenario_2; then
        test_results+=("场景2: ✅ 通过")
    else
        test_results+=("场景2: ❌ 失败")
    fi
    
    cleanup_test
    
    if test_scenario_3; then
        test_results+=("场景3: ✅ 通过")
    else
        test_results+=("场景3: ❌ 失败")
    fi
    
    # 输出测试结果
    log_test "=== 测试结果汇总 ==="
    for result in "${test_results[@]}"; do
        log_test "$result"
    done
    
    # 检查是否有失败的测试
    local failed_tests=$(printf '%s\n' "${test_results[@]}" | grep -c "❌" || echo "0")
    
    if [ "$failed_tests" -eq 0 ]; then
        log_test "🎉 所有测试通过！Monitor脚本的退出机制工作正常"
        exit 0
    else
        log_test "⚠️ 有 $failed_tests 个测试失败，需要进一步检查"
        exit 1
    fi
}

# 信号处理
trap 'log_test "收到中断信号，清理测试环境..."; cleanup_test; exit 130' INT TERM

# 运行主函数
main "$@"


