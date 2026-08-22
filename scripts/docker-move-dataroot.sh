#!/usr/bin/env bash
#
# docker-move-dataroot.sh
#
# Verlegt Dockers Datenverzeichnis vom Systemdatentraeger auf die NVMe.
#
# Warum: liegt / auf einem USB-Flash-Speicher, ist /var/lib/docker die mit
# Abstand schreibintensivste Stelle des Systems (Container-Schichten, Logs,
# Volumes). Stallt der Stick laenger als das Watchdog-Timeout, setzt die
# Hardware den Pi zurueck - mitten im Schreibbetrieb.
#
# Es wird ausschliesslich kopiert und umbenannt. Nichts wird geloescht:
# das alte Verzeichnis bleibt als /var/lib/docker.alt-<Zeitstempel> liegen.
#
# Aufruf:
#   sudo ./docker-move-dataroot.sh --to /srv/dev-disk-by-uuid-XXXX/docker [--yes]
#
set -uo pipefail
TARGET=""; ASSUME_YES=0
while [ $# -gt 0 ]; do
  case "$1" in
    --to)  TARGET="${2:?--to braucht einen Pfad}"; shift ;;
    --yes|-y) ASSUME_YES=1 ;;
    -h|--help) sed -n '2,18p' "$0"; exit 0 ;;
    *) echo "Unbekannte Option: $1"; exit 2 ;;
  esac; shift
done
die()  { printf '\033[31mFEHLER:\033[0m %s\n' "$*" >&2; exit 1; }
ok()   { printf '\033[32m[ ok ]\033[0m %s\n' "$*"; }
inf()  { printf '[info] %s\n' "$*"; }
warn() { printf '\033[33m[warn]\033[0m %s\n' "$*"; }
step() { printf '\n\033[1m== %s ==\033[0m\n' "$*"; }

[ "$(id -u)" = 0 ] || die "Bitte mit sudo ausfuehren."
[ -n "$TARGET" ] || die "Zielpfad mit --to angeben."
command -v rsync >/dev/null 2>&1 || die "rsync fehlt: sudo apt install -y rsync"

step "1. Ausgangslage"
SRC=$(docker info --format '{{.DockerRootDir}}' 2>/dev/null)
SRC="${SRC:-/var/lib/docker}"
inf "aktuell : $SRC   (auf $(findmnt -no SOURCE --target "$SRC"))"
inf "Ziel    : $TARGET (auf $(findmnt -no SOURCE --target "$(dirname "$TARGET")"))"
[ "$(findmnt -no SOURCE --target "$SRC")" != "$(findmnt -no SOURCE --target "$(dirname "$TARGET")")" ] \
  || warn "Quelle und Ziel liegen auf demselben Datentraeger - das bringt nichts."

NEED=$(du -sb "$SRC" 2>/dev/null | cut -f1)
FREE=$(df -B1 --output=avail "$(dirname "$TARGET")" | tail -1)
inf "Datenmenge: $(numfmt --to=iec "$NEED")   frei am Ziel: $(numfmt --to=iec "$FREE")"
[ "$FREE" -gt "$((NEED + NEED / 10))" ] || die "Zu wenig Platz am Ziel."

echo; echo "Ablauf: Container stoppen, Docker stoppen, Daten kopieren,"
echo "        data-root umstellen, Docker starten, pruefen."
echo "        Das alte Verzeichnis bleibt erhalten."
if [ "$ASSUME_YES" = 0 ]; then
  printf 'Fortfahren? [j/N] '
  read -r a; case "$a" in j|J|y|Y) ;; *) die "Abgebrochen." ;; esac
fi

step "2. Laufende Container notieren und Docker stoppen"
docker ps --format '{{.Names}}' > /tmp/docker-running-before.txt 2>/dev/null
inf "liefen: $(tr '\n' ' ' < /tmp/docker-running-before.txt)"
systemctl stop docker.socket 2>/dev/null
systemctl stop docker || die "Docker liess sich nicht stoppen."
sleep 2
pgrep -x dockerd >/dev/null && die "dockerd laeuft noch - Abbruch, es wurde nichts geaendert."
ok "Docker gestoppt."

step "3. Daten kopieren (Rechte, Hardlinks und erweiterte Attribute bleiben)"
mkdir -p "$TARGET" || die "Zielverzeichnis nicht anlegbar."
rsync -aHAX --numeric-ids --info=progress2 "$SRC/" "$TARGET/" || {
  warn "rsync fehlgeschlagen. Docker wird wieder gestartet, nichts wurde umgestellt."
  systemctl start docker; die "Abbruch."
}
ok "Kopie abgeschlossen."

step "4. data-root umstellen"
CFG=/etc/docker/daemon.json
TS=$(date +%Y%m%d-%H%M%S)
mkdir -p /etc/docker
if [ -f "$CFG" ]; then
  cp -a "$CFG" "$CFG.bak-$TS" && ok "gesichert: $CFG.bak-$TS"
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$CFG" "$TARGET" <<'PY' || die "daemon.json liess sich nicht anpassen."
import json, sys
path, target = sys.argv[1], sys.argv[2]
try:
    with open(path) as f:
        cfg = json.load(f) or {}
except Exception:
    cfg = {}
cfg["data-root"] = target
with open(path, "w") as f:
    json.dump(cfg, f, indent=2)
    f.write("\n")
PY
  fi
else
  printf '{\n  "data-root": "%s"\n}\n' "$TARGET" > "$CFG"
fi
ok "daemon.json:"; sed 's/^/    /' "$CFG"

step "5. Docker starten und pruefen"
systemctl start docker || die "Docker startet nicht. Notfall: $CFG.bak-$TS zurueckspielen."
sleep 3
NOW=$(docker info --format '{{.DockerRootDir}}' 2>/dev/null)
if [ "$NOW" = "$TARGET" ]; then
  ok "Docker benutzt jetzt: $NOW"
else
  die "data-root ist weiterhin '$NOW'. daemon.json pruefen."
fi
docker ps -a --format 'table {{.Names}}\t{{.Status}}' | sed 's/^/  /'

step "6. Altes Verzeichnis zur Seite legen"
OLD="$SRC.alt-$TS"
mv -T -- "$SRC" "$OLD" 2>/dev/null && ok "altes Verzeichnis: $OLD (nicht geloescht)" \
  || warn "Umbenennen nicht moeglich - $SRC bleibt liegen, das stoert aber nicht."

cat <<EOF

== Danach ==
1. Container hochfahren (OMV: Services > Compose > immich > Up) und pruefen.
2. Wichtig, damit es dauerhaft bleibt: falls OMV unter
   Services > Compose > Einstellungen ein Feld fuer den Docker-Speicherpfad
   hat, dort denselben Pfad eintragen - sonst kann OMV daemon.json
   ueberschreiben.
3. Erst wenn alles laeuft und ein Neustart ueberstanden ist:
       sudo rm -rf "$OLD"
   Das gibt $(du -sh "$OLD" 2>/dev/null | cut -f1) auf dem Systemdatentraeger frei.
EOF
