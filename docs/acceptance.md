# 验收手册

先完成 README 的部署和知识导入。仅 `/healthz` 成功代表进程可响应；`/readyz` 成功代表 MySQL 核心表和 Milvus 可达。两者不检查模型余额、知识命中率或实际答复质量。

在客服页面从新会话执行下列用例，订单 1001 是模拟单。模型措辞可以变化，验收按证据和动作判断。

| 用例 | 操作 | 通过条件 |
| --- | --- | --- |
| 政策问答 | 问“退货运费谁承担？” | 答复基于退换货政策，引用可点开核对；不承诺材料中不存在的规则。 |
| 订单物流 | 问“订单 1001 的物流到哪了？” | 使用订单工具取得单号，再走物流 MCP；可在工具审计中看到来源、状态和耗时。 |
| 退款咨询 | 新会话问“我想退货”，按界面提示选择订单 1001 | 缺订单时请求选择；选择后继续处理，参考订单状态与售后政策。不会直接退款。 |
| 证据不足 | 问“能报销外部宠物医院的手术费吗？” | 证据不足时兜底，不编造报销政策；可在问题池或日志核对。 |
| 工单确认 | 要求建一条售后工单，先取消；再提出同样请求并确认 | 取消不建单；确认后执行并留审计。 |

部署后可用 CLI 重放前三条验收路径。该命令发起真实模型调用，会产生演示会话；工单确认与答复质量仍按上表检查。

```sh
uv run --locked python -m scripts.verify_business --base-url http://127.0.0.1:8080
```

离线回归使用与 CI 相同的测试范围：

```sh
uv sync --locked --python 3.12
uv run --locked pytest -q tests/test_release_health.py tests/test_business_verification.py tests/test_llm_structured.py tests/test_static.py tests/test_context_assembly.py tests/test_prompt_cache_prefix.py tests/graph/test_routing.py tests/graph/test_forced_rag.py tests/core/test_layers.py tests/core/test_observability.py tests/tools/test_engine.py tests/tools/test_order_ownership.py tests/tools/test_mcp_servers.py
```

配置缺失时，可以填入 CI 定义的测试环境变量。此套件不会要求真实模型凭证。其余集成测试按场景启用测试 MySQL 和 Milvus；`TEST_DATABASE_URL` 必须指向独立测试库，数据库测试会重建测试表。旧评测报告未随仓库发布，需使用当前模型与样例重新生成。
