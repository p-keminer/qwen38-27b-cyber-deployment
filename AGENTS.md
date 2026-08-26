# Arbeitsregeln fuer den lokalen Agenten

- Arbeite nur in diesem Projekt und nur an Systemen, fuer die der Benutzer eine ausdrueckliche Berechtigung hat.
- Erklaere Annahmen, relevante Werkzeugaufrufe und die Ursache von Fehlern nachvollziehbar.
- Veraendere oder loesche nichts ausserhalb des Projekts.
- Behandle `.runpod`, Zugangsdaten, SSH-Schluessel und Umgebungsvariablen als geheim.
- Frage vor Datei-Aenderungen, Shell-Befehlen, Subagenten und anderen zustandsaendernden Aktionen in der GUI um Freigabe.
- Der Standardmodus `offline-v1` hat keinen Webzugriff. Nutze oeffentliche
  HTTP-/HTTPS-Ziele nur, wenn der Benutzer sie fuer die aktuelle Aufgabe
  ausdruecklich freigegeben hat und die GUI sichtbar im Modus
  `controlled-web-v1` laeuft. Nichtoeffentliche, reservierte und sonstige nicht
  freigegebene Ziele bleiben verboten. Weise vor einer moeglichen Uebertragung
  von Projektinhalten darauf hin, dass oeffentliche HTTPS-Verbindungen Daten aus
  dem freigegebenen Arbeitsordner nach aussen uebertragen koennen.
- Die nativen OpenCode-Aktionen `webfetch` und `websearch` stehen immer auf
  `ask`: Jede Nutzung braucht eine sichtbare Benutzerfreigabe. Diese Freigabe
  erzeugt in `offline-v1` keine Netzroute; erst `controlled-web-v1` stellt den
  gefilterten HTTP-/HTTPS-Pfad bereit.
- Die Shell laeuft im isolierten Agent-Container. Versuche nie, Container-, Netzwerk- oder Mountgrenzen zu umgehen.
- Setze bei Shell-Befehlen, die voraussichtlich laenger als 120 Sekunden laufen,
  im Shell-Werkzeug explizit `timeout: 0`. Nutze `background: true`, wenn
  waehrenddessen weitergearbeitet werden kann; Hintergrundbefehle laufen ohne
  Timeout und OpenCode meldet ihren Abschluss automatisch. Belasse kurze
  Befehle beim Standardtimeout und verwende fuer Hintergrundjobs keine
  Poll-/Sleep-Schleifen.
