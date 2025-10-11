#!/bin/bash
###
# 测试browser-tools启动流程
###

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="$SCRIPT_DIR/logs/test-startup.log"

# 创建日志目录
mkdir -p "$SCRIPT_DIR/logs"
> "$LOG_FILE"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

log "========== 测试开始 =========="

# 1. 清理环境
log "步骤1: 清理所有现有进程和状态文件"
killall -9 node npm 2>/dev/null || true
sleep 2
rm -f "$SCRIPT_DIR/logs/browser-tools-"*.pid
rm -f "$SCRIPT_DIR/logs/browser-tools-"*.lock
rm -f "$SCRIPT_DIR/logs/browser-tools-shutdown"
rm -f "$SCRIPT_DIR/logs/browser-tools-client-count.txt"
log "✅ 环境清理完成"

# 2. 检查环境
log "步骤2: 验证环境已清理"
if ps aux | grep -E "browser-tools" | grep -v grep | grep -v test_startup; then
    log "❌ 错误: 仍有browser-tools进程在运行"
    exit 1
fi

if lsof -i:3025 > /dev/null 2>&1; then
    log "❌ 错误: 端口3025仍被占用"
    exit 1
fi
log "✅ 环境验证通过"

# 3. 模拟MCP启动（单个客户端）
log "步骤3: 模拟MCP模式启动第一个客户端"
log "执行命令: $SCRIPT_DIR/browser-tools.sh &"
"$SCRIPT_DIR/browser-tools.sh" >> "$LOG_FILE" 2>&1 &
FIRST_CLIENT_PID=$!
log "第一个客户端进程: $FIRST_CLIENT_PID"

# 等待server启动
log "等待server启动..."
sleep 10

# 4. 检查server是否成功启动
log "步骤4: 检查server状态"

# 检查server PID文件
if [ -f "$SCRIPT_DIR/logs/browser-tools-shared-server.pid" ]; then
    SERVER_PID=$(cat "$SCRIPT_DIR/logs/browser-tools-shared-server.pid" 2>/dev/null)
    if [ -n "$SERVER_PID" ] && ps -p "$SERVER_PID" > /dev/null 2>&1; then
        log "✅ Server进程存在: PID=$SERVER_PID"
        
        # 检查进程命令
        SERVER_CMD=$(ps -p "$SERVER_PID" -o args= 2>/dev/null)
        log "   进程命令: $SERVER_CMD"
        
        if echo "$SERVER_CMD" | grep -q "browser-tools-server"; then
            log "✅ Server进程命令验证通过"
        else
            log "❌ 错误: Server进程命令不匹配"
        fi
    else
        log "❌ 错误: Server进程不存在或已退出"
    fi
else
    log "❌ 错误: Server PID文件不存在"
fi

# 检查端口
log "检查端口监听状态..."
if lsof -i:3025 > /dev/null 2>&1; then
    log "✅ 端口3025正在监听"
    PORT_PID=$(lsof -i:3025 -t | head -1)
    log "   监听进程: $PORT_PID"
else
    log "❌ 错误: 端口3025未被监听"
fi

# 检查HTTP响应
log "检查HTTP响应..."
if curl -s --max-time 2 "http://localhost:3025/" > /dev/null 2>&1; then
    log "✅ Server HTTP响应正常"
else
    log "❌ 错误: Server HTTP不响应"
fi

# 检查引用计数
log "检查引用计数..."
if [ -f "$SCRIPT_DIR/logs/browser-tools-client-count.txt" ]; then
    REF_COUNT=$(cat "$SCRIPT_DIR/logs/browser-tools-client-count.txt" 2>/dev/null)
    log "✅ 引用计数: $REF_COUNT"
    if [ "$REF_COUNT" -eq 1 ]; then
        log "✅ 引用计数正确（应为1）"
    else
        log "⚠️ 警告: 引用计数不是1，当前为$REF_COUNT"
    fi
else
    log "❌ 错误: 引用计数文件不存在"
fi

# 5. 模拟第二个客户端启动
log "步骤5: 模拟启动第二个MCP客户端"
"$SCRIPT_DIR/browser-tools.sh" >> "$LOG_FILE" 2>&1 &
SECOND_CLIENT_PID=$!
log "第二个客户端进程: $SECOND_CLIENT_PID"

sleep 5

# 检查是否复用了现有server
log "检查是否正确复用了现有server..."
if [ -f "$SCRIPT_DIR/logs/browser-tools-shared-server.pid" ]; then
    NEW_SERVER_PID=$(cat "$SCRIPT_DIR/logs/browser-tools-shared-server.pid" 2>/dev/null)
    if [ "$NEW_SERVER_PID" = "$SERVER_PID" ]; then
        log "✅ 正确复用了现有server"
    else
        log "⚠️ 警告: Server PID发生变化 (旧:$SERVER_PID, 新:$NEW_SERVER_PID)"
    fi
fi

# 检查引用计数是否递增
if [ -f "$SCRIPT_DIR/logs/browser-tools-client-count.txt" ]; then
    NEW_REF_COUNT=$(cat "$SCRIPT_DIR/logs/browser-tools-client-count.txt" 2>/dev/null)
    log "✅ 新引用计数: $NEW_REF_COUNT"
    if [ "$NEW_REF_COUNT" -eq 2 ]; then
        log "✅ 引用计数正确递增到2"
    else
        log "⚠️ 警告: 引用计数应为2，当前为$NEW_REF_COUNT"
    fi
fi

# 6. 清理测试进程
log "步骤6: 清理测试进程"
log "终止测试客户端进程..."
kill -TERM $FIRST_CLIENT_PID $SECOND_CLIENT_PID 2>/dev/null || true
sleep 3

log "等待清理监控器自动清理server..."
sleep 10

# 7. 最终验证
log "步骤7: 最终验证"
if ps aux | grep -E "browser-tools-server" | grep -v grep; then
    log "⚠️ Server进程仍在运行（可能需要更长时间清理）"
else
    log "✅ Server进程已被清理"
fi

if [ -f "$SCRIPT_DIR/logs/browser-tools-client-count.txt" ]; then
    FINAL_COUNT=$(cat "$SCRIPT_DIR/logs/browser-tools-client-count.txt" 2>/dev/null)
    log "最终引用计数: $FINAL_COUNT"
else
    log "✅ 引用计数文件已被清理"
fi

log "========== 测试完成 =========="
log "详细日志: $LOG_FILE"
log "主日志: $SCRIPT_DIR/logs/browser-tools.log"
log "引用计数日志: $SCRIPT_DIR/logs/browser-tools-ref-count.log"



