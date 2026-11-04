from fastapi.testclient import TestClient

from app.main import app
from app.api import health


def test_liveness_reports_process_status():
    response = TestClient(app).get('/healthz')
    assert response.status_code == 200
    assert response.json() == {'status': 'ok'}


def test_readiness_reports_dependency_failure_without_details(monkeypatch):
    async def mysql_ok():
        return None

    async def milvus_down():
        raise OSError('private dependency endpoint')

    monkeypatch.setattr(health, '_check_mysql', mysql_ok)
    monkeypatch.setattr(health, '_check_milvus', milvus_down)
    response = TestClient(app).get('/readyz')
    assert response.status_code == 503
    assert response.json() == {'status': 'not_ready', 'checks': {'mysql': 'ok', 'milvus': 'unavailable'}}


def test_readiness_succeeds_with_both_dependencies(monkeypatch):
    async def ok():
        return None

    monkeypatch.setattr(health, '_check_mysql', ok)
    monkeypatch.setattr(health, '_check_milvus', ok)
    response = TestClient(app).get('/readyz')
    assert response.status_code == 200
    assert response.json() == {'status': 'ready', 'checks': {'mysql': 'ok', 'milvus': 'ok'}}
