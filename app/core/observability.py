"""按配置为 LangGraph 接入 Langfuse，记录意图和置信度。"""
import logging

from app.config import settings

logger = logging.getLogger(__name__)
_client = None


def langfuse_enabled() -> bool:
    return bool(settings.langfuse_public_key and settings.langfuse_secret_key
                and settings.langfuse_base_url)


def _init_client():
    """初始化(或复用)Langfuse 单例。"""
    global _client
    if _client is None:
        from langfuse import Langfuse
        _client = Langfuse(
            public_key=settings.langfuse_public_key,
            secret_key=settings.langfuse_secret_key,
            base_url=settings.langfuse_base_url,
        )
    return _client


def _make_handler():
    from langfuse.langchain import CallbackHandler

    class _InlineCallbackHandler(CallbackHandler):
        """run_inline=True:让 LangChain 在调用方协程内联执行回调,而不是丢进独立 task。
        没有它,handler 的 OTel context.attach 挂在别的 task 上,节点代码里没有活动
        span 上下文,tag_intent 的 propagate_attributes 写不进当前 trace(上下文约束)。"""
        run_inline = True

    return _InlineCallbackHandler()


def get_langfuse():
    """启用时返回已初始化 client(cost 脚本用 client.api 查询);未启用返回 None。"""
    if not langfuse_enabled():
        return None
    return _init_client()


def attach_observability(graph):
    """为已编译的图配置回调。缺少配置时返回原图。"""
    if not langfuse_enabled():
        return graph
    _init_client()
    return graph.with_config({"callbacks": [_make_handler()]})


def tag_intent(intent: str, confidence: float) -> None:
    """标注意图和置信度，供调用成本按意图归集。"""
    if not langfuse_enabled():
        return
    try:
        from langfuse import get_client, propagate_attributes
        # 不能只 with...pass 写"当前活动 span"——LangGraph 异步调度下它可能已 ended,
        # OTel 对 ended span 的写入静默丢弃(上下文约束)。改为在传播上下文内新建一个
        # event 观测:新 span 必然存活,trace 级属性(metadata/tags)随它上提到整条 trace。
        with propagate_attributes(
            metadata={"intent": intent, "intent_confidence": f"{confidence:.2f}"},
            tags=[f"intent:{intent}"],
        ):
            get_client().create_event(name="intent-tagged")
    except Exception:
        logger.warning("langfuse tag_intent 失败(已忽略)", exc_info=True)
