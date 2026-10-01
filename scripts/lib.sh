#!/bin/sh
# Funciones comunes de los contenedores de Slim (se cargan con `.`).
#
# - drop_empty_vars: compose pasa las variables opcionales vacías; Slim usa
#   `os.environ.get(NOMBRE, default)`, que con una variable vacía devuelve ''
#   en vez del default. Se eliminan las vacías.
# - load_secrets: carga `secrets.env` (SECRET_KEY, FIELD_ENCRYPTION_KEY) solo
#   para las variables que no vengan definidas en `.env`.
# - export_versions: SLIM_COMMIT (lo deja el build) y LIBREDTE_BACKEND_COMMIT
#   (si CORE_API_VERSION es un hash completo) para el pie de la app.

SECRETS_FILE="${SLIM_STATE_DIR:-/var/lib/slim/state}/secrets.env"

drop_empty_vars() {
    for name in $(env | sed -n 's/^\([A-Za-z_][A-Za-z0-9_]*\)=$/\1/p'); do
        unset "${name}"
    done
}

# Valor de NAME en secrets.env ('' si no existe). No se hace `.` del archivo:
# los valores pueden traer caracteres especiales.
secret_value() {
    [ -f "${SECRETS_FILE}" ] || return 0
    sed -n "s/^$1=//p" "${SECRETS_FILE}" | head -n 1
}

load_secrets() {
    for name in SECRET_KEY FIELD_ENCRYPTION_KEY; do
        eval "current=\${${name}:-}"
        if [ -z "${current}" ]; then
            value="$(secret_value "${name}")"
            if [ -n "${value}" ]; then
                export "${name}=${value}"
            fi
        fi
    done
}

export_versions() {
    if [ -z "${SLIM_COMMIT:-}" ] && [ -s /etc/slim-commit ]; then
        SLIM_COMMIT="$(cat /etc/slim-commit)"
        export SLIM_COMMIT
    fi
    # Con la Core API fijada a un hash completo (el tag de sus imágenes es el
    # commit), ese hash es la versión exacta del backend.
    core_version="${CORE_API_VERSION:-}"
    if [ -z "${LIBREDTE_BACKEND_COMMIT:-}" ] && [ "${#core_version}" -eq 40 ] \
        && ! printf '%s' "${core_version}" | grep '[^0-9a-f]' > /dev/null; then
        LIBREDTE_BACKEND_COMMIT="${core_version}"
        export LIBREDTE_BACKEND_COMMIT
    fi
}
