<div align="center">
  <img src="../MyClip/Assets.xcassets/AppIcon.appiconset/icon_256x256.png" alt="Icono de MyClip" width="120" height="120">
  <h1 align="center">MyClip</h1>
  <p align="center">MyClip te ayuda a recordar en qué estabas trabajando. Captura la ventana activa o la pantalla que la contiene en tu Mac y utiliza Codex o Claude para convertir las capturas en notas que puedes buscar, conocimiento conectado y sugerencias de tareas.</p>
</div>

<p align="center">
  <a href="../README.md">English</a> · <a href="README.zh-CN.md">简体中文</a> · <strong>Español</strong> · <a href="README.fr.md">Français</a> · <a href="README.de.md">Deutsch</a> · <a href="README.ja.md">日本語</a> · <a href="README.ko.md">한국어</a>
</p>

[Descargar para macOS](https://github.com/section9-lab/MyClip/releases) (Apple Silicon / Intel). Requiere macOS 13+, una cuenta de Codex o Claude y Node.js 22+ para el conector del agente. [Abrir versiones autofirmadas](release-signing.md).

<p align="center">
  <a href="https://section9-lab.github.io/MyClip/demo/"><img src="images/myclip-demo.gif" alt="Demo de MyClip: configuración inicial, Memory, Timeline, Kanban, Reports, Backstage, ajustes y recuperación de recuerdos con Codex y Claude" width="1000"></a>
</p>
<p align="center"><a href="https://section9-lab.github.io/MyClip/demo/">Ver en alta definición</a> · <a href="images/myclip-demo.mp4">Descargar MP4</a></p>
<p align="center"><sub>Demo HTML de 45 segundos · Datos de ejemplo · Interfaz en chino.</sub></p>

## Qué puedes hacer

- **Retomar tu trabajo.** Explora la cronología de capturas y consulta las fuentes de tus notas. Cada captura tiene un documento OCR local que puedes leer, copiar o abrir.
- **Crear una biblioteca de conocimiento personal.** Busca, edita y enlaza notas de proyectos, temas y trabajo diario. Son archivos Markdown que también puedes abrir con otros editores.
- **Seguir los próximos pasos.** Revisa las tareas sugeridas, confirma las importantes y sigue su progreso en un tablero. Alterna entre **Kanban** y **Reports** para consultar informes diarios, semanales o mensuales organizados por proyecto y progreso.
- **Dar contexto a tus herramientas de IA.** Permite que Codex, Claude Code, Claude Desktop, Cursor u OpenCode busquen en tus recuerdos guardados.

## Privacidad y control

- **Elige qué capturar.** Ajustes agrupa la captura en tres controles: ámbito (ventana activa por defecto o pantalla que la contiene), disparadores independientes del ratón (clic dentro de los 5 s tras mover el ratón y pausa de 3 s tras desplazarse hacia abajo) y disparador del teclado (letras seguidas de Intro por defecto, o cada Intro). La captura funciona mientras MyClip está abierto; sal de la aplicación para detenerla. Puedes excluir aplicaciones concretas, también en la captura de pantalla completa.
- **Conserva tu biblioteca localmente.** Las capturas y notas se almacenan en tu Mac. Las imágenes originales caducan a los 30 días por defecto; las notas guardadas permanecen. Puedes cambiar ese período en Ajustes.
- **Decide cuándo usar IA.** La organización utiliza el servicio del modelo del agente seleccionado, que puede procesar capturas y notas en la nube. Desactiva la organización automática para mantener las nuevas capturas localmente hasta que decidas procesarlas.

<details>
<summary>Compilar desde el código fuente</summary>

Requiere Xcode 26, Swift 6.2 y XcodeGen.

```sh
xcodegen generate
bash Scripts/test.sh
xcodebuild -project MyClip.xcodeproj -scheme MyClip -configuration Debug build
```

Para crear un DMG, ejecuta `Scripts/package_dmg.sh`. Se genera `dist/MyClip-<version>.dmg`.

Para generar paquetes separados para Apple Silicon e Intel, ejecuta `MYCLIP_ARCH=arm64 bash Scripts/package_dmg.sh` o `MYCLIP_ARCH=x86_64 bash Scripts/package_dmg.sh`. Los nombres terminan en `-arm64.dmg` y `-x86_64.dmg`, respectivamente. Al enviar una etiqueta `v<version>`, GitHub Actions prueba y empaqueta ambas arquitecturas y publica una versión con los dos DMG y `SHA256SUMS`. La etiqueta debe coincidir con `CFBundleShortVersionString`; las notas se guardan en `docs/releases/v<version>.md`.

</details>
