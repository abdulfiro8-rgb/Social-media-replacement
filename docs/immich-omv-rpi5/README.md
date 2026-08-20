# Immich auf Raspberry Pi 5 / OMV 8 — Diagnose & Reparatur des Postgres-Auth-Fehlers

Stand: 2026-08-19 · Immich `v3` · OMV 8 (Debian Trixie) · Raspberry Pi 5 · `192.168.0.125`

---

## 1. Kurzfassung der Ursache

`immich_server` benutzt **nicht** ein falsches Passwort — er hat **überhaupt kein**
`DB_PASSWORD` in seiner Container-Umgebung und fällt deshalb auf den in Immich
eingebauten Default zurück.

Die dokumentierten Defaults des Immich-Servers sind:

| Variable           | Default      |
| ------------------ | ------------ |
| `DB_HOSTNAME`      | `database`   |
| `DB_PORT`          | `5432`       |
| `DB_USERNAME`      | `postgres`   |
| `DB_PASSWORD`      | `postgres`   |
| `DB_DATABASE_NAME` | `immich`     |

Der Server verbindet sich also als `postgres` mit dem Passwort **`postgres`**.
Die Datenbank wurde beim ersten Start (`initdb`) aber mit dem echten
`DB_PASSWORD` aus der OMV-Environment angelegt. Ergebnis:

```
PostgresError: password authentication failed for user "postgres"  (28P01)
```

Der Healthcheck-Fehler `curl: (7) Failed to connect to localhost port 2283`
ist reine Folgewirkung: der Server bricht vor dem Start des HTTP-Listeners ab,
deshalb liefert auch `ss -lntp | grep 2283` nichts.

### Warum fehlt `DB_PASSWORD` im Container?

Die offizielle Compose-Datei übergibt die DB-Zugangsdaten an `immich-server`
ausschließlich so:

```yaml
    env_file:
      - .env
```

Genau dieser Block wurde bei `immich-server` und `immich-machine-learning`
entfernt. Damit ist der einzige Weg weggefallen, auf dem die Variablen in den
Container gelangen.

Der ursprüngliche Fehler davor war eine Folge falschen Auskommentierens:

```yaml
    volumes:
      - ${UPLOAD_LOCATION}:/data
      - /etc/localtime:/etc/localtime:ro
    #env_file:
      - .env          # <-- gehört jetzt zur volumes-Liste!
```

Weil nur die Zeile `env_file:` auskommentiert wurde, rutschte `- .env` als
dritter Eintrag in die `volumes:`-Liste. Daher exakt:

```
invalid mount config for type "volume": invalid mount path: '.env' mount path must be absolute
```

Das Entfernen des ganzen Blocks hat den Mount-Fehler beseitigt — und dabei die
DB-Zugangsdaten mitgenommen.

### Drei weitere Fallen, die hier zusammenwirken

1. **Das OMV-Compose-„Environment"-Feld injiziert nichts in Container.**
   OMV schreibt daraus eine Env-Datei und übergibt sie als `--env-file`.
   `--env-file` bedient ausschließlich die `${...}`-Substitution *in der
   Compose-Datei*. In einen Container kommt eine Variable nur über
   `environment:` oder `env_file:` im jeweiligen Service.
   Deshalb funktioniert `database` (hat einen `environment:`-Block) und
   `immich-server` nicht (hatte keinen).

2. **`POSTGRES_PASSWORD` wirkt nur beim allerersten `initdb`.**
   Sobald das Datenverzeichnis existiert, ändert eine neue `.env` das Passwort
   in der Datenbank nicht mehr. Deshalb war `ALTER USER` grundsätzlich der
   richtige Weg — er ging nur ins Leere, weil die Gegenseite ohnehin
   `postgres` schickt.

3. **`docker restart` lädt keine neue Umgebung.**
   Environment ist Teil der Container-Konfiguration und wird beim *Erstellen*
   festgelegt. Nach Änderungen an Compose-Datei oder Env-Datei muss der
   Container **neu erstellt** werden (`docker compose up -d --force-recreate`
   bzw. im OMV-Webinterface „Up"). Niemals mit `-v`.

---

## 2. Beweis in drei Befehlen

```bash
# a) Welche DB-Variablen hat der Server wirklich? (erwartet: keine)
sudo docker inspect immich_server \
  --format '{{range .Config.Env}}{{println .}}{{end}}' | grep -E '^(DB_|REDIS_)' || echo "KEINE DB_*-Variablen gesetzt"

# b) Fingerprints vergleichen, ohne Passwörter auszugeben
sudo docker inspect immich_postgres \
  --format '{{range .Config.Env}}{{println .}}{{end}}' | sed -n 's/^POSTGRES_PASSWORD=//p' | tr -d '\n' | sha256sum

# c) Akzeptiert Postgres das, was der Server schickt? (hier der Default)
printf 'postgres\n' | sudo docker exec -i immich_postgres sh -c \
  'read -r PGPASSWORD; export PGPASSWORD; psql -h 127.0.0.1 -U postgres -d immich -tAc "select 1"'
```

Bequemer geht das alles mit dem Diagnose-Skript aus diesem Repo:

```bash
sudo ./scripts/immich-diagnose.sh
```

Es ändert nichts, druckt keine Passwörter (nur gekürzte SHA-256-Fingerprints)
und prüft zusätzlich Mounts, Rechte, Port 2283 und die Logs.

---

## 2b. Fallstrick beim Nachtesten: `127.0.0.1` lügt

Ein Anmeldetest *innerhalb* des Postgres-Containers über `127.0.0.1` beweist
nichts. Das offizielle Postgres-Image erzeugt eine `pg_hba.conf`, in der
`initdb` zuerst Loopback-Regeln schreibt und der Docker-Entrypoint danach
`host all all all scram-sha-256` anhängt:

```
host    all   all   127.0.0.1/32   trust            <-- greift zuerst
host    all   all   ::1/128        trust
host    all   all   all            scram-sha-256    <-- gilt für immich_server
```

`pg_hba` ist first-match-wins. Ein `psql -h 127.0.0.1` landet auf `trust` und
ist auch mit falschem Passwort erfolgreich. `immich_server` verbindet sich aus
einem anderen Container über das Docker-Netz und landet auf `scram-sha-256`.

Deshalb testen die Skripte über die Container-IP:

```bash
printf '%s\n' "$PW" | sudo docker exec -i immich_postgres sh -c '
  read -r PGPASSWORD; export PGPASSWORD
  IP=$(hostname -i | cut -d" " -f1)
  psql -h "$IP" -U postgres -d immich -tAc "select 1"'
```

## 3. Reparatur

> Keine Datenbank, kein Volume und kein Verzeichnis wird dabei angefasst.
> Kein `down -v`, kein `rm -rf`, keine rekursiven Rechteänderungen,
> keine Änderung an `mtb-bot` oder `twingate-neon-mosquito`.

### Der schnelle Weg: ein Befehl

```bash
sudo ./scripts/immich-apply-fix.sh --dry-run   # zeigt Konfiguration und Plan
sudo ./scripts/immich-apply-fix.sh             # führt aus
```

Das Skript zeigt die aktuelle Konfiguration (Passwort maskiert), sichert die
Compose-Dateien mit Zeitstempel, trägt den fehlenden `environment:`-Block per
echtem YAML-Merge in die `compose.override.yml` ein (vorhandene Einträge
bleiben erhalten — OMV lädt diese Datei ohnehin bereits mit), validiert mit
`docker compose config`, setzt das Rollenpasswort, prüft die Anmeldung über
das Docker-Netz und erstellt nur `immich-server` und
`immich-machine-learning` neu (`--no-deps`, `database` und `redis` bleiben
unberührt).

Die Schritte einzeln, falls du es von Hand machen willst:

### Schritt 1 — Compose-Datei korrigieren

OMV-Webinterface → **Services → Compose → Files → `immich` → Bearbeiten**.
Im Service `immich-server` unterhalb von `volumes:` einfügen (gleiche
Einrückungsebene wie `volumes:` und `ports:`):

```yaml
    environment:
      DB_HOSTNAME: database
      DB_PORT: 5432
      DB_USERNAME: ${DB_USERNAME}
      DB_PASSWORD: ${DB_PASSWORD}
      DB_DATABASE_NAME: ${DB_DATABASE_NAME}
      REDIS_HOSTNAME: redis
      TZ: ${TZ}
```

Und bei `immich-machine-learning` (braucht keine DB, nur die Zeitzone):

```yaml
    environment:
      TZ: ${TZ}
```

Die vollständige, geprüfte Datei liegt hier:
[`compose/immich/docker-compose.yml`](../../compose/immich/docker-compose.yml)
— sie kann 1:1 in das OMV-Feld kopiert werden.

**Warum `environment:` und nicht wieder `env_file: - .env`?**
`env_file: - .env` ist relativ zur Compose-Datei und setzt voraus, dass die
OMV-Env-Datei exakt `.env` heißt und im selben Verzeichnis liegt. Je nach
OMV-Compose-Version heißt sie anders. Der `environment:`-Block funktioniert
unabhängig davon, weil er die bereits substituierten `${...}`-Werte benutzt.
Wenn im Stack-Verzeichnis tatsächlich eine `.env` liegt (das Diagnose-Skript
zeigt es in Abschnitt 2 der Ausgabe), ist `env_file: - .env` gleichwertig —
dann aber bitte **den ganzen Block** einfügen, nicht nur die Listenzeile.

OMV Compose legt neben der Stack-Datei (`immich.yml`) auch eine
`compose.override.yml` an und lädt beide. Der `environment:`-Block kann
deshalb auch dort stehen — das ist der Weg, den `immich-apply-fix.sh` nimmt,
weil er die von OMV verwaltete Hauptdatei nicht anfasst. Damit OMV die
Änderung beim nächsten Speichern nicht überschreibt, sollte der Block
zusätzlich einmal im Webinterface hinterlegt werden.

### Schritt 2 — Passwort synchronisieren und Container neu erstellen

```bash
sudo ./scripts/immich-fix-db-password.sh --dry-run   # erst ansehen
sudo ./scripts/immich-fix-db-password.sh             # dann ausführen
```

Das Skript

1. liest den Sollwert `DB_PASSWORD` aus der Env-Datei des Stacks,
2. setzt die Postgres-Rolle per `ALTER USER … WITH PASSWORD …` auf diesen Wert
   (nur Rollen-Metadaten, keine Daten betroffen),
3. testet die Anmeldung wirklich (`select 1` über TCP mit diesem Passwort),
4. erstellt **nur** `immich-server` neu (`up -d --force-recreate immich-server`),
5. wartet auf `healthy`.

Das Passwort wird dabei nie als Kommandozeilenargument übergeben (wäre in `ps`
sichtbar), sondern über stdin, und nie ausgegeben.

Alternativ manuell — der Kern ist eine Zeile, das Passwort kommt über stdin,
nicht über die Shell-History:

```bash
sudo docker exec -i -u postgres immich_postgres psql -v ON_ERROR_STOP=1 -d postgres
ALTER USER postgres WITH PASSWORD 'DEIN_WERT_AUS_DER_ENV';
\q
```

Danach den Stack im OMV-Webinterface einmal **Down** und **Up** schalten
(die Schaltfläche „Down" in OMV Compose löscht keine Volumes) oder:

```bash
sudo docker compose -p immich \
  --project-directory /pfad/zum/stack -f /pfad/zum/stack/docker-compose.yml \
  --env-file /pfad/zum/stack/.env \
  up -d --force-recreate immich-server
```

Den Pfad zeigt:

```bash
sudo docker inspect immich_server \
  --format '{{index .Config.Labels "com.docker.compose.project.working_dir"}}'
```

### Schritt 3 — Passwortzeichen prüfen

Immich schreibt ausdrücklich vor: **nur `A-Za-z0-9`** im `DB_PASSWORD`.
Gründe, die genau hier durchschlagen:

* `$` wird von Compose als Variablenbeginn interpretiert,
* ` #` wird in `.env`-Dateien als Kommentar abgeschnitten,
* Leerzeichen und Anführungszeichen werden je nach Pfad unterschiedlich geparst.

Wenn das aktuelle Passwort Sonderzeichen enthält: in der OMV-Environment auf
rein alphanumerisch ändern und Schritt 2 erneut laufen lassen. Beide Skripte
warnen automatisch.

---

## 3b. Ergebnis des Reparaturlaufs (2026-08-20)

Durchgeführt auf dem Pi, Ergebnis:

```
[ ok ] Compose loest DB_PASSWORD fuer immich-server jetzt auf.
[ ok ] ALTER ROLE ausgefuehrt
[ ok ] scram-Anmeldung mit dem Env-Passwort funktioniert.
[ ok ] immich_server hat jetzt das richtige DB_PASSWORD
[ ok ] HTTP-API antwortet (200)
immich_server   Up (healthy)   ·   immich_postgres/immich_redis healthy
```

`immich-machine-learning` stand danach noch auf `health: starting` — das ist
der erste Modell-Download beim Kaltstart und erledigt sich selbst.

### Wichtig: die Änderung ist noch nicht dauerhaft

Der Kopf beider Stack-Dateien sagt es unmissverständlich:

```
# This file is auto-generated by openmediavault
# WARNING: Do not edit this file, your changes will get lost.
```

OMV rendert `immich.yml`, `compose.override.yml` und `immich.env` aus seiner
eigenen Konfigurationsdatenbank. Beim nächsten Speichern oder
`omv-salt deploy run compose` wird die vom Skript geschriebene
`compose.override.yml` **überschrieben** — und damit ist der `28P01`-Fehler
zurück.

Deshalb muss der Block einmal über das Webinterface in OMVs Datenbank:
**Services → Compose → Files → `immich` → Bearbeiten**, im Service
`immich-server` auf der Ebene von `volumes:` und `ports:`:

```yaml
    environment:
      DB_HOSTNAME: database
      DB_PORT: 5432
      DB_USERNAME: ${DB_USERNAME}
      DB_PASSWORD: ${DB_PASSWORD}
      DB_DATABASE_NAME: ${DB_DATABASE_NAME}
      REDIS_HOSTNAME: redis
      TZ: ${TZ}
```

Erst danach überlebt die Reparatur ein OMV-Deployment.

---

## 4. Verifikation

```bash
sudo docker ps --filter name=immich_ --format 'table {{.Names}}\t{{.Status}}'
sudo docker inspect immich_server --format '{{.State.Health.Status}}'   # healthy
sudo ss -lntp | grep 2283                                               # Listener da
curl -sf -o /dev/null -w '%{http_code}\n' http://192.168.0.125:2283/api/server/ping
sudo docker logs --tail 20 immich_server | grep -i 'listening'
```

Ziel: alle vier Container `healthy`, `http://192.168.0.125:2283` erreichbar.
Beim allerersten erfolgreichen Start wird im Webinterface der Admin-Account
angelegt.

---

## 5. Empfehlung: Postgres-Verzeichnis aus dem Upload-Verzeichnis herausnehmen

Aktuell:

```
UPLOAD_LOCATION  = .../nascld/Immich
DB_DATA_LOCATION = .../nascld/Immich/postgres     <-- liegt INNERHALB
```

`UPLOAD_LOCATION` wird als `/data` in den Server gemountet, und Immich
verwaltet diesen Baum selbst (`upload/`, `library/`, `thumbs/`,
`encoded-video/`, `profile/`, `backups/`). Ein fremdes, `0700`-geschütztes
Postgres-Verzeichnis darin ist eine dauerhafte Fehlerquelle — u. a. für
Immichs eigene Datenbank-Backups und die Speicherstatistik.

Besser:

```
DB_DATA_LOCATION = .../nascld/immich-db
```

Solange die Bibliothek noch leer ist, ist das ein Sekundenvorgang (reines
`mv` auf demselben Dateisystem, es wird nichts gelöscht):

```bash
sudo ./scripts/immich-move-db-dir.sh \
  --to /srv/dev-disk-by-uuid-b3ea1171-e620-4617-90b2-c30ead200312/nascld/immich-db
```

Danach `DB_DATA_LOCATION` in der OMV-Environment anpassen und den Stack
hochfahren. **Zwingend**: die NVMe bleibt das Ziel — ein Netzlaufwerk (SMB/NFS)
ist für das Postgres-Datenverzeichnis nicht unterstützt.

---

## 6. Was in dieser Situation ausdrücklich nicht getan wird

| Nicht tun | Warum |
| --- | --- |
| `docker compose down -v` | löscht benannte Volumes — Datenverlustrisiko |
| `docker volume rm` / `rm -rf .../postgres` | vernichtet die Datenbank |
| Immich neu installieren | behebt die Ursache nicht, kostet die Bibliothek |
| `chown -R` / `chmod -R` auf Datenverzeichnisse | zerstört Postgres-Rechte (`0700`, uid 999) |
| `mtb-bot` oder `twingate-neon-mosquito` anfassen | unbeteiligt; das eigene `twingate_apps`-Netz bleibt wie es ist |
| `docker restart` nach Env-Änderung | lädt die Umgebung nicht neu — es braucht ein Recreate |

---

## 7. Offene Nebenbaustellen

* **Twingate-Tokens**: Access- und Refresh-Token wurden früher im Klartext
  gepostet und gelten als kompromittiert. Im Twingate-Adminbereich rotieren
  (neuer Connector-Token), danach den Connector-Container mit den neuen Werten
  neu erstellen. Die alten Werte werden hier bewusst nicht wiederholt und
  gehören auch nicht in dieses Repository.
* **OMV `Failed to open file (filename=/tmp/bgstatus…)`**: Statusdatei eines
  OMV-Hintergrundjobs, dessen Ausgabe abgeräumt wurde (typisch nach
  Session-/Browser-Timeout oder `/tmp`-Bereinigung). Unabhängig vom
  Immich-Problem. Abhilfe: neu anmelden und die Aktion erneut starten; falls
  dauerhaft, `sudo systemctl restart openmediavault-engined`.
* **Plex-Repository**: bleibt deaktiviert. Falls Plex später gebraucht wird,
  das Repo mit aktuellem Signierschlüssel und `signed-by=` neu einbinden — die
  alte SHA1-Signatur wird von Debian Trixie seit 2026-02-01 abgelehnt.
* **Backup**: sobald Immich läuft, in der Weboberfläche unter
  *Administration → Einstellungen → Backup-Einstellungen* die Datenbank-Dumps
  aktivieren. Ein Dump plus `UPLOAD_LOCATION` ist die vollständige Sicherung;
  ein Backup des Postgres-Verzeichnisses bei laufender DB ist es nicht.
