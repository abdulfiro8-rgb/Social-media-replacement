#!/usr/bin/env bash
#
# immich-fix-db-password.sh
#
# Synchronisiert das Postgres-Rollen-Passwort mit dem Wert aus der Env-Datei
# des OMV-Compose-Stacks und erstellt danach NUR den immich-server neu, damit
# er die Variablen tatsaechlich uebernimmt.
#
# Was dieses Skript NIEMALS tut:
#   - keine Datenbank loeschen
#   - kein "docker compose down -v", kein "docker volume rm"
#   - kein rm -rf auf Datenverzeichnisse
#   - keine rekursiven chown/chmod
#   - keine Aenderung an anderen Containern (mtb-bot, twingate-*)
#
# Passwoerter werden nie als Kommandozeilenargument uebergeben (waeren in `ps`
# sichtbar) und nie ausgegeben - nur gekuerzte SHA-256-Fingerprints.
#
# Aufruf:
#   sudo ./immich-fix-db-password.sh --dry-run      # nur zeigen, was passieren wuerde
#   sudo ./immich-fix-db-password.sh                # ausfuehren (fragt nach)
#   sudo ./immich-fix-db-password.sh --yes          # ohne Rueckfrage
#   sudo ./immich-fix-db-password.sh --env-file /pfad/zur/.env
#
set -uo pipefail

DOCKER="${DOCKER:-docker}"
DRYRUN=0
ASSUME_YES=0
ENVFILE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run)  DRYRUN=1 ;;
    --yes|-y)   ASSUME_YES=1 ;;
    --env-file) ENVFILE="${2:?--env-file braucht einen Pfad}"; shift ;;
    -h|--help)  sed -n '2,30p' "$0"; exit 0 ;;
    *) echo "Unbekannte Option: $1"; exit 2 ;;
  esac
  shift
done

die()  { printf '\033[31mFEHLER:\033[0m %s\n' "$*" >&2; exit 1; }
ok()   { printf '\033[32m[ ok ]\033[0m %s\n' "$*"; }
warn() { printf '\033[33m[warn]\033[0m %s\n' "$*"; }
inf()  { printf '[info] %s\n' "$*"; }
step() { printf '\n\033[1m== %s ==\033[0m\n' "$*"; }
fp()   { [ -z "${1-}" ] && { printf '<leer>'; return; }; printf '%s' "$1" | sha256sum | cut -c1-12; }
run()  { if [ "$DRYRUN" = 1 ]; then printf '  (dry-run) %s\n' "$*"; else "$@"; fi; }

sql_lit()   { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/''/g")"; }
sql_ident() { printf '"%s"' "$(printf '%s' "$1" | sed 's/"/""/g')"; }

command -v "$DOCKER" >/dev/null 2>&1 || die "docker nicht gefunden"
$DOCKER inspect immich_postgres >/dev/null 2>&1 || die "Container immich_postgres existiert nicht"

step "1. Stack-Dateien ermitteln"
WORKDIR=$($DOCKER inspect immich_server --format '{{index .Config.Labels "com.docker.compose.project.working_dir"}}' 2>/dev/null)
CFGFILE=$($DOCKER inspect immich_server --format '{{index .Config.Labels "com.docker.compose.project.config_files"}}' 2>/dev/null | cut -d, -f1)
PROJECT=$($DOCKER inspect immich_server --format '{{index .Config.Labels "com.docker.compose.project"}}' 2>/dev/null)
PROJECT="${PROJECT:-immich}"
inf "Projekt      : $PROJECT"
inf "working_dir  : ${WORKDIR:-<unbekannt>}"
inf "compose-Datei: ${CFGFILE:-<unbekannt>}"

if [ -z "$ENVFILE" ] && [ -n "${WORKDIR:-}" ] && [ -d "$WORKDIR" ]; then
  for cand in "$WORKDIR/.env" "$WORKDIR"/*.env; do
    [ -f "$cand" ] && { ENVFILE="$cand"; break; }
  done
fi
[ -n "$ENVFILE" ] || die "Keine Env-Datei gefunden. Bitte mit --env-file /pfad/zur/.env angeben.
Tipp: im OMV-Webinterface unter Services > Compose > Files steht der Pfad des Stacks."
[ -r "$ENVFILE" ] || die "Env-Datei nicht lesbar: $ENVFILE (mit sudo starten)"
ok "Env-Datei: $ENVFILE"

step "2. Sollwerte aus der Env-Datei lesen"
getenv() {
  local v
  v=$(sed -n "s/^[[:space:]]*$1=//p" "$ENVFILE" | head -n1 | tr -d '\r')
  v="${v%\"}"; v="${v#\"}"; v="${v%\'}"; v="${v#\'}"
  printf '%s' "$v"
}
ENV_PW=$(getenv DB_PASSWORD)
ENV_USER=$(getenv DB_USERNAME); ENV_USER="${ENV_USER:-postgres}"
ENV_DB=$(getenv DB_DATABASE_NAME); ENV_DB="${ENV_DB:-immich}"
[ -n "$ENV_PW" ] || die "DB_PASSWORD steht nicht in $ENVFILE"
inf "DB_USERNAME      = $ENV_USER"
inf "DB_DATABASE_NAME = $ENV_DB"
inf "DB_PASSWORD      = <verborgen>, fingerprint $(fp "$ENV_PW")"

case "$ENV_PW" in
  *[!A-Za-z0-9]*)
    warn "Das Passwort enthaelt Zeichen ausserhalb von A-Za-z0-9."
    warn "Immich empfiehlt ausdruecklich nur A-Za-z0-9; '\$', ' ' und ' #'"
    warn "brechen .env-/Compose-Verarbeitung reproduzierbar."
    warn "Wenn es nach diesem Skript weiter klemmt: Passwort auf rein"
    warn "alphanumerisch aendern (in der OMV-Env UND danach dieses Skript erneut)."
    ;;
esac

step "3. Postgres-Rollenpasswort auf den Sollwert setzen (ohne Datenverlust)"
inf "SQL: ALTER USER $(sql_ident "$ENV_USER") WITH PASSWORD '<verborgen>';"
inf "ALTER USER aendert nur die Rolle - Datenbanken, Tabellen und Dateien bleiben unangetastet."
if [ "$ASSUME_YES" = 0 ] && [ "$DRYRUN" = 0 ]; then
  printf 'Fortfahren? [j/N] '
  read -r a; case "$a" in j|J|y|Y) ;; *) die "Abgebrochen." ;; esac
fi
if [ "$DRYRUN" = 1 ]; then
  echo "  (dry-run) ALTER USER wuerde jetzt ausgefuehrt"
else
  out=$(printf 'ALTER USER %s WITH PASSWORD %s;\n' "$(sql_ident "$ENV_USER")" "$(sql_lit "$ENV_PW")" \
        | $DOCKER exec -i -u postgres immich_postgres psql -v ON_ERROR_STOP=1 -q -d postgres -f - 2>&1)
  rc=$?
  if [ $rc -ne 0 ]; then
    printf '%s\n' "$out" | sed 's/^/    /'
    die "ALTER USER fehlgeschlagen."
  fi
  ok "Rollenpasswort gesetzt (ALTER ROLE)."
fi

step "4. Passwort gegen die Datenbank testen"
if [ "$DRYRUN" = 0 ]; then
  # Test ueber die Container-IP, nicht ueber 127.0.0.1: fuer Loopback steht in
  # der pg_hba.conf des Images ein "trust"-Eintrag, der das Passwort ignoriert.
  out=$(printf '%s\n' "$ENV_PW" | $DOCKER exec -i immich_postgres sh -c '
      read -r PGPASSWORD; export PGPASSWORD
      IP=$(hostname -i 2>/dev/null | cut -d" " -f1); [ -n "$IP" ] || IP=database
      psql -h "$IP" -U "$1" -d "$2" -tAc "select 1" 2>&1' sh "$ENV_USER" "$ENV_DB")
  if [ "$(printf '%s' "$out" | tr -d '[:space:]')" = "1" ]; then
    ok "Anmeldung an der Datenbank funktioniert."
  else
    printf '%s\n' "$out" | sed 's/^/    /'
    die "Anmeldung schlaegt weiterhin fehl."
  fi
fi

step "5. Bekommt der immich_server diese Werte ueberhaupt?"
SRV_PW=$($DOCKER inspect immich_server --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null | sed -n 's/^DB_PASSWORD=//p' | head -n1)
NEED_COMPOSE_FIX=0
if [ -z "$SRV_PW" ]; then
  NEED_COMPOSE_FIX=1
  warn "immich_server hat KEIN DB_PASSWORD in seiner Umgebung."
  warn "Immich faellt dann auf den eingebauten Default 'postgres' zurueck."
elif [ "$(fp "$SRV_PW")" != "$(fp "$ENV_PW")" ]; then
  NEED_COMPOSE_FIX=0
  inf "immich_server hat ein DB_PASSWORD, aber es weicht ab"
  inf "  Container : $(fp "$SRV_PW")"
  inf "  Env-Datei : $(fp "$ENV_PW")"
  inf "=> Neuerstellung des Containers uebernimmt den neuen Wert."
else
  ok "immich_server hat bereits den passenden Wert."
fi

if [ "$NEED_COMPOSE_FIX" = 1 ]; then
  cat <<'PATCH'

  ---------------------------------------------------------------------------
  Die Compose-Datei muss vorher ergaenzt werden. Im Service "immich-server"
  fehlen sowohl "env_file:" als auch "environment:". Bitte im OMV-Webinterface
  (Services > Compose > Files > immich > Bearbeiten) unterhalb der "volumes:"
  Liste des Service immich-server einfuegen:

    environment:
      DB_HOSTNAME: database
      DB_PORT: 5432
      DB_USERNAME: ${DB_USERNAME}
      DB_PASSWORD: ${DB_PASSWORD}
      DB_DATABASE_NAME: ${DB_DATABASE_NAME}
      REDIS_HOSTNAME: redis
      TZ: ${TZ}

  Achtung auf die Einrueckung: "environment:" liegt auf derselben Ebene wie
  "volumes:" und "ports:" (6 Leerzeichen Einrueckung fuer die Schluessel).
  Die fertige Datei liegt im Repo unter compose/immich/docker-compose.yml.

  Danach dieses Skript erneut ausfuehren.
  ---------------------------------------------------------------------------
PATCH
  exit 3
fi

step "6. immich-server neu erstellen (KEIN down, KEIN -v)"
if [ -z "${CFGFILE:-}" ] || [ ! -f "$CFGFILE" ]; then
  warn "Compose-Datei nicht auffindbar - bitte im OMV-Webinterface den Stack"
  warn "'immich' einmal 'Down' und 'Up' schalten (NIEMALS 'Down' mit Volumes-Loeschen)."
else
  set -- "$DOCKER" compose -p "$PROJECT" --project-directory "${WORKDIR:-$(dirname "$CFGFILE")}" \
        -f "$CFGFILE" --env-file "$ENVFILE" up -d --force-recreate immich-server
  inf "Kommando: $*"
  run "$@" || die "Neuerstellung fehlgeschlagen."
  ok "immich-server neu erstellt."
fi

step "7. Warten auf Health"
if [ "$DRYRUN" = 0 ]; then
  for i in $(seq 1 60); do
    st=$($DOCKER inspect immich_server --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' 2>/dev/null)
    printf '\r  Status: %-12s (%ds)' "$st" $((i*5))
    [ "$st" = "healthy" ] && break
    sleep 5
  done
  echo
  if [ "${st:-}" = "healthy" ]; then
    ok "immich_server ist healthy."
    ok "Weboberflaeche: http://192.168.0.125:2283"
  else
    warn "Noch nicht healthy. Letzte Logzeilen:"
    $DOCKER logs --tail 30 immich_server 2>&1 | sed 's/^/    /'
  fi
fi
