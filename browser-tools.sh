#!/bin/bash
###
# @Author: chenjie chenjie@huimei.com
# @Date: 2025-01-27 
 # @LastEditors: chenjie chenjie@huimei.com
 # @LastEditTime: 2025-10-27 16:36:04
# @FilePath: browser-tools.sh
# @Description: 合并的browser-tools启动和停止脚本，支持信号处理
### 

# 解析命令行参数
SET_CUSTOM_PATH=false
for arg in "$@"; do
    if [ "$arg" = "path=true" ]; then
        SET_CUSTOM_PATH=true
        break
    fi
done

# 获取脚本所在目录的绝对路径
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 根据参数决定是否设置自定义环境变量
if [ "$SET_CUSTOM_PATH" = true ]; then
    # 设置必要的环境变量，确保能找到node/npm/npx
    export PATH="/usr/local/opt/node@18/bin:/usr/local/bin:/usr/bin:/bin:$PATH"
    NPX_PATH=$(which npx 2>/dev/null || echo "/usr/local/opt/node@18/bin/npx")
else
    # 使用默认的npx路径
    NPX_PATH=$(which npx 2>/dev/null || echo "npx")
fi

# 设置日志文件和端口（使用绝对路径）
LOG_FILE="$SCRIPT_DIR/logs/browser-tools.log"
STOP_LOG_FILE="$SCRIPT_DIR/logs/browser-tools-stop.log"
SERVER_PORT=3025

# 立即创建logs目录并写入启动日志
mkdir -p "$SCRIPT_DIR/logs"
# 确保日志文件可写，并强制刷新
echo "$(date '+%Y-%m-%d %H:%M:%S') [INIT] browser-tools.sh脚本开始执行，PID: $$" >> "$LOG_FILE"
# 强制刷新文件系统缓冲区
sync

# 检测运行环境 - 是否在MCP模式下运行
IS_MCP_MODE=false

# 方法1: 检查是否有MCP相关环境变量
echo "$(date '+%Y-%m-%d %H:%M:%S') [DEBUG] 检查MCP环境变量: CURSOR_MCP_PROCESS=${CURSOR_MCP_PROCESS:-未设置}, MCP_SERVER=${MCP_SERVER:-未设置}" >> "$LOG_FILE"
if [ -n "$CURSOR_MCP_PROCESS" ] || [ -n "$MCP_SERVER" ]; then
    IS_MCP_MODE=true
    echo "$(date '+%Y-%m-%d %H:%M:%S') [DEBUG] 方法1检测到MCP模式" >> "$LOG_FILE"
fi

# 方法2: 检查父进程是否是Cursor相关进程
if [ "$IS_MCP_MODE" = false ]; then
    parent_pid=$(ps -o ppid= -p $$ 2>/dev/null | tr -d ' ')
    if [ -n "$parent_pid" ]; then
        parent_cmd=$(ps -p "$parent_pid" -o args= 2>/dev/null || echo "")
        if echo "$parent_cmd" | grep -qi "cursor\|vscode-webview"; then
            IS_MCP_MODE=true
        fi
    fi
fi

# 方法3: 检查进程树中是否有Cursor主进程
if [ "$IS_MCP_MODE" = false ]; then
    # 向上查找进程树，检查是否有Cursor进程
    current_pid=$$
    for i in {1..5}; do
        parent_pid=$(ps -o ppid= -p "$current_pid" 2>/dev/null | tr -d ' ')
        if [ -z "$parent_pid" ] || [ "$parent_pid" = "1" ]; then
            break
        fi
        parent_cmd=$(ps -p "$parent_pid" -o args= 2>/dev/null || echo "")
        if echo "$parent_cmd" | grep -qi "/Applications/Cursor.app\|vscode-webview\|vscode-file"; then
            IS_MCP_MODE=true
            break
        fi
        current_pid="$parent_pid"
    done
fi

# 方法4: 检查系统中是否有Cursor进程在运行
if [ "$IS_MCP_MODE" = false ]; then
    # 检查系统中是否有活跃的Cursor进程
    if ps -ef | grep "/Applications/Cursor.app" | grep "vscode-webview" | grep -v grep > /dev/null; then
        # 进一步检查是否可能通过MCP启动
        if [ -f "$HOME/.cursor/mcp.json" ]; then
            IS_MCP_MODE=true
        fi
    fi
fi

# 记录最终的模式检测结果
echo "$(date '+%Y-%m-%d %H:%M:%S') [DEBUG] 最终模式检测结果: IS_MCP_MODE=$IS_MCP_MODE" >> "$LOG_FILE"

# PID文件路径（使用绝对路径）
SERVER_PID_FILE="$SCRIPT_DIR/logs/browser-tools-shared-server.pid"
MCP_PID_FILE="$SCRIPT_DIR/logs/browser-tools-mcp.pid"
ALL_PIDS_FILE="$SCRIPT_DIR/logs/browser-tools-all-pids.txt"

# 记录日志到文件，但不输出到标准输出
log_file() {
    # 使用更可靠的日志写入方式
    echo "$(date '+%Y-%m-%d %H:%M:%S') $1" >> "$LOG_FILE" 2>/dev/null || {
        # 如果写入失败，尝试创建目录并重试
        mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null
        echo "$(date '+%Y-%m-%d %H:%M:%S') $1" >> "$LOG_FILE" 2>/dev/null
    }
    # 强制刷新到磁盘
    sync 2>/dev/null || true
}

# 安全输出函数 - 根据运行模式决定输出方式
safe_output() {
    local message="$1"
    if [ "$IS_MCP_MODE" = true ]; then
        # MCP模式下只写日志，避免干扰JSON通信
        log_file "$message"
    else
        # 终端模式下可以正常输出到stdout
        echo "$message"
        log_file "$message"
    fi
}

# 诊断MCP客户端退出原因
diagnose_mcp_exit() {
    local mcp_pid=$1
    local exit_code=$2
    
    log_file "===== MCP客户端退出诊断 ====="
    log_file "进程ID: $mcp_pid"
    log_file "退出码: $exit_code"
    log_file "退出时间: $(date)"
    
    # 检查系统资源
    log_file "系统资源状态:"
    log_file "  内存使用: $(free -m 2>/dev/null || vm_stat 2>/dev/null | head -5 || echo '无法获取内存信息')"
    log_file "  CPU负载: $(uptime 2>/dev/null || echo '无法获取负载信息')"
    
    # 检查网络连接
    log_file "网络连接状态:"
    if lsof -i:$ACTUAL_PORT > /dev/null 2>&1; then
        log_file "  端口 $ACTUAL_PORT 仍在监听"
        # 显示监听进程详情
        local port_info=$(lsof -i:$ACTUAL_PORT 2>/dev/null | head -5)
        if [ -n "$port_info" ]; then
            echo "$port_info" | while IFS= read -r line; do
                log_file "    $line"
            done
        fi
    else
        log_file "  端口 $ACTUAL_PORT 未在监听"
    fi
    
    # 检查最近的错误日志
    if [ -f $LOG_FILE ]; then
        log_file "最近的服务器日志 (最后20行):"
        tail -20 $LOG_FILE | grep -v "Unhandled message type: heartbeat" | while IFS= read -r line; do
            log_file "  $line"
        done
    fi
    
    # 分析可能的退出原因
    case $exit_code in
        0)
            log_file "分析: 正常退出，可能是接收到终止信号"
            ;;
        1)
            log_file "分析: 一般错误，可能是配置或连接问题"
            ;;
        2)
            log_file "分析: 参数错误，检查命令行参数"
            ;;
        130)
            log_file "分析: 收到SIGINT信号（Ctrl+C）"
            ;;
        143)
            log_file "分析: 收到SIGTERM信号"
            ;;
        *)
            log_file "分析: 未知退出码，可能是崩溃或异常终止"
            ;;
    esac
    
    log_file "===== 诊断结束 ====="
}

# 记录停止日志到文件
log_stop() {
    echo "$1" >> $STOP_LOG_FILE
}

# 记录进程PID到文件
record_pid() {
    local pid=$1
    local description=$2
    echo "$pid:$description:$(date)" >> $ALL_PIDS_FILE
    log_file "记录进程PID: $pid ($description)"
}

# 选择性终止server相关进程（仅终止包含browser-tools-server的进程树分支）
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
                log_stop "递归终止server子进程: $child"
                kill_server_process_tree "$child" "$signal"
            else
                log_stop "跳过非server子进程: $child ($child_cmd)"
            fi
        fi
    done
    
    # 如果当前进程是server相关进程，则终止它
    if [ "$is_server_process" = true ]; then
        log_stop "终止server进程: $pid (信号: $signal)"
        log_stop "进程命令: $process_cmd"
        
        kill -"$signal" "$pid" 2>/dev/null || true
        
        # 如果是TERM信号，等待一下再检查
        if [ "$signal" = "TERM" ]; then
            sleep 1
            if ps -p "$pid" > /dev/null 2>&1; then
                log_stop "server进程 $pid 未响应TERM信号，使用KILL信号"
                kill -KILL "$pid" 2>/dev/null || true
            fi
        fi
    else
        log_stop "跳过非server进程: $pid ($process_cmd)"
    fi
}

# 验证PID是否为我们启动的主进程
validate_main_process_pid() {
    local pid=$1
    local process_type=$2  # "server" 或 "mcp"
    
    if [ -z "$pid" ] || ! ps -p "$pid" > /dev/null 2>&1; then
        log_stop "PID验证失败: 进程 $pid 不存在"
        return 1  # 进程不存在
    fi
    
    # 获取进程命令
    local process_cmd=$(ps -p "$pid" -o args= 2>/dev/null || echo "")
    if [ -z "$process_cmd" ]; then
        process_cmd=$(ps -p "$pid" -o comm= 2>/dev/null || echo "")
        if [ -z "$process_cmd" ]; then
            log_stop "PID验证失败: 无法获取进程 $pid 的命令信息"
            return 1
        fi
    fi
    
    # 系统安全检查 - 绝对不能终止系统关键进程
    # 在MCP模式下，额外保护Cursor进程
    if [ "$IS_MCP_MODE" = true ]; then
        if echo "$process_cmd" | grep -qiE "(Cursor|Code|VSCode|Electron|Chrome|Safari|Firefox|System|Kernel|launchd|systemd|init|ssh|sshd|Terminal|Finder|Dock|Helper|Framework|crashpad|TextInput)"; then
            log_stop "🛑 MCP模式安全检查: 拒绝终止系统关键进程 PID $pid: $process_cmd"
            return 1  # 绝对不安全
        fi
    else
        # 非MCP模式下的原有逻辑，但排除Cursor相关检查
        if echo "$process_cmd" | grep -qiE "(System|Kernel|launchd|systemd|init|ssh|sshd|Terminal|Finder|Dock|Helper|Framework|crashpad|TextInput)"; then
            log_stop "🛑 安全检查: 拒绝终止系统关键进程 PID $pid: $process_cmd"
            return 1  # 绝对不安全
        fi
    fi
    
    # 检查系统路径
    if echo "$process_cmd" | grep -qiE "(/Applications/|/System/|/Library/|/usr/bin/|/bin/|/sbin/)"; then
        log_stop "🛑 安全检查: 拒绝终止系统路径进程 PID $pid: $process_cmd"
        return 1  # 系统进程
    fi
    
    # 验证是否是我们启动的browser-tools进程
    if echo "$process_cmd" | grep -q "@agentdeskai.*browser-tools-$process_type"; then
        log_stop "✅ PID验证通过: $pid 是browser-tools-$process_type主进程"
        return 0  # 验证通过
    else
        log_stop "⚠️ PID验证失败: $pid 不是预期的browser-tools-$process_type进程: $process_cmd"
        return 1  # 不匹配
    fi
}

# 安全终止主进程PID（包含进程组管理）
safe_kill_main_process() {
    local pid=$1
    local process_type=$2  # "server" 或 "mcp"
    local description=$3
    
    if [ -z "$pid" ]; then
        log_stop "❌ 错误: 未提供PID"
        return 1
    fi
    
    # 验证PID
    if ! validate_main_process_pid "$pid" "$process_type"; then
        log_stop "❌ 跳过PID $pid: 验证失败"
        return 1
    fi
    
    log_stop "🔄 正在终止主进程: $pid ($description)"
    
    # 🎯 新的安全终止策略：递归终止子进程，避免进程组问题
    log_stop "🔍 查找进程 $pid 的所有子进程..."
    
    # 递归查找并终止所有子进程
    terminate_process_tree() {
        local parent_pid=$1
        local level=$2
        
        # 查找直接子进程
        local children=$(pgrep -P "$parent_pid" 2>/dev/null || echo "")
        if [ -n "$children" ]; then
            log_stop "📋 进程 $parent_pid 的子进程 (级别$level): $children"
            for child in $children; do
                # 验证子进程是否安全
                local child_cmd=$(ps -p "$child" -o args= 2>/dev/null || echo "")
                if echo "$child_cmd" | grep -qiE "(Cursor|Code|VSCode|Electron|vscode-webview|vscode-file|/Applications/Cursor.app)"; then
                    log_stop "🛑 跳过系统关键子进程: $child ($child_cmd)"
                    continue
                fi
                
                # 递归处理孙进程
                if [ $level -lt 3 ]; then  # 限制递归深度
                    terminate_process_tree "$child" $((level + 1))
                fi
                
                # 终止子进程
                log_stop "🎯 终止子进程: $child"
                kill -TERM "$child" 2>/dev/null || true
            done
            
            # 等待子进程退出
            sleep 2
            
            # 强制终止仍在运行的子进程
            for child in $children; do
                if ps -p "$child" > /dev/null 2>&1; then
                    log_stop "⚡ 强制终止子进程: $child"
                    kill -9 "$child" 2>/dev/null || true
                fi
            done
        else
            log_stop "📋 进程 $parent_pid 没有子进程 (级别$level)"
        fi
    }
    
    # 开始递归终止进程树
    terminate_process_tree "$pid" 1
    
    # 单独处理主进程（如果还在运行）
    if ps -p "$pid" > /dev/null 2>&1; then
        log_stop "🎯 单独终止主进程 $pid"
        kill -9 "$pid" 2>/dev/null || true
        sleep 1
    fi
    
    # 最终验证
    if ps -p "$pid" > /dev/null 2>&1; then
        log_stop "⚠️ 警告: 主进程 $pid 仍在运行"
        return 1
    else
        log_stop "✅ 主进程 $pid 及其子进程已成功终止"
        return 0
    fi
}

# 安全检查函数：确保不会误杀系统关键进程
is_safe_to_kill() {
    local pid=$1
    local process_cmd=$2
    
    # 在MCP模式下，严格保护所有系统进程
    if [ "$IS_MCP_MODE" = true ]; then
        # MCP模式下绝对不能终止任何系统进程，特别是Cursor相关进程
        if echo "$process_cmd" | grep -qiE "(cursor|code|vscode|electron|chrome|safari|firefox|system|kernel|launchd|systemd|init|ssh|sshd|Terminal|Finder|Dock|Helper|Framework|crashpad|TextInput|CursorUI|vscode-webview|vscode-file|/Applications/Cursor.app)"; then
            return 1  # 不安全，不能终止
        fi
    else
        # 终端模式下的检查，但仍然保护关键系统进程
        if echo "$process_cmd" | grep -qiE "(system|kernel|launchd|systemd|init|ssh|sshd|Terminal|Finder|Dock|Helper|Framework|crashpad|TextInput)"; then
            return 1  # 不安全，不能终止
        fi
    fi
    
    # 检查进程路径是否在系统目录中
    if echo "$process_cmd" | grep -qiE "(/Applications/|/System/|/Library/|/usr/bin/|/bin/|/sbin/)"; then
        return 1  # 系统进程，不能终止
    fi
    
    # 检查进程命令是否明确包含browser-tools相关关键词
    if echo "$process_cmd" | grep -qiE "(browser-tools-server|browser-tools-mcp|@agentdeskai.*browser-tools)"; then
        return 0  # 安全，可以终止
    fi
    
    # 检查是否是npm/npx启动的browser-tools进程
    if echo "$process_cmd" | grep -qiE "(npm exec.*browser-tools|npx.*browser-tools)"; then
        return 0  # 安全，可以终止
    fi
    
    # 默认情况下，为了安全起见，不终止未明确确认的进程
    return 1  # 不安全，不能终止
}

# 更安全的进程查找函数
find_browser_tools_processes() {
    local pattern=$1
    local processes=""
    
    # 使用更精确的匹配方式
    case $pattern in
        "browser-tools-server")
            # 只匹配包含完整browser-tools-server字符串的进程
            processes=$(pgrep -f 'browser-tools-server' 2>/dev/null | while read pid; do
                if [ -n "$pid" ]; then
                    process_cmd=$(ps -p $pid -o cmd --no-headers 2>/dev/null || echo "")
                    if echo "$process_cmd" | grep -q "browser-tools-server"; then
                        echo "$pid"
                    fi
                fi
            done)
            ;;
        "browser-tools-mcp")
            # 只匹配包含完整browser-tools-mcp字符串的进程
            processes=$(pgrep -f 'browser-tools-mcp' 2>/dev/null | while read pid; do
                if [ -n "$pid" ]; then
                    process_cmd=$(ps -p $pid -o cmd --no-headers 2>/dev/null || echo "")
                    if echo "$process_cmd" | grep -q "browser-tools-mcp"; then
                        echo "$pid"
                    fi
                fi
            done)
            ;;
        "npm-browser-tools")
            # 匹配npm exec browser-tools进程
            processes=$(pgrep -f 'npm exec.*browser-tools' 2>/dev/null | while read pid; do
                if [ -n "$pid" ]; then
                    process_cmd=$(ps -p $pid -o cmd --no-headers 2>/dev/null || echo "")
                    if echo "$process_cmd" | grep -q "npm exec" && echo "$process_cmd" | grep -q "browser-tools"; then
                        echo "$pid"
                    fi
                fi
            done)
            ;;
        "npx-browser-tools")
            # 匹配npx browser-tools进程
            processes=$(pgrep -f 'npx.*browser-tools' 2>/dev/null | while read pid; do
                if [ -n "$pid" ]; then
                    process_cmd=$(ps -p $pid -o cmd --no-headers 2>/dev/null || echo "")
                    if echo "$process_cmd" | grep -q "npx" && echo "$process_cmd" | grep -q "browser-tools"; then
                        echo "$pid"
                    fi
                fi
            done)
            ;;
    esac
    
    echo "$processes"
}

# 安全检测进程函数 - 只检测不终止
safe_detect_process() {
    local pid=$1
    local description=$2
    
    if [ -z "$pid" ]; then
        log_stop "⚠️ 检测失败: 未提供PID"
        return 1
    fi
    
    # 检查进程是否存在
    if ! ps -p "$pid" > /dev/null 2>&1; then
        log_stop "📋 进程检测: PID $pid 不存在"
        return 1
    fi
    
    # 获取进程详细信息
    local process_cmd=$(ps -p "$pid" -o args= 2>/dev/null || echo "")
    local process_comm=$(ps -p "$pid" -o comm= 2>/dev/null || echo "")
    local process_info=$(ps -p "$pid" -o pid,ppid,user,comm,args 2>/dev/null || echo "")
    
    log_stop "🔍 进程检测结果 ($description):"
    log_stop "    PID: $pid"
    log_stop "    命令行: $process_cmd"
    log_stop "    进程名: $process_comm"
    log_stop "    详细信息:"
    echo "$process_info" | while IFS= read -r line; do
        log_stop "      $line"
    done
    
    # 安全性检查
    if echo "$process_cmd" | grep -qiE "(Cursor|Code|VSCode|Electron|Chrome|Safari|Firefox|System|Kernel|launchd|systemd|init|ssh|sshd|Terminal|Finder|Dock|Helper|Framework|crashpad|TextInput|/Applications/Cursor.app|vscode-webview|vscode-file)"; then
        log_stop "🛑 安全警告: PID $pid 是系统关键进程，不应终止!"
        log_stop "    匹配的关键词: $(echo "$process_cmd" | grep -ioE "(Cursor|Code|VSCode|Electron|Chrome|Safari|Firefox|System|Kernel|launchd|systemd|init|ssh|sshd|Terminal|Finder|Dock|Helper|Framework|crashpad|TextInput|/Applications/Cursor.app|vscode-webview|vscode-file)" | head -3 | tr '\n' ' ')"
        return 1
    fi
    
    # 检查是否是browser-tools进程
    if echo "$process_cmd" | grep -q "@agentdeskai.*browser-tools"; then
        log_stop "✅ 确认: PID $pid 是browser-tools相关进程"
        return 0
    else
        log_stop "❌ 警告: PID $pid 不是预期的browser-tools进程"
        return 1
    fi
}

# MCP安全模式的停止服务函数 - 只检测不终止
stop_services_mcp_safe() {
    log_stop "===== MCP安全模式停止服务 $(date) ====="
    echo "正在安全检测browser-tools进程（MCP模式 - 仅检测不终止）..."
    log_stop "正在安全检测browser-tools进程（MCP模式 - 仅检测不终止）..."
    
    local detected_count=0
    local safe_count=0
    local unsafe_count=0
    
    # 只检测PID文件中记录的主进程，不进行终止操作
    
    # 1. 检测MCP客户端主进程
    if [ -f "$MCP_PID_FILE" ]; then
        MCP_PID=$(cat "$MCP_PID_FILE" 2>/dev/null)
        if [ -n "$MCP_PID" ]; then
            echo "检测MCP客户端主进程 (PID: $MCP_PID)..."
            detected_count=$((detected_count + 1))
            if safe_detect_process "$MCP_PID" "MCP客户端"; then
                safe_count=$((safe_count + 1))
                log_stop "✅ MCP进程 $MCP_PID 检测安全，可以终止"
            else
                unsafe_count=$((unsafe_count + 1))
                log_stop "🛑 MCP进程 $MCP_PID 检测不安全，不应终止!"
            fi
        fi
    else
        log_stop "📋 未找到MCP客户端PID文件: $MCP_PID_FILE"
    fi
    
    # 2. 检测服务器主进程
    if [ -f "$SERVER_PID_FILE" ]; then
        SERVER_PID=$(cat "$SERVER_PID_FILE" 2>/dev/null)
        if [ -n "$SERVER_PID" ]; then
            echo "检测服务器主进程 (PID: $SERVER_PID)..."
            detected_count=$((detected_count + 1))
            if safe_detect_process "$SERVER_PID" "服务器"; then
                safe_count=$((safe_count + 1))
                log_stop "✅ 服务器进程 $SERVER_PID 检测安全，可以终止"
            else
                unsafe_count=$((unsafe_count + 1))
                log_stop "🛑 服务器进程 $SERVER_PID 检测不安全，不应终止!"
            fi
        fi
    else
        log_stop "📋 未找到服务器PID文件: $SERVER_PID_FILE"
    fi
    
    log_stop "===== MCP安全模式检测报告 ====="
    log_stop "检测到的进程数: $detected_count"
    log_stop "安全可终止进程数: $safe_count"
    log_stop "不安全进程数: $unsafe_count"
    
    if [ $unsafe_count -gt 0 ]; then
        log_stop "🛑 检测到不安全进程，停止操作以保护系统"
        echo "🛑 检测到不安全进程，已停止终止操作以保护系统"
        echo "详细信息请查看日志: $STOP_LOG_FILE"
    else
        log_stop "✅ 所有检测的进程都是安全的browser-tools进程"
        echo "✅ 进程检测完成，所有进程都是安全的"
    fi
    
    echo "⚠️ 当前为安全检测模式，未实际终止任何进程"
    log_stop "⚠️ 安全检测模式完成，未实际终止任何进程"
}

# MCP静默模式的停止服务函数 - 简化版，只处理server进程
stop_services_mcp_silent() {
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S.%3N')
    
    log_stop "$timestamp [info] ===== MCP静默模式停止服务 (仅清理server进程) ====="
    
    local terminated_count=0
    local failed_count=0
    
    # 注意：MCP客户端进程由Cursor管理，无需脚本处理
    log_stop "$timestamp [info] MCP客户端进程由Cursor管理，跳过处理"
    
    # 只处理服务器主进程树
    if [ -f "$SERVER_PID_FILE" ]; then
        SERVER_PID=$(cat "$SERVER_PID_FILE" 2>/dev/null)
        if [ -n "$SERVER_PID" ] && ps -p "$SERVER_PID" > /dev/null 2>&1; then
            local process_cmd=$(ps -p "$SERVER_PID" -o args= 2>/dev/null || echo "未知命令")
            
            log_stop "$timestamp [info] 发现并终止服务器进程树 $SERVER_PID"
            log_stop "$timestamp [info] 命令: $process_cmd"
            
            # 修改安全检查：支持多种browser-tools-server进程格式
            if echo "$process_cmd" | grep -qE "(browser-tools-server|@agentdeskai.*browser-tools)"; then
                # 使用选择性进程树终止
                kill_server_process_tree "$SERVER_PID" "TERM"
                sleep 1
                
                # 检查server进程是否被终止
                local remaining_server_processes=$(ps -ef | grep "browser-tools-server" | grep -v grep | wc -l | tr -d ' ')
                if [ "$remaining_server_processes" -eq 0 ]; then
                    log_stop "$timestamp [info] ✅ 服务器进程树已成功终止"
                    terminated_count=$((terminated_count + 1))
                else
                    log_stop "$timestamp [warn] 部分服务器进程可能仍在运行 (剩余: $remaining_server_processes)"
                    # 显示剩余的server进程
                    ps -ef | grep "browser-tools-server" | grep -v grep | while IFS= read -r line; do
                        log_stop "$timestamp [info] 剩余server进程: $line"
                    done
                    failed_count=$((failed_count + 1))
                fi
            else
                log_stop "$timestamp [warn] 服务器进程安全检查失败，跳过终止: $process_cmd"
                failed_count=$((failed_count + 1))
            fi
        else
            log_stop "$timestamp [info] 服务器进程不存在或已退出"
        fi
        rm -f "$SERVER_PID_FILE"
    else
        log_stop "$timestamp [info] 未找到服务器PID文件"
    fi
    
    # 清理其他记录文件
    if [ -f "$ALL_PIDS_FILE" ]; then
        log_stop "$timestamp [info] 清理进程记录文件: $ALL_PIDS_FILE"
        rm -f "$ALL_PIDS_FILE"
    fi
    
    # 清理MCP PID文件（如果存在）
    if [ -f "$MCP_PID_FILE" ]; then
        log_stop "$timestamp [info] 清理MCP PID文件: $MCP_PID_FILE"
        rm -f "$MCP_PID_FILE"
    fi
    
    # 生成终止报告
    log_stop "$timestamp [info] ===== MCP静默模式终止报告 ====="
    log_stop "$timestamp [info] 服务器进程终止数: $terminated_count"
    log_stop "$timestamp [info] 终止失败进程数: $failed_count"
    log_stop "$timestamp [info] MCP客户端进程由Cursor自动管理"
    
    if [ $failed_count -eq 0 ]; then
        log_stop "$timestamp [info] ✅ 所有browser-tools进程已安全终止"
    else
        log_stop "$timestamp [warn] ⚠️ 部分进程终止失败"
    fi
}

# 辅助函数：根据模式输出日志
output_log() {
    local message="$1"
    local silent_mode="$2"
    
    if [ "$silent_mode" = true ]; then
        log_stop "$message"
    else
        echo "$message"
        log_stop "$message"
    fi
}

# MCP增强模式的停止服务函数 - 带详细输出的实际终止
stop_services_mcp_enhanced() {
    local silent_mode=${1:-false}  # 第一个参数控制是否静默模式（不输出到标准输出）
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S.%3N')
    
    output_log "$timestamp [info] ===== MCP增强模式停止服务 =====" "$silent_mode"
    
    local terminated_count=0
    local failed_count=0
    local skipped_count=0
    
    # 1. 处理MCP客户端主进程
    if [ -f "$MCP_PID_FILE" ]; then
        MCP_PID=$(cat "$MCP_PID_FILE" 2>/dev/null)
        if [ -n "$MCP_PID" ] && ps -p "$MCP_PID" > /dev/null 2>&1; then
            # 获取进程详细信息
            local process_info=$(ps -p "$MCP_PID" -o pid,ppid,user,comm,args 2>/dev/null || echo "进程信息获取失败")
            local process_cmd=$(ps -p "$MCP_PID" -o args= 2>/dev/null || echo "未知命令")
            
            output_log "$timestamp [info] 发现MCP客户端进程:" "$silent_mode"
            output_log "$timestamp [info]   PID: $MCP_PID" "$silent_mode"
            output_log "$timestamp [info]   命令: $process_cmd" "$silent_mode"
            output_log "$timestamp [info]   详细信息: $process_info" "$silent_mode"
            
            # 安全检查
            if echo "$process_cmd" | grep -q "@agentdeskai.*browser-tools"; then
                output_log "$timestamp [info] 正在终止MCP客户端进程 $MCP_PID..." "$silent_mode"
                log_stop "正在终止MCP客户端进程 $MCP_PID: $process_cmd"
                
                # 优雅终止
                if kill -TERM "$MCP_PID" 2>/dev/null; then
                    sleep 2
                    if ps -p "$MCP_PID" > /dev/null 2>&1; then
                        output_log "$timestamp [info] 强制终止MCP客户端进程 $MCP_PID" "$silent_mode"
                        kill -9 "$MCP_PID" 2>/dev/null || true
                        sleep 1
                    fi
                    
                    if ps -p "$MCP_PID" > /dev/null 2>&1; then
                        echo "$timestamp [warn] MCP客户端进程 $MCP_PID 终止失败"
                        log_stop "❌ MCP客户端进程 $MCP_PID 终止失败"
                        failed_count=$((failed_count + 1))
                    else
                        output_log "$timestamp [info] ✅ MCP客户端进程 $MCP_PID 已成功终止" "$silent_mode"
                        log_stop "✅ MCP客户端进程 $MCP_PID 已成功终止"
                        terminated_count=$((terminated_count + 1))
                    fi
                else
                    echo "$timestamp [warn] 无法发送终止信号给MCP客户端进程 $MCP_PID"
                    log_stop "❌ 无法发送终止信号给MCP客户端进程 $MCP_PID"
                    failed_count=$((failed_count + 1))
                fi
            else
                echo "$timestamp [warn] MCP进程 $MCP_PID 安全检查失败，跳过终止: $process_cmd"
                log_stop "🛑 MCP进程 $MCP_PID 安全检查失败，跳过终止: $process_cmd"
                skipped_count=$((skipped_count + 1))
            fi
        else
            output_log "$timestamp [info] MCP客户端进程不存在或已退出" "$silent_mode"
            log_stop "📋 MCP客户端进程不存在或已退出"
        fi
        rm -f "$MCP_PID_FILE"
    else
        output_log "$timestamp [info] 未找到MCP客户端PID文件" "$silent_mode"
        log_stop "📋 未找到MCP客户端PID文件: $MCP_PID_FILE"
    fi
    
    # 2. 处理服务器主进程
    if [ -f "$SERVER_PID_FILE" ]; then
        SERVER_PID=$(cat "$SERVER_PID_FILE" 2>/dev/null)
        if [ -n "$SERVER_PID" ] && ps -p "$SERVER_PID" > /dev/null 2>&1; then
            # 获取进程详细信息
            local process_info=$(ps -p "$SERVER_PID" -o pid,ppid,user,comm,args 2>/dev/null || echo "进程信息获取失败")
            local process_cmd=$(ps -p "$SERVER_PID" -o args= 2>/dev/null || echo "未知命令")
            
            output_log "$timestamp [info] 发现服务器进程:" "$silent_mode"
            output_log "$timestamp [info]   PID: $SERVER_PID" "$silent_mode"
            output_log "$timestamp [info]   命令: $process_cmd" "$silent_mode"
            output_log "$timestamp [info]   详细信息: $process_info" "$silent_mode"
            
            # 安全检查
            if echo "$process_cmd" | grep -q "@agentdeskai.*browser-tools"; then
                output_log "$timestamp [info] 正在终止服务器进程 $SERVER_PID..." "$silent_mode"
                log_stop "正在终止服务器进程 $SERVER_PID: $process_cmd"
                
                # 优雅终止
                if kill -TERM "$SERVER_PID" 2>/dev/null; then
                    sleep 2
                    if ps -p "$SERVER_PID" > /dev/null 2>&1; then
                        output_log "$timestamp [info] 强制终止服务器进程 $SERVER_PID" "$silent_mode"
                        kill -9 "$SERVER_PID" 2>/dev/null || true
                        sleep 1
                    fi
                    
                    if ps -p "$SERVER_PID" > /dev/null 2>&1; then
                        echo "$timestamp [warn] 服务器进程 $SERVER_PID 终止失败"
                        log_stop "❌ 服务器进程 $SERVER_PID 终止失败"
                        failed_count=$((failed_count + 1))
                    else
                        output_log "$timestamp [info] ✅ 服务器进程 $SERVER_PID 已成功终止" "$silent_mode"
                        log_stop "✅ 服务器进程 $SERVER_PID 已成功终止"
                        terminated_count=$((terminated_count + 1))
                    fi
                else
                    echo "$timestamp [warn] 无法发送终止信号给服务器进程 $SERVER_PID"
                    log_stop "❌ 无法发送终止信号给服务器进程 $SERVER_PID"
                    failed_count=$((failed_count + 1))
                fi
            else
                echo "$timestamp [warn] 服务器进程 $SERVER_PID 安全检查失败，跳过终止: $process_cmd"
                log_stop "🛑 服务器进程 $SERVER_PID 安全检查失败，跳过终止: $process_cmd"
                skipped_count=$((skipped_count + 1))
            fi
        else
            output_log "$timestamp [info] 服务器进程不存在或已退出" "$silent_mode"
            log_stop "📋 服务器进程不存在或已退出"
        fi
        rm -f "$SERVER_PID_FILE"
    else
        output_log "$timestamp [info] 未找到服务器PID文件" "$silent_mode"
        log_stop "📋 未找到服务器PID文件: $SERVER_PID_FILE"
    fi
    
    # 3. 清理其他记录文件
    if [ -f "$ALL_PIDS_FILE" ]; then
        output_log "$timestamp [info] 清理进程记录文件: $ALL_PIDS_FILE" "$silent_mode"
        log_stop "清理进程记录文件: $ALL_PIDS_FILE"
        rm -f "$ALL_PIDS_FILE"
    fi
    
    # 4. 检查端口释放情况
    if [ -n "$ACTUAL_PORT" ]; then
        output_log "$timestamp [info] 检查端口 $ACTUAL_PORT 释放情况..." "$silent_mode"
        if lsof -i:$ACTUAL_PORT > /dev/null 2>&1; then
            echo "$timestamp [warn] 端口 $ACTUAL_PORT 仍被占用"
            local port_info=$(lsof -i:$ACTUAL_PORT 2>/dev/null | head -5)
            if [ -n "$port_info" ]; then
                output_log "$timestamp [info] 占用端口的进程:" "$silent_mode"
                echo "$port_info" | while IFS= read -r line; do
                    output_log "$timestamp [info]   $line" "$silent_mode"
                done
            fi
        else
            output_log "$timestamp [info] 端口 $ACTUAL_PORT 已释放" "$silent_mode"
        fi
    fi
    
    # 5. 生成终止报告
    output_log "$timestamp [info] ===== MCP增强模式终止报告 =====" "$silent_mode"
    output_log "$timestamp [info] 成功终止进程数: $terminated_count" "$silent_mode"
    output_log "$timestamp [info] 终止失败进程数: $failed_count" "$silent_mode"
    output_log "$timestamp [info] 跳过进程数: $skipped_count" "$silent_mode"
    
    log_stop "===== MCP增强模式终止报告 ====="
    log_stop "成功终止进程数: $terminated_count"
    log_stop "终止失败进程数: $failed_count"
    log_stop "跳过进程数: $skipped_count"
    
    if [ $failed_count -eq 0 ]; then
        output_log "$timestamp [info] ✅ 所有browser-tools进程已安全终止" "$silent_mode"
        log_stop "✅ 所有browser-tools进程已安全终止"
    else
        echo "$timestamp [warn] ⚠️ 部分进程终止失败，详情请查看: $STOP_LOG_FILE"
        log_stop "⚠️ 部分进程终止失败"
    fi
}

# 停止服务函数 - 基于PID文件的精确停止
stop_services() {
    log_stop "===== 停止服务 $(date) ====="
    echo "正在停止browser-tools服务..."
    log_stop "正在停止browser-tools服务..."
    
    local stopped_count=0
    local failed_count=0
    
    # 显示占用端口3025的进程
    if lsof -i:3025 >/dev/null 2>&1; then
        log_stop "端口3025被以下进程占用："
        lsof -i:3025 | while IFS= read -r line; do
            log_stop "  $line"
        done
    fi
    
    # 1. 停止MCP客户端主进程
    if [ -f "$MCP_PID_FILE" ]; then
        MCP_PID=$(cat "$MCP_PID_FILE" 2>/dev/null)
        if [ -n "$MCP_PID" ]; then
            echo "检测MCP客户端主进程 (PID: $MCP_PID)..."
            if safe_detect_process "$MCP_PID" "MCP客户端"; then
                echo "✅ MCP进程检测安全，但当前为检测模式"
                log_stop "⚠️ 检测模式: MCP进程未实际终止 (PID: $MCP_PID)"
                stopped_count=$((stopped_count + 1))  # 模拟成功
            else
                echo "🛑 MCP进程检测不安全，跳过终止操作"
                log_stop "🛑 MCP进程 $MCP_PID 检测不安全，已跳过终止操作"
                failed_count=$((failed_count + 1))
            fi
        fi
        rm -f "$MCP_PID_FILE"
    else
        log_stop "未找到MCP客户端PID文件: $MCP_PID_FILE"
    fi
    
    # 2. 停止服务器主进程
    if [ -f "$SERVER_PID_FILE" ]; then
        SERVER_PID=$(cat "$SERVER_PID_FILE" 2>/dev/null)
        if [ -n "$SERVER_PID" ]; then
            echo "检测服务器主进程 (PID: $SERVER_PID)..."
            if safe_detect_process "$SERVER_PID" "服务器"; then
                echo "✅ 服务器进程检测安全，但当前为检测模式"
                log_stop "⚠️ 检测模式: 服务器进程未实际终止 (PID: $SERVER_PID)"
                stopped_count=$((stopped_count + 1))  # 模拟成功
            else
                echo "🛑 服务器进程检测不安全，跳过终止操作"
                log_stop "🛑 服务器进程 $SERVER_PID 检测不安全，已跳过终止操作"
                failed_count=$((failed_count + 1))
            fi
        fi
        rm -f "$SERVER_PID_FILE"
    else
        log_stop "未找到服务器PID文件: $SERVER_PID_FILE"
    fi
    
    # 3. 清理PID记录文件（所有主进程已在上面处理）
    if [ -f "$ALL_PIDS_FILE" ]; then
        log_stop "清理进程记录文件: $ALL_PIDS_FILE"
        rm -f "$ALL_PIDS_FILE"
    fi
    
    # 4. 等待端口释放
    echo "检查端口$SERVER_PORT是否已释放..."
    log_stop "检查端口$SERVER_PORT是否已释放..."
    
    for i in {1..5}; do
        if lsof -i:$SERVER_PORT > /dev/null 2>&1; then
            log_stop "等待端口$SERVER_PORT释放... (尝试 $i/5)"
            if [ $i -eq 5 ]; then
                echo "警告: 端口$SERVER_PORT仍被占用"
                log_stop "警告: 端口$SERVER_PORT仍被占用"
                # 显示占用端口的进程
                port_processes=$(lsof -i:$SERVER_PORT 2>/dev/null || true)
                if [ -n "$port_processes" ]; then
                    log_stop "占用端口$SERVER_PORT的进程："
                    echo "$port_processes" | while IFS= read -r line; do
                        log_stop "  $line"
                    done
                fi
            else
                sleep 1
            fi
        else
            echo "端口$SERVER_PORT已释放"
            log_stop "端口$SERVER_PORT已释放"
            break
        fi
    done
    
    # 5. 生成停止报告
    echo "browser-tools服务停止完成"
    log_stop "===== 停止报告 ====="
    log_stop "成功停止进程数: $stopped_count"
    log_stop "失败/跳过进程数: $failed_count"
    
    if [ $failed_count -eq 0 ]; then
        log_stop "✅ 所有记录的进程都已成功停止"
        echo "✅ 所有进程已安全停止"
    else
        log_stop "⚠️ 部分进程停止失败，请检查日志"
        echo "⚠️ 部分进程停止失败，详情请查看: $STOP_LOG_FILE"
    fi
    
    log_stop "browser-tools服务已停止"
    log_stop "停止日志保存在: $STOP_LOG_FILE"
    log_file "服务已通过PID管理安全停止 $(date)"
}

# 全局变量用于跟踪进程
SERVER_PID=""
MCP_PID=""
MONITOR_PID=""

# 增强的信号处理器
cleanup_and_exit() {
    local signal=$1
    log_file "收到信号 $signal，开始清理服务..."
    
    # 创建关闭信号文件，告知MCP客户端这是正常关闭
    touch "$SCRIPT_DIR/logs/browser-tools-shutdown"
    
    # 在MCP模式下，只输出到日志文件，避免干扰JSON通信
    if [ "$IS_MCP_MODE" = true ]; then
        log_file "$(date '+%Y-%m-%d %H:%M:%S.%3N') [info] 收到信号 $signal，开始清理browser-tools服务..."
        log_file "$(date '+%Y-%m-%d %H:%M:%S.%3N') [info] MCP模式: 开始清理记录的进程..."
        stop_services_mcp_silent  # 使用专门的静默版本
        log_file "$(date '+%Y-%m-%d %H:%M:%S.%3N') [info] browser-tools服务清理完成"
    else
        # 终端模式可以正常输出到标准输出
        safe_output "收到信号 $signal，开始清理browser-tools服务..."
        safe_output "终端模式: 开始停止所有browser-tools服务..."
        stop_services
        safe_output "browser-tools服务清理完成"
    fi
    exit 0
}

# 设置信号处理器 - 监听更多信号
trap 'cleanup_and_exit SIGTERM' SIGTERM
trap 'cleanup_and_exit SIGINT' SIGINT
trap 'cleanup_and_exit SIGHUP' SIGHUP
trap 'cleanup_and_exit SIGQUIT' SIGQUIT
trap 'cleanup_and_exit SIGUSR1' SIGUSR1
trap 'cleanup_and_exit SIGUSR2' SIGUSR2

# 启动服务函数
start_services() {
    # 清空日志文件
    > "$LOG_FILE"
    > "$STOP_LOG_FILE"
    
    # 启动服务前先停止所有已经在运行的browser-tools相关进程
    log_file "===== 启动服务 $(date) ====="
    log_file "正在停止所有现有的browser-tools服务..."
    
    # 使用精确的PID管理停止现有服务
    if [ -f "$SERVER_PID_FILE" ] || [ -f "$MCP_PID_FILE" ] || [ -f "$ALL_PIDS_FILE" ]; then
        log_file "发现现有服务的PID文件，正在安全停止..."
        stop_services
        sleep 1
    else
        log_file "未发现现有服务的PID文件"
    fi
    
    # 确保使用正确的Node.js版本
    export NVM_DIR="$HOME/.nvm"
    [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
    nvm use 18.0.0 >> "$LOG_FILE" 2>&1
    log_file "Node.js版本设置完成"
    
    # 检查Chrome是否在运行
    if ! ps aux | grep -v grep | grep -q "Chrome.*remote-debugging-port=9222"; then
        log_file "警告: Chrome未运行或未启用远程调试端口9222"
        log_file "请确保Chrome已启动并使用以下参数:"
        log_file "  --remote-debugging-port=9222"
    fi
    
    # 清空旧的PID记录文件
    > "$ALL_PIDS_FILE"
    echo "PID:DESCRIPTION:TIMESTAMP" >> "$ALL_PIDS_FILE"  # 添加标题行
    
    # 启动Browser Tools Server
    log_file "正在启动Browser Tools Server..."
    # 在macOS上使用nohup代替setsid
    nohup "$NPX_PATH" -y @agentdeskai/browser-tools-server@1.2.0 --port=$SERVER_PORT >> "$LOG_FILE" 2>&1 &
    NPM_PID=$!
    log_file "NPM包装进程ID: $NPM_PID"
    log_file "🎯 新终止策略: 使用递归子进程终止，不依赖进程组"
    
    # 等待服务器启动并获取实际的node进程PID
    log_file "等待服务器启动..."
    sleep 5
    if ! ps -p $NPM_PID > /dev/null; then
        log_file "服务器启动失败！NPM进程 $NPM_PID 已退出"
        # 尝试获取更多信息
        if [ -f $LOG_FILE ]; then
            log_file "最近的服务器日志："
            tail -20 $LOG_FILE | while IFS= read -r line; do
                log_file "  $line"
            done
        fi
        exit 1
    fi
    
    # 获取实际的node服务器进程PID
    log_file "查找实际的node服务器进程..."
    SERVER_PID=""
    for i in {1..10}; do
        # 查找NPM进程的子进程中的node进程
        NODE_PID=$(pgrep -P $NPM_PID 2>/dev/null | head -1)
        if [ -n "$NODE_PID" ]; then
            # 验证这是browser-tools-server进程
            if ps -p "$NODE_PID" -o args= 2>/dev/null | grep -q "browser-tools-server"; then
                SERVER_PID=$NODE_PID
                log_file "找到实际服务器进程ID: $SERVER_PID"
                break
            fi
        fi
        sleep 1
    done
    
    if [ -z "$SERVER_PID" ]; then
        log_file "警告: 无法找到实际的node服务器进程，使用NPM进程ID: $NPM_PID"
        SERVER_PID=$NPM_PID
    fi
    
    # 记录服务器进程PID
    echo "$SERVER_PID" > "$SERVER_PID_FILE"
    record_pid "$SERVER_PID" "browser-tools-server-main"
    record_pid "$NPM_PID" "browser-tools-npm-wrapper"
    
    # 等待更长时间确保服务器完全启动
    log_file "等待服务器完全启动..."
    for i in {1..10}; do
        if curl -s "http://localhost:$SERVER_PORT/" > /dev/null 2>&1; then
            log_file "服务器已就绪（尝试 $i/10）"
            break
        elif curl -s "http://localhost:3026/" > /dev/null 2>&1; then
            log_file "服务器已就绪，使用端口3026（尝试 $i/10）"
            SERVER_PORT=3026
            break
        elif curl -s "http://localhost:3027/" > /dev/null 2>&1; then
            log_file "服务器已就绪，使用端口3027（尝试 $i/10）"
            SERVER_PORT=3027
            break
        else
            log_file "等待服务器就绪... (尝试 $i/10)"
            sleep 2
        fi
    done
    
    # 测试服务器是否响应 - 动态检测实际端口
    log_file "测试服务器连接..."
    
    # 检测服务器实际使用的端口
    ACTUAL_PORT=$SERVER_PORT
    for port in $SERVER_PORT 3026 3027 3028 3029; do
        if curl -s "http://localhost:$port/" > /dev/null 2>&1; then
            ACTUAL_PORT=$port
            log_file "服务器在端口 $port 上响应正常"
            break
        fi
    done
    
    # 如果找不到响应的端口，检查进程是否还在运行
    if ! curl -s "http://localhost:$ACTUAL_PORT/" > /dev/null 2>&1; then
        if ps -p $SERVER_PID > /dev/null; then
            log_file "警告: 服务器进程运行中但未响应HTTP请求，继续启动..."
        else
            log_file "服务器启动失败！进程已退出"
            exit 1
        fi
    fi
    
    log_file "服务器启动成功，监听端口 $ACTUAL_PORT"
    
    # 等待服务器完全启动
    sleep 2
    log_file "服务器启动完成，子进程将通过进程组管理"
    log_file "注意: 只记录主进程PID，子进程通过进程组统一管理"
    
    # 启动MCP客户端进程监控
    log_file "正在启动MCP客户端..."
    log_file "browser-tools服务已启动，按Ctrl+C或发送SIGTERM信号来停止服务"
    
    # 启动MCP客户端进程监控函数
    monitor_mcp_client() {
        local max_retries=3
        local retry_count=0
        
        while [ $retry_count -lt $max_retries ]; do
            # 确保服务器可达后再启动MCP客户端 - 改进的检查方法
            log_file "最终确认服务器可达性... (尝试 $((retry_count + 1))/$max_retries)"
            
            # 首先检查端口是否在监听
            if ! lsof -i:$ACTUAL_PORT > /dev/null 2>&1; then
                log_file "错误: 服务器端口 $ACTUAL_PORT 未在监听"
                if [ $retry_count -eq $((max_retries - 1)) ]; then
                    log_file "服务器端口检查失败，无法启动MCP客户端"
                    exit 1
                fi
                retry_count=$((retry_count + 1))
                sleep 3
                continue
            fi
            
            # 然后检查HTTP响应（允许404）
            local http_response=$(curl -s -w "%{http_code}" "http://localhost:$ACTUAL_PORT/" -o /dev/null 2>/dev/null || echo "000")
            if [ "$http_response" = "000" ]; then
                log_file "错误: 服务器HTTP不响应"
                if [ $retry_count -eq $((max_retries - 1)) ]; then
                    log_file "服务器HTTP检查失败，无法启动MCP客户端"
                    exit 1
                fi
                retry_count=$((retry_count + 1))
                sleep 3
                continue
            else
                log_file "服务器检查通过 (端口监听正常，HTTP状态码: $http_response)"
            fi
            
            log_file "服务器确认可达，启动MCP客户端..."
            
            # 启动MCP客户端进程，使用实际端口
            "$NPX_PATH" -y @agentdeskai/browser-tools-mcp@1.2.0 --port=$ACTUAL_PORT &
            MCP_PID=$!
            echo $MCP_PID > "$MCP_PID_FILE"
            record_pid "$MCP_PID" "browser-tools-mcp-main"
            log_file "MCP客户端进程ID: $MCP_PID，连接端口: $ACTUAL_PORT"
            
            # 等待MCP客户端启动和连接
            sleep 8
            log_file "MCP客户端启动完成，子进程将通过进程组管理"
            
            # 监控MCP客户端进程
            local consecutive_failures=0
            local max_consecutive_failures=3
            
            while true; do
                # 检查MCP客户端进程状态 - 增强的检查
                local mcp_process_info=$(ps -p $MCP_PID -o pid,ppid,stat,time,command 2>/dev/null || echo "")
                if [ -z "$mcp_process_info" ]; then
                    local timestamp=$(date '+%Y-%m-%d %H:%M:%S.%3N')
                    
                    # 输出到日志文件，避免干扰MCP协议的JSON通信
                    log_file "$timestamp [info] MCP客户端进程 $MCP_PID 已退出"
                    log_file "$timestamp [info] 开始分析MCP客户端退出原因..."
                    
                    log_file "MCP客户端进程 $MCP_PID 不存在"
                    log_file "MCP客户端进程已退出，分析退出原因..."
                    
                    # 尝试获取进程退出状态，但不依赖wait命令
                    local exit_code=0
                    # wait $MCP_PID 2>/dev/null  # 注释掉可能有问题的wait命令
                    log_file "$timestamp [info] MCP客户端退出码: $exit_code (在后台进程模式下可能不准确)"
                    log_file "MCP客户端退出码: $exit_code (注意: 在后台进程模式下可能不准确)"
                    
                    # 输出详细的进程信息到日志文件
                    log_file "$timestamp [info] MCP客户端进程详情:"
                    log_file "$timestamp [info]   进程ID: $MCP_PID"
                    log_file "$timestamp [info]   连接端口: $ACTUAL_PORT"
                    if [ -f "$MCP_PID_FILE" ]; then
                        log_file "$timestamp [info]   PID文件: $MCP_PID_FILE"
                    fi
                    
                    # 检查端口状态
                    if [ -n "$ACTUAL_PORT" ]; then
                        if lsof -i:$ACTUAL_PORT > /dev/null 2>&1; then
                            log_file "$timestamp [info]   端口状态: $ACTUAL_PORT 仍被占用"
                            local port_info=$(lsof -i:$ACTUAL_PORT 2>/dev/null | head -3)
                            if [ -n "$port_info" ]; then
                                log_file "$timestamp [info]   占用端口的进程:"
                                echo "$port_info" | while IFS= read -r line; do
                                    log_file "$timestamp [info]     $line"
                                done
                            fi
                        else
                            log_file "$timestamp [info]   端口状态: $ACTUAL_PORT 已释放"
                        fi
                    fi
                    
                    # 执行详细诊断
                    diagnose_mcp_exit "$MCP_PID" "$exit_code"
                    
                    # 检查是否是正常退出（通过信号）
                    if [ -f "logs/browser-tools-shutdown" ]; then
                        log_file "$timestamp [info] 检测到正常关闭信号，开始清理服务器进程..."
                        log_file "检测到正常关闭信号，清理服务器进程..."
                        rm -f "logs/browser-tools-shutdown"
                        
                        log_file "$timestamp [info] 执行服务清理程序..."
                        stop_services
                        log_file "$timestamp [info] 所有browser-tools服务已完全停止"
                        exit 0
                    fi
                    
                    # 分析异常退出原因
                    consecutive_failures=$((consecutive_failures + 1))
                    echo "$timestamp [warn] MCP客户端异常退出 (连续失败: $consecutive_failures/$max_consecutive_failures)"
                    log_file "MCP客户端异常退出 (连续失败: $consecutive_failures/$max_consecutive_failures)"
                    
                    # 检查服务器是否还在运行
                    if [ -n "$SERVER_PID" ] && ! ps -p $SERVER_PID > /dev/null 2>&1; then
                        echo "$timestamp [error] 服务器进程 $SERVER_PID 也已退出，停止重试"
                        log_file "服务器进程也已退出，停止重试"
                        exit 1
                    fi
                    
                    # 检查服务器是否可达 - 改进的检查方法
                    log_file "$timestamp [info] 检查服务器端口 $ACTUAL_PORT 可达性..."
                    if ! lsof -i:$ACTUAL_PORT > /dev/null 2>&1; then
                        echo "$timestamp [error] 服务器端口 $ACTUAL_PORT 不可达，停止重试"
                        log_file "服务器端口不可达，停止重试"
                        exit 1
                    else
                        log_file "$timestamp [info] 服务器端口 $ACTUAL_PORT 正常监听"
                    fi
                    
                    # 额外的HTTP检查（允许404响应，因为根路径可能不存在）
                    log_file "$timestamp [info] 检查服务器HTTP响应..."
                    local http_response=$(curl -s -w "%{http_code}" "http://localhost:$ACTUAL_PORT/" -o /dev/null 2>/dev/null || echo "000")
                    if [ "$http_response" = "000" ]; then
                        echo "$timestamp [error] 服务器HTTP不响应，停止重试"
                        log_file "服务器HTTP不响应，停止重试"
                        exit 1
                    else
                        log_file "$timestamp [info] 服务器HTTP响应正常 (状态码: $http_response)"
                        log_file "服务器HTTP响应正常 (状态码: $http_response)"
                    fi
                    
                    # 如果连续失败次数过多，停止重试
                    if [ $consecutive_failures -ge $max_consecutive_failures ]; then
                        echo "$timestamp [error] MCP客户端连续失败 $max_consecutive_failures 次，停止服务"
                        log_file "MCP客户端连续失败 $max_consecutive_failures 次，停止服务"
                        log_file "$timestamp [info] 开始清理所有browser-tools服务..."
                        stop_services
                        log_file "$timestamp [info] 服务清理完成，退出程序"
                        exit 1
                    fi
                    
                    # 尝试重启MCP客户端
                    local remaining_retries=$((max_consecutive_failures - consecutive_failures))
                    log_file "$timestamp [info] 尝试重启MCP客户端... (剩余重试次数: $remaining_retries)"
                    log_file "尝试重启MCP客户端... (剩余重试次数: $remaining_retries)"
                    
                    log_file "$timestamp [info] 等待5秒后重启..."
                    sleep 5
                    
                    log_file "$timestamp [info] 启动新的MCP客户端进程..."
                    "$NPX_PATH" -y @agentdeskai/browser-tools-mcp@1.2.0 --port=$ACTUAL_PORT &
                    MCP_PID=$!
                    echo $MCP_PID > "$MCP_PID_FILE"
                    record_pid "$MCP_PID" "browser-tools-mcp-main-restart"
                    
                    log_file "$timestamp [info] MCP客户端重启完成，新进程ID: $MCP_PID"
                    log_file "MCP客户端重启，新进程ID: $MCP_PID"
                    
                    sleep 8
                    continue
                fi
                
                # 检查服务器进程是否还在运行
                if [ -n "$SERVER_PID" ] && ! ps -p $SERVER_PID > /dev/null 2>&1; then
                    local timestamp=$(date '+%Y-%m-%d %H:%M:%S.%3N')
                    echo "$timestamp [error] 服务器进程 $SERVER_PID 意外退出，清理MCP客户端进程..."
                    log_file "服务器进程意外退出，清理MCP客户端进程..."
                    
                    log_file "$timestamp [info] 终止MCP客户端进程 $MCP_PID..."
                    kill $MCP_PID 2>/dev/null || true
                    sleep 1
                    
                    log_file "$timestamp [info] browser-tools服务异常终止"
                    exit 1
                fi
                
                # 重置连续失败计数器（进程正常运行）
                if [ $consecutive_failures -gt 0 ]; then
                    local timestamp=$(date '+%Y-%m-%d %H:%M:%S.%3N')
                    consecutive_failures=0
                    log_file "$timestamp [info] MCP客户端恢复正常运行，重置失败计数器"
                    log_file "MCP客户端恢复正常运行，重置失败计数器"
                fi
                
                # 定期记录进程状态（每分钟一次）
                local current_time=$(date +%s)
                if [ -z "$last_status_time" ] || [ $((current_time - last_status_time)) -ge 60 ]; then
                    log_file "MCP客户端状态检查: PID $MCP_PID 正在运行"
                    echo "$mcp_process_info" | while IFS= read -r line; do
                        log_file "  $line"
                    done
                    last_status_time=$current_time
                fi
                
                sleep 10  # 增加检查间隔到10秒，减少CPU占用
            done
            
            # 如果到达这里，说明监控循环结束，尝试重启
            retry_count=$((retry_count + 1))
            if [ $retry_count -lt $max_retries ]; then
                log_file "MCP客户端监控循环结束，尝试重新启动... ($retry_count/$max_retries)"
                sleep 5
            fi
        done
        
        log_file "MCP客户端启动重试次数已达上限，服务启动失败"
        stop_services
        exit 1
    }
    
    # 启动监控
    monitor_mcp_client 
}

# MCP模式特殊处理：当被Cursor作为MCP服务器启动时，直接运行MCP服务器
if [ "$IS_MCP_MODE" = true ]; then
    # 确保logs目录存在
    mkdir -p "$SCRIPT_DIR/logs"
    # 立即写入日志，确保脚本被执行
    echo "$(date '+%Y-%m-%d %H:%M:%S') [STARTUP] 脚本开始执行，检测到MCP模式" >> "$LOG_FILE"
    log_file "检测到MCP模式，作为MCP服务器直接运行..."
    
    # 检查服务器是否已经在运行
    SERVER_PORT=3025
    ACTUAL_PORT=""
    
    # 简化的服务器检测逻辑 - 直接使用引用计数管理器
    log_file "🔍 使用引用计数管理器检测server状态..."
    
    # 端口检测将在引用计数管理器中进行，这里先跳过
    
    if [ -z "$ACTUAL_PORT" ]; then
        log_file "未发现运行中的服务器，检查是否需要启动新服务器..."
        
        # 5. 原子级启动锁机制，防止并发启动
        STARTUP_LOCK="$SCRIPT_DIR/logs/browser-tools-startup.lock"
        
        # 使用原子操作获取启动锁
        if (set -C; echo $$ > "$STARTUP_LOCK") 2>/dev/null; then
            log_file "✅ 获取启动锁成功，PID: $$"
            
            # 获取锁后再次检查是否有server启动了（双重检查）
            double_check_pids=$(pgrep -f "browser-tools-server" 2>/dev/null)
            if [ -n "$double_check_pids" ]; then
                log_file "🔍 双重检查发现已有server进程，取消启动"
                for pid in $double_check_pids; do
                    if ps -p "$pid" > /dev/null 2>&1; then
                        # 使用timeout防止lsof卡住，优先使用快速的端口扫描方式
                        log_file "检测进程 $pid 的监听端口..."
                        retry_port=""
                        
                        # 方法1: 快速端口扫描（优先）
                        for port in 3025 3026 3027 3028 3029; do
                            if curl -s --max-time 0.5 "http://localhost:$port/" > /dev/null 2>&1; then
                                retry_port=$port
                                log_file "✅ 通过快速扫描发现端口: $port"
                                break
                            fi
                        done
                        
                        # 方法2: 使用timeout保护的lsof（备用）
                        if [ -z "$retry_port" ]; then
                            log_file "快速扫描未找到端口，尝试使用lsof..."
                            retry_port=$(timeout 2 lsof -p "$pid" -i 2>/dev/null | grep LISTEN | grep -o ':\([0-9]*\)' | head -1 | cut -d: -f2 2>/dev/null || echo "")
                            if [ -n "$retry_port" ]; then
                                log_file "✅ 通过lsof发现端口: $retry_port"
                            else
                                log_file "⚠️ lsof未找到端口信息"
                            fi
                        fi
                        
                        if [ -n "$retry_port" ]; then
                            ACTUAL_PORT=$retry_port
                            log_file "✅ 双重检查后发现可用服务器，PID: $pid, 端口: $retry_port，直接使用该服务器"
                            rm -f "$STARTUP_LOCK"
                            # 跳过server启动，直接使用现有server
                            # 将ACTUAL_PORT设置后跳过启动部分
                            break  # 找到一个有效端口就退出循环
                        fi
                    fi
                done
                # 如果找到了可用端口，跳过启动流程
                if [ -n "$ACTUAL_PORT" ]; then
                    log_file "🎯 复用现有server，跳过启动流程"
                    # 不需要再继续启动，跳到后面的注册部分
                else
                    log_file "⚠️ 双重检查后未找到可用端口，需要启动新server"
                    # 清理无效的PID，准备启动新server
                    rm -f "$STARTUP_LOCK"
                fi
            fi
        else
            # 无法获取锁，说明有其他进程在启动
            lock_pid=$(cat "$STARTUP_LOCK" 2>/dev/null)
            if [ -n "$lock_pid" ] && ps -p "$lock_pid" > /dev/null 2>&1; then
                log_file "检测到另一个启动进程 (PID: $lock_pid)，等待其完成..."
                # 使用5毫秒间隔等待，最多等待15秒
                wait_count=0
                while [ $wait_count -lt 3000 ] && [ -f "$STARTUP_LOCK" ]; do
                    sleep 0.005  # 5毫秒
                    wait_count=$((wait_count + 1))
                    
                    # 每秒检查一次并输出状态
                    if [ $((wait_count % 200)) -eq 0 ]; then
                        log_file "等待启动锁释放... (${wait_count}*5ms)"
                    fi
                done
                # 重新检测是否有server启动了
                retry_server_pids=$(pgrep -f "browser-tools-server" 2>/dev/null)
                if [ -n "$retry_server_pids" ]; then
                    for pid in $retry_server_pids; do
                        if ps -p "$pid" > /dev/null 2>&1; then
                            log_file "等待后发现server进程 $pid，检测端口..."
                            retry_port=""
                            
                            # 方法1: 快速端口扫描（优先）
                            for port in 3025 3026 3027 3028 3029; do
                                if curl -s --max-time 0.5 "http://localhost:$port/" > /dev/null 2>&1; then
                                    retry_port=$port
                                    log_file "✅ 通过快速扫描发现端口: $port"
                                    break
                                fi
                            done
                            
                            # 方法2: 使用timeout保护的lsof（备用）
                            if [ -z "$retry_port" ]; then
                                retry_port=$(timeout 2 lsof -p "$pid" -i 2>/dev/null | grep LISTEN | grep -o ':\([0-9]*\)' | head -1 | cut -d: -f2 2>/dev/null || echo "")
                            fi
                            
                            if [ -n "$retry_port" ]; then
                                ACTUAL_PORT=$retry_port
                                log_file "等待后发现新启动的服务器，PID: $pid, 端口: $retry_port"
                                break
                            fi
                        fi
                    done
                fi
            else
                # 锁文件存在但进程不存在，清理锁文件
                rm -f "$STARTUP_LOCK"
                log_file "清理无效的启动锁文件"
            fi
        fi
        
        # 6. 如果仍然没有找到server（且双重检查也没找到），则创建启动锁并启动新server
        if [ -z "$ACTUAL_PORT" ]; then
            # 再次确认是否需要启动（可能在等待期间有其他进程启动了）
            if [ -f "$STARTUP_LOCK" ]; then
                lock_pid=$(cat "$STARTUP_LOCK" 2>/dev/null)
                if [ "$lock_pid" != "$$" ]; then
                    log_file "检测到已有启动锁（PID: $lock_pid），跳过启动"
                    # 不需要启动，等待其他进程完成
                else
                    log_file "当前进程持有启动锁，继续启动流程"
                fi
            else
                mkdir -p "$SCRIPT_DIR/logs"
                echo $$ > "$STARTUP_LOCK"
                log_file "创建启动锁，PID: $$"
            fi
            
            # 使用引用计数管理器检查并整合server进程
        REF_COUNT_MANAGER="$SCRIPT_DIR/mcp_ref_count_manager.sh"
        if [ -f "$REF_COUNT_MANAGER" ]; then
            chmod +x "$REF_COUNT_MANAGER"
            if "$REF_COUNT_MANAGER" ensure-single-server; then
                # 获取整合后的server PID
                if existing_server_pid=$("$REF_COUNT_MANAGER" get-server-pid); then
                    log_file "发现并整合了现有server进程: $existing_server_pid"
                    SERVER_PID=$existing_server_pid
                    
                    # 检测server的实际端口
                    for port in $SERVER_PORT 3026 3027 3028 3029; do
                        if curl -s "http://localhost:$port/" > /dev/null 2>&1; then
                            ACTUAL_PORT=$port
                            log_file "现有服务器在端口 $port 上响应正常"
                            break
                        fi
                    done
                    
                    if [ -n "$ACTUAL_PORT" ]; then
                        log_file "复用现有服务器，端口: $ACTUAL_PORT，PID: $SERVER_PID"
                    else
                        log_file "现有服务器不响应，将启动新服务器"
                        ACTUAL_PORT=""
                    fi
                fi
            fi
        fi
        
        # 如果没有可用的服务器，启动新的
        if [ -z "$ACTUAL_PORT" ]; then
            log_file "启动新的服务器..."
            nohup "$NPX_PATH" -y @agentdeskai/browser-tools-server@1.2.0 --port=$SERVER_PORT >> "$LOG_FILE" 2>&1 &
            NPM_PID=$!
            
            # 等待并获取实际的node服务器进程PID
            sleep 3
            SERVER_PID=""
            for i in {1..10}; do
                NODE_PID=$(pgrep -P $NPM_PID 2>/dev/null | head -1)
                if [ -n "$NODE_PID" ] && ps -p "$NODE_PID" -o args= 2>/dev/null | grep -q "browser-tools-server"; then
                    SERVER_PID=$NODE_PID
                    break
                fi
                sleep 1
            done
            
            if [ -z "$SERVER_PID" ]; then
                log_file "警告: 无法找到实际的node服务器进程，使用NPM进程ID: $NPM_PID"
                SERVER_PID=$NPM_PID
            fi
            
            echo "$SERVER_PID" > "$SERVER_PID_FILE"
            record_pid "$SERVER_PID" "browser-tools-server-main"
            record_pid "$NPM_PID" "browser-tools-npm-wrapper"
            
            # 等待服务器完全启动并验证
            log_file "等待服务器完全启动..."
            server_started=false
            for i in {1..15}; do
                if curl -s --max-time 1 "http://localhost:$SERVER_PORT/" > /dev/null 2>&1; then
                    ACTUAL_PORT=$SERVER_PORT
                    server_started=true
                    log_file "✅ Server在端口$SERVER_PORT上启动成功"
                    break
                fi
                log_file "等待server启动... (尝试 $i/15)"
                sleep 1
            done
            
            if [ "$server_started" = false ]; then
                log_file "❌ 错误: Server启动超时或失败"
                # 清理失败的进程
                kill -TERM $NPM_PID 2>/dev/null || true
                kill -TERM $SERVER_PID 2>/dev/null || true
                rm -f "$SERVER_PID_FILE"
                rm -f "$STARTUP_LOCK" 2>/dev/null
                # 不继续执行，直接退出
                exit 1
            fi
            
            # 清理启动锁
            rm -f "$STARTUP_LOCK" 2>/dev/null
            log_file "服务器启动完成，清理启动锁"
        else
            # 如果找到了现有服务器，也要清理启动锁
            rm -f "$STARTUP_LOCK" 2>/dev/null
            log_file "复用现有服务器，清理启动锁"
        fi
        fi
    fi
    
    # 在MCP模式下，直接运行MCP服务器，不要启动额外的MCP客户端
    log_file "启动MCP服务器，连接到browser-tools-server端口: $ACTUAL_PORT"
    
    # 注册MCP客户端（递增引用计数）并立即整合重复进程
    REF_COUNT_MANAGER="$SCRIPT_DIR/mcp_ref_count_manager.sh"
    if [ -f "$REF_COUNT_MANAGER" ]; then
        chmod +x "$REF_COUNT_MANAGER"
        
        # 首先确保我们有一个有效的server进程
        # 使用引用计数管理器来获取或验证server PID
        log_file "🔍 通过引用计数管理器验证server状态..."
        log_file "DEBUG: 准备调用引用计数管理器 get-server-pid"
        if server_pid=$("$REF_COUNT_MANAGER" get-server-pid 2>/dev/null); then
            log_file "DEBUG: 引用计数管理器返回PID: $server_pid"
            SERVER_PID=$server_pid
            log_file "✅ 引用计数管理器找到有效server: PID=$SERVER_PID"
            
            # 确定端口
            if [ -z "$ACTUAL_PORT" ]; then
                for port in 3025 3026 3027 3028 3029; do
                    if curl -s --max-time 1 "http://localhost:$port/" > /dev/null 2>&1; then
                        ACTUAL_PORT=$port
                        log_file "✅ 检测到server端口: $ACTUAL_PORT"
                        break
                    fi
                done
            fi
            
            # 清理重复的server进程
            log_file "🔍 清理重复server进程..."
            # 更安全的重复进程清理：只清理真正的重复node server进程，不清理npm父进程
            existing_server_pids=$(pgrep -f "node.*browser-tools-server" 2>/dev/null)
            for other_pid in $existing_server_pids; do
                if [ "$other_pid" != "$SERVER_PID" ] && ps -p "$other_pid" > /dev/null 2>&1; then
                    other_cmd=$(ps -p "$other_pid" -o args= 2>/dev/null)
                    # 只清理真正的node server进程，不清理npm父进程
                    if echo "$other_cmd" | grep -q "node.*browser-tools-server"; then
                        log_file "🔄 终止重复node server进程: $other_pid"
                        kill -TERM "$other_pid" 2>/dev/null || true
                        sleep 0.1
                        if ps -p "$other_pid" > /dev/null 2>&1; then
                            kill -KILL "$other_pid" 2>/dev/null || true
                        fi
                    else
                        log_file "⚠️ 跳过非node server进程: $other_pid ($other_cmd)"
                    fi
                fi
            done
        else
            # 没有找到有效server，启动新的
            log_file "DEBUG: 引用计数管理器未找到有效server"
            log_file "📋 引用计数管理器未找到有效server，启动新server..."
            nohup "$NPX_PATH" -y @agentdeskai/browser-tools-server@1.2.0 --port=$SERVER_PORT >> "$LOG_FILE" 2>&1 &
            NPM_PID=$!
            log_file "NPM进程ID: $NPM_PID，等待实际node server进程..."
            
            # 等待并获取实际的node服务器进程PID
            sleep 3
            SERVER_PID=""
            for i in {1..10}; do
                NODE_PID=$(pgrep -P $NPM_PID 2>/dev/null | head -1)
                if [ -n "$NODE_PID" ] && ps -p "$NODE_PID" -o args= 2>/dev/null | grep -q "browser-tools-server"; then
                    SERVER_PID=$NODE_PID
                    log_file "找到实际node server进程: $SERVER_PID"
                    break
                fi
                sleep 1
            done
            
            if [ -z "$SERVER_PID" ]; then
                log_file "警告: 无法找到实际的node服务器进程，使用NPM进程ID: $NPM_PID"
                SERVER_PID=$NPM_PID
            fi
            
            echo "$SERVER_PID" > "$SERVER_PID_FILE"
            record_pid "$SERVER_PID" "browser-tools-server-main-new"
            record_pid "$NPM_PID" "browser-tools-npm-wrapper-new"
            log_file "新server进程ID: $SERVER_PID，端口: $SERVER_PORT，PID文件已创建"
            
            # 等待server完全启动并验证端口响应
            log_file "等待server完全启动..."
            server_started=false
            for i in {1..15}; do
                if curl -s --max-time 1 "http://localhost:$SERVER_PORT/" > /dev/null 2>&1; then
                    ACTUAL_PORT=$SERVER_PORT
                    server_started=true
                    log_file "✅ Server在端口$SERVER_PORT上启动成功"
                    break
                fi
                log_file "等待server启动... (尝试 $i/15)"
                sleep 1
            done
            
            if [ "$server_started" = false ]; then
                log_file "❌ 错误: Server启动超时或失败"
                # 清理失败的进程
                kill -TERM $NPM_PID 2>/dev/null || true
                kill -TERM $SERVER_PID 2>/dev/null || true
                rm -f "$SERVER_PID_FILE"
                # 不继续执行，直接退出
                exit 1
            fi
        fi
        
        # 验证PID文件是否存在，如果不存在则重新创建
        if [ ! -f "$SERVER_PID_FILE" ] || [ ! -s "$SERVER_PID_FILE" ]; then
            log_file "⚠️ 警告: SERVER_PID_FILE不存在或为空，尝试重新创建"
            if [ -n "$SERVER_PID" ] && ps -p "$SERVER_PID" > /dev/null 2>&1; then
                echo "$SERVER_PID" > "$SERVER_PID_FILE"
                record_pid "$SERVER_PID" "browser-tools-server-main-recovered"
                log_file "✅ 重新创建SERVER_PID_FILE成功: $SERVER_PID"
            else
                log_file "❌ 错误: 无法重新创建PID文件，SERVER_PID无效或进程不存在"
                log_file "❌ 终止MCP客户端启动流程"
                exit 1
            fi
        else
            log_file "✅ SERVER_PID_FILE验证通过: $(cat "$SERVER_PID_FILE" 2>/dev/null)"
        fi
        
        # 执行引用计数递增
        log_file "DEBUG: 准备调用引用计数递增"
        current_count=$("$REF_COUNT_MANAGER" increment)
        log_file "DEBUG: 引用计数递增完成，返回值: $current_count"
        log_file "MCP客户端注册完成，当前引用计数: $current_count"
        
        # 在注册客户端后启动清理监控器（确保引用计数>0）
        nohup "$SCRIPT_DIR/mcp_cleanup_monitor.sh" > /dev/null 2>&1 &
        log_file "启动MCP清理监控器"
    else
        log_file "警告: 引用计数管理器不存在，无法跟踪客户端数量"
    fi
    
    # 设置退出时清理引用计数
    cleanup_on_exit() {
        if [ -f "$REF_COUNT_MANAGER" ]; then
            remaining_count=$("$REF_COUNT_MANAGER" decrement)
            log_file "MCP客户端注销，剩余引用计数: $remaining_count"
        fi
    }
    trap cleanup_on_exit EXIT
    
    # 直接执行MCP客户端（前台运行，作为Cursor的MCP服务器）
    log_file "启动MCP客户端，连接到端口: $ACTUAL_PORT"
    exec "$NPX_PATH" -y @agentdeskai/browser-tools-mcp@1.2.0 --port=$ACTUAL_PORT
else
    # 主逻辑：默认启动服务
    # 所有启动信息都记录到日志文件，避免干扰MCP客户端的JSON输出
    # 确保logs目录存在
    mkdir -p "$SCRIPT_DIR/logs"
    # 立即写入日志，确保脚本被执行
    echo "$(date '+%Y-%m-%d %H:%M:%S') [STARTUP] 脚本开始执行，终端模式" >> "$LOG_FILE"
    log_file "启动browser-tools服务..."
    log_file "===== 环境检测详情 ====="
    log_file "当前脚本PID: $$"
    log_file "父进程PID: $(ps -o ppid= -p $$ 2>/dev/null | tr -d ' ')"
    log_file "父进程命令: $(ps -p "$(ps -o ppid= -p $$ 2>/dev/null | tr -d ' ')" -o args= 2>/dev/null || echo 'unknown')"
    log_file "CURSOR_MCP_PROCESS环境变量: ${CURSOR_MCP_PROCESS:-未设置}"
    log_file "MCP_SERVER环境变量: ${MCP_SERVER:-未设置}"
    log_file "运行模式: $([ "$IS_MCP_MODE" = true ] && echo "MCP模式" || echo "终端模式")"
    log_file "===== 环境检测完成 ====="
    log_file "日志文件: $LOG_FILE"
    log_file "停止日志文件: $STOP_LOG_FILE"
    log_file "使用Ctrl+C或发送SIGTERM信号来停止服务"

    start_services
fi
