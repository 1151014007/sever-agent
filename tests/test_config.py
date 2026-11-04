import pytest
from pydantic import ValidationError

from app.config import Settings


_REQUIRED = {
    "CHAT_MODEL": "deepseek-ai/DeepSeek-V4-Flash",
    "CHAT_BASE_URL": "https://api.siliconflow.cn/v1",
    "CHAT_API_KEY": "sk-test",
    "EMBED_API_KEY": "sk-test",
    "RERANK_API_KEY": "sk-test",
}


def _fill(monkeypatch, skip=None):
    for k, v in _REQUIRED.items():
        if k == skip:
            monkeypatch.delenv(k, raising=False)
        else:
            monkeypatch.setenv(k, v)


@pytest.mark.parametrize("missing", sorted(_REQUIRED))
def test_账号相关的配置都必填(monkeypatch, missing):
    # 这几项都跟着账号走,给默认值等于假定上游模型:猜错不在启动时报错,而是第一次调上游时
    # 抛一个看不懂的 401。缺了就在启动报 Field required,直接指向 .env
    _fill(monkeypatch, skip=missing)
    with pytest.raises(ValidationError):
        Settings(_env_file=None)


def test_嵌入与重排的地址有默认值_只要填_key(monkeypatch):
    # 这两个上游地址是固定的(硅基流动),保持可覆盖的默认值
    _fill(monkeypatch)
    s = Settings(_env_file=None)
    assert s.embed_base_url == "https://api.siliconflow.cn/v1"
    assert s.rerank_base_url == "https://api.siliconflow.cn/v1"


def test_settings_defaults(monkeypatch):
    # 隔离 .env 与其他测试可能泄漏进 os.environ 的值,测的是代码默认值
    _fill(monkeypatch)
    monkeypatch.delenv("MILVUS_COLLECTION", raising=False)
    s = Settings(_env_file=None)
    assert s.token_budget == 2000
    assert s.rerank_model == "BAAI/bge-reranker-v2-m3"
    assert s.milvus_collection == "mewhelp_knowledge"


def test_settings_env_override(monkeypatch):
    _fill(monkeypatch)
    monkeypatch.setenv("TOKEN_BUDGET", "500")
    monkeypatch.setenv("MILVUS_COLLECTION", "isolated_test_kb")
    s = Settings(_env_file=None)
    assert s.token_budget == 500
    assert s.milvus_collection == "isolated_test_kb"
