#!/bin/bash
# Respaldos de Slim: base de datos, media (logos), secretos (volumen state:
# SECRET_KEY y FIELD_ENCRYPTION_KEY, sin la cual los certificados guardados
# quedan ilegibles) y el .env del host.
#
#   backup.sh                       # ciclo: respalda ahora y cada BACKUP_INTERVAL_HOURS
#   backup.sh now                   # un respaldo
#   backup.sh list                  # lista los respaldos
#   backup.sh restore <timestamp>   # repone base de datos, media y secretos
#   backup.sh health                # healthcheck: el último respaldo es reciente
#
# Archivos en /backups: <timestamp>-db.dump (pg_dump, formato custom),
# <timestamp>-files.tar.gz (media/ y state/) y <timestamp>-env (el .env), que
# se borran pasados BACKUP_KEEP_DAYS días. No incluye los ZIP de PDF de la
# emisión masiva (se regeneran).
set -euo pipefail
# Los respaldos contienen contraseñas y claves: solo el dueño.
umask 077

BACKUP_DIR=/backups
DATA_DIR=/data
# Dueño de los archivos: el usuario `slim` de la imagen de Slim.
APP_UID=10001 APP_GID=10001
export PGHOST="${DB_HOST}" PGPORT="${DB_PORT}" PGUSER="${DB_USER}" PGPASSWORD="${DB_PASSWORD}"

backup() {
    local ts tmp
    ts="$(date -u +%Y%m%dT%H%M%SZ)"
    echo "==> Respaldo ${ts}"
    tmp="${BACKUP_DIR}/.${ts}"
    pg_dump --format=custom --no-owner --dbname="${DB_NAME}" --file="${tmp}-db.dump"
    tar -C "${DATA_DIR}" -czf "${tmp}-files.tar.gz" media state
    cp /host/.env "${tmp}-env"
    mv "${tmp}-db.dump" "${BACKUP_DIR}/${ts}-db.dump"
    mv "${tmp}-files.tar.gz" "${BACKUP_DIR}/${ts}-files.tar.gz"
    mv "${tmp}-env" "${BACKUP_DIR}/${ts}-env"
    find "${BACKUP_DIR}" -maxdepth 1 \( -name '*-db.dump' -o -name '*-files.tar.gz' -o -name '*-env' \) \
        -mtime +"${BACKUP_KEEP_DAYS}" -delete
    ls -lh "${BACKUP_DIR}/${ts}"-*
}

restore() {
    local ts="${1:?Uso: backup.sh restore <timestamp> (ver: backup.sh list)}"
    local db="${BACKUP_DIR}/${ts}-db.dump" files="${BACKUP_DIR}/${ts}-files.tar.gz"
    [ -f "${db}" ] && [ -f "${files}" ] || { echo "No existe el respaldo ${ts}" >&2; exit 1; }
    echo "==> Reponiendo la base de datos ${DB_NAME} desde ${db}"
    # Base nueva: nada creado después del respaldo sobrevive. --force cierra las
    # conexiones abiertas de Slim.
    dropdb --if-exists --force --maintenance-db=postgres "${DB_NAME}"
    createdb --maintenance-db=postgres "${DB_NAME}"
    pg_restore --no-owner --exit-on-error --dbname="${DB_NAME}" "${db}"
    echo "==> Reponiendo media y secretos desde ${files}"
    find "${DATA_DIR}/media" "${DATA_DIR}/state" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
    tar -C "${DATA_DIR}" -xzpf "${files}"
    chown -R "${APP_UID}:${APP_GID}" "${DATA_DIR}/media" "${DATA_DIR}/state"
    echo "==> Repuesto ${ts}"
    if [ -f "${BACKUP_DIR}/${ts}-env" ]; then
        echo "    El .env de ese respaldo está en ${BACKUP_DIR}/${ts}-env (no se toca el .env"
        echo "    del host: compáralo y cópialo a mano si hace falta)."
    fi
}

case "${1:-loop}" in
    now) backup ;;
    list)
        for file in "${BACKUP_DIR}"/*-db.dump; do
            [ -e "${file}" ] && basename "${file}" -db.dump
        done | sort
        ;;
    restore) restore "${2:-}" ;;
    health)
        [ -n "$(find "${BACKUP_DIR}" -maxdepth 1 -name '*-db.dump' \
            -mmin -$(( BACKUP_INTERVAL_HOURS * 60 + 60 )) 2>/dev/null)" ]
        ;;
    loop)
        while :; do
            backup || echo "Falló el respaldo" >&2
            sleep $(( BACKUP_INTERVAL_HOURS * 3600 ))
        done
        ;;
    *) echo "Comando desconocido: $1" >&2; exit 2 ;;
esac
