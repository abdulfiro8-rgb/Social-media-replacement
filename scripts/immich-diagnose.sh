#!/usr/bin/env bash
#
# immich-diagnose.sh - Nur-Lesen-Diagnose fuer den Immich-Stack auf OMV.
#
# Aendert NICHTS: keine Container, keine Volumes, keine Rechte, keine DB.
# Gibt niemals Passwoerter im Klartext aus - nur gekuerzte SHA-256-Fingerprints,
# damit man Werte vergleichen kann, ohne sie zu offenbaren.
#
# Aufruf:  sudo ./immich-diagnose.sh
#
set -uo pipefail

DOCKER="${DOCKER:-docker}"

c_ok()   { printf '  \033[32m[ ok ]\033[0m %s\n' "$*"; }
c_bad()  { printf '  \033[31m[FEHL]\033[0m %s\n' "$*"; }
c_warn() { printf '  \033[33m[warn]\033[0m %s\n' "$*"; }
c_inf()  { printf '  [info] %s\n' "$*"; }
head1()  { printf '\n\033[1m== %s ==\033[0m\n' "$*"; }

# Kurzer Fingerprint eines Geheimnisses (12 Hex-Zeichen), leerer String -> "<leer>"
fp() {
  local v="${1-}"
  if [ -z "$v" ]; then printf '<leer>'; return; fi
  printf '%s' "$v" | sha256sum | cut -c1-12
}

# Wert einer Variablen aus der Container-Umgebung lesen (ohne ihn auszugeben)
container_env() { # $1=container $2=key
  $DOCKER inspect "$1" --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null \
    | sed -n "s/^$2=//p" | head -n1
}

command -v "$DOCKER" >/dev/null 2>&1 || { echo "docker nicht gefunden"; exit 1; }

head1 "1. Container-Status"
$DOCKER ps -a --filter 'name=immich_' \
  --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}' || true

for c in immich_server immich_postgres immich_redis immich_machine_learning; do
  if $DOCKER inspect "$c" >/dev/null 2>&1; then
    hs=$($DOCKER inspect "$c" --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}<kein healthcheck>{{end}}')
    rs=$($DOCKER inspect "$c" --format '{{.RestartCount}}')
    printf '  %-26s health=%-14s restarts=%s\n' "$c" "$hs" "$rs"
  else
    c_warn "$c existiert nicht"
  fi
done

head1 "2. Compose-Projekt (woher kommen Compose-Datei und Env-Datei?)"
WORKDIR=$($DOCKER inspect immich_server --format '{{index .Config.Labels "com.docker.compose.project.working_dir"}}' 2>/dev/null)
CFGFILE=$($DOCKER inspect immich_server --format '{{index .Config.Labels "com.docker.compose.project.config_files"}}' 2>/dev/null)
c_inf "working_dir : ${WORKDIR:-<unbekannt>}"
c_inf "config_files: ${CFGFILE:-<unbekannt>}"
ENVFILE=""
if [ -n "${WORKDIR:-}" ] && [ -d "$WORKDIR" ]; then
  echo "  Inhalt des Stack-Verzeichnisses:"
  ls -la "$WORKDIR" | sed 's/^/    /'
  for cand in "$WORKDIR/.env" "$WORKDIR"/*.env; do
    [ -f "$cand" ] && { ENVFILE="$cand"; break; }
  done
  if [ -n "$ENVFILE" ]; then
    c_ok "Env-Datei gefunden: $ENVFILE"
  else
    c_warn "Keine .env / *.env im Stack-Verzeichnis gefunden."
  fi
fi

head1 "3. Kernfrage: welche DB-Variablen stecken WIRKLICH im immich_server?"
if $DOCKER inspect immich_server >/dev/null 2>&1; then
  echo "  Gesetzte DB_/REDIS_-Schluessel im Container (nur Namen):"
  $DOCKER inspect immich_server --format '{{range .Config.Env}}{{println .}}{{end}}' \
    | sed -n 's/^\(DB_[A-Z_]*\|REDIS_[A-Z_]*\|TZ\)=.*/    \1/p' | sort -u | grep . || echo "    (keine - genau das ist das Problem)"
  SRV_PW=$(container_env immich_server DB_PASSWORD)
  SRV_USER=$(container_env immich_server DB_USERNAME)
  SRV_DB=$(container_env immich_server DB_DATABASE_NAME)
  SRV_HOST=$(container_env immich_server DB_HOSTNAME)
  if [ -z "$SRV_PW" ]; then
    c_bad "DB_PASSWORD ist im immich_server NICHT gesetzt."
    c_bad "=> Immich benutzt seinen eingebauten Default 'postgres'."
    c_bad "=> Genau das erzeugt 'password authentication failed for user \"postgres\"'."
    c_inf "Ursache: in der Compose-Datei fehlen fuer immich-server sowohl"
    c_inf "         'env_file: - .env' als auch ein 'environment:'-Block."
    SRV_EFFECTIVE="postgres (Default, weil nicht gesetzt)"
    SRV_PW_FP=$(fp "postgres")
  else
    c_ok "DB_PASSWORD ist gesetzt (fingerprint $(fp "$SRV_PW"))"
    SRV_EFFECTIVE="aus Container-Environment"
    SRV_PW_FP=$(fp "$SRV_PW")
  fi
  c_inf "DB_USERNAME=${SRV_USER:-<nicht gesetzt -> Default postgres>}"
  c_inf "DB_DATABASE_NAME=${SRV_DB:-<nicht gesetzt -> Default immich>}"
  c_inf "DB_HOSTNAME=${SRV_HOST:-<nicht gesetzt -> Default database>}"
  c_inf "effektives Passwort: $SRV_EFFECTIVE"
else
  c_bad "Container immich_server existiert nicht."
  SRV_PW_FP="<n/a>"
fi

head1 "4. Was hat der Postgres-Container beim Anlegen bekommen?"
if $DOCKER inspect immich_postgres >/dev/null 2>&1; then
  PG_PW=$(container_env immich_postgres POSTGRES_PASSWORD)
  c_inf "POSTGRES_PASSWORD fingerprint: $(fp "$PG_PW")"
  c_warn "Achtung: POSTGRES_PASSWORD wirkt NUR beim allerersten initdb."
  c_warn "Spaetere Aenderungen an der .env aendern das Passwort in der DB nicht."
fi

head1 "5. Env-Datei des Stacks"
if [ -n "$ENVFILE" ] && [ -r "$ENVFILE" ]; then
  ENV_PW=$(sed -n 's/^[[:space:]]*DB_PASSWORD=//p' "$ENVFILE" | head -n1 | tr -d '\r')
  ENV_PW="${ENV_PW%\"}"; ENV_PW="${ENV_PW#\"}"
  ENV_PW="${ENV_PW%\'}"; ENV_PW="${ENV_PW#\'}"
  c_inf "DB_PASSWORD (Env-Datei) fingerprint: $(fp "$ENV_PW")"
  case "$ENV_PW" in
    *' '*)  c_warn "Passwort enthaelt ein Leerzeichen - das bricht .env/Compose leicht." ;;
  esac
  case "$ENV_PW" in
    *'#'*)  c_warn "Passwort enthaelt '#'. In .env-Dateien kann ' #' als Kommentar abgeschnitten werden." ;;
  esac
  case "$ENV_PW" in
    *'$'*)  c_warn "Passwort enthaelt '\$'. Das bricht die Compose-Variablensubstitution." ;;
  esac
  if printf '%s' "$ENV_PW" | grep -qv '^[A-Za-z0-9]*$'; then
    c_warn "Immich empfiehlt ausdruecklich nur A-Za-z0-9 im DB_PASSWORD."
  fi
  echo
  echo "  Vergleich der Fingerprints:"
  printf '    immich_server (effektiv): %s\n' "$SRV_PW_FP"
  printf '    Env-Datei               : %s\n' "$(fp "$ENV_PW")"
  if [ "$SRV_PW_FP" = "$(fp "$ENV_PW")" ]; then
    c_ok "Server-Environment und Env-Datei stimmen ueberein."
  else
    c_bad "Server-Environment und Env-Datei stimmen NICHT ueberein."
    c_inf "Ein 'docker restart' laedt die Env-Datei nicht neu - der Container"
    c_inf "muss neu ERSTELLT werden (docker compose up -d --force-recreate)."
  fi
else
  c_warn "Env-Datei nicht lesbar/gefunden - Schritt uebersprungen."
fi

head1 "6. Live-Test: akzeptiert Postgres das Passwort, das immich_server benutzt?"
if $DOCKER inspect immich_postgres >/dev/null 2>&1; then
  TESTPW="${SRV_PW:-postgres}"
  TESTUSER="${SRV_USER:-postgres}"
  TESTDB="${SRV_DB:-immich}"
  # WICHTIG: NICHT ueber 127.0.0.1 testen. Die pg_hba.conf des Postgres-Images
  # hat fuer 127.0.0.1/32 einen "trust"-Eintrag, der vor der scram-Regel greift
  # - ein Test ueber Loopback ignoriert das Passwort und meldet faelschlich Erfolg.
  # Deshalb ueber die Container-IP im Docker-Netz, genau wie immich_server.
  out=$(printf '%s\n' "$TESTPW" | $DOCKER exec -i immich_postgres sh -c '
      read -r PGPASSWORD; export PGPASSWORD
      IP=$(hostname -i 2>/dev/null | cut -d" " -f1); [ -n "$IP" ] || IP=database
      psql -h "$IP" -U "$1" -d "$2" -tAc "select 1" 2>&1' sh "$TESTUSER" "$TESTDB")
  if [ "$(printf '%s' "$out" | tr -d '[:space:]')" = "1" ]; then
    c_ok "Postgres akzeptiert das Passwort von immich_server."
    c_inf "=> Das DB-Passwort ist NICHT (mehr) die Ursache."
  else
    c_bad "Postgres lehnt das Passwort von immich_server ab:"
    printf '%s\n' "$out" | sed 's/^/      /'
  fi
fi

head1 "7. Datenverzeichnisse"
UP=$($DOCKER inspect immich_server --format '{{range .Mounts}}{{if eq .Destination "/data"}}{{.Source}}{{end}}{{end}}' 2>/dev/null)
DBD=$($DOCKER inspect immich_postgres --format '{{range .Mounts}}{{if eq .Destination "/var/lib/postgresql/data"}}{{.Source}}{{end}}{{end}}' 2>/dev/null)
c_inf "UPLOAD_LOCATION  -> ${UP:-<unbekannt>}"
c_inf "DB_DATA_LOCATION -> ${DBD:-<unbekannt>}"
if [ -n "$UP" ] && [ -n "$DBD" ] && [ "${DBD#"$UP"/}" != "$DBD" ]; then
  c_warn "Das Postgres-Datenverzeichnis liegt INNERHALB von UPLOAD_LOCATION."
  c_warn "Immich verwaltet /data selbst - DB-Dateien haben dort nichts zu suchen."
  c_warn "Empfehlung (jetzt, solange die Bibliothek noch leer ist):"
  c_warn "  scripts/immich-move-db-dir.sh - verschiebt (mv) ohne Datenverlust."
fi
[ -n "$DBD" ] && [ -d "$DBD" ] && {
  echo "  Eigentuemer/Rechte des DB-Verzeichnisses:"
  stat -c '    %A %U:%G (uid=%u gid=%g)  %n' "$DBD"
  [ -f "$DBD/PG_VERSION" ] && c_ok "PG_VERSION vorhanden: $(cat "$DBD/PG_VERSION") (Datenbank existiert, nicht loeschen!)"
}

head1 "8. Port 2283"
if command -v ss >/dev/null 2>&1; then
  if ss -lntp 2>/dev/null | grep -q ':2283'; then
    ss -lntp 2>/dev/null | grep ':2283' | sed 's/^/  /'
  else
    c_warn "Nichts lauscht auf 2283 (passt zu einem Server, der wegen DB-Fehler nicht hochkommt)."
  fi
else
  c_inf "ss nicht verfuegbar - Portpruefung uebersprungen."
fi

head1 "9. Letzte relevante Logzeilen von immich_server"
$DOCKER logs --tail 40 immich_server 2>&1 \
  | grep -Ei 'error|fatal|password|28P01|ECONN|listen|Immich Server is listening|Bootstrap' \
  | tail -n 20 | sed 's/^/  /' || c_inf "keine passenden Zeilen"

head1 "Fertig"
echo "  Diese Diagnose hat nichts veraendert."
echo "  Reparatur: scripts/immich-fix-db-password.sh"
