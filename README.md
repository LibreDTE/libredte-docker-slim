# LibreDTE Slim: stack Docker

Stack Docker Compose de [LibreDTE Slim](https://github.com/LibreDTE/libredte-app-slim),
la aplicación de facturación electrónica (DTE) para Chile de
[LibreDTE](https://www.libredte.cl), para desarrollo local y para producción en un
servidor. Cada componente corre en su propio contenedor.

| Componente | Imagen | Versión por defecto |
|---|---|---|
| Servidor web (TLS, estáticos, media) | `caddy:<ver>-alpine` | 2.11 |
| LibreDTE Slim: web (gunicorn) y workers (Celery) | imagen propia (se construye al primer `up`) | último commit de la rama por defecto |
| Backend de Slim: LibreDTE Lib Core API | `ghcr.io/libredte/libredte-lib-core-api` | `latest` |
| Base de datos | `postgres:<ver>-alpine` | 18 |
| Cola y caché | `valkey/valkey:<ver>-alpine` | 9.2 |
| Correo de pruebas (opcional, desarrollo) | `axllent/mailpit` | v1.31 |

LibreDTE Slim delega toda la lógica tributaria (timbrar, firmar, generar PDF,
catálogos del SII) en la Core API, que corre en este mismo stack y solo es
accesible desde la red interna.

## Requisitos

- Docker Engine 24+ con el plugin Compose v2 (2.24+).
- Unos 2 GB de disco para las imágenes y 2 GB de RAM para el stack (en reposo usa
  poco más de 1 GB).
- Acceso a GitHub y a `ghcr.io` (el primer `up` clona Slim y baja la Core API).
- Desarrollo: puertos 8080, 8443 y 8025 libres. Producción: 80 y 443 alcanzables y
  un registro DNS del dominio apuntando al servidor.

## Inicio rápido (con datos de demostración)

```shell
git clone https://github.com/LibreDTE/libredte-docker-slim.git
cd libredte-docker-slim
cp .env.example .env
docker compose up -d
docker compose logs -f setup   # espera "==> Listo" (varios minutos la primera vez)
```

- LibreDTE Slim: http://localhost:8080 (usuario `demo`, contraseña `Slim123%`).
- Mailpit, con el correo que envía Slim: http://localhost:8025

El primer `up` **construye** la imagen de Slim (clona el repositorio e instala sus
dependencias): tarda varios minutos. Los siguientes arrancan en segundos.

`.env.example` carga datos de demostración. Si prefieres partir sin ellos, pon
`SLIM_SEED_DEMO=0` antes del primer `up`: el primer usuario y el contribuyente se
crean desde el navegador.

## Producción

```shell
cp .env.prod.example .env
# Obligatorias: SITE_HOSTNAME, SITE_ADDRESS y DB_PASSWORD.
docker compose up -d
```

- Con `SITE_ADDRESS` igual al dominio, Caddy obtiene y renueva un certificado de
  Let's Encrypt (quedan en el volumen `caddy_data`).
- Detrás de otro proxy que termina el TLS, usa `SITE_ADDRESS=:80` y
  `SITE_URL_SCHEMA=https`. Con un Traefik existente, sin puertos del host:
  `overrides/traefik.yaml` (ver [Overrides](#overrides)).
- Configura el correo (`EMAIL_*`): Slim envía por correo el resultado de la emisión
  masiva y los enlaces de recuperación de contraseña. Sin `EMAIL_HOST`, los correos
  solo se escriben en el log.
- Compose se niega a arrancar mientras falte una variable obligatoria.
- El perfil `backup` viene activado en la plantilla de producción.
- **No uses `SLIM_SEED_DEMO=1` en un servidor**: crea un usuario con contraseña
  pública. Para pasar de una instalación con demo a producción, parte de volúmenes
  nuevos (`docker compose down -v`).
- Recomendado: `overrides/local-dirs.yaml`, para que los datos queden en
  directorios del host que un `down -v` no borra.

## Servicios

| Servicio | Perfil | Función |
|---|---|---|
| `caddy` | | Único con puertos publicados. TLS, `/static/`, `/media/` y proxy a `web`. |
| `web` | | LibreDTE Slim (gunicorn, puerto interno 8000). |
| `worker` | | Celery, cola `default`. |
| `worker-emision-masiva` | | Celery, cola `emision_masiva` (tareas largas, de a una por proceso). |
| `libredte-lib-core-api` | | El backend de Slim: timbra, firma, genera PDF. |
| `db` | | PostgreSQL. |
| `valkey` | | Broker de Celery y caché de Django. |
| `setup` | | Job de instalación (`scripts/setup.sh`); corre en cada `up` y es seguro de repetir. |
| `console` | `tools` | `manage.py` de Slim bajo demanda. |
| `backup` | `backup` | Respaldos periódicos (ver [Respaldos](#respaldos)). |
| `mailpit` | `mailpit` | Correo de pruebas (desarrollo). |

Los perfiles se activan con `COMPOSE_PROFILES` en `.env` (separados por coma).

`setup` hace, en orden: dueños de los volúmenes, secretos, migraciones, archivos
estáticos para Caddy y catálogos del SII (`seed`); con `SLIM_SEED_DEMO=1`, además
`seed_demo`. Los mensajes "ya hay … cargados, no se hizo nada" de las siguientes
corridas son normales. Si falla, ni `web` ni los workers arrancan.

## Dónde queda cada dato

| Qué | Dónde |
|---|---|
| Configuración del stack (dominio, puertos, SMTP, `DB_PASSWORD`…) | `.env`, junto a `compose.yaml`. Es tuyo: el stack nunca lo modifica. |
| `SECRET_KEY` y `FIELD_ENCRYPTION_KEY` | Volumen `state` (`secrets.env`). Los genera `setup` la primera vez, si no los defines en `.env`. |
| Archivos que suben los usuarios (logos) | Volumen `media`; Caddy los sirve en `/media/` (son públicos). |
| ZIP de PDF de la emisión masiva | Volumen `emision_masiva` (privado; los genera el worker y los descarga `web`). |
| Base de datos | Volumen `db_data`. |

También hay volúmenes de `static` (lo regenera `setup`), `valkey_data` (broker y
caché) y `caddy_data`/`caddy_config` (certificados).

- Los volúmenes sobreviven a `docker compose down` y a reconstruir contenedores.
  Solo `docker compose down -v` los borra.
- **`FIELD_ENCRYPTION_KEY` cifra la clave privada de los certificados digitales.**
  Si se pierde, los certificados guardados no se pueden leer: está en los respaldos.
- Si pones en `.env` una `FIELD_ENCRYPTION_KEY` distinta de la ya registrada,
  `setup` falla a propósito. Para reemplazarla (los certificados guardados quedan
  inservibles y hay que volver a cargarlos):

  ```shell
  docker compose run --rm --no-deps -u root --entrypoint sh setup \
    -c "sed -i '/^FIELD_ENCRYPTION_KEY=/d' /var/lib/slim/state/secrets.env"
  # agrega la nueva clave a .env y luego:
  docker compose up -d
  ```

## Comandos útiles

```shell
docker compose ps                                  # estado de los servicios
docker compose logs -f web worker                  # logs
docker compose run --rm console changepassword demo
docker compose run --rm console shell              # consola de Django
docker compose --profile '*' down                  # detener todo (conserva los datos)
```

Con la consola (`console`) los archivos quedan a nombre del usuario `slim`.

## Versiones y actualización

- **Slim**: `SLIM_VERSION` vacío usa el último commit de la rama por defecto del
  repositorio; con un tag (ej. `SLIM_VERSION=v0.1.0b1`) se fija esa versión. El pie
  de la aplicación muestra la versión y el commit con el que corre.
  - Con un tag: cambia `SLIM_VERSION` y ejecuta `docker compose up -d --build`.
  - Sin tag, para traer lo último: `docker compose build --pull --no-cache web` y
    `docker compose up -d` (Docker reutiliza la capa del clon si no se pide
    `--no-cache`).
  - `setup` aplica las migraciones al arrancar.
- **Core API**: LibreDTE Lib Core API no publica versiones numeradas. `latest` es la
  última (`docker compose pull libredte-lib-core-api && docker compose up -d`).
  Para fijarla, usa como `CORE_API_VERSION` el hash completo del commit
  (40 caracteres): sus imágenes se publican con ese tag, y el pie de Slim mostrará
  la versión exacta del backend.
- Reconstruye de vez en cuando (`docker compose build --pull --no-cache`) para
  recibir parches de seguridad de Python y del sistema base.

## Respaldos

El perfil `backup` guarda, cada `BACKUP_INTERVAL_HOURS` horas y durante
`BACKUP_KEEP_DAYS` días, en el volumen `backups`:

- `<fecha>-db.dump`: la base de datos (`pg_dump`).
- `<fecha>-files.tar.gz`: `media` y `state` (los secretos).
- `<fecha>-env`: tu `.env` (contiene `DB_PASSWORD`, SMTP y tokens).

No incluye los ZIP de PDF de la emisión masiva (se regeneran). Los archivos quedan
con modo 0600: protégelos como protegerías las claves.

```shell
docker compose run --rm --no-deps backup now          # un respaldo ahora
docker compose run --rm --no-deps backup list
docker compose run --rm --no-deps backup restore <fecha>
```

`restore` repone la base de datos, `media` y `state`; el `.env` del respaldo queda
junto a él y **no** reemplaza al del host (cópialo a mano si hace falta). Usa
siempre `run --rm --no-deps`: sin `--no-deps` arrancaría `setup`, que falla con
datos dañados. La base de datos debe estar corriendo. Copia además los respaldos
fuera del servidor.

## Overrides

Se activan con `COMPOSE_FILE` en `.env`:

```shell
COMPOSE_FILE=compose.yaml:overrides/local-dirs.yaml:overrides/traefik.yaml
```

- `overrides/local-dirs.yaml`: los datos en `${DATA_DIR:-./data}/<nombre>` en vez de
  volúmenes nombrados. Actívalo antes del primer `up` (los datos de volúmenes ya
  existentes no se mueven).
- `overrides/traefik.yaml`: publica el sitio por un Traefik existente (red externa
  `TRAEFIK_NETWORK`, `TRAEFIK_HOST`), sin puertos del host. Requiere
  `SITE_ADDRESS=:80` y `SITE_URL_SCHEMA=https`.
- Un `compose.override.yaml` propio (ignorado por git) se aplica solo.

## Configuración

Todo se configura con variables en `.env`; `.env.example` y `.env.prod.example`
las documentan una por una. Las principales: `SITE_HOSTNAME`, `SITE_ADDRESS`,
`SITE_URL_SCHEMA`, `DB_PASSWORD`, `SLIM_SEED_DEMO`, `EMAIL_*`, los puertos
(`HTTP_PORT`, `HTTPS_PORT`), las versiones y los límites de memoria.

## Seguridad

- `DEBUG` apagado; Slim se niega a arrancar con las claves por defecto.
- Solo Caddy publica puertos (`HTTP_BIND` por defecto en `127.0.0.1`; la plantilla
  de producción usa `0.0.0.0`). La base de datos, Valkey y la Core API nunca se
  publican.
- Slim acepta únicamente el dominio de `SITE_HOSTNAME` (más `SITE_EXTRA_HOSTS`):
  otras cabeceras `Host` reciben `400`.
- Con HTTPS, cabecera HSTS y cookies seguras. Caddy no revela su versión.
- Slim, los workers y la Core API corren como usuario sin privilegios, con el
  sistema de archivos de solo lectura y `no-new-privileges`.
- Una contraseña de base de datos nueva en `.env` no cambia la existente en
  PostgreSQL: cámbiala también dentro de la base.
- La interfaz de Slim carga Bootstrap, Font Awesome y htmx desde `cdn.jsdelivr.net`:
  el navegador de quien usa Slim necesita acceso a ese dominio.

## Decisiones

- **Imagen de Slim construida aquí**: Slim no publica imagen. Este repositorio la
  construye clonando la app (`image/Dockerfile`, Python 3.14 sobre Debian slim: sus
  dependencias traen binarios `manylinux`), instalando dependencias con `uv`.
- **Caddy** como servidor web y **PostgreSQL** como única base de datos del stack
  (con web y workers concurrentes, SQLite no sirve).
- **Valkey** en vez de Redis (compatible, licencia abierta).
- **La Core API se ejecuta como `www-data`** con `/tmp`, `/data`, `/config` y
  `/app/var` en memoria (tmpfs), porque su imagen corre como root.
- Sin celery beat: Slim no tiene tareas periódicas.

## Validación

Probado en Docker Desktop (macOS, arm64, 8 GB):

- Los cuatro comandos del inicio rápido, de cero, con demo: login, páginas,
  descarga de PDF (generado por la Core API) y emisión masiva con PDF (worker, enlace
  de descarga en el correo, ZIP descargable).
- Plantilla de producción sin demo: pantalla de alta del primer usuario, login del
  usuario creado, directorios locales (`local-dirs.yaml`), HTTPS local con HSTS.
- Segunda corrida de `up` (`setup` repetible, secretos sin cambio), `down` + `up`
  conservando usuarios y secretos, respaldo → daño → restauración (base de datos,
  media y secretos), `FIELD_ENCRYPTION_KEY` distinta falla y el procedimiento de
  reemplazo funciona.
- `docker compose config -q` falla sin `.env` y pasa con cada plantilla y override;
  `shellcheck` limpio; sin puertos inesperados en los contenedores.
- Memoria en reposo: web ≈ 330 MiB, worker ≈ 280 MiB, worker de emisión masiva
  ≈ 210 MiB, Core API ≈ 50 MiB, PostgreSQL ≈ 30 MiB, Caddy ≈ 12 MiB.

## Licencia y términos de uso

Este stack se distribuye bajo la licencia AGPL (ver `COPYING`), igual que LibreDTE.
Al usar LibreDTE aceptas sus
[términos y condiciones de uso](https://slim.libredte.cl/legal).
