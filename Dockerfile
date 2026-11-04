FROM ghcr.io/astral-sh/uv:0.12.5 AS uv
FROM python:3.12-slim
COPY --from=uv /uv /usr/local/bin/uv
ENV PYTHONUTF8=1 PYTHONUNBUFFERED=1 PYTHONDONTWRITEBYTECODE=1 \
    UV_PYTHON_DOWNLOADS=never UV_LINK_MODE=copy UV_NO_SYNC=1 \
    PATH="/srv/mewhelp/.venv/bin:$PATH"
WORKDIR /srv/mewhelp
RUN apt-get update && apt-get install -y --no-install-recommends make libgomp1 \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --system --create-home --uid 10001 mewhelp
COPY pyproject.toml uv.lock ./
RUN uv sync --locked --no-dev --no-install-project
COPY --chown=mewhelp:mewhelp app app
COPY --chown=mewhelp:mewhelp mcp_servers mcp_servers
COPY --chown=mewhelp:mewhelp scripts scripts
COPY --chown=mewhelp:mewhelp data/kb data/kb
COPY --chown=mewhelp:mewhelp tests/data tests/data
COPY --chown=mewhelp:mewhelp Makefile ./
RUN mkdir -p data/session log && chown -R mewhelp:mewhelp data log
USER mewhelp
EXPOSE 8000
CMD ["python", "-m", "uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]
