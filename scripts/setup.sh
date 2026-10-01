#!/bin/sh
# Instala o actualiza Slim en cada `docker compose up`; seguro de repetir.
# Corre como root solo para los dueños de los volúmenes; Slim, como `slim`.
#
# 1. Dueños de los volúmenes compartidos.
# 2. Secretos (SECRET_KEY, FIELD_ENCRYPTION_KEY) en el volumen `state`.
# 3. Migraciones, estáticos para Caddy y catálogos del SII (`seed`).
# 4. Solo con SLIM_SEED_DEMO: los datos de demostración (`seed_demo`).
set -eu

# shellcheck source=/dev/null
. /usr/local/share/stack/scripts/lib.sh

STATE_DIR="${SLIM_STATE_DIR:-/var/lib/slim/state}"

as_slim() { runuser -u slim -- "$@"; }

drop_empty_vars
export_versions

echo "==> Volúmenes"
for dir in /var/lib/slim/media /var/lib/slim/emision_masiva /srv/static "${STATE_DIR}"; do
    mkdir -p "${dir}"
    find "${dir}" ! -user slim -exec chown slim:slim {} +
done
chmod 700 "${STATE_DIR}"

echo "==> Secretos"
generate() {
    case "$1" in
        SECRET_KEY) python -c 'import secrets; print(secrets.token_urlsafe(64))' ;;
        *) python -c 'from cryptography.fernet import Fernet; print(Fernet.generate_key().decode())' ;;
    esac
}
tmp="${SECRETS_FILE}.tmp"
(
    umask 077
    : > "${tmp}"
)
for name in SECRET_KEY FIELD_ENCRYPTION_KEY; do
    eval "from_env=\${${name}:-}"
    recorded="$(secret_value "${name}")"
    if [ "${name}" = FIELD_ENCRYPTION_KEY ] && [ -n "${from_env}" ] && [ -n "${recorded}" ] \
        && [ "${from_env}" != "${recorded}" ]; then
        rm -f "${tmp}"
        echo "ERROR: FIELD_ENCRYPTION_KEY de .env es distinta de la registrada en el" >&2
        echo "volumen state: cambiarla deja ilegibles los certificados guardados." >&2
        echo "Quita la variable de .env (se usa la registrada) o sigue el procedimiento" >&2
        echo "de rotación del README." >&2
        exit 1
    fi
    if [ -n "${from_env}" ]; then
        value="${from_env}"
    elif [ -n "${recorded}" ]; then
        value="${recorded}"
    else
        value="$(generate "${name}")"
        echo "Generada ${name}"
    fi
    echo "${name}=${value}" >> "${tmp}"
done
chown slim:slim "${tmp}"
chmod 600 "${tmp}"
mv "${tmp}" "${SECRETS_FILE}"
load_secrets

cd /app

echo "==> Migraciones"
as_slim python manage.py migrate --no-input

echo "==> Archivos estáticos para Caddy"
as_slim python manage.py collectstatic --no-input --clear > /dev/null

echo "==> Catálogos del SII"
as_slim python manage.py seed

case "$(echo "${SLIM_SEED_DEMO:-0}" | tr '[:upper:]' '[:lower:]')" in
    1 | true | yes)
        echo "==> Datos de demostración"
        as_slim python manage.py seed_demo
        ;;
esac

echo "==> Listo: LibreDTE Slim ${SLIM_COMMIT:-}"
echo "    Sitio: ${SITE_URL_SCHEMA:-http}://${SITE_HOSTNAME%% *}/"
