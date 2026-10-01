#!/bin/sh
# Entrypoint de los contenedores de Slim (web, workers, console): prepara el
# entorno y ejecuta el comando.
set -eu

# shellcheck source=/dev/null
. /usr/local/share/stack/scripts/lib.sh

drop_empty_vars
load_secrets
export_versions

exec "$@"
