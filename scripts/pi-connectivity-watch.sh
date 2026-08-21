#!/usr/bin/env bash
#
# pi-connectivity-watch.sh - Dauerprotokoll auf dem Pi.
#
# Beantwortet die Frage: gehen die Dienste selbst weg, oder nur der Weg dorthin?
# Prueft alle 10 Sekunden lokal (ueber localhost, also ohne Netzwerkstrecke):
#   - OMV auf Port 80
#   - Immich auf Port 2283
#   - Link-Status und IP-Adresse von end0
#   - Health der Immich-Container
#
# Bleiben die localhost-Werte durchgehend 200, waehrend der Zugriff von aussen
# aussetzt, liegt es garantiert nicht am Pi.
#
# Aufruf (laeuft weiter, auch wenn die SSH-Sitzung endet):
#   nohup ./scripts/pi-connectivity-watch.sh > /dev/null 2>&1 &
# Mitlesen:
#   tail -f ~/pi-connectivity.log
# Beenden:
#   pkill -f pi-connectivity-watch.sh
#
set -u
LOG="${LOG:-$HOME/pi-connectivity.log}"
IFACE="${IFACE:-end0}"
INTERVAL="${INTERVAL:-10}"

# curl schreibt bei einem gescheiterten Verbindungsaufbau "000" und liefert
# gleichzeitig einen Exit-Code != 0. Ein "|| echo" haenge daher nichts an -
# sonst stuende beides in der Zeile. 000 ist die Aussage: keine Verbindung.
code() { curl -s -o /dev/null -w '%{http_code}' --max-time 3 "$1" 2>/dev/null; }

# Nur eine Instanz - zwei Watcher schreiben sonst abwechselnd in dieselbe
# Datei und das Protokoll liest sich wie doppelte Messwerte.
# Ueber eine Sperrdatei, nicht ueber pgrep: pgrep -f zaehlt den eigenen
# Prozess und einen etwaigen Wrapper gleich mit und meldet dann falschen Alarm.
LOCK="${LOCK:-/tmp/pi-connectivity-watch.lock}"
if command -v flock >/dev/null 2>&1; then
  exec 9>"$LOCK" 2>/dev/null || true
  if ! flock -n 9; then
    echo "Es laeuft bereits ein Watcher. Erst beenden:  pkill -f $(basename "$0")" >&2
    exit 1
  fi
fi

# Docker-Zugriff klaeren. Ohne Mitgliedschaft in der Gruppe 'docker' braucht es
# sudo - sonst bliebe die Health-Spalte dauerhaft auf '?' und taeuschte einen
# Ausfall vor, den es nicht gibt.
if docker info >/dev/null 2>&1; then
  DOCKER_CMD="docker"
elif sudo -n docker info >/dev/null 2>&1; then
  DOCKER_CMD="sudo -n docker"
else
  DOCKER_CMD=""
  echo "Hinweis: kein Docker-Zugriff - die Health-Spalte bleibt '?'." >&2
  echo "         Mit 'sudo ./$(basename "$0")' starten oder sich der Gruppe" >&2
  echo "         docker hinzufuegen: sudo usermod -aG docker \$USER (dann neu anmelden)." >&2
fi

printf '# Start %s (Intervall %ss, System laeuft seit %s)\n' \
  "$(date '+%F %T')" "$INTERVAL" "$(uptime -s 2>/dev/null || echo '?')" >> "$LOG"
printf '# Zeit     omv immich  link  ip                health(server/ml/pg/redis)\n' >> "$LOG"

while :; do
  ts=$(date '+%H:%M:%S')
  omv=$(code http://localhost/)
  imm=$(code http://localhost:2283/api/server/ping)

  carrier="?"
  [ -r "/sys/class/net/$IFACE/carrier" ] && carrier=$(cat "/sys/class/net/$IFACE/carrier" 2>/dev/null)
  case "$carrier" in 1) link="up  ";; 0) link="DOWN";; *) link="?   ";; esac

  ip=$(ip -4 -o addr show "$IFACE" 2>/dev/null | awk '{print $4}' | head -n1)
  ip="${ip:-<keine>}"

  h=""
  for c in immich_server immich_machine_learning immich_postgres immich_redis; do
    s=""
    [ -n "$DOCKER_CMD" ] && s=$($DOCKER_CMD inspect "$c" --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' 2>/dev/null)
    case "$s" in healthy) h="${h}+";; starting) h="${h}~";; unhealthy) h="${h}!";; "") h="${h}?";; *) h="${h}x";; esac
  done

  printf '%s  %-3s %-6s %s  %-18s %s\n' "$ts" "$omv" "$imm" "$link" "$ip" "$h" >> "$LOG"

  # Auffaelligkeiten zusaetzlich markieren
  if [ "$omv" != "200" ] || [ "$carrier" != "1" ]; then
    printf '%s  ^^^ AUFFAELLIG: omv=%s carrier=%s\n' "$ts" "$omv" "$carrier" >> "$LOG"
  fi

  # fd 9 fuer das Kind schliessen: sleep wuerde die Sperre sonst erben und
  # nach einem Abbruch des Watchers bis zum eigenen Ende weiter halten -
  # ein Neustart scheiterte dann an einer Sperre, die niemand mehr haelt.
  sleep "$INTERVAL" 9>&-
done
