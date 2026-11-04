"""Verify the deployed customer journey through the HTTP and SSE APIs."""
import argparse
import json
import sys
from uuid import uuid4

import httpx


class CheckFailed(RuntimeError):
    pass


def require(condition: bool, message: str) -> None:
    if not condition:
        raise CheckFailed(message)


def stream_events(client: httpx.Client, path: str, payload: dict) -> list[dict]:
    events: list[dict] = []
    complete = False
    with client.stream("POST", path, json=payload) as response:
        response.raise_for_status()
        for line in response.iter_lines():
            if line.strip() == "event: error":
                raise CheckFailed("服务返回 SSE 错误事件，请查看应用日志")
            if not line.startswith("data:"):
                continue
            data = line.removeprefix("data:").strip()
            if data == "[DONE]":
                complete = True
                break
            event = json.loads(data)
            require(isinstance(event, dict), "SSE 数据不是 JSON 对象")
            events.append(event)
    require(complete, "SSE 未收到结束标记")
    return events


def completed_answer(events: list[dict]) -> bool:
    return (
        any(event.get("event") == "done" for event in events)
        and any(bool(event.get("delta")) for event in events)
    )


def verify_logistics(client: httpx.Client, user_id: str) -> None:
    response = client.post("/api/agent", json={
        "user_id": user_id, "message": "订单 1001 的物流到哪了？",
    })
    response.raise_for_status()
    body = response.json()
    results = {r["tool_call_id"]: r for r in body["tool_results"] if r.get("ok")}
    tracking_numbers: set[str] = set()
    for call in body["tool_calls"]:
        result = results.get(call["id"])
        if result is None:
            continue
        if call["name"] not in {"query_order", "query_logistics"}:
            continue
        data = json.loads(result["content"])
        tracking = data.get("tracking_no")
        if call["name"] == "query_order" and tracking:
            tracking_numbers.add(tracking)
        if (call["name"] == "query_logistics" and tracking in tracking_numbers
                and tracking == call["args"].get("tracking_no") and body.get("answer")):
            return
    raise CheckFailed("物流查询未成功使用订单工具返回的运单号")


def verify(client: httpx.Client) -> None:
    ready = client.get("/readyz")
    ready.raise_for_status()
    require(ready.json().get("status") == "ready", "服务依赖未就绪")
    user = f"delivery-check-{uuid4().hex[:10]}"

    def chat(message: str) -> list[dict]:
        return stream_events(client, "/api/chat", {"user_id": user, "message": message})

    policy = chat("退货退款政策是什么？")
    require(completed_answer(policy), "政策问答未完成")
    require(any(e.get("event") == "citations" and e.get("items") for e in policy),
            "政策问答没有可核对的知识引用")
    print("PASS: 政策问答与知识引用")

    verify_logistics(client, user)
    print("PASS: 订单和物流工具成功，运单号一致")

    refund = chat("我想退货")
    interrupt = next((e for e in refund if e.get("event") == "interrupt"
                      and e.get("kind") == "select_order"), None)
    require(interrupt is not None, "退款咨询缺少订单选择中断")
    require(any(str(o.get("order_id")) == "1001" for o in interrupt.get("orders", [])),
            "退款中断没有返回演示订单 1001")
    conversation_id = interrupt["conversation_id"]
    resumed = stream_events(client, "/api/actions/resume",
                            {"conversation_id": conversation_id, "order_id": "1001"})
    require(completed_answer(resumed) and any(
        e.get("event") == "done" and e.get("conversation_id") == conversation_id
        for e in resumed
    ), "退款咨询未在同一会话续跑完成")
    print("PASS: 退款订单选择与同会话续跑")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base-url", default="http://127.0.0.1:8080")
    parser.add_argument("--timeout", type=float, default=90.0)
    args = parser.parse_args()
    try:
        with httpx.Client(base_url=args.base_url, timeout=args.timeout) as client:
            verify(client)
    except (CheckFailed, httpx.HTTPError, ValueError, KeyError) as exc:
        print(f"FAIL: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
