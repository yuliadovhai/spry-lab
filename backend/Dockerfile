# syntax=docker/dockerfile:1

# --- builder: resolve dependencies into a self-contained virtualenv ---
FROM python:3.14-slim AS builder

COPY --from=ghcr.io/astral-sh/uv:latest /uv /usr/local/bin/uv

ENV UV_COMPILE_BYTECODE=1 \
    UV_LINK_MODE=copy \
    UV_PROJECT_ENVIRONMENT=/app/.venv

WORKDIR /app

COPY pyproject.toml uv.lock ./
RUN --mount=type=cache,target=/root/.cache/uv \
    uv sync --frozen --no-dev --no-install-project

# --- dev: same base plus dev dependencies, used by docker-compose.override.yml ---
FROM builder AS dev

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PATH="/app/.venv/bin:$PATH"

RUN --mount=type=cache,target=/root/.cache/uv \
    uv sync --frozen --no-install-project

RUN apt-get update \
    && apt-get install -y --no-install-recommends curl \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY . .
EXPOSE 8000
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000", "--reload"]


# --- runtime ---
FROM python:3.14-slim AS runtime

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PATH="/app/.venv/bin:$PATH"

RUN apt-get update \
    && apt-get install -y --no-install-recommends curl \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --create-home --uid 1000 app

WORKDIR /app

COPY --from=builder --chown=app:app /app/.venv /app/.venv
COPY --chown=app:app . .

USER app
EXPOSE 8000

CMD ["./scripts/entrypoint.sh"]


# --- lambda: what scripts/deploy-backend.sh ships to AWS Lambda ---
# AWS's base image carries the runtime interface client. The virtualenv from
# the builder cannot be reused here - it points at /usr/local/bin/python - so
# the locked dependencies are installed straight into the task root instead.
FROM public.ecr.aws/lambda/python:3.14 AS lambda

RUN --mount=from=ghcr.io/astral-sh/uv:latest,source=/uv,target=/bin/uv \
    --mount=type=bind,source=pyproject.toml,target=pyproject.toml \
    --mount=type=bind,source=uv.lock,target=uv.lock \
    uv export --frozen --no-dev --no-hashes --no-emit-project -o /tmp/requirements.txt \
    && uv pip install --no-cache --compile-bytecode \
        --target "${LAMBDA_TASK_ROOT}" -r /tmp/requirements.txt \
    && rm /tmp/requirements.txt

COPY app ${LAMBDA_TASK_ROOT}/app
COPY migrations ${LAMBDA_TASK_ROOT}/migrations
COPY alembic.ini ${LAMBDA_TASK_ROOT}/

CMD ["app.lambda_handler.handler"]


# --- ai: the agenda parser Lambda (Lab 6), outside the VPC ---
# Its own small image: the parser needs the Anthropic SDK and pydantic, not
# FastAPI or the database driver, and app/ai imports nothing else from app/.
FROM public.ecr.aws/lambda/python:3.14 AS ai

COPY requirements-ai.txt /tmp/requirements-ai.txt
RUN pip install --no-cache-dir --target "${LAMBDA_TASK_ROOT}" -r /tmp/requirements-ai.txt \
    && rm /tmp/requirements-ai.txt

COPY app/__init__.py ${LAMBDA_TASK_ROOT}/app/__init__.py
COPY app/ai ${LAMBDA_TASK_ROOT}/app/ai

CMD ["app.ai.agenda_lambda.handler"]
