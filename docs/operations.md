# 运行手册

推荐部署命令均从仓库根目录执行，并使用 `-f compose.release.yml`。不带该参数的旧 Compose 文件用于本机开发依赖。

| 检查点 | 怎么查 | 异常时先看什么 |
| --- | --- | --- |
| 应用进程 | `GET /healthz` | 服务日志、端口占用和应用启动配置 |
| 核心依赖 | `GET /readyz` | 返回体的 `checks.mysql`、`checks.milvus`；异常时 HTTP 503 |
| 知识问答 | 运营工作台的知识库页面 | 导入任务、向量维度、检索集合和重排上游 |
| MCP 查询 | 订单物流验收用例 | `logistics`、`aftersales` 的日志和工具审计 |
| 模型调用 | `app` 日志及可选 Langfuse | 接口地址、模型标识、额度、超时和上下文窗口 |

```sh
docker compose -f compose.release.yml ps
docker compose -f compose.release.yml logs --tail 100 app
docker compose -f compose.release.yml logs --tail 100 mysql milvus logistics aftersales
docker compose -f compose.release.yml down
```

如果构建停在 `load metadata` 或 `pull`，先用 `docker pull python:3.12-slim`、`docker pull ghcr.io/astral-sh/uv:0.12.5` 分别核对镜像仓库访问。宿主机浏览器能联网不代表 Docker Engine 使用的代理和 DNS 可用。

普通 `down` 保留命名卷。MySQL、Milvus 对象与元数据、SQLite 会话检查点分别持久化。备份与恢复需要同时考虑 MySQL 中的知识索引记录、Milvus 向量数据及 SQLite 检查点。升级时先备份；MySQL 首次初始化脚本只在空卷执行，已有库应单独应用并验证迁移。请勿用删除卷代替升级。

后台的知识、评估和分类器页面可读取本地生成的产物，缺失时显示未生成。训练和容器管理任务适合在开发环境执行；交付镜像未挂载 Docker socket，也未安装训练依赖。可选的 Langfuse 依赖使用独立 Compose 文件，默认仅在本机绑定端口。它的 PostgreSQL 连接使用 `LANGFUSE_DATABASE_URL`，与客服的 `DATABASE_URL` 分开配置。需要 Langfuse 时填入容器可达地址；直接写 `localhost` 会指向应用容器自身。

当前订单身份由演示会话提供，应用监听通过 Compose 限定在宿主机环回地址。对公网或真实客户交付前，应由接入方接管身份认证、管理接口授权、真实订单工具和日志脱敏。模型密钥、数据库快照、运行日志和生成报告不属于公开交付内容。
