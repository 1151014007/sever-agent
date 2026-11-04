"""Windows 开发启动检查。只连数据库、Milvus 和本机服务，不调用付费模型。"""
from __future__ import annotations

import argparse
import asyncio
import json
import logging
import socket
import sys
from pathlib import Path
from urllib.parse import urlparse
from urllib.request import urlopen

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))


def config():
    if not (ROOT / ".env").is_file():
        raise RuntimeError("缺少 .env，请先完成模型和数据库配置。")
    # 不输出配置异常里的 input_value，避免错误日志带出密钥。
    from pydantic import ValidationError

    try:
        from app.config import settings
    except ValidationError as exc:
        fields = ", ".join(".".join(map(str, item["loc"])) for item in exc.errors())
        raise RuntimeError(f"请检查 .env 中这些配置项：{fields}") from None
    for name in ("chat_api_key", "embed_api_key", "rerank_api_key"):
        if not getattr(settings, name).strip():
            raise RuntimeError(f".env 中 {name.upper()} 为空。")
    return settings


def mcp_ports(settings) -> dict[str, int]:
    ports = {}
    for name in ("logistics", "aftersales"):
        uri = urlparse(getattr(settings, f"mcp_{name}_url"))
        if uri.scheme != "http" or uri.hostname not in ("127.0.0.1", "localhost") or not uri.port or uri.path.rstrip("/") != "/mcp":
            raise RuntimeError(f"MCP_{name.upper()}_URL 应使用本机 http://127.0.0.1:端口/mcp。")
        ports[name] = uri.port
    if ports["logistics"] == ports["aftersales"]:
        raise RuntimeError("两台 MCP 服务不能使用同一个端口。")
    return ports


async def preflight(settings) -> None:
    from sqlalchemy import text
    from sqlalchemy.ext.asyncio import create_async_engine

    engine = create_async_engine(settings.database_url, connect_args={"connect_timeout": 5})
    try:
        async with asyncio.timeout(8):
            async with engine.connect() as conn:
                await conn.execute(text("SELECT 1"))
    except Exception:
        raise RuntimeError("MySQL 连接失败，请确认本机 MySQL 服务及 .env 中的 DATABASE_URL。") from None
    finally:
        await engine.dispose()
    print("[OK] MySQL 连接与数据库登录正常。", flush=True)

    uri = urlparse(settings.milvus_uri)
    if uri.scheme not in ("http", "https") or not uri.hostname:
        raise RuntimeError("当前启动入口需要 MILVUS_URI 指向虚拟机中的 Milvus Standalone。")
    try:
        with socket.create_connection((uri.hostname, uri.port or 19530), timeout=5):
            pass
        # 此项目的 Standalone 在 9091 提供健康检查。
        with urlopen(f"http://{uri.hostname}:9091/healthz", timeout=5) as response:
            if response.status != 200:
                raise OSError("unhealthy")
    except Exception:
        raise RuntimeError(
            f"Milvus 未就绪（{uri.hostname}）。请启动 Ubuntu，在 ~/milvus 执行 docker compose up -d；"
            "若虚拟机 IP 改变，请更新 .env 的 MILVUS_URI。"
        ) from None
    print("[OK] Milvus 端口与健康检查正常。", flush=True)
    mcp_ports(settings)
    print("[OK] 模型配置项齐全；本次检查不会请求模型 API。", flush=True)


async def probe(settings, service: str, port: int) -> None:
    if service == "app":
        with urlopen(f"http://127.0.0.1:{port}/openapi.json", timeout=3) as response:
            if json.load(response).get("info", {}).get("title") != "MewHelp":
                raise RuntimeError("该端口不是 MewHelp 应用。")
        return
    import httpx
    from mcp import ClientSession
    from mcp.client.streamable_http import streamable_http_client

    async with asyncio.timeout(6):
        async with httpx.AsyncClient(timeout=4) as http:
            async with streamable_http_client(getattr(settings, f"mcp_{service}_url"), http_client=http) as (read, write, _):
                async with ClientSession(read, write) as session:
                    result = await session.initialize()
                    if result.serverInfo.name != service:
                        raise RuntimeError("该端口的 MCP 服务名称不匹配。")
                    tools = await session.list_tools()
                    required = {"logistics": {"query_logistics"}, "aftersales": {"query_warranty", "query_return_status"}}
                    if not required[service] <= {tool.name for tool in tools.tools}:
                        raise RuntimeError("MCP 服务缺少预期工具。")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["config", "check", "probe"])
    parser.add_argument("--service", choices=["app", "logistics", "aftersales"])
    parser.add_argument("--port", type=int, default=8000)
    args = parser.parse_args()
    logging.disable(logging.CRITICAL)
    try:
        settings = config()
        if args.action == "config":
            print(json.dumps(mcp_ports(settings)))
        elif args.action == "check":
            asyncio.run(preflight(settings))
        elif args.service:
            asyncio.run(probe(settings, args.service, args.port))
        else:
            raise RuntimeError("probe 需要 --service。")
    except KeyboardInterrupt:
        return 130
    except Exception as exc:
        # probe 失败只作为就绪判据；不打印上游响应或连接串。
        if args.action != "probe":
            message = str(exc) if isinstance(exc, RuntimeError) else "检查失败，请核对本地环境与 .env。"
            print(f"[ERROR] {message}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
