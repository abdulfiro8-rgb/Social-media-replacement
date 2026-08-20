#!/usr/bin/env bash
#
# immich-apply-fix.sh - Komplettreparatur in einem Durchgang.
#
# 1. zeigt die aktuelle Stack-Konfiguration (Passwort maskiert)
# 2. sichert die Compose-Dateien mit Zeitstempel
# 3. traegt den fehlenden environment:-Block in compose.override.yml ein
#    (echtes YAML-Merge, vorhandene Eintraege bleiben erhalten)
# 4. setzt das Postgres-Rollenpasswort auf den Wert aus der Env-Datei
# 5. erstellt NUR immich-server und immich-machine-learning neu
# 6. verifiziert Anmeldung, Health und HTTP
#
# Nicht angefasst: Datenbank-Inhalt, Volumes, Verzeichnisse, database- und
# redis-Container, andere Stacks (mtb-bot, twingate-*).
#
# Aufruf:  sudo ./immich-apply-fix.sh [--dry-run] [--yes]
#
set -uo pipefail
DOCKER="${DOCKER:-docker}"
DRYRUN=0; ASSUME_YES=0
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRYRUN=1 ;;
    --yes|-y)  ASSUME_YES=1 ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "Unbekannte Option: $1"; exit 2 ;;
  esac; shift
done

die()  { printf '\033[31mFEHLER:\033[0m %s\n' "$*" >&2; exit 1; }
ok()   { printf '\033[32m[ ok ]\033[0m %s\n' "$*"; }
warn() { printf '\033[33m[warn]\033[0m %s\n' "$*"; }
inf()  { printf '[info] %s\n' "$*"; }
step() { printf '\n\033[1m== %s ==\033[0m\n' "$*"; }
fp()   { [ -z "${1-}" ] && { printf '<leer>'; return; }; printf '%s' "$1" | sha256sum | cut -c1-12; }
sql_lit()   { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/''/g")"; }
sql_ident() { printf '"%s"' "$(printf '%s' "$1" | sed 's/"/""/g')"; }

[ "$(id -u)" = 0 ] || die "Bitte mit sudo starten (die Stack-Dateien sind 0600 root)."
command -v "$DOCKER" >/dev/null 2>&1 || die "docker nicht gefunden"
command -v python3   >/dev/null 2>&1 || die "python3 nicht gefunden"
python3 -c 'import yaml' 2>/dev/null || die "python3-yaml fehlt: sudo apt install -y python3-yaml"

step "1. Stack-Dateien ermitteln"
WORKDIR=$($DOCKER inspect immich_server --format '{{index .Config.Labels "com.docker.compose.project.working_dir"}}' 2>/dev/null)
CFGRAW=$($DOCKER inspect immich_server --format '{{index .Config.Labels "com.docker.compose.project.config_files"}}' 2>/dev/null)
PROJECT=$($DOCKER inspect immich_server --format '{{index .Config.Labels "com.docker.compose.project"}}' 2>/dev/null)
PROJECT="${PROJECT:-immich}"
[ -n "$WORKDIR" ] && [ -d "$WORKDIR" ] || die "Stack-Verzeichnis nicht ermittelbar."
[ -n "$CFGRAW" ] || die "Compose-Dateien nicht ermittelbar."
inf "Projekt     : $PROJECT"
inf "Verzeichnis : $WORKDIR"

COMPOSE_ARGS=(); BASEFILE=""; OVERRIDE=""
OLDIFS=$IFS; IFS=','
for f in $CFGRAW; do
  IFS=$OLDIFS
  [ -f "$f" ] || die "Compose-Datei laut Label nicht vorhanden: $f"
  COMPOSE_ARGS+=(-f "$f")
  case "$(basename "$f")" in
    *override*) OVERRIDE="$f" ;;
    *)          [ -z "$BASEFILE" ] && BASEFILE="$f" ;;
  esac
  IFS=','
done
IFS=$OLDIFS
[ -n "$BASEFILE" ] || die "Basis-Compose-Datei nicht erkannt."
if [ -z "$OVERRIDE" ]; then
  OVERRIDE="$WORKDIR/compose.override.yml"
  COMPOSE_ARGS+=(-f "$OVERRIDE")
  inf "Keine Override-Datei vorhanden - sie wird angelegt: $OVERRIDE"
fi
inf "Basis-Datei : $BASEFILE"
inf "Override    : $OVERRIDE"

ENVFILE=""
for cand in "$WORKDIR/.env" "$WORKDIR"/*.env; do [ -f "$cand" ] && { ENVFILE="$cand"; break; }; done
[ -n "$ENVFILE" ] || die "Env-Datei nicht gefunden."
inf "Env-Datei   : $ENVFILE"

step "2. Aktuelle Konfiguration (Passwort maskiert)"
echo "----- $(basename "$BASEFILE") -----"
# Maskiert nur echte Werte. Variablen-Referenzen wie ${DB_PASSWORD} bleiben
# lesbar - sie sind kein Geheimnis und ihr Anblick ist diagnostisch wichtig.
sed -E '/(PASSWORD|SECRET|TOKEN|KEY)[A-Za-z_]*[=:][[:space:]]*\$/!s/((PASSWORD|SECRET|TOKEN|KEY)[A-Za-z_]*[=:][[:space:]]*)[^[:space:]].*/\1<MASKIERT>/I' "$BASEFILE"
echo "----- $(basename "$OVERRIDE") -----"
[ -f "$OVERRIDE" ] && cat "$OVERRIDE" || echo "(existiert noch nicht)"
echo "----- $(basename "$ENVFILE") (maskiert) -----"
sed -E '/^[[:space:]]*[A-Z_]*(PASSWORD|SECRET|TOKEN|KEY)[A-Z_]*=[[:space:]]*\$/!s/^([[:space:]]*[A-Z_]*(PASSWORD|SECRET|TOKEN|KEY)[A-Z_]*=).*/\1<MASKIERT>/' "$ENVFILE"

getenv() {
  local v; v=$(sed -n "s/^[[:space:]]*$1=//p" "$ENVFILE" | head -n1 | tr -d '\r')
  v="${v%\"}"; v="${v#\"}"; v="${v%\'}"; v="${v#\'}"; printf '%s' "$v"
}
ENV_PW=$(getenv DB_PASSWORD)
ENV_USER=$(getenv DB_USERNAME); ENV_USER="${ENV_USER:-postgres}"
ENV_DB=$(getenv DB_DATABASE_NAME); ENV_DB="${ENV_DB:-immich}"
[ -n "$ENV_PW" ] || die "DB_PASSWORD fehlt in $ENVFILE"
inf "DB_PASSWORD fingerprint: $(fp "$ENV_PW")"
case "$ENV_PW" in *[!A-Za-z0-9]*) warn "Passwort enthaelt Zeichen ausserhalb A-Za-z0-9 - Immich empfiehlt rein alphanumerisch." ;; esac

if [ "$ASSUME_YES" = 0 ] && [ "$DRYRUN" = 0 ]; then
  echo; printf 'Reparatur jetzt durchfuehren? [j/N] '
  read -r a; case "$a" in j|J|y|Y) ;; *) die "Abgebrochen." ;; esac
fi

step "3. Sicherungskopien"
TS=$(date +%Y%m%d-%H%M%S)
for f in "$BASEFILE" "$OVERRIDE"; do
  [ -f "$f" ] || continue
  if [ "$DRYRUN" = 1 ]; then echo "  (dry-run) cp $f $f.bak-$TS"
  else cp -a "$f" "$f.bak-$TS" && ok "gesichert: $(basename "$f").bak-$TS"; fi
done

step "4. environment:-Block in die Override-Datei eintragen"
if [ "$DRYRUN" = 1 ]; then
  echo "  (dry-run) YAML-Merge in $OVERRIDE"
else
  python3 - "$OVERRIDE" <<'PY'
import sys, yaml, os
path = sys.argv[1]
data = {}
if os.path.exists(path) and os.path.getsize(path) > 0:
    with open(path) as f:
        data = yaml.safe_load(f) or {}
if not isinstance(data, dict):
    sys.exit("Override-Datei ist kein YAML-Mapping - Abbruch, nichts geaendert.")
services = data.get('services') or {}
if not isinstance(services, dict):
    sys.exit("'services' in der Override-Datei ist kein Mapping - Abbruch.")

def merge_env(name, want):
    svc = services.get(name) or {}
    if not isinstance(svc, dict):
        sys.exit(f"Service '{name}' in der Override-Datei ist kein Mapping - Abbruch.")
    env = svc.get('environment')
    if isinstance(env, list):                     # Listenform KEY=VAL -> Mapping
        conv = {}
        for item in env:
            k, _, v = str(item).partition('=')
            conv[k.strip()] = v
        env = conv
    elif not isinstance(env, dict):
        env = {}
    env.update(want)
    svc['environment'] = env
    services[name] = svc

merge_env('immich-server', {
    'DB_HOSTNAME':      'database',
    'DB_PORT':          '5432',
    'DB_USERNAME':      '${DB_USERNAME}',
    'DB_PASSWORD':      '${DB_PASSWORD}',
    'DB_DATABASE_NAME': '${DB_DATABASE_NAME}',
    'REDIS_HOSTNAME':   'redis',
    'TZ':               '${TZ}',
})
merge_env('immich-machine-learning', {'TZ': '${TZ}'})

data['services'] = services
with open(path, 'w') as f:
    f.write("# Von scripts/immich-apply-fix.sh ergaenzt.\n"
            "# Grund: die Basis-Compose-Datei uebergibt immich-server keine DB-Variablen\n"
            "# (weder env_file noch environment), Immich faellt dann auf DB_PASSWORD=postgres\n"
            "# zurueck -> SQLSTATE 28P01.\n")
    yaml.safe_dump(data, f, default_flow_style=False, sort_keys=False, allow_unicode=True)
print("Override-Datei zusammengefuehrt.")
PY
  [ $? -eq 0 ] || die "YAML-Merge fehlgeschlagen - die Sicherung liegt als .bak-$TS daneben."
  ok "Override-Datei aktualisiert:"
  sed 's/^/    /' "$OVERRIDE"
fi

step "5. Compose-Konfiguration validieren"
if [ "$DRYRUN" = 0 ]; then
  if out=$($DOCKER compose -p "$PROJECT" --project-directory "$WORKDIR" "${COMPOSE_ARGS[@]}" --env-file "$ENVFILE" config 2>&1); then
    if printf '%s' "$out" | grep -q 'DB_PASSWORD'; then
      ok "Compose loest DB_PASSWORD fuer immich-server jetzt auf."
    else
      warn "DB_PASSWORD taucht in der zusammengefuehrten Konfiguration nicht auf."
    fi
  else
    printf '%s\n' "$out" | tail -20 | sed 's/^/    /'
    die "docker compose config schlaegt fehl - Override zurueckspielen mit: cp $OVERRIDE.bak-$TS $OVERRIDE"
  fi
fi

step "6. Postgres-Rollenpasswort auf den Env-Wert setzen"
if [ "$DRYRUN" = 1 ]; then
  echo "  (dry-run) ALTER USER $(sql_ident "$ENV_USER") WITH PASSWORD '<verborgen>';"
else
  out=$(printf 'ALTER USER %s WITH PASSWORD %s;\n' "$(sql_ident "$ENV_USER")" "$(sql_lit "$ENV_PW")" \
        | $DOCKER exec -i -u postgres immich_postgres psql -v ON_ERROR_STOP=1 -q -d postgres -f - 2>&1) \
    && ok "ALTER ROLE ausgefuehrt (nur Rollen-Metadaten, keine Daten beruehrt)." \
    || { printf '%s\n' "$out" | sed 's/^/    /'; die "ALTER USER fehlgeschlagen."; }
fi

step "7. Anmeldung ueber das Docker-Netz pruefen (nicht ueber 127.0.0.1)"
if [ "$DRYRUN" = 0 ]; then
  out=$(printf '%s\n' "$ENV_PW" | $DOCKER exec -i immich_postgres sh -c '
      read -r PGPASSWORD; export PGPASSWORD
      IP=$(hostname -i 2>/dev/null | cut -d" " -f1); [ -n "$IP" ] || IP=database
      psql -h "$IP" -U "$1" -d "$2" -tAc "select 1" 2>&1' sh "$ENV_USER" "$ENV_DB")
  if [ "$(printf '%s' "$out" | tr -d '[:space:]')" = "1" ]; then
    ok "scram-Anmeldung mit dem Env-Passwort funktioniert."
  else
    printf '%s\n' "$out" | sed 's/^/    /'
    die "Anmeldung schlaegt weiterhin fehl."
  fi
fi

step "8. immich-server und immich-machine-learning neu erstellen"
inf "database und redis werden NICHT angefasst."
CMD=("$DOCKER" compose -p "$PROJECT" --project-directory "$WORKDIR" "${COMPOSE_ARGS[@]}" --env-file "$ENVFILE"
     up -d --force-recreate --no-deps immich-server immich-machine-learning)
inf "Kommando: ${CMD[*]}"
if [ "$DRYRUN" = 1 ]; then echo "  (dry-run) nicht ausgefuehrt"
else "${CMD[@]}" || die "Neuerstellung fehlgeschlagen."; fi

step "9. Verifikation"
if [ "$DRYRUN" = 0 ]; then
  SRV_PW=$($DOCKER inspect immich_server --format '{{range .Config.Env}}{{println .}}{{end}}' | sed -n 's/^DB_PASSWORD=//p' | head -n1)
  if [ "$(fp "$SRV_PW")" = "$(fp "$ENV_PW")" ]; then
    ok "immich_server hat jetzt das richtige DB_PASSWORD (fingerprint $(fp "$SRV_PW"))."
  else
    warn "immich_server hat immer noch nicht den erwarteten Wert."
  fi
  printf '  Warte auf healthy '
  for i in $(seq 1 72); do
    st=$($DOCKER inspect immich_server --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' 2>/dev/null)
    printf '\r  Warte auf healthy: %-12s (%ds)  ' "$st" $((i*5))
    [ "$st" = "healthy" ] && break
    sleep 5
  done
  echo
  $DOCKER ps --filter 'name=immich_' --format 'table {{.Names}}\t{{.Status}}' | sed 's/^/  /'
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 http://127.0.0.1:2283/api/server/ping 2>/dev/null)
  if [ "$code" = "200" ]; then
    ok "HTTP-API antwortet (200). Weboberflaeche: http://192.168.0.125:2283"
  else
    warn "HTTP-Ping lieferte '$code'. Letzte Logzeilen:"
    $DOCKER logs --tail 25 immich_server 2>&1 | sed 's/^/    /'
  fi
  if [ "$($DOCKER inspect immich_machine_learning --format '{{.State.Health.Status}}' 2>/dev/null)" != "healthy" ]; then
    warn "immich_machine_learning noch nicht healthy - letzte Logzeilen:"
    $DOCKER logs --tail 15 immich_machine_learning 2>&1 | sed 's/^/    /'
    inf "Das ML-Modell wird beim ersten Start heruntergeladen; auf dem Pi dauert das."
    inf "Immich funktioniert auch ohne ML - nur Gesichtserkennung/Suche fehlen bis dahin."
  fi
fi

cat <<EOF

== Damit es dauerhaft bleibt ==
OMV verwaltet die Compose-Dateien und kann sie beim naechsten Speichern
neu schreiben. Deshalb denselben Block einmal im Webinterface eintragen:
  Services > Compose > Files > immich > Bearbeiten
Im Service immich-server, auf der Ebene von volumes:/ports::

    environment:
      DB_HOSTNAME: database
      DB_PORT: 5432
      DB_USERNAME: \${DB_USERNAME}
      DB_PASSWORD: \${DB_PASSWORD}
      DB_DATABASE_NAME: \${DB_DATABASE_NAME}
      REDIS_HOSTNAME: redis
      TZ: \${TZ}

Sicherungen dieses Laufs: *.bak-$TS im Stack-Verzeichnis.
EOF
