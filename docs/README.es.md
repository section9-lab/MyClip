<div align="center">
  <img src="../MyClip/Assets.xcassets/AppIcon.appiconset/icon_256x256.png" alt="Icono de MyClip" width="120" height="120">
  <h1 align="center">MyClip</h1>
  <p align="center">MyClip te ayuda a recordar en qué estabas trabajando. Captura la ventana activa o la pantalla que la contiene en tu Mac y utiliza Codex o Claude para convertir las capturas en notas que puedes buscar, conocimiento conectado y sugerencias de tareas.</p>
</div>

<p align="center">
  <a href="../README.md">English</a> · <a href="README.zh-CN.md">简体中文</a> · <strong>Español</strong> · <a href="README.fr.md">Français</a> · <a href="README.de.md">Deutsch</a> · <a href="README.ja.md">日本語</a> · <a href="README.ko.md">한국어</a>
</p>

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

## Primeros pasos

Necesitas **macOS 13 o posterior** y una **cuenta de Codex o Claude**. Instalar el conector del agente también requiere **Node.js 22 o posterior**. Más abajo encontrarás las instrucciones de compilación local.

1. Abre MyClip y entra en **Backstage** desde la barra lateral. Instala un conector, inicia sesión y pulsa **Connect** para comprobar que está disponible. Después pulsa **Enable** para utilizar ese agente en la organización. Conectarlo no inicia tareas; puedes conectar varios agentes, pero solo activar uno a la vez.
2. Concede los permisos de **grabación de pantalla** y **accesibilidad**. La captura comienza automáticamente mientras MyClip está abierto, también después de conceder los permisos.
3. Trabaja con normalidad. Por defecto, MyClip captura la ventana activa al hacer clic después de mantener el puntero quieto un segundo, tras dos segundos sin desplazamiento vertical o al pulsar una letra y después Intro. La organización automática convierte las nuevas capturas en Memory.
4. Consulta las notas en **Memory**, las capturas en **Timeline** y el trabajo sugerido en **Kanban**.

Para usar tu memoria desde una herramienta de IA, activa **MyClip MCP** en Ajustes, selecciona los clientes y aplica la configuración. Después reinicia el cliente o abre una sesión nueva.

**Claude Code (CLI)** organiza las capturas en segundo plano mediante ACP. **Claude Desktop** tiene una entrada independiente para abrir la aplicación y configurar el acceso MCP a la memoria en Chat y en las sesiones locales de Code; no se puede activar para organizar capturas en segundo plano. La configuración de escritorio se guarda en `~/Library/Application Support/Claude/claude_desktop_config.json`, conserva los servidores existentes y no modifica la configuración de la CLI. Cierra completamente Claude Desktop y vuelve a abrirlo después de configurarlo.

## Documentos de texto de las capturas

MyClip extrae texto en chino e inglés en el dispositivo con Apple Vision, independientemente de la organización con IA. En los detalles de una captura, selecciona **OCR 文档** para leer o copiar el texto, o **打开文档** para abrir el archivo UTF-8 `.txt` guardado junto a la imagen original. Las capturas repetidas comparten una imagen y un documento de texto. Las imágenes sin texto reconocible reciben un documento vacío; los fallos de reconocimiento se pueden reintentar.

Las capturas existentes se procesan en segundo plano al iniciar la aplicación. Los documentos OCR y su índice de búsqueda caducan junto con las imágenes originales según el período de conservación. Las notas de Memory guardadas se mantienen. La aplicación admite macOS 13 y posteriores, incluido macOS 27; en macOS 13 utiliza un flujo de un solo fotograma de ScreenCaptureKit con las mismas exclusiones de aplicaciones que en los sistemas más recientes.

## Organización de capturas

Las capturas entran en una cola persistente en cuanto se guardan. La organización automática espera tres minutos desde la captura pendiente más antigua y después forma un lote cronológico para el mismo agente: hasta **8 imágenes y 32 registros OCR**, con un máximo de **12.000 caracteres OCR** en total. Las capturas manuales y las activadas con Intro usan imágenes; las de clic, desplazamiento y los antiguos eventos del puntero usan OCR local. El OCR que falte se genera antes del envío. Si está vacío, ha fallado o un registro supera el límite individual, se usa la imagen original y se contabiliza dentro del límite de imágenes. El lote termina antes del primer registro que excedería un límite, sin saltárselo. Las nuevas capturas no reinician el temporizador. Solo se ejecuta un lote a la vez, con al menos tres minutos entre sus inicios.

**Backstage** muestra las capturas pendientes, la cuenta atrás y el lote actual. **Organize Now** permite iniciar un lote antes de tiempo. Un fallo o una interrupción pausa el procesamiento automático hasta que lo reintentes o lo reanudes; las capturas y los archivos de Memory existentes se conservan. Los modos de entrada y el contenido OCR quedan fijados al crear el lote, incluso durante reintentos y reinicios. **按图片重新整理**, en los detalles de una captura, envía expresamente la imagen original, útil para gráficos o diseños que el OCR no conserva. Al activar otro agente se reasignan las capturas pendientes de organización automática. Los lotes en ejecución terminan con su agente original. Los trabajos existentes y sus reintentos también conservan el agente original y esperan a que vuelva a activarse.

Cada lote utiliza una sesión temporal independiente. Claude recibe `persistSession: false`; el proxy app-server de MyClip para Codex exige `ephemeral: true` y rechaza un backend que no lo confirme. El proceso del agente se cierra al finalizar cada ejecución. Las conversaciones guardadas anteriormente no se reanudan ni se eliminan. El lote siguiente recibe las reglas fijas de organización, únicamente el traspaso del último lote completado correctamente (hasta 4 KiB), las entradas actuales con fecha y hora e identificadores de origen, los metadatos de aplicación, ventana y disparador, y el contexto de tareas existentes. Los archivos de Memory relacionados se leen cuando hacen falta. El traspaso registra cambios de archivos guardados e identificadores de origen, excluye el historial de conversación y el contenido de Memory, y solo se sustituye cuando la publicación de Memory finaliza correctamente. Los reintentos tras un fallo empiezan desde cero e inspeccionan los archivos actuales.

Sin un agente activado, las capturas permanecen en la cola. Desactivar un agente detiene las tareas nuevas, pero permite terminar la que está en curso. MyClip recuerda el agente activado y lo reconecta al iniciarse. Las antiguas preferencias de agente predeterminado no lo activan automáticamente: debes activarlo expresamente después de actualizar.

MyClip inicia todas las sesiones de organización y detección de tareas con **acceso completo**: `agent-full-access` para Codex y `bypassPermissions` para Claude Code. El acceso a archivos, las ediciones, los comandos, el acceso a la red y las llamadas a herramientas MCP se realizan sin tarjetas de confirmación por operación. Las solicitudes de permiso restantes se gestionan automáticamente para la sesión activa; las tareas canceladas rechazan las solicitudes tardías. La actividad de las herramientas sigue disponible en el registro de ejecución.

**Backstage** contabiliza el consumo de tokens comunicado para la organización, la detección de tareas y los reintentos, con totales por agente y lote. El consumo se guarda localmente al terminar cada solicitud; los datos antiguos o no comunicados aparecen como no disponibles, no como cero. La ocupación de la ventana de contexto no cuenta como consumo. Los lotes activos muestran su fase, el tiempo transcurrido y el tiempo desde la última actualización de progreso. Claude ACP utiliza el inicio de sesión y la configuración de red existentes de Claude Code, por lo que un proxy local configurado debe estar en funcionamiento.

La organización se detiene después de cinco minutos sin nuevo razonamiento, texto de respuesta, actividad de herramientas o solicitudes de permisos en la sesión actual. Un lote puede continuar mientras avance, hasta un máximo total de quince minutos. Las actualizaciones que solo informan del consumo y la actividad de otras sesiones no prolongan el tiempo de espera.

Memory distingue la hora de observación de la captura (`observed_at`) de la fecha de actualización del archivo (`updated_at`). Now muestra cuándo se capturaron sus fuentes; las fuentes antiguas no pueden reemplazar una página Now más reciente. Si falta la hora de observación, permanece desconocida. El organizador consolida los eventos en Daily, guarda las conclusiones en páginas de proyectos o temas y retira de Inbox los asuntos resueltos. La navegación repetida o incidental no exige crear una nota permanente.

En las páginas recién organizadas, `source_ids` contiene los identificadores reales de las capturas citadas en el texto. Las capturas de referencia del lote se conservan por separado en `context_source_ids`; no respaldan todas las afirmaciones. Los resultados de búsqueda de MCP incluyen los identificadores de origen citados de sus párrafos, y `memory_get` resume las capturas detrás de una página (cantidad, intervalo de tiempo, aplicaciones). Las notas existentes siguen siendo legibles y adoptan estas reglas cuando se vuelven a organizar; la actualización no las reescribe en masa.

La búsqueda de la aplicación y MCP utiliza la misma clasificación de SQLite FTS5. Las palabras clave pueden coincidir con cualquier término; primero los títulos exactos y los alias declarados, luego una combinación de los párrafos que mejor coinciden en cada nota y el BM25 de la nota completa, y por último la fecha de modificación del archivo. Puntuar por párrafos evita que las notas largas superen al párrafo que realmente responde la pregunta. Se mantiene la coincidencia literal de subcadenas para el chino y la puntuación. Una consulta vacía lista las notas editadas recientemente.

MCP ofrece dos herramientas de solo lectura. `memory_search` recibe `query` (la pregunta o palabras clave) más, opcionalmente, `since`, `until`, `app` y `limit` (10 por defecto), y devuelve resultados clasificados con `path`, `title`, un `snippet` breve (hasta dos párrafos coincidentes de 300 caracteres como máximo cada uno), `time`, los `sourceIDs` citados de los párrafos y las `apps` de origen. `memory_get` recibe un `path` de esos resultados, opcionalmente con `#heading` para leer una sección, y `from`/`lines` para rangos de líneas; devuelve las líneas en Markdown, los enlaces de la página agrupados por encabezado, sus retroenlaces (los más recientes primero, cada uno con la línea que contiene el enlace y su fecha) y un resumen de las capturas detrás de la página. Los argumentos desconocidos se rechazan en lugar de ignorarse.

La búsqueda sigue los Wikilinks. Las coincidencias más fuertes, junto con ambos extremos de los enlaces cuya línea coincide con la pregunta, sirven de semilla para una expansión de dos pasos por el grafo de enlaces: un salto desde cada semilla y un segundo salto solo a través de páginas de entidad (una nota Daily → una página de persona o tema → otra nota Daily). Cada enlace se pondera según cuánto coincide su línea con la pregunta y se amortigua según el número de enlaces que tiene la página de destino, de modo que páginas centrales como `Now.md` no inunden los resultados; los archivos raíz y `Wiki/Archives` quedan excluidos. Las páginas alcanzadas así se clasifican junto con las coincidencias directas y llevan `via`: uno o dos saltos, cada uno con la página que contiene el enlace, su encabezado, la línea misma y su fecha. Los enlaces indican asociación, no prueban una relación factual.

`time` y los filtros `since`/`until` describen cuándo ocurrió el contenido: un evento anotado en el párrafo, si no, una captura citada, y si no, la fecha de edición del archivo. `since` es inclusivo y `until` exclusivo; ambos aceptan marcas temporales ISO 8601. Con `app`, las notas con eventos coinciden mediante un párrafo de evento que también cite una captura de esa aplicación, y las notas sin eventos necesitan una captura citada que cumpla tanto el rango como la aplicación. Las fechas de eventos desconocidas nunca se sustituyen por fechas de captura o edición. Las páginas fechadas sin un rango favorecen ligeramente los días recientes.

Las anotaciones de eventos se guardan como comentarios HTML justo antes del párrafo, sin una línea en blanco. Se conservan al copiar Markdown y reconstruir el índice. Ejemplo:

```markdown
<!-- myclip-event {"start":"2026-09-10T00:00:00+08:00","end":"2026-09-11T00:00:00+08:00","precision":"day","evidence":"2026-09-10"} -->
El 2026-09-10 finalizó la reunión con el cliente. Fuente: captura `REPLACE_WITH_ACTUAL_SOURCE_UUID`.
```

Utiliza evidencia real y el identificador de una captura citada. Las precisiones admitidas son `day` (día del calendario local), `range` (intervalo explícito con final exclusivo) e `instant` (final omitido o igual al inicio). Las marcas temporales deben incluir un desplazamiento UTC explícito. La búsqueda informa el inicio del evento como el `time` del resultado: refleja lo afirmado por la nota, no una verificación independiente de la fuente. Las fechas inválidas, las anotaciones contradictorias o incluidas en ejemplos de código, la ausencia de citas en el párrafo o una expresión `evidence` que no aparezca en él no generan fechas de eventos indexadas. Las fechas relativas requieren conocer la hora y la zona horaria del mensaje original; el organizador debe conservar la expresión y explicar la conversión. Las fechas de captura y edición nunca completan una fecha de evento ausente. Las notas existentes se pueden buscar sin anotaciones y las reciben cuando se organiza evidencia relevante; la actualización no inventa ni reescribe sus fechas.

Los índices de pasajes, eventos y enlaces son datos derivados de SQLite. Se actualizan al editar, se eliminan con la nota y se reconstruyen para bibliotecas antiguas sin modificar Markdown. Para preguntas que necesitan más de dos saltos, el agente lee una página con `memory_get` y sigue los enlaces o retroenlaces que esta indica.

Las sesiones temporales no se pueden volver a abrir en Codex o Claude. Consulta sus detalles de ejecución en MyClip; cada registro también muestra cuántas imágenes y textos recibió. Estas opciones evitan conversaciones locales reanudables, pero no determinan la conservación de datos en los servidores del proveedor del modelo.

Pulsa un registro de organización en **Backstage** para inspeccionar cada solicitud, incluidos los reintentos: llamadas a herramientas, argumentos, resultados, ubicaciones y ediciones de archivos, respuestas del agente, tokens de entrada y salida, lecturas y escrituras de caché y coste comunicado. Los registros de herramientas se guardan durante la ejecución y siguen disponibles tras cancelar o reiniciar. El coste se calcula mediante la diferencia entre los importes acumulados comunicados por la sesión; si falta un informe o se desconoce el importe inicial, el coste permanece desconocido. Los registros antiguos conservan sus totales de tokens, pero no pueden recuperar detalles de herramientas que nunca se guardaron.

## Privacidad y control

- **Elige qué capturar.** Ajustes agrupa la captura en tres controles: ámbito (ventana activa por defecto o pantalla que la contiene), disparadores independientes del ratón (reposo seguido de clic y desplazamiento seguido de pausa) y disparador del teclado (letras seguidas de Intro por defecto, o cada Intro). La captura funciona mientras MyClip está abierto; sal de la aplicación para detenerla. Puedes excluir aplicaciones concretas, también en la captura de pantalla completa.
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
