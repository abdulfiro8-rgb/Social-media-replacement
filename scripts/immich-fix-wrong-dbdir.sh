#!/usr/bin/env bash
#
# immich-fix-wrong-dbdir.sh
#
# Repariert die Situation, in der das Postgres-Datenverzeichnis verschoben
# wurde, der Stack aber gestartet wurde, BEVOR DB_DATA_LOCATION angepasst war.
# Docker legt den alten Pfad dann als leeres Verzeichnis an und Postgres
# initialisiert darin eine neue, leere Datenbank. Der Stack wirkt gesund,
# die echten Daten liegen unbenutzt daneben.
#
# Dieses Skript
#   - vergleicht beide Verzeichnisse und zeigt, welches die echten Daten haelt
#   - stoppt die Immich-Container
#   - schiebt die leere Instanz zur Seite (mv, KEIN Loeschen)
#   - setzt eine Sperre, damit kein Start mit falschem Pfad mehr moeglich ist
#
# Aufruf:
#   sudo ./immich-fix-wrong-dbdir.sh --real /pfad/zur/echten/db [--yes]
#
set -uo pipefail
DOCKER="${DOCKER:-docker}"
REAL=""; ASSUME_YES=0
while [ $# -gt 0 ]; do
  case "$1" in
    --real) REAL="${2:?--real braucht einen Pfad}"; shift ;;
    --yes|-y) ASSUME_YES=1 ;;
    -h|--help) sed -n '2,18p' "$0"; exit 0 ;;
    *) echo "Unbekannte Option: $1"; exit 2 ;;
  esac; shift
done
die()  { printf '\033[31mFEHLER:\033[0m %s\n' "$*" >&2; exit 1; }
ok()   { printf '\033[32m[ ok ]\033[0m %s\n' "$*"; }
inf()  { printf '[info] %s\n' "$*"; }
warn() { printf '\033[33m[warn]\033[0m %s\n' "$*"; }

[ "$(id -u)" = 0 ] || die "Bitte mit sudo ausfuehren."
[ -n "$REAL" ] || die "Bitte den Pfad der echten Datenbank mit --real angeben."
[ -f "$REAL/PG_VERSION" ] || die "$REAL enthaelt kein PG_VERSION - das ist kein Postgres-Datenverzeichnis."

WRONG=$($DOCKER inspect immich_postgres \
  --format '{{range .Mounts}}{{if eq .Destination "/var/lib/postgresql/data"}}{{.Source}}{{end}}{{end}}' 2>/dev/null)
[ -n "$WRONG" ] || die "Aktuell gemountetes DB-Verzeichnis nicht ermittelbar."
[ "$WRONG" != "$REAL" ] || { ok "Der Container mountet bereits $REAL - nichts zu tun."; exit 0; }

echo
echo "Vergleich:"
for d in "$WRONG" "$REAL"; do
  if [ -d "$d" ]; then
    printf '  %s\n' "$d"
    printf '    PG_VERSION vom : %s\n' "$(stat -c '%y' "$d/PG_VERSION" 2>/dev/null | cut -d. -f1)"
    printf '    Groesse        : %s\n' "$(du -sh "$d" 2>/dev/null | cut -f1)"
  else
    printf '  %s  (existiert nicht)\n' "$d"
  fi
done
echo
inf "Aktuell in Benutzung : $WRONG"
inf "Echte Daten laut dir : $REAL"
warn "Die aktuell benutzte Instanz wird zur Seite geschoben, NICHT geloescht."

if [ "$ASSUME_YES" = 0 ]; then
  printf 'Fortfahren? [j/N] '
  read -r a; case "$a" in j|J|y|Y) ;; *) die "Abgebrochen." ;; esac
fi

for c in immich_server immich_machine_learning immich_postgres immich_redis; do
  $DOCKER inspect "$c" >/dev/null 2>&1 && { $DOCKER stop "$c" >/dev/null && ok "gestoppt: $c"; }
done
sleep 2

TS=$(date +%Y%m%d-%H%M%S)
PARK="$(dirname "$REAL")/immich-db-leer-$TS"
if [ -d "$WRONG" ]; then
  mv -T -- "$WRONG" "$PARK" || die "Verschieben fehlgeschlagen - es wurde nichts geloescht."
  ok "Leere Instanz geparkt unter: $PARK"
fi

cat > "$WRONG" <<GUARD
Absichtliche Sperre von immich-fix-wrong-dbdir.sh.

Das Postgres-Datenverzeichnis ist jetzt:  $REAL
Die versehentlich angelegte leere Instanz liegt unter: $PARK

Solange diese Datei existiert, kann der Stack nicht mit dem falschen Pfad
starten. Nach dem Anpassen von DB_DATA_LOCATION diese Datei loeschen:
    sudo rm -f "$WRONG"
GUARD
chmod 444 "$WRONG"
ok "Sperre gesetzt: ein Start mit dem alten Pfad scheitert jetzt sichtbar."

cat <<EOF

NAECHSTE SCHRITTE - GENAU IN DIESER REIHENFOLGE:

  1. OMV: Services > Compose > Files > immich > Environment
         DB_DATA_LOCATION=$REAL
     (bei der Gelegenheit auch DB_PASSWORD erneuern), speichern.

  2. Sperre entfernen:
         sudo rm -f "$WRONG"

  3. Stack 'Up' schalten.

  4. Passwort mit der Datenbank abgleichen und pruefen:
         sudo ./scripts/immich-apply-fix.sh

Kontrolle danach - der Mount muss auf $REAL zeigen:
    sudo docker inspect immich_postgres \\
      --format '{{range .Mounts}}{{.Source}}{{end}}'

Die geparkte leere Instanz unter $PARK kann geloescht werden, sobald Immich
mit deinen Daten laeuft. Vorher nicht.
EOF
