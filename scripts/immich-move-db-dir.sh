#!/usr/bin/env bash
#
# immich-move-db-dir.sh (OPTIONAL, empfohlen solange die Bibliothek klein ist)
#
# Verschiebt das Postgres-Datenverzeichnis aus dem Immich-Upload-Verzeichnis
# heraus. Grund: Immich mountet UPLOAD_LOCATION als /data und verwaltet diesen
# Baum selbst (upload/, library/, thumbs/, encoded-video/, profile/, backups/).
# Ein Postgres-Datenverzeichnis darin ist eine Fehlerquelle - u.a. bei Immichs
# eigenen DB-Backups, Storage-Statistiken und Ordner-Scans.
#
# Es wird ausschliesslich "mv" benutzt. Es wird NICHTS geloescht.
#
# Aufruf:
#   sudo ./immich-move-db-dir.sh --to /srv/dev-disk-by-uuid-XXXX/nascld/immich-db [--yes]
#
set -uo pipefail
DOCKER="${DOCKER:-docker}"
TARGET=""; ASSUME_YES=0
while [ $# -gt 0 ]; do
  case "$1" in
    --to)  TARGET="${2:?--to braucht einen Pfad}"; shift ;;
    --yes|-y) ASSUME_YES=1 ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "Unbekannte Option: $1"; exit 2 ;;
  esac; shift
done
die()  { printf '\033[31mFEHLER:\033[0m %s\n' "$*" >&2; exit 1; }
ok()   { printf '\033[32m[ ok ]\033[0m %s\n' "$*"; }
inf()  { printf '[info] %s\n' "$*"; }
warn() { printf '\033[33m[warn]\033[0m %s\n' "$*"; }

[ -n "$TARGET" ] || die "Bitte Zielpfad mit --to angeben."
[ "$(id -u)" = 0 ] || die "Bitte mit sudo ausfuehren."

SRC=$($DOCKER inspect immich_postgres --format '{{range .Mounts}}{{if eq .Destination "/var/lib/postgresql/data"}}{{.Source}}{{end}}{{end}}' 2>/dev/null)
[ -n "$SRC" ] || die "Aktuelles DB-Verzeichnis nicht ermittelbar (laeuft immich_postgres?)."
[ -f "$SRC/PG_VERSION" ] || die "$SRC sieht nicht wie ein Postgres-Datenverzeichnis aus (kein PG_VERSION)."
inf "Quelle: $SRC"
inf "Ziel  : $TARGET"
[ "$SRC" = "$TARGET" ] && die "Quelle und Ziel sind identisch."
if [ -e "$TARGET" ]; then
  [ -d "$TARGET" ] || die "$TARGET existiert und ist kein Verzeichnis."
  [ -z "$(ls -A "$TARGET" 2>/dev/null)" ] || die "$TARGET existiert und ist nicht leer - abgebrochen."
fi

SRC_FS=$(df -P "$SRC" | awk 'NR==2{print $1}')
DST_FS=$(df -P "$(dirname "$TARGET")" | awk 'NR==2{print $1}')
if [ "$SRC_FS" != "$DST_FS" ]; then
  warn "Quelle ($SRC_FS) und Ziel ($DST_FS) liegen auf verschiedenen Dateisystemen."
  warn "Das Verschieben kopiert dann physisch und dauert entsprechend."
fi

echo
echo "Ablauf:"
echo "  1. immich_server, immich_machine_learning, immich_postgres, immich_redis stoppen"
echo "  2. mv \"$SRC\" -> \"$TARGET\"   (kein Loeschen)"
echo "  3. DB_DATA_LOCATION im OMV-Compose-Environment auf den neuen Pfad setzen (manuell)"
echo "  4. Stack im OMV-Webinterface wieder 'Up' schalten"
echo
if [ "$ASSUME_YES" = 0 ]; then
  printf 'Schritte 1 und 2 jetzt ausfuehren? [j/N] '
  read -r a; case "$a" in j|J|y|Y) ;; *) die "Abgebrochen." ;; esac
fi

for c in immich_server immich_machine_learning immich_postgres immich_redis; do
  $DOCKER inspect "$c" >/dev/null 2>&1 && { $DOCKER stop "$c" >/dev/null && ok "gestoppt: $c"; }
done
sleep 2

mkdir -p "$(dirname "$TARGET")" || die "Zielverzeichnis nicht anlegbar."
mv -T -- "$SRC" "$TARGET" || die "mv fehlgeschlagen - es wurde nichts geloescht."
ok "Verschoben nach $TARGET"
stat -c '  %A %U:%G %n' "$TARGET"

# ---------------------------------------------------------------------------
# Sperre gegen einen verfruehten Start.
#
# Wird der Stack hochgefahren, bevor DB_DATA_LOCATION auf den neuen Pfad zeigt,
# legt Docker den alten Pfad stillschweigend als leeres Verzeichnis an und
# Postgres initialisiert darin eine neue, leere Datenbank. Der Stack ist danach
# "healthy", die echten Daten liegen unbenutzt daneben - ein Fehler, der sich
# als Erfolg tarnt.
#
# Deshalb steht am alten Pfad jetzt eine DATEI statt eines Verzeichnisses.
# Docker kann eine Datei nicht auf das Verzeichnis /var/lib/postgresql/data
# mounten und bricht den Start mit einer klaren Fehlermeldung ab. Lauter
# Fehlschlag statt stiller Datenverlust.
# ---------------------------------------------------------------------------
cat > "$SRC" <<GUARD
Diese Datei ist eine absichtliche Sperre von immich-move-db-dir.sh.

Das Postgres-Datenverzeichnis liegt jetzt unter:
    $TARGET

Solange diese Datei existiert, kann der Immich-Stack nicht mit dem alten,
falschen Pfad starten - das verhindert, dass Postgres hier versehentlich eine
neue, leere Datenbank anlegt.

So geht es weiter:
  1. Im OMV-Webinterface unter Services > Compose > Files > immich >
     Environment setzen:  DB_DATA_LOCATION=$TARGET
  2. Diese Datei loeschen:  sudo rm -f "$SRC"
  3. Den Stack 'Up' schalten.
GUARD
chmod 444 "$SRC"
ok "Sperre am alten Pfad gesetzt (verhindert einen Start mit falschem Pfad)."

cat <<EOF

NAECHSTE SCHRITTE - GENAU IN DIESER REIHENFOLGE:

  1. OMV-Webinterface: Services > Compose > Files > immich > Environment
         DB_DATA_LOCATION=$TARGET
     speichern.

  2. Sperre entfernen:
         sudo rm -f "$SRC"

  3. Erst jetzt den Stack 'Up' schalten.

Wird Schritt 3 vor Schritt 1 ausgefuehrt, scheitert der Start des
Postgres-Containers mit einer Mount-Fehlermeldung. Das ist beabsichtigt und
schuetzt die Daten - dann einfach bei Schritt 1 weitermachen.

Die Daten liegen vollstaendig unter $TARGET. Es wurde nichts geloescht.
EOF
