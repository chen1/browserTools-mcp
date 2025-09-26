# Browser Tools 安装和配置指南

## 文件结构

```
~/browser-tools/
├── browser-tools.sh          # 主启动脚本
├── mcp_cleanup_monitor.sh     # MCP清理监控器（支持引用计数）
├── mcp_ref_count_manager.sh   # MCP引用计数管理器
├── test_mcp_ref_count.sh      # 引用计数测试脚本
├── README.md                  # 功能说明文档
└── SETUP.md                   # 本安装指南

~/browser-tools.sh             # 软链接，向后兼容
```

## 安装步骤

### 1. 确认文件权限
```bash
chmod +x ~/browser-tools/*.sh
```

### 2. Cursor MCP 配置

在 Cursor 中配置 MCP 服务器，编辑 `~/.cursor/mcp.json`：

```json
{
  "mcpServers": {
    "browser-tools": {
      "command": "/path/to/your/browser-tools/browser-tools.sh",
      "args": []
    }
  }
}
```

### 3. 验证安装

#### 方法1：终端测试
```bash
cd ~/browser-tools
./browser-tools.sh
```

#### 方法2：MCP测试
在 Cursor 中重启 MCP 服务器，查看是否正常启动。

## 工作原理

### MCP 模式（推荐）
1. Cursor 启动 `browser-tools.sh` 作为 MCP 服务器
2. 脚本检测到 MCP 模式，启动 browser-tools-server
3. 启动后台清理监控器 `mcp_cleanup_monitor.sh`（支持引用计数）
4. 注册MCP客户端到引用计数管理器
5. 使用 `exec` 替换为 browser-tools-mcp 进程
6. 当所有MCP客户端都退出时，监控器自动清理 server 进程

### 终端模式
1. 直接运行脚本启动所有服务
2. 支持进程监控和自动重启
3. 使用 Ctrl+C 优雅退出

## 日志和调试

### 日志文件位置
- **主日志**: `logs/browser-tools.log`
- **停止日志**: `logs/browser-tools-stop.log`

### 进程状态检查
```bash
# 查看所有 browser-tools 进程
ps -ef | grep browser-tools | grep -v grep

# 查看 PID 文件
ls -la logs/browser-tools*.pid

# 查看引用计数状态
~/browser-tools/mcp_ref_count_manager.sh status
```

### 手动清理（如果需要）
```bash
# 停止所有 browser-tools 进程
pkill -f browser-tools

# 清理 PID 文件和引用计数文件
rm -f logs/browser-tools*.pid logs/browser-tools*.txt

# 清理引用计数
~/browser-tools/mcp_ref_count_manager.sh cleanup
```

## 故障排除

### 问题1：MCP 服务器启动失败
- 检查脚本权限：`ls -la ~/browser-tools/*.sh`
- 查看日志：`tail -f logs/browser-tools.log`
- 验证 Node.js 环境：`node --version`

### 问题2：进程清理不完整
- 查看监控器日志：`tail -f logs/browser-tools-stop.log`
- 手动清理残留进程：`pkill -f browser-tools`

### 问题3：端口占用
- 检查端口占用：`lsof -i:3025`
- 更换端口（修改脚本中的 SERVER_PORT 变量）

## 更新和维护

### 更新脚本
```bash
# 备份当前版本
cp ~/browser-tools/browser-tools.sh ~/browser-tools/browser-tools.sh.backup

# 替换新版本后，确认权限
chmod +x ~/browser-tools/*.sh
```

### 清理旧版本文件
```bash
# 清理根目录下的旧版本文件（保留软链接）
rm -f ~/browser-tools_*.sh ~/start-browser-tools.sh ~/stop-browser-tools.sh
```
