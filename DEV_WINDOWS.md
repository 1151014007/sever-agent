# Windows 启动与 VS Code 调试

适用于当前部署：Windows 本机 MySQL + Ubuntu 虚拟机 Milvus + 本机 Python 应用。
本指南用于 Windows 本机开发。交付部署参见 [README](README.md)。

## 1. 每次启动前

1. 打开 Ubuntu 虚拟机，在 Ubuntu 终端执行：

   ```bash
   cd ~/milvus
   docker compose up -d
   ```

2. 确认 Windows 的 MySQL 服务在运行。
3. 如果虚拟机 IP 改变，只修改 `.env` 中的 `MILVUS_URI`。

Python 依赖与知识库已经准备好，日常启动无需重新建库、灌数据或向量化。
脚本会检查数据库登录、Milvus TCP 连接和 9091 健康检查，检查过程不调用模型 API。

## 2. 在 VS Code 中按 F5 调试

1. 在 VS Code 选择「文件 → 从文件打开工作区」，打开本目录的 `MewHelp.code-workspace`。
   也可以直接打开 `python` 目录；不要只打开外层 `server agent` 目录，否则读不到本目录的 `.vscode` 配置。
2. 无需手动清理 8000 端口：启动任务会识别并停止这个项目的旧主应用（含热重载进程），等待端口释放。
   其他程序占用时会提示且保留它；已有 MCP 服务继续复用。
3. 按 `F5`，选择「MewHelp：调试客服主程序」。
4. 启动前任务会检查依赖，并启动或复用物流、售后 MCP 服务。
5. VS Code 用项目的 `.venv` 启动 FastAPI，启动完成后自动打开 `http://127.0.0.1:8000`。

你的电脑已经装有 Python、Python Debugger 扩展；无需给项目另装 `debugpy`。
调试配置会直接运行主应用，不开热重载，断点不会落到另一个重载子进程里。

建议先在 `app/api/chat.py` 的 `chat()` 函数体内点一个断点，再到网页发送消息，观察请求字段和执行顺序。
按 `F10` 单步越过，`F11` 进入函数，`F5` 继续，`Shift+F5` 停止主应用。
修改 Python 代码后停止并重新按 F5；修改 HTML/CSS 后直接刷新网页。

停止调试后 MCP 会保持运行，方便下次 F5 直接复用。需要全部收起时，运行下方的停止任务。

## 3. 直接启动展示（无需断点）

在 `python` 目录的 PowerShell 终端运行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\start.ps1
```

命令启动两台 MCP，并自动替换这个项目的旧主应用；确认就绪后退出启动命令，服务在后台继续运行。
应用默认监听 `127.0.0.1:8000`，修改 `app` 下的 Python 文件会自动重载；前端修改后刷新浏览器。
`ExecutionPolicy Bypass` 只用于这次 PowerShell 进程，不修改系统的执行策略。

如不需要热重载：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\start.ps1 -NoReload
```

不必激活虚拟环境，也不依赖终端能否找到 `uv`。脚本按自身位置寻找 `.venv`，路径中有空格也可以运行。

## 4. 停止与查看状态

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\stop.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\start.ps1 -Status
```

停止脚本根据 `log/windows-dev.json` 中的 PID、启动时间和 Python 路径识别进程，结束对应进程树，包含热重载子进程。
启动时会自动结束通过本项目虚拟环境启动的旧主应用，并重新使用当前参数启动，包含以前手动运行的主应用。
启动脚本会核对进程路径、启动时间，以及应用命令或页面，避免按端口直接结束其他程序。
已手动启动的 MCP 服务会被复用，但不会被停止脚本接管或结束。
F5 启动的主应用由 VS Code 管理，请先按 `Shift+F5`，再用停止脚本收起后台 MCP。
MySQL、虚拟机和 Milvus 的生命周期由你单独管理。

状态命令只看端口是否监听；需要检查数据库和 Milvus 是否就绪时用：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\start.ps1 -CheckOnly
```

只启动或复用 MCP（例如手动运行主程序前）：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\start.ps1 -McpOnly
```

也可以按 `Ctrl+Shift+P` →「任务：运行任务」选择：

| 任务 | 用途 |
| --- | --- |
| `MewHelp: start` | 后台启动，默认构建任务，亦可按 `Ctrl+Shift+B` |
| `MewHelp: stop` | 停止脚本管理的应用和 MCP |
| `MewHelp: check` | 检查 MySQL、Milvus、配置项 |
| `MewHelp: status` | 查看应用和 MCP 端口 |

## 5. 日志与常见情况

- 主应用启动日志：`log/app-8000.stderr.log`；标准输出：`log/app-8000.stdout.log`。
- MCP 日志：`log/mcp-logistics.stderr.log`、`log/mcp-aftersales.stderr.log`，标准输出在同名 `.stdout.log`。
- 业务执行日志：`log/app.log`。F5 期间启动日志直接显示在 VS Code 调试终端和调试控制台。
- 输出 `[RESTART]` → `[FREE]`：旧主应用已停止，端口已释放，随后会启动新应用或交给 F5 调试器启动。
- 提示端口不属于本项目：占用者是其他程序或无法核验，脚本会保留它并退出。
- 提示 `Milvus 未就绪`：确认虚拟机已开、容器已启动、IP 没有变。
- MCP 文件改动不参与主应用热重载，需要停止相应 MCP 后重新启动。
- `.env` 修改后需要重启主应用。不要重新复制 `.env.example` 覆盖已经配置好的 `.env`。
- 启动失败会尝试清理本次新建的进程，保留之前就运行的服务；失败时查看对应 `.stderr.log`。

辅助参数 `-Port 8125` 可用于临时换应用端口；启动和停止时传入相同的端口。VS Code 的 F5 配置固定使用 8000。
