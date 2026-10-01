# Imagen de LibreDTE Slim: clona el código de la app (rama por defecto, o el
# tag SLIM_VERSION) e instala sus dependencias. Sirve para web, workers,
# setup y console (cambia solo el comando).
ARG PYTHON_VERSION=3.14

# --- Etapa de construcción: git, uv y el entorno virtual ---
FROM python:${PYTHON_VERSION}-slim AS build

RUN apt-get update \
    && apt-get install -y --no-install-recommends git ca-certificates \
    && rm -rf /var/lib/apt/lists/*
COPY --from=ghcr.io/astral-sh/uv:0.12 /uv /usr/local/bin/uv

ARG SLIM_REPO=https://github.com/LibreDTE/libredte-app-slim.git
# Vacío: último commit de la rama por defecto. Con valor: ese tag.
ARG SLIM_VERSION=

# El hash completo se guarda aparte (en la imagen final no hay `.git`): Slim lo
# muestra en el pie y sirve para saber con qué código corre un servidor.
RUN if [ -n "${SLIM_VERSION}" ]; then \
        git clone --depth 1 --branch "${SLIM_VERSION}" "${SLIM_REPO}" /app; \
    else \
        git clone --depth 1 "${SLIM_REPO}" /app; \
    fi \
    && git -C /app rev-parse HEAD > /slim-commit \
    && rm -rf /app/.git

# Las dependencias salen de `pyproject.toml` (sin extras `dev`): el proyecto no
# se instala como paquete, se ejecuta desde /app.
RUN uv venv /opt/venv \
    && uv pip install --python /opt/venv/bin/python --requirement /app/pyproject.toml

# --- Imagen final ---
FROM python:${PYTHON_VERSION}-slim

ENV PATH=/opt/venv/bin:$PATH \
    PYTHONPATH=/app \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    STATIC_ROOT=/srv/static \
    MEDIA_ROOT=/var/lib/slim/media \
    EMISION_MASIVA_PDF_DIR=/var/lib/slim/emision_masiva

# UID fijo: los volúmenes compartidos (media, emision_masiva) deben tener el
# mismo dueño en todos los contenedores.
RUN groupadd --gid 10001 slim \
    && useradd --uid 10001 --gid slim --no-create-home --shell /usr/sbin/nologin slim \
    && mkdir -p /srv/static /var/lib/slim/media /var/lib/slim/emision_masiva /var/lib/slim/state \
    && chown -R slim:slim /srv/static /var/lib/slim \
    && chmod 700 /var/lib/slim/state

COPY --from=build /opt/venv /opt/venv
COPY --from=build --chown=root:root /app /app
COPY --from=build /slim-commit /etc/slim-commit

WORKDIR /app
USER slim
