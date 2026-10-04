#!/usr/bin/env bash
#
# immich-healthcheck.sh - Nur-Lesen-Gesamtpruefung des Immich-Setups.
# Aendert nichts, gibt keine Passwoerter aus.
#
# Aufruf:  sudo ./scripts/immich-healthcheck.sh
#
set -uo pipefail
NAS="${NAS:-/srv/dev-disk-by-uuid-b3ea1171-e620-4617-90b2-c30ead200312/nascld}"
IP="${IP:-192.168.0.125}"
fails=0
ok()   { printf '  \033[32m[ ok ]\033[0m %s\n' "$*"; }
bad()  { printf '  \033[31m[FEHL]\033[0m %s\n' "$*"; fails=$((fails+1)); }
warn() { printf '  \033[33m[warn]\033[0m %s\n' "$*"; }
head1(){ printf '\n\033[1m== %s ==\033[0m\n' "$*"; }
[ "$(id -u)" = 0 ] || { echo "Bitte mit sudo starten."; exit 1; }

head1 "Neustarts und Laufzeit"
echo "  Boot: $(uptime -s)   ($(uptime -p))"
echo "  Boots im Journal: $(journalctl --list-boots 2>/dev/null | wc -l)"
dmesg -T 2>/dev/null | grep -qiE 'orphan cleanup on readonly fs' \
  && warn "dmesg: 'orphan cleanup' - letzter Shutdown war nicht sauber" || ok "kein Hinweis auf unsauberes Aushaengen"

head1 "Hardware"
if command -v vcgencmd >/dev/null; then
  t=$(vcgencmd get_throttled | sed 's/.*=//')
  [ "$t" = "0x0" ] && ok "throttled=0x0 (keine Unterspannung seit Boot)" || bad "throttled=$t"
  echo "  $(vcgencmd measure_temp)   5V: $(vcgencmd pmic_read_adc EXT5V_V 2>/dev/null | sed 's/.*=//')"
fi
dmesg -T 2>/dev/null | grep -iE 'I/O error|EXT4-fs error|nvme.*(timeout|reset)|AER:.*error' | tail -3 | sed 's/^/  /' \
  | grep . >/dev/null && bad "Speicher-/PCIe-Fehler im dmesg (siehe: dmesg -T | grep -iE 'I/O error|EXT4-fs error|nvme')" || ok "keine E/A-Fehler im dmesg"
echo "  Speicher: $(free -h | awk '/Mem:/{print "frei "$7" von "$2}')   Load: $(cut -d' ' -f1-3 /proc/loadavg)"

head1 "Datentraeger"
R=$(findmnt -no SOURCE /); echo "  Root: $R  ($(df -h / | awk 'NR==2{print $5" belegt"}'))"
df -h "$NAS" | awk 'NR==2{print "  NAS : "$1"  "$5" belegt, "$4" frei"}'
DR=$(docker info --format '{{.DockerRootDir}}' 2>/dev/null)
[ "$(findmnt -no SOURCE --target "$DR")" = "$(findmnt -no SOURCE --target "$NAS")" ] \
  && ok "Docker laeuft von der NVMe ($DR)" || bad "Docker-Datenverzeichnis liegt NICHT auf der NVMe: $DR"
ls -d /var/lib/docker.alt-* "$NAS"/immich-db-leer-* 2>/dev/null | sed 's/^/  Altlast, nach Pruefung loeschbar: /'

head1 "Container"
for c in immich_server immich_machine_learning immich_postgres immich_redis mtb-bot twingate-neon-mosquito; do
  s=$(docker inspect "$c" --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}} restarts={{.RestartCount}}' 2>/dev/null)
  case "$s" in healthy*|running*) ok "$c: $s";; "") bad "$c: fehlt";; *) bad "$c: $s";; esac
done

head1 "Datenbank"
M=$(docker inspect immich_postgres --format '{{range .Mounts}}{{if eq .Destination "/var/lib/postgresql/data"}}{{.Source}}{{end}}{{end}}' 2>/dev/null)
echo "  Mount: $M"
case "$M" in "$NAS"/immich-db) ok "Postgres nutzt das richtige Verzeichnis";; *) bad "unerwarteter DB-Pfad";; esac
[ -e "$NAS/Immich/postgres" ] && warn "$NAS/Immich/postgres existiert (Sperre oder Altlast?)"
n=$(docker exec -u postgres immich_postgres psql -d immich -tAc "select count(*) from \"user\"" 2>/dev/null | tr -d ' ')
[ -n "$n" ] && echo "  Benutzer in Immich: $n   Assets: $(docker exec -u postgres immich_postgres psql -d immich -tAc 'select count(*) from asset' 2>/dev/null | tr -d ' ')" || warn "Abfrage der Immich-Tabellen nicht moeglich"
pw=$(docker inspect immich_server --format '{{range .Config.Env}}{{println .}}{{end}}' | sed -n 's/^DB_PASSWORD=//p' | head -1)
fp=$(printf '%s' "$pw" | sha256sum | cut -c1-12)
[ "$fp" = "e5dba549c025" ] && bad "DB_PASSWORD ist noch der alte, im Chat veroeffentlichte Wert" || ok "DB_PASSWORD wurde geaendert (fingerprint $fp)"

head1 "Erreichbarkeit (lokal)"
for u in "http://localhost/" "http://localhost:2283/api/server/ping"; do
  c=$(curl -s -o /dev/null -w '%{http_code}' -m 5 "$u"); [ "$c" = 200 ] && ok "$u -> 200" || bad "$u -> $c"
done
[ -n "$(docker inspect immich_server --format '{{range .Config.Env}}{{println .}}{{end}}' | grep '^DB_USERNAME=')" ] \
  && ok "environment:-Block ist im Container angekommen" || bad "immich_server hat keine DB_*-Variablen"

head1 "Zusammenfassung"
[ "$fails" = 0 ] && echo "  Alles in Ordnung." || echo "  $fails Punkt(e) pruefen."
exit "$fails"
