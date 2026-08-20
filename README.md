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
| [`scripts/immich-diagnose.sh`](scripts/immich-diagnose.sh) | Nur-Lesen-Diagnose, gibt keine Passwörter aus |
| [`scripts/immich-fix-db-password.sh`](scripts/immich-fix-db-password.sh) | Synchronisiert das Postgres-Passwort und erstellt nur `immich-server` neu |
| [`scripts/immich-move-db-dir.sh`](scripts/immich-move-db-dir.sh) | Verschiebt das Postgres-Datenverzeichnis aus `UPLOAD_LOCATION` heraus (nur `mv`) |

Keine der Skripte löscht Datenbanken, Volumes oder Verzeichnisse, und keines
verändert andere Container.

> In dieses Repository gehören keine Passwörter, Tokens oder Schlüssel.
