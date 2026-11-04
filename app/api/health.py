"""Liveness and dependency readiness for the service."""
import asyncio

from fastapi import APIRouter
from fastapi.responses import JSONResponse
from sqlalchemy import text

from app.db.base import engine
from app.kb import milvus_client

router = APIRouter(tags=["Health"])
_PROBE_TIMEOUT = 3.0


async def _check_mysql() -> None:
    async with engine.connect() as conn:
        await conn.execute(text("SELECT 1 FROM conversations LIMIT 1"))


async def _check_milvus() -> None:
    def probe() -> None:
        milvus_client.get_client().list_collections(timeout=2.0)

    await milvus_client.acall(probe)


async def _status(probe) -> str:
    try:
        await asyncio.wait_for(probe(), timeout=_PROBE_TIMEOUT)
    except Exception:
        return "unavailable"
    return "ok"


@router.get("/healthz")
async def liveness() -> dict:
    return {"status": "ok"}


@router.get("/readyz")
async def readiness() -> JSONResponse:
    mysql, milvus = await asyncio.gather(_status(_check_mysql), _status(_check_milvus))
    ready = mysql == milvus == "ok"
    return JSONResponse(
        {"status": "ready" if ready else "not_ready",
         "checks": {"mysql": mysql, "milvus": milvus}},
        status_code=200 if ready else 503,
    )
