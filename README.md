# Browser Tools 脚本集合

这个目录包含了 browser-tools 相关的所有脚本和配置文件。

## 主要文件

### 1. browser-tools.sh
- **作用**: 主启动脚本，支持MCP模式和终端模式
- **MCP模式**: 作为Cursor的MCP服务器运行
- **终端模式**: 独立启动browser-tools服务
- **功能**: 
  - 自动检测运行环境
  - 启动browser-tools-server和browser-tools-mcp
  - 进程监控和自动重启
  - 信号处理和优雅退出

### 2. mcp_cleanup_monitor.sh
- **作用**: MCP模式下的后台清理监控器（支持引用计数）
- **功能**:
  - 监控所有MCP进程状态
  - 使用引用计数机制跟踪活跃客户端数量
  - 当所有MCP客户端都退出时自动清理server进程
  - 选择性终止server相关进程树
  - 避免孤儿进程和资源泄漏

### 3. mcp_ref_count_manager.sh
- **作用**: MCP客户端引用计数管理器
- **功能**:
  - 管理MCP客户端的引用计数
  - 支持并发安全的递增/递减操作
  - 提供文件锁机制防止竞态条件
  - 判断是否应该清理server进程

## 使用方法

### MCP模式（推荐）
在Cursor的MCP配置中使用：
```json
{
  "mcpServers": {
    "browser-tools": {
      "command": "/path/to/your/browser-tools/browser-tools.sh"
    }
  }
}
```

### 终端模式
直接运行脚本：
```bash
cd ~/browser-tools
./browser-tools.sh
```

## 日志文件
- `logs/browser-tools.log` - 主日志文件
- `logs/browser-tools-stop.log` - 停止操作日志

## PID文件和状态文件
- `logs/browser-tools-shared-server.pid` - Server进程PID
- `logs/browser-tools-mcp.pid` - MCP进程PID
- `logs/browser-tools-all-pids.txt` - 所有进程记录
- `logs/browser-tools-mcp-monitor.pid` - 监控器进程PID
- `logs/browser-tools-client-count.txt` - MCP客户端引用计数
- `logs/browser-tools-ref-count.lock` - 引用计数操作锁文件

## 注意事项
1. 确保脚本有执行权限：`chmod +x *.sh`
2. MCP模式下会自动启动清理监控器和引用计数管理器
3. 支持多窗口MCP客户端场景，使用引用计数确保server在最后一个客户端退出时才被清理
4. 支持优雅退出和进程清理
5. 兼容macOS环境

## 多窗口支持
新的引用计数机制解决了多窗口场景下的服务清理问题：
- **问题**: 多个Cursor窗口启动MCP客户端，共用一个server，关闭所有客户端时server未被清理
- **解决**: 使用引用计数跟踪活跃客户端数量，只有当所有客户端都退出时才清理server
- **优势**: 支持并发操作，使用文件锁防止竞态条件
