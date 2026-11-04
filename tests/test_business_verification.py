import httpx
import pytest

from scripts.verify_business import CheckFailed, stream_events


def test_error_event_fails_even_with_successful_http_status():
    body = 'event: error\n\ndata: {"message":"provider unavailable"}\n\n'
    with httpx.Client(
        base_url="http://test",
        transport=httpx.MockTransport(lambda _: httpx.Response(200, text=body)),
    ) as client, pytest.raises(CheckFailed, match="SSE"):
        stream_events(client, "/api/chat", {})


def test_incomplete_stream_does_not_count_as_a_pass():
    body = 'data: {"delta":"partial"}\n\n'
    with httpx.Client(
        base_url="http://test",
        transport=httpx.MockTransport(lambda _: httpx.Response(200, text=body)),
    ) as client, pytest.raises(CheckFailed, match="结束标记"):
        stream_events(client, "/api/chat", {})


def test_events_are_preserved_in_stream_order():
    body = 'data: {"event":"tool","name":"query_order"}\n\ndata: {"event":"done"}\n\ndata: [DONE]\n\n'
    with httpx.Client(
        base_url="http://test",
        transport=httpx.MockTransport(lambda _: httpx.Response(200, text=body)),
    ) as client:
        events = stream_events(client, "/api/chat", {})
    assert [ev["event"] for ev in events] == ["tool", "done"]


@pytest.mark.parametrize("lookup_ok", [True, False])
def test_logistics_checks_tool_execution_and_tracking_number(lookup_ok):
    from scripts.verify_business import verify_logistics

    body = {
        "answer": "运单正在运输",
        "tool_calls": [
            {"id": "order", "name": "query_order", "args": {"order_id": "1001"}},
            {"id": "logistics", "name": "query_logistics", "args": {"tracking_no": "SF123"}},
        ],
        "tool_results": [
            {"tool_call_id": "order", "name": "query_order", "ok": True,
             "content": '{"tracking_no":"SF123"}'},
            {"tool_call_id": "logistics", "name": "query_logistics", "ok": lookup_ok,
             "content": '{"tracking_no":"SF123","status":"运输中"}'},
        ],
    }

    def handler(request):
        assert request.url.path == "/api/agent"
        return httpx.Response(200, json=body)

    with httpx.Client(base_url="http://test", transport=httpx.MockTransport(handler)) as client:
        if lookup_ok:
            verify_logistics(client, "demo")
        else:
            with pytest.raises(CheckFailed, match="成功"):
                verify_logistics(client, "demo")
