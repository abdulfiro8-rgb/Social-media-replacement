# iPhone-Speicher freigeben, Fotos bleiben auf dem Pi

Ziel: Originale liegen dauerhaft auf dem NAS, das iPhone gibt seinen lokalen
Speicher frei, die Bilder bleiben sichtbar und werden bei Bedarf nachgeladen.

## 1. Die ehrliche Antwort zur „iCloud-artigen" Integration

Es gibt **keine** iOS-App, die die Apple-Fotos-App auf ein eigenes NAS-Backend
umstellt — und Stand heute auch keine, die es künftig könnte. iOS bietet dafür
schlicht keine Schnittstelle:

* **PhotoKit** erlaubt Drittanbieter-Apps, die lokale Fotomediathek zu lesen und
  zu ergänzen. Es erlaubt nicht, sie durch einen fremden Cloud-Dienst zu
  *unterlegen*. „Optimize iPhone Storage" (Platzhalter lokal, Original in der
  Cloud) ist eine geschlossene Funktion von iCloud-Fotos.
* **File-Provider-Extensions** (die Technik hinter Nextcloud, Synology Drive,
  Dropbox) binden sich in die **Dateien**-App ein, nicht in Fotos.
* Wer „NAS statt iCloud" liest, findet ausnahmslos Backup-/Upload-Apps mit
  **eigener** Galerie: [PhotoSync](https://www.photosync-app.com/home) (kann
  „nach Übertragung löschen"), [AmberTime](https://ambertime.app/guides/backup-iphone-photos-to-nas),
  [DSPhoto Backup](https://apps.apple.com/us/app/app/id6448807884),
  [Camera » NAS](https://apps.apple.com/us/app/id6502561543),
  [CCC Mobile Backup](https://apps.apple.com/py/app/ccc-mobile-backup/id6471621409?l=en-GB).
  Keine davon integriert sich in die Fotos-App.

Praktisch bedeutet das: **die Immich-App wird die Galerie.** Genau dafür ist
sie gebaut, und sie hat die Löschfunktion bereits eingebaut.

## 2. Der Weg mit Immich: „Free Up Space"

Die Immich-App bringt genau die gesuchte Funktion mit
([Doku](https://docs.immich.app/features/mobile-app/)): lokale Kopien, die
nachweislich auf dem Server liegen, werden vom Gerät entfernt; die Fotos
bleiben in der Immich-App vollständig sichtbar und werden bei Bedarf vom Pi
geladen.

Reihenfolge:

1. **Server verbinden** — in der App `http://192.168.0.125:2283` eintragen,
   Admin-Account anlegen bzw. anmelden.
2. **Backup einschalten** — Einstellungen → Backup → Album(s) wählen
   (in der Regel „Aufnahmen"/„Recents"), Hintergrund-Backup aktivieren,
   „nur im WLAN" nach Geschmack. Ersten Durchlauf am Ladekabel laufen lassen.
3. **Vollständigkeit prüfen, bevor irgendetwas gelöscht wird.** Die App zeigt
   „x von y gesichert". Zusätzlich serverseitig gegenprüfen:

   ```bash
   sudo docker exec -i -u postgres immich_postgres \
     psql -d immich -tAc "select count(*) from asset"
   du -sh /srv/dev-disk-by-uuid-b3ea1171-e620-4617-90b2-c30ead200312/nascld/Immich/upload
   ```

4. **Free Up Space** — Einstellungen der App. Große Mengen werden in Blöcken
   abgearbeitet (auf iOS ca. 10 000 Assets pro Durchgang).
5. **„Zuletzt gelöscht" leeren** — iOS behält gelöschte Fotos 30 Tage lang.
   Der Speicher wird erst nach dem Leeren dieses Albums tatsächlich frei.

## 3. Zwei Warnungen, die wirklich zählen

**iCloud-Fotos.** Ist iCloud-Fotos aktiv, ist die lokale Mediathek nur eine
Ansicht der iCloud-Mediathek: Was „Free Up Space" lokal entfernt, verschwindet
über die Synchronisation auch aus iCloud und damit von allen anderen Geräten.
Deshalb vorher entscheiden — entweder iCloud-Fotos abschalten und Immich
übernimmt allein, oder bewusst in Kauf nehmen, dass beides zusammen gelöscht
wird. Ein Zwischenzustand („lokal weg, in iCloud noch da") ist nicht vorgesehen.

**Nach dem Löschen ist der Pi die einzige Kopie.** Ein RAID hat er nicht, eine
einzelne NVMe ist kein Backup. Vor dem ersten großen „Free Up Space" mindestens
eine zweite Kopie einrichten, z. B. eine USB-Platte am Pi:

```bash
# Medien
rsync -aH --delete \
  /srv/dev-disk-by-uuid-.../nascld/Immich/ /srv/backup-platte/immich/
# Datenbank-Dump (Immich legt eigene Dumps unter /data/backups an,
# wenn Administration -> Einstellungen -> Backup aktiviert ist)
```

Immichs eingebaute Datenbank-Backups in der Weboberfläche aktivieren:
*Administration → Einstellungen → Backup-Einstellungen*.

## 4. Was dem „Original bei Bedarf laden" außerhalb von Immich am nächsten kommt

In der **Dateien**-App lässt sich der OMV-Freigabeordner direkt als SMB-Server
einbinden (Dateien → … → Mit Server verbinden → `smb://192.168.0.125`).
Damit sind die Originale on-demand verfügbar, ohne Platz zu belegen — aber eben
in Dateien, nicht in Fotos.

## 5. Zugriff von unterwegs

Immich nicht per Portweiterleitung ins Internet stellen. Es ist bereits ein
Twingate-Connector auf dem Pi vorhanden; alternativ Tailscale oder WireGuard.
In der Immich-App lassen sich zwei Server-URLs hinterlegen (lokal und extern),
sodass sie im Heimnetz direkt und unterwegs über den Tunnel geht.

---

Quellen:
[Immich Mobile App](https://docs.immich.app/features/mobile-app/) ·
[Immich Mobile Backup](https://docs.immich.app/features/mobile-backup/) ·
[Immich Environment Variables](https://docs.immich.app/install/environment-variables) ·
[PhotoSync](https://www.photosync-app.com/home) ·
[AmberTime](https://ambertime.app/guides/backup-iphone-photos-to-nas)
