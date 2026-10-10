<div align="center">
  <img src="../MyClip/Assets.xcassets/AppIcon.appiconset/icon_256x256.png" alt="MyClip-Symbol" width="120" height="120">
  <h1 align="center">MyClip</h1>
  <p align="center">MyClip hilft dir, den Überblick über deine Arbeit zu behalten. Die App erfasst das aktive Fenster oder dessen Bildschirm auf deinem Mac und verwandelt die Aufnahmen mit Codex oder Claude in durchsuchbare Notizen, verknüpftes Wissen und Aufgabenvorschläge.</p>
</div>

<p align="center">
  <a href="../README.md">English</a> · <a href="README.zh-CN.md">简体中文</a> · <a href="README.es.md">Español</a> · <a href="README.fr.md">Français</a> · <strong>Deutsch</strong> · <a href="README.ja.md">日本語</a> · <a href="README.ko.md">한국어</a>
</p>

[Für macOS herunterladen](https://github.com/section9-lab/MyClip/releases) (Apple Silicon / Intel). Erfordert macOS 13+, ein Codex- oder Claude-Konto und Node.js 22+ für den Agent-Connector. [Selbstsignierte Builds öffnen](release-signing.md).

<p align="center">
  <a href="https://section9-lab.github.io/MyClip/demo/"><img src="images/myclip-demo.gif" alt="MyClip-Demo: Einrichtung, Memory, Timeline, Kanban, Reports, Backstage, Einstellungen und Erinnerungsabruf in Codex und Claude" width="1000"></a>
</p>
<p align="center"><a href="https://section9-lab.github.io/MyClip/demo/">HD-Video ansehen</a> · <a href="images/myclip-demo.mp4">MP4 herunterladen</a></p>
<p align="center"><sub>45-sekündige HTML-Demo · Beispieldaten · Chinesische Oberfläche.</sub></p>

## Was du damit machen kannst

- **Deine Arbeit wiederfinden.** Durchsuche die Aufnahmechronik und prüfe die Quellen deiner Notizen. Zu jeder Aufnahme gehört ein lokales OCR-Textdokument, das du lesen, kopieren oder öffnen kannst.
- **Eine persönliche Wissensbibliothek aufbauen.** Suche, bearbeite und verknüpfe Notizen zu Projekten, Themen und deinem Arbeitsalltag. Sie liegen als Markdown-Dateien vor und lassen sich auch in anderen Editoren öffnen.
- **Nächste Schritte verfolgen.** Prüfe vorgeschlagene Aufgaben, bestätige Wichtiges und verfolge den Fortschritt auf einem Board. Wechsle zwischen **Kanban** und **Reports**, um Tages-, Wochen- oder Monatsberichte nach Projekt und Fortschritt zu lesen.
- **Deinen KI-Werkzeugen Kontext geben.** Lass Codex, Claude Code, Claude Desktop, Cursor oder OpenCode deine gespeicherten Erinnerungen durchsuchen.

## Datenschutz und Kontrolle

- **Wähle, was erfasst wird.** Die Einstellungen enthalten drei Bereiche: Umfang (standardmäßig das aktive Fenster oder dessen Bildschirm), unabhängige Maus-Auslöser (Klick innerhalb von 5 Sekunden nach Mausbewegung sowie 3 Sekunden Pause nach dem Scrollen nach unten) und Tastatur-Auslöser (standardmäßig Buchstaben gefolgt von Eingabe oder jede Eingabetaste). Die Erfassung läuft, solange MyClip geöffnet ist; beende die App, um sie zu stoppen. Bestimmte Apps können ausgeschlossen werden, auch bei Aufnahmen des gesamten Bildschirms.
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
