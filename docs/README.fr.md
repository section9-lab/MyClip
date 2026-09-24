<div align="center">
  <img src="../MyClip/Assets.xcassets/AppIcon.appiconset/icon_256x256.png" alt="Icône de MyClip" width="120" height="120">
  <h1 align="center">MyClip</h1>
  <p align="center">MyClip vous aide à retrouver le fil de votre travail. Il capture la fenêtre active ou l’écran qui la contient sur votre Mac et utilise Codex ou Claude pour transformer les captures en notes consultables, en connaissances reliées et en suggestions de tâches.</p>
</div>

<p align="center">
  <a href="../README.md">English</a> · <a href="README.zh-CN.md">简体中文</a> · <a href="README.es.md">Español</a> · <strong>Français</strong> · <a href="README.de.md">Deutsch</a> · <a href="README.ja.md">日本語</a> · <a href="README.ko.md">한국어</a>
</p>

<p align="center">
  <a href="https://section9-lab.github.io/MyClip/demo/"><img src="images/myclip-demo.gif" alt="Démo de MyClip : configuration initiale, Memory, Timeline, Kanban, Reports, Backstage, réglages et rappel de mémoire avec Codex et Claude" width="1000"></a>
</p>
<p align="center"><a href="https://section9-lab.github.io/MyClip/demo/">Voir en haute définition</a> · <a href="images/myclip-demo.mp4">Télécharger le MP4</a></p>
<p align="center"><sub>Démo HTML de 45 secondes · Données d’exemple · Interface en chinois.</sub></p>

## Ce que vous pouvez faire

- **Retrouver votre travail.** Parcourez la chronologie des captures et consultez les sources de vos notes. Chaque capture possède un document OCR local à lire, copier ou ouvrir.
- **Constituer une bibliothèque personnelle.** Recherchez, modifiez et reliez les notes de vos projets, sujets et activités quotidiennes. Ce sont des fichiers Markdown, également lisibles dans d’autres éditeurs.
- **Suivre les prochaines étapes.** Examinez les tâches proposées, confirmez celles qui comptent et suivez leur avancement sur un tableau. Passez de **Kanban** à **Reports** pour consulter des rapports quotidiens, hebdomadaires ou mensuels organisés par projet et par avancement.
- **Donner du contexte à vos outils d’IA.** Autorisez Codex, Claude Code, Claude Desktop, Cursor ou OpenCode à rechercher dans vos souvenirs enregistrés.

## Prise en main

Nécessite **macOS 13 ou une version ultérieure** et un **compte Codex ou Claude**. L’installation du connecteur d’agent nécessite aussi **Node.js 22 ou une version ultérieure**. Les instructions de compilation locale figurent ci-dessous.

1. Ouvrez MyClip et accédez à **Backstage** dans la barre latérale. Installez un connecteur, connectez-vous à votre compte, puis cliquez sur **Connect** pour vérifier sa disponibilité. Cliquez ensuite sur **Enable** pour utiliser cet agent pour l’organisation. La connexion seule ne lance aucune tâche ; plusieurs agents peuvent être connectés, mais un seul peut être activé à la fois.
2. Accordez les autorisations d’**enregistrement de l’écran** et d’**accessibilité**. La capture démarre automatiquement lorsque MyClip est ouvert, y compris après l’octroi des autorisations.
3. Travaillez normalement. Par défaut, MyClip capture la fenêtre active après un clic suivant une seconde d’immobilité du pointeur, après deux secondes sans défilement vertical, ou après une lettre suivie d’Entrée. L’organisation automatique transforme les nouvelles captures en Memory.
4. Consultez les notes dans **Memory**, les captures dans **Timeline** et les tâches proposées dans **Kanban**.

Pour utiliser votre mémoire dans un outil d’IA, activez **MyClip MCP** dans les réglages, choisissez vos clients et appliquez la configuration. Redémarrez ensuite le client ou ouvrez une nouvelle session.

**Claude Code (CLI)** organise les captures en arrière-plan via ACP. **Claude Desktop** dispose d’une entrée distincte pour ouvrir l’application et configurer l’accès MCP à la mémoire dans Chat et les sessions Code locales ; il ne peut pas être activé pour l’organisation en arrière-plan. Sa configuration est enregistrée dans `~/Library/Application Support/Claude/claude_desktop_config.json`, en préservant les serveurs existants et sans modifier la configuration CLI. Quittez complètement Claude Desktop puis relancez-le après la configuration.

## Documents texte des captures

MyClip extrait le texte chinois et anglais sur l’appareil avec Apple Vision, indépendamment de l’organisation par IA. Dans le détail d’une capture, choisissez **OCR 文档** pour lire ou copier son texte, ou **打开文档** pour ouvrir le fichier UTF-8 `.txt` enregistré à côté de l’image originale. Les captures identiques partagent une image et un document texte. Une capture sans texte lisible reçoit un document vide ; les échecs de reconnaissance peuvent être réessayés.

Les captures existantes sont traitées en arrière-plan au démarrage. Les documents OCR et leur index de recherche expirent avec les images originales selon la durée de conservation choisie. Les notes Memory enregistrées sont conservées. L’application prend en charge macOS 13 et les versions ultérieures, dont macOS 27 ; macOS 13 utilise un flux ScreenCaptureKit d’une seule image avec les mêmes exclusions d’applications que les systèmes plus récents.

## Organisation des captures

Les captures rejoignent une file persistante dès leur enregistrement. L’organisation automatique attend trois minutes à partir de la capture en attente la plus ancienne, puis constitue un lot chronologique destiné au même agent : au maximum **8 images et 32 enregistrements OCR**, pour **12 000 caractères OCR** au total. Les captures manuelles et celles déclenchées par Entrée utilisent les images ; celles issues de clics, de défilements et des anciens déclencheurs du pointeur utilisent l’OCR local. L’OCR manquant est généré avant l’envoi. Un résultat vide, en échec ou trop long individuellement est remplacé par l’image originale, comptée dans la limite d’images. Le lot s’arrête avant le premier enregistrement qui dépasserait une limite, sans l’ignorer. Les nouvelles captures ne réinitialisent pas le délai. Un seul lot s’exécute à la fois, avec au moins trois minutes entre deux démarrages.

**Backstage** affiche le nombre d’éléments en attente, le compte à rebours et le lot actuel. **Organize Now** lance un lot plus tôt. Un échec ou une interruption suspend le traitement automatique jusqu’à une nouvelle tentative ou une reprise ; les captures et les fichiers Memory existants sont conservés. Les modes d’entrée et le contenu OCR sont figés à la création du lot, y compris lors des nouvelles tentatives et des redémarrages. **按图片重新整理**, dans le détail d’une capture, envoie explicitement l’image originale, utile pour les graphiques et mises en page que l’OCR ne restitue pas. Activer un autre agent réattribue les captures en attente d’organisation automatique. Les lots en cours se terminent avec leur agent initial. Les tâches existantes et leurs nouvelles tentatives conservent également cet agent et attendent sa réactivation.

Chaque lot utilise une session temporaire indépendante. Claude reçoit `persistSession: false` ; le proxy app-server de MyClip pour Codex impose `ephemeral: true` et refuse un backend qui ne le confirme pas. Le processus de l’agent se ferme après chaque exécution. Les anciennes conversations enregistrées ne sont ni reprises ni supprimées. Le lot suivant reçoit les règles fixes d’organisation, uniquement la transmission du dernier lot réussi (4 KiB au maximum), les entrées actuelles horodatées avec leurs identifiants de source, les métadonnées d’application, de fenêtre et de déclenchement, ainsi que le contexte des tâches existantes. Les fichiers Memory associés sont lus à la demande. La transmission consigne les modifications de fichiers enregistrées et les identifiants de source, sans historique de conversation ni corps des notes Memory. Elle n’est remplacée qu’après la publication réussie de Memory. Une nouvelle tentative après échec démarre dans une session neuve et inspecte les fichiers actuels.

Sans agent activé, les captures restent dans la file. Désactiver un agent empêche les nouvelles tâches mais laisse la tâche en cours se terminer. MyClip mémorise l’agent activé et le reconnecte au démarrage. Les anciennes préférences d’agent par défaut ne l’activent pas automatiquement : activez-en un explicitement après la mise à jour.

MyClip démarre chaque session d’organisation ou de détection de tâches avec un **accès complet** : `agent-full-access` pour Codex et `bypassPermissions` pour Claude Code. L’accès aux fichiers, les modifications, les commandes, l’accès réseau et les appels MCP s’effectuent sans confirmation pour chaque opération. Les demandes d’autorisation restantes sont gérées automatiquement pour la session active ; les tâches annulées refusent les demandes tardives. L’activité des outils reste consultable dans le journal d’exécution.

**Backstage** suit la consommation de tokens signalée pour l’organisation, la détection de tâches et les nouvelles tentatives, avec des totaux par agent et par lot. Les données sont enregistrées localement à la fin de chaque requête ; les valeurs anciennes ou non communiquées sont indiquées comme indisponibles, et non comme nulles. L’occupation de la fenêtre de contexte n’est pas considérée comme de la consommation. Les lots actifs affichent leur étape, le temps écoulé et le délai depuis la dernière progression. Claude ACP utilise les identifiants et les réglages réseau existants de Claude Code : un proxy local configuré doit donc être en fonctionnement.

L’organisation s’arrête après cinq minutes sans nouveau raisonnement, texte de réponse, activité d’outil ou demande d’autorisation dans la session actuelle. Un lot peut continuer tant qu’il progresse, dans la limite de quinze minutes au total. Les seules mises à jour de consommation et l’activité des autres sessions ne prolongent pas ce délai.

Memory distingue l’heure d’observation des captures (`observed_at`) de la date de modification des fichiers (`updated_at`). Now indique quand ses sources ont été capturées ; des sources plus anciennes ne peuvent pas remplacer une page Now plus récente. Une heure d’observation absente reste inconnue. L’organisateur rassemble l’historique des événements dans Daily, conserve les conclusions dans les pages de projets ou de sujets et retire les éléments résolus d’Inbox. Une navigation répétée ou occasionnelle n’impose pas la création d’une note permanente.

Pour les pages nouvellement organisées, `source_ids` contient les identifiants réels des captures citées dans le texte. Les captures de référence du lot sont conservées séparément dans `context_source_ids` et ne constituent pas des preuves pour chaque affirmation. Les résultats de recherche MCP portent les identifiants de source cités de leurs paragraphes, et `memory_get` résume les captures derrière une page (nombre, intervalle de temps, applications). Les notes existantes restent lisibles et adoptent ces règles lors d’une nouvelle organisation ; la mise à jour ne les réécrit pas en masse.

La recherche dans l’application et dans MCP utilise le même classement SQLite FTS5. Les mots-clés peuvent correspondre à n’importe quel terme ; les titres exacts et les alias déclarés viennent d’abord, puis un mélange des paragraphes les mieux adaptés de chaque note et du BM25 sur la note entière, puis la date de modification du fichier. Le classement par paragraphe évite qu’une note longue ne l’emporte sur le paragraphe qui répond réellement à la question. La correspondance littérale de sous-chaînes reste disponible pour le chinois et la ponctuation. Une recherche vide liste les notes récemment modifiées.

MCP propose deux outils en lecture seule. `memory_search` prend `query` (la question ou des mots-clés), ainsi que, en option, `since`, `until`, `app` et `limit` (10 par défaut), et renvoie des résultats classés avec `path`, `title`, un court `snippet` (jusqu’à deux paragraphes correspondants de 300 caractères maximum chacun), `time`, les `sourceIDs` cités des paragraphes et les `apps` sources. `memory_get` prend un `path` issu de ces résultats, en option avec `#heading` pour lire une seule section, et `from`/`lines` pour des plages de lignes ; il renvoie les lignes Markdown, les liens de la page groupés par titre, ses liens entrants du plus récent au plus ancien (chacun avec la ligne qui porte le lien et sa date), et un résumé des captures derrière la page. Les arguments inconnus sont rejetés plutôt qu’ignorés.

La recherche suit les Wikilinks. Les meilleures correspondances, ainsi que les deux extrémités des liens dont la ligne correspond à la question, servent de points de départ à une propagation en deux étapes dans le graphe de liens : un saut depuis chaque point de départ, puis un second saut uniquement à travers les pages d’entité (une note Daily → une page de personne ou de sujet → une autre note Daily). Chaque lien est pondéré selon la correspondance de sa ligne avec la question et atténué selon le nombre de liens que possède la page visée, afin que les pages centrales comme `Now.md` n’inondent pas les résultats ; les fichiers racine et `Wiki/Archives` en sont exclus. Les pages ainsi atteintes sont classées avec les correspondances directes et portent `via` : un ou deux sauts, chacun avec la page qui porte le lien, son titre, la ligne elle-même et sa date. Un lien indique une association, pas la preuve d’une relation factuelle.

`time` et les filtres `since`/`until` décrivent le moment où le contenu s’est produit : un événement annoté sur le paragraphe, sinon une capture citée, sinon la date de modification du fichier. `since` est inclusif et `until` exclusif ; tous deux acceptent des horodatages ISO 8601. Avec `app`, les notes comportant des événements doivent correspondre via un paragraphe d’événement qui cite aussi une capture de cette application, et les notes sans événement ont besoin d’une capture citée qui satisfait à la fois la période et l’application. Les dates d’événement inconnues ne sont jamais remplacées par des dates de capture ou de modification. Les pages datées sans plage favorisent légèrement les jours récents.

Les annotations d’événements sont des commentaires HTML placés immédiatement avant leur paragraphe, sans ligne vide. Elles résistent à la copie Markdown et à la reconstruction de l’index. Exemple :

```markdown
<!-- myclip-event {"start":"2026-09-10T00:00:00+08:00","end":"2026-09-11T00:00:00+08:00","precision":"day","evidence":"2026-09-10"} -->
Le 2026-09-10, la réunion avec le client s’est terminée. Source : capture `REPLACE_WITH_ACTUAL_SOURCE_UUID`.
```

Utilisez une preuve réelle et un identifiant de capture effectivement cité. Les précisions possibles sont `day` (jour du calendrier local), `range` (intervalle explicite à borne finale exclue) et `instant` (fin omise ou égale au début). Les horodatages doivent comporter un décalage UTC explicite. La recherche indique le début de l’événement comme `time` du résultat : cela décrit l’affirmation de la note, sans vérifier indépendamment la source. Les dates invalides, annotations contradictoires, annotations dans les exemples de code, paragraphes sans citation ou expressions `evidence` absentes du paragraphe ne produisent pas de dates d’événements indexées. Une date relative nécessite l’heure et le fuseau du message original ; l’organisateur doit conserver l’expression et expliquer sa conversion. Les dates de capture et de modification ne remplacent jamais une date d’événement absente. Les notes existantes restent consultables sans annotation et en reçoivent lors de l’organisation de sources pertinentes ; la mise à jour n’invente ni ne réécrit leurs dates.

Les index de passages, d’événements et de liens sont des données SQLite dérivées. Ils sont actualisés lors des modifications, supprimés avec leur note et reconstruits pour les anciennes bibliothèques sans modifier Markdown. Pour les questions nécessitant plus de deux sauts, un agent lit une page avec `memory_get` et suit les liens ou liens entrants qu’elle indique.

Les sessions temporaires ne peuvent pas être rouvertes dans Codex ou Claude. Consultez leurs détails d’exécution dans MyClip ; chaque enregistrement indique aussi le nombre d’images et de textes en entrée. Ces réglages empêchent les conversations locales d’agent pouvant être reprises, mais ne déterminent pas la conservation des données sur les serveurs du fournisseur du modèle.

Dans **Backstage**, cliquez sur un enregistrement d’organisation pour consulter chaque requête, y compris les nouvelles tentatives : appels d’outils, arguments, résultats, chemins et modifications de fichiers, réponses de l’agent, tokens d’entrée et de sortie, lectures et écritures du cache et coût signalé. Les journaux sont sauvegardés pendant l’exécution et restent disponibles après annulation ou redémarrage. Le coût correspond à la différence entre les montants cumulés communiqués par la session ; sans montant communiqué ou avec une référence initiale inconnue, il reste inconnu. Les anciens enregistrements conservent leurs totaux de tokens mais ne peuvent pas récupérer des détails d’outils jamais sauvegardés.

## Confidentialité et contrôle

- **Choisissez ce qui est capturé.** Les réglages regroupent trois contrôles : la portée (fenêtre active par défaut ou écran qui la contient), les déclencheurs indépendants de la souris (immobilité puis clic, défilement puis pause) et le déclencheur clavier (lettres puis Entrée par défaut, ou chaque Entrée). La capture fonctionne tant que MyClip est ouvert ; quittez l’application pour l’arrêter. Vous pouvez exclure certaines applications, y compris lors de la capture de l’écran entier.
- **Gardez votre bibliothèque en local.** Captures et notes sont stockées sur votre Mac. Les captures originales expirent après 30 jours par défaut ; les notes enregistrées restent disponibles. Vous pouvez modifier cette durée dans les réglages.
- **Décidez quand utiliser l’IA.** L’organisation utilise le service du modèle de l’agent choisi, qui peut traiter captures et notes dans le cloud. Désactivez l’organisation automatique pour garder les nouvelles captures en local jusqu’au moment où vous décidez de les traiter.

<details>
<summary>Compiler depuis les sources</summary>

Nécessite Xcode 26, Swift 6.2 et XcodeGen.

```sh
xcodegen generate
bash Scripts/test.sh
xcodebuild -project MyClip.xcodeproj -scheme MyClip -configuration Debug build
```

Pour créer un DMG, exécutez `Scripts/package_dmg.sh`. Le résultat est `dist/MyClip-<version>.dmg`.

Pour créer des paquets distincts pour Apple Silicon et Intel, exécutez `MYCLIP_ARCH=arm64 bash Scripts/package_dmg.sh` ou `MYCLIP_ARCH=x86_64 bash Scripts/package_dmg.sh`. Leurs noms se terminent respectivement par `-arm64.dmg` et `-x86_64.dmg`. Le push d’un tag `v<version>` déclenche les tests et la création des deux paquets dans GitHub Actions, puis une Release contenant les deux DMG et `SHA256SUMS`. Le tag doit correspondre à `CFBundleShortVersionString`, avec les notes dans `docs/releases/v<version>.md`.

</details>
