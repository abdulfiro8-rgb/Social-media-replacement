# Social-media-replacement

Selbstgehostete Alternativen zu kommerziellen Cloud-Diensten.

## Immich auf Raspberry Pi 5 / OpenMediaVault 8

| Datei | Inhalt |
| --- | --- |
| [`docs/immich-omv-rpi5/README.md`](docs/immich-omv-rpi5/README.md) | Ursachenanalyse und Reparatur des `password authentication failed for user "postgres"` (28P01), Verifikation, Stolperfallen |
| [`docs/immich-omv-rpi5/iphone-speicher-freigeben.md`](docs/immich-omv-rpi5/iphone-speicher-freigeben.md) | iPhone-Speicher freigeben, Originale bleiben auf dem NAS |
| [`compose/immich/docker-compose.yml`](compose/immich/docker-compose.yml) | Für OMV Compose korrigierte Immich-Compose-Datei |
| [`compose/immich/example.env`](compose/immich/example.env) | Vorlage für den OMV-Environment-Block (ohne Geheimnisse) |
| [`scripts/immich-apply-fix.sh`](scripts/immich-apply-fix.sh) | Komplettreparatur in einem Durchgang: Konfiguration zeigen, sichern, `environment:`-Block per YAML-Merge ergänzen, Passwort synchronisieren, neu erstellen, verifizieren |
| [`scripts/docker-move-dataroot.sh`](scripts/docker-move-dataroot.sh) | Verlegt Dockers Datenverzeichnis vom USB-Systemdatentraeger auf die NVMe (rsync, ohne Löschen) |
| [`scripts/pi-connectivity-watch.sh`](scripts/pi-connectivity-watch.sh) | Dauerprotokoll: Dienste, Link, Temperatur, 5V, Throttling, Load — jede Zeile sofort auf Platte |
| [`scripts/immich-healthcheck.sh`](scripts/immich-healthcheck.sh) | Nur-Lesen-Gesamtprüfung: Boot, Hardware, Datenträger, Container, Datenbank, Passwort-Fingerprint, Erreichbarkeit |
| [`scripts/immich-diagnose.sh`](scripts/immich-diagnose.sh) | Nur-Lesen-Diagnose, gibt keine Passwörter aus |
| [`scripts/immich-fix-db-password.sh`](scripts/immich-fix-db-password.sh) | Synchronisiert das Postgres-Passwort und erstellt nur `immich-server` neu |
| [`scripts/immich-move-db-dir.sh`](scripts/immich-move-db-dir.sh) | Verschiebt das Postgres-Datenverzeichnis aus `UPLOAD_LOCATION` heraus (nur `mv`) und verriegelt den alten Pfad |
| [`scripts/immich-fix-wrong-dbdir.sh`](scripts/immich-fix-wrong-dbdir.sh) | Repariert eine versehentlich angelegte leere Datenbank nach einem Verschieben; parkt sie zur Seite statt sie zu löschen |

Keine der Skripte löscht Datenbanken, Volumes oder Verzeichnisse, und keines
verändert andere Container.

> In dieses Repository gehören keine Passwörter, Tokens oder Schlüssel.
