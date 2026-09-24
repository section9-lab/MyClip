<div align="center">
  <img src="../MyClip/Assets.xcassets/AppIcon.appiconset/icon_256x256.png" alt="MyClip-Symbol" width="120" height="120">
  <h1 align="center">MyClip</h1>
  <p align="center">MyClip hilft dir, den Überblick über deine Arbeit zu behalten. Die App erfasst das aktive Fenster oder dessen Bildschirm auf deinem Mac und verwandelt die Aufnahmen mit Codex oder Claude in durchsuchbare Notizen, verknüpftes Wissen und Aufgabenvorschläge.</p>
</div>

<p align="center">
  <a href="../README.md">English</a> · <a href="README.zh-CN.md">简体中文</a> · <a href="README.es.md">Español</a> · <a href="README.fr.md">Français</a> · <strong>Deutsch</strong> · <a href="README.ja.md">日本語</a> · <a href="README.ko.md">한국어</a>
</p>

<p align="center"><img src="images/myclip-demo.gif" alt="MyClip lokal: Ersteinrichtung mit Auswahl des Standard-Agenten und Berechtigungen, Memory-Dateinavigation, Screenshots in Timeline durchsuchen und filtern sowie OCR-Texte anzeigen, unabhängig scrollende Kanban-Spalten sowie Tages-, Wochen- und Monatsberichte" width="1000"></p>
<p align="center"><sub>Aufgenommen in der nativen MyClip-App für macOS · Lokale Bibliothek · Chinesische Oberfläche.</sub></p>

## Was du damit machen kannst

- **Deine Arbeit wiederfinden.** Durchsuche die Aufnahmechronik und prüfe die Quellen deiner Notizen. Zu jeder Aufnahme gehört ein lokales OCR-Textdokument, das du lesen, kopieren oder öffnen kannst.
- **Eine persönliche Wissensbibliothek aufbauen.** Suche, bearbeite und verknüpfe Notizen zu Projekten, Themen und deinem Arbeitsalltag. Sie liegen als Markdown-Dateien vor und lassen sich auch in anderen Editoren öffnen.
- **Nächste Schritte verfolgen.** Prüfe vorgeschlagene Aufgaben, bestätige Wichtiges und verfolge den Fortschritt auf einem Board. Wechsle zwischen **Kanban** und **Reports**, um Tages-, Wochen- oder Monatsberichte nach Projekt und Fortschritt zu lesen.
- **Deinen KI-Werkzeugen Kontext geben.** Lass Codex, Claude Code, Claude Desktop, Cursor oder OpenCode deine gespeicherten Erinnerungen durchsuchen.

## Erste Schritte

Voraussetzungen sind **macOS 13 oder neuer** und ein **Codex- oder Claude-Konto**. Zum Installieren eines Agent-Connectors wird außerdem **Node.js 22 oder neuer** benötigt. Hinweise zum lokalen Build findest du weiter unten.

1. Öffne MyClip und gehe in der Seitenleiste zu **Backstage**. Installiere einen Connector, melde dich an und prüfe mit **Connect**, ob er verfügbar ist. Klicke anschließend auf **Enable**, um diesen Agent für die Aufbereitung zu aktivieren. Das Verbinden allein startet keine Aufgaben. Mehrere Agents können verbunden sein, aber nur einer kann gleichzeitig aktiviert werden.
2. Erteile die Berechtigungen für **Bildschirmaufnahme** und **Bedienungshilfen**. Die Erfassung startet automatisch, solange MyClip geöffnet ist, auch direkt nach Erteilung der Berechtigungen.
3. Arbeite wie gewohnt. Standardmäßig erfasst MyClip das aktive Fenster nach einem Klick, wenn der Zeiger zuvor eine Sekunde stillstand, nach zwei Sekunden ohne vertikales Scrollen oder nach einer Buchstabentaste gefolgt von der Eingabetaste. Die automatische Aufbereitung überführt neue Aufnahmen in Memory.
4. Öffne **Memory** für Notizen, **Timeline** für Aufnahmen und **Kanban** für vorgeschlagene Aufgaben.

Um die Erinnerungen in einem KI-Werkzeug zu verwenden, aktiviere **MyClip MCP** in den Einstellungen, wähle die Clients und übernimm die Konfiguration. Starte danach den Client neu oder beginne eine neue Sitzung.

**Claude Code (CLI)** bereitet Aufnahmen über ACP im Hintergrund auf. **Claude Desktop** hat einen eigenen Eintrag zum Öffnen der App und zum Einrichten des MCP-Zugriffs auf Erinnerungen in Chat und lokalen Code-Sitzungen. Es lässt sich nicht für die Aufbereitung im Hintergrund aktivieren. Die Desktop-Konfiguration wird in `~/Library/Application Support/Claude/claude_desktop_config.json` gespeichert. Vorhandene Server bleiben erhalten, die CLI-Konfiguration wird nicht verändert. Beende Claude Desktop danach vollständig und öffne es erneut.

## Textdokumente zu Aufnahmen

MyClip erkennt chinesischen und englischen Text lokal mit Apple Vision, unabhängig von der KI-Aufbereitung. Wähle in den Aufnahmedetails **OCR 文档**, um den Text zu lesen oder zu kopieren, oder **打开文档**, um die neben dem Originalbild gespeicherte UTF-8-Datei `.txt` zu öffnen. Wiederholte Aufnahmen teilen sich ein Bild und ein Textdokument. Aufnahmen ohne erkennbaren Text erhalten ein leeres Dokument; fehlgeschlagene Erkennungen können wiederholt werden.

Vorhandene Aufnahmen werden nach dem Start im Hintergrund verarbeitet. OCR-Dokumente und ihr Suchindex laufen entsprechend der Aufbewahrungseinstellung zusammen mit den Originalbildern ab. Gespeicherte Memory-Notizen bleiben erhalten. Die App unterstützt macOS 13 und neuer einschließlich macOS 27. Unter macOS 13 nutzt sie einen ScreenCaptureKit-Stream mit einem einzelnen Bild und denselben App-Ausschlüssen wie unter neueren Systemen.

## Aufbereitung von Bildschirmaufnahmen

Aufnahmen gelangen direkt nach dem Speichern in eine dauerhafte Warteschlange. Die automatische Aufbereitung wartet drei Minuten ab der ältesten ausstehenden Aufnahme und bildet dann ein chronologisches Paket für denselben Agent: höchstens **8 Bilder und 32 OCR-Einträge** mit insgesamt maximal **12.000 OCR-Zeichen**. Manuelle Aufnahmen und Aufnahmen durch die Eingabetaste verwenden Bilder. Mausklicks, Scroll-Ereignisse und ältere Zeiger-Auslöser verwenden lokal erkannten Text. Fehlende OCR wird vor dem Versand erzeugt. Leere, fehlgeschlagene oder einzeln zu lange OCR-Einträge werden durch das Originalbild ersetzt und auf die Bildgrenze angerechnet. Das Paket endet vor dem ersten Eintrag, der eine Grenze überschreiten würde; dieser wird nicht übersprungen. Neue Aufnahmen setzen den Timer nicht zurück. Es läuft immer nur ein Paket, mit mindestens drei Minuten Abstand zwischen zwei Starts.

**Backstage** zeigt die Anzahl wartender Aufnahmen, den Countdown und das aktuelle Paket. **Organize Now** startet ein Paket vorzeitig. Fehler oder Unterbrechungen pausieren die automatische Verarbeitung, bis du sie wiederholst oder fortsetzt; Aufnahmen und vorhandene Memory-Dateien bleiben erhalten. Eingabemodi und OCR-Inhalte werden beim Erstellen eines Pakets festgelegt und bleiben auch bei Wiederholungen und Neustarts gleich. **按图片重新整理** in den Aufnahmedetails sendet ausdrücklich das Originalbild, etwa für Diagramme oder Layouts, die OCR nicht bewahrt. Wenn du einen anderen Agent aktivierst, werden wartende Aufnahmen für die automatische Aufbereitung neu zugeordnet. Laufende Pakete werden mit dem ursprünglichen Agent abgeschlossen. Bestehende Aufträge und Wiederholungen behalten ebenfalls ihren ursprünglichen Agent und warten auf dessen erneute Aktivierung.

Jedes Paket verwendet eine unabhängige temporäre Sitzung. Claude erhält `persistSession: false`. MyClips Codex-app-server-Proxy erzwingt `ephemeral: true` und lehnt Backends ab, die dies nicht bestätigen. Der Agent-Prozess endet nach jedem Durchlauf. Alte gespeicherte Unterhaltungen werden weder fortgesetzt noch gelöscht. Das nächste Paket erhält die festen Aufbereitungsregeln, nur die Übergabe des letzten erfolgreichen Pakets mit höchstens 4 KiB, die aktuellen Eingaben mit Zeitstempeln und Quell-IDs, Metadaten zu App, Fenster und Auslöser sowie den vorhandenen Aufgabenkontext. Verwandte Memory-Dateien werden bei Bedarf gelesen. Die Übergabe enthält gespeicherte Dateiänderungen und Quell-IDs, aber weder Gesprächsverlauf noch Memory-Inhalte. Sie wird erst ersetzt, nachdem Memory erfolgreich veröffentlicht wurde. Wiederholungen nach einem Fehler beginnen mit einer neuen Sitzung und prüfen die aktuellen Dateien.

Ohne aktivierten Agent bleiben die Aufnahmen in der Warteschlange. Das Deaktivieren verhindert neue Aufgaben, während die laufende Aufgabe beendet werden darf. MyClip merkt sich den aktivierten Agent und verbindet ihn beim Start erneut. Ältere Einstellungen für den Standard-Agent aktivieren ihn nicht automatisch; nach einem Upgrade musst du einen Agent ausdrücklich aktivieren.

MyClip startet jede Sitzung zur Aufbereitung oder Aufgabenerkennung mit **Vollzugriff**: `agent-full-access` für Codex und `bypassPermissions` für Claude Code. Dateizugriffe, Bearbeitungen, Befehle, Netzwerkzugriffe und MCP-Aufrufe erfolgen ohne einzelne Bestätigungskarten. Verbleibende Werkzeug-Berechtigungsanfragen werden für die aktive Sitzung automatisch bearbeitet; abgebrochene Aufgaben lehnen verspätete Anfragen ab. Werkzeugaktivitäten bleiben im Ausführungsprotokoll sichtbar.

**Backstage** erfasst den gemeldeten Token-Verbrauch für Aufbereitung, Aufgabenerkennung und Wiederholungen, mit Summen pro Agent und Paket. Die Daten werden am Ende jeder Anfrage lokal gespeichert. Ältere oder nicht gemeldete Werte erscheinen als nicht verfügbar, nicht als null. Die Belegung des Kontextfensters zählt nicht als Verbrauch. Aktive Pakete zeigen ihre aktuelle Phase, die Laufzeit und die Zeit seit dem letzten Fortschritt. Claude ACP verwendet die vorhandene Anmeldung und Netzwerkkonfiguration von Claude Code. Ein konfigurierter lokaler Proxy muss deshalb laufen.

Die Aufbereitung wird gestoppt, wenn es in der aktuellen Sitzung fünf Minuten lang keine neuen Überlegungen, Antworttexte, Werkzeug- oder Berechtigungsaktivitäten gibt. Solange Fortschritt stattfindet, kann ein Paket bis zu insgesamt fünfzehn Minuten laufen. Reine Verbrauchsmeldungen und andere Sitzungen verlängern dieses Zeitlimit nicht.

Memory trennt die Beobachtungszeit der Aufnahme (`observed_at`) vom Änderungszeitpunkt der Datei (`updated_at`). Now zeigt, wann die zugehörigen Quellen aufgenommen wurden. Ältere Quellen dürfen eine neuere Now-Seite nicht ersetzen. Fehlt die Beobachtungszeit, bleibt sie unbekannt. Der Organisator bündelt Ereignisverläufe in Daily, hält Schlussfolgerungen in Projekt- und Themenseiten fest und entfernt erledigte Punkte aus Inbox. Wiederholtes oder beiläufiges Browsen muss keine neue dauerhafte Notiz erzeugen.

Bei neu aufbereiteten Seiten enthält `source_ids` die tatsächlichen IDs der im Text zitierten Aufnahmen. Referenzaufnahmen des Pakets stehen getrennt in `context_source_ids`; sie belegen nicht jede Aussage. Die MCP-Suchergebnisse führen die zitierten Quell-IDs ihrer Absätze, und `memory_get` fasst die Aufnahmen hinter einer Seite zusammen (Anzahl, Zeitspanne, Apps). Vorhandene Notizen bleiben lesbar und übernehmen diese Regeln bei erneuter Aufbereitung. Ein Upgrade schreibt sie nicht gesammelt um.

Die Suche in App und MCP verwendet dieselbe SQLite-FTS5-Rangfolge. Suchwörter dürfen mit beliebigen Einzelbegriffen übereinstimmen; zuerst zählen exakte Titel und hinterlegte Aliasse, danach eine Mischung aus den am besten passenden Absätzen jeder Notiz und notizweitem BM25, dann die Dateiänderungszeit. Die Bewertung nach Absätzen verhindert, dass lange Notizen den Absatz überdecken, der die Frage tatsächlich beantwortet. Wörtliche Teilzeichenfolgen bleiben für Chinesisch und Satzzeichen verfügbar. Eine leere Suche zeigt zuletzt bearbeitete Notizen.

MCP bietet zwei reine Lesewerkzeuge. `memory_search` nimmt `query` (die Frage oder Suchwörter) sowie optional `since`, `until`, `app` und `limit` (Standard 10) entgegen und liefert eingestufte Ergebnisse mit `path`, `title`, einem kurzen `snippet` (bis zu zwei passenden Absätzen mit höchstens 300 Zeichen je Absatz), `time`, den zitierten `sourceIDs` der Absätze und den Quell-`apps`. `memory_get` nimmt einen `path` aus diesen Ergebnissen entgegen, optional mit `#heading` für einen einzelnen Abschnitt, sowie `from`/`lines` für Zeilenbereiche; es liefert die Markdown-Zeilen, die Links der Seite gruppiert nach Überschrift, ihre Rückverweise (neueste zuerst, jeweils mit der Zeile, die den Link enthält, und deren Datum) sowie eine Zusammenfassung der Aufnahmen hinter der Seite. Unbekannte Argumente werden abgelehnt statt ignoriert.

Die Suche folgt Wikilinks. Die stärksten Treffer sowie beide Enden von Links, deren Zeile zur Frage passt, bilden die Startpunkte für eine zweistufige Ausbreitung über den Link-Graphen: einen Schritt von jedem Startpunkt aus und einen zweiten Schritt nur über Entitätsseiten (eine Daily-Notiz → eine Personen- oder Themenseite → eine weitere Daily-Notiz). Jeder Link wird danach gewichtet, wie gut seine Zeile zur Frage passt, und gedämpft nach der Anzahl der Links auf der Zielseite, damit Knotenpunkte wie `Now.md` die Ergebnisse nicht überfluten; Root-Dateien und `Wiki/Archives` bleiben außen vor. So erreichte Seiten werden zusammen mit direkten Treffern eingestuft und tragen `via`: ein oder zwei Schritte, jeweils mit der Seite, die den Link enthält, ihrer Überschrift, der Zeile selbst und deren Datum. Links zeigen eine Verbindung, beweisen aber keinen sachlichen Zusammenhang.

`time` sowie die Filter `since`/`until` beschreiben, wann der Inhalt geschah: ein annotiertes Ereignis am Absatz, sonst eine zitierte Aufnahme, sonst die Dateiänderungszeit. `since` ist inklusiv und `until` exklusiv; beide akzeptieren ISO-8601-Zeitstempel. Mit `app` müssen Notizen mit Ereignissen über einen Ereignisabsatz passen, der zusätzlich eine Aufnahme dieser App zitiert; Notizen ohne Ereignisse benötigen eine zitierte Aufnahme, die sowohl den Zeitraum als auch die App erfüllt. Unbekannte Ereignisdaten werden nie durch Aufnahme- oder Bearbeitungsdaten ersetzt. Datierte Seiten ohne Zeitraum bevorzugen leicht aktuellere Tage.

Ereignisannotationen werden direkt vor ihrem Absatz als HTML-Kommentar ohne Leerzeile gespeichert. Sie bleiben beim Kopieren von Markdown und beim Neuaufbau des Index erhalten. Beispiel:

```markdown
<!-- myclip-event {"start":"2026-09-10T00:00:00+08:00","end":"2026-09-11T00:00:00+08:00","precision":"day","evidence":"2026-09-10"} -->
Am 2026-09-10 endete das Kundengespräch. Quelle: Aufnahme `REPLACE_WITH_ACTUAL_SOURCE_UUID`.
```

Verwende tatsächliche Belege und eine wirklich zitierte Aufnahme-ID. Unterstützt werden `day` für einen lokalen Kalendertag, `range` für ein explizites Intervall mit exklusivem Ende und `instant` für einen Zeitpunkt, dessen Ende fehlt oder dem Beginn entspricht. Zeitstempel benötigen einen expliziten UTC-Offset. Die Suche gibt den Ereignisbeginn als `time` des Ergebnisses an; das dokumentiert die Aussage der Notiz, keine unabhängige Überprüfung der Quelle. Ungültige Daten, widersprüchliche Annotationen, Annotationen in Codebeispielen, fehlende Quellenzitate im Absatz oder ein dort nicht vorkommender `evidence`-Ausdruck erzeugen keine indizierten Ereigniszeiten. Relative Datumsangaben setzen Zeitpunkt und Zeitzone der ursprünglichen Nachricht voraus; der Organisator muss die Originalformulierung behalten und die Umrechnung erklären. Aufnahme- und Bearbeitungszeit ersetzen niemals ein fehlendes Ereignisdatum. Bestehende Notizen bleiben ohne Annotationen durchsuchbar und erhalten diese beim Aufbereiten relevanter Quellen. Ein Upgrade erfindet oder verändert keine Ereignisdaten.

Passagen-, Ereignis- und Link-Indizes sind abgeleitete SQLite-Daten. Sie werden bei Änderungen aktualisiert, zusammen mit der Notiz gelöscht und für ältere Bibliotheken neu aufgebaut, ohne Markdown zu verändern. Für Fragen, die mehr als zwei Schritte benötigen, liest ein Agent eine Seite mit `memory_get` und folgt den dort aufgeführten Links oder Rückverweisen.

Temporäre Sitzungen lassen sich nicht in Codex oder Claude erneut öffnen. Prüfe stattdessen die Ausführungsdetails in MyClip. Jeder Eintrag zeigt auch die Anzahl der Bild- und Texteingaben. Diese Einstellungen verhindern fortsetzbare lokale Agent-Unterhaltungen, legen aber nicht fest, wie lange der Modellanbieter Daten auf seinen Servern speichert.

Klicke in **Backstage** auf einen Aufbereitungseintrag, um jede Anfrage einschließlich Wiederholungen zu prüfen: Werkzeugaufrufe, Befehlsargumente, Ergebnisse, Dateipfade und Änderungen, Agent-Antworten, Ein- und Ausgabe-Tokens, Cache-Lese- und Schreibvorgänge sowie gemeldete Kosten. Werkzeugprotokolle werden während der Ausführung gespeichert und bleiben nach Abbruch oder Neustart erhalten. Kosten ergeben sich aus der Differenz gemeldeter kumulierter Sitzungsbeträge. Fehlen Meldungen oder ist der Ausgangswert unbekannt, bleiben auch die Kosten unbekannt. Ältere Einträge behalten ihre Token-Summen; nie gespeicherte Werkzeugdetails lassen sich jedoch nicht wiederherstellen.

## Datenschutz und Kontrolle

- **Wähle, was erfasst wird.** Die Einstellungen enthalten drei Bereiche: Umfang (standardmäßig das aktive Fenster oder dessen Bildschirm), unabhängige Maus-Auslöser (Stillstand und anschließender Klick sowie Scrollen und anschließende Pause) und Tastatur-Auslöser (standardmäßig Buchstaben gefolgt von Eingabe oder jede Eingabetaste). Die Erfassung läuft, solange MyClip geöffnet ist; beende die App, um sie zu stoppen. Bestimmte Apps können ausgeschlossen werden, auch bei Aufnahmen des gesamten Bildschirms.
- **Behalte deine Bibliothek lokal.** Aufnahmen und Notizen liegen auf deinem Mac. Originalaufnahmen laufen standardmäßig nach 30 Tagen ab, gespeicherte Notizen bleiben erhalten. Die Aufbewahrungsdauer lässt sich in den Einstellungen ändern.
- **Entscheide, wann KI verwendet wird.** Die Aufbereitung nutzt den Modelldienst des ausgewählten Agents, der Aufnahmen und Notizen möglicherweise in der Cloud verarbeitet. Deaktiviere die automatische Aufbereitung, damit neue Aufnahmen lokal bleiben, bis du ihre Verarbeitung auswählst.

<details>
<summary>Aus dem Quellcode bauen</summary>

Benötigt Xcode 26, Swift 6.2 und XcodeGen.

```sh
xcodegen generate
bash Scripts/test.sh
xcodebuild -project MyClip.xcodeproj -scheme MyClip -configuration Debug build
```

Mit `Scripts/package_dmg.sh` erstellst du ein DMG. Die Ausgabedatei heißt `dist/MyClip-<version>.dmg`.

Für getrennte Pakete für Apple Silicon und Intel führen Sie `MYCLIP_ARCH=arm64 bash Scripts/package_dmg.sh` oder `MYCLIP_ARCH=x86_64 bash Scripts/package_dmg.sh` aus. Die Dateinamen enden entsprechend auf `-arm64.dmg` und `-x86_64.dmg`. Ein Push des Tags `v<version>` startet Tests und Paketierung beider Architekturen in GitHub Actions. Anschließend wird ein Release mit beiden DMGs und `SHA256SUMS` veröffentlicht. Der Tag muss zu `CFBundleShortVersionString` passen; die Release-Notizen liegen unter `docs/releases/v<version>.md`.

</details>
