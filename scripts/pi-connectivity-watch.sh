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

printf '# Start %s (Intervall %ss)\n' "$(date '+%F %T')" "$INTERVAL" >> "$LOG"
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
    s=$(docker inspect "$c" --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' 2>/dev/null)
    case "$s" in healthy) h="${h}+";; starting) h="${h}~";; unhealthy) h="${h}!";; "") h="${h}?";; *) h="${h}x";; esac
  done

  printf '%s  %-3s %-6s %s  %-18s %s\n' "$ts" "$omv" "$imm" "$link" "$ip" "$h" >> "$LOG"

  # Auffaelligkeiten zusaetzlich markieren
  if [ "$omv" != "200" ] || [ "$carrier" != "1" ]; then
    printf '%s  ^^^ AUFFAELLIG: omv=%s carrier=%s\n' "$ts" "$omv" "$carrier" >> "$LOG"
  fi

  sleep "$INTERVAL"
done
