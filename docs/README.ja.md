<div align="center">
  <img src="../MyClip/Assets.xcassets/AppIcon.appiconset/icon_256x256.png" alt="MyClip のアイコン" width="120" height="120">
  <h1 align="center">MyClip</h1>
  <p align="center">MyClip は、作業の流れを思い出すためのアプリです。Mac のアクティブなウインドウ、またはそのウインドウがあるディスプレイをキャプチャし、Codex や Claude を使って、検索できるノート、関連づけられた知識、タスクの候補に整理します。</p>
</div>

<p align="center">
  <a href="../README.md">English</a> · <a href="README.zh-CN.md">简体中文</a> · <a href="README.es.md">Español</a> · <a href="README.fr.md">Français</a> · <a href="README.de.md">Deutsch</a> · <strong>日本語</strong> · <a href="README.ko.md">한국어</a>
</p>

[macOS 版をダウンロード](https://github.com/section9-lab/MyClip/releases)（Apple Silicon / Intel）。macOS 13 以降、Codex または Claude のアカウント、エージェントのコネクタ用に Node.js 22 以降が必要です。[自己署名版の開き方](release-signing.md)。

<p align="center">
  <a href="https://section9-lab.github.io/MyClip/demo/"><img src="images/myclip-demo.gif" alt="MyClip デスクトップデモ：初期設定、Memory、Timeline、Kanban、Reports、Backstage、設定、Codex と Claude でのメモリ検索" width="1000"></a>
</p>
<p align="center"><a href="https://section9-lab.github.io/MyClip/demo/">HD版を見る</a> · <a href="images/myclip-demo.mp4">MP4をダウンロード</a></p>
<p align="center"><sub>45秒のHTMLデモ · サンプルデータ · 中国語UI。</sub></p>

## できること

- **作業を振り返る。** キャプチャを時系列で確認し、ノートの根拠となる資料に戻れます。各キャプチャにはローカルの OCR テキスト文書があり、閲覧、コピー、ファイルとして開く操作ができます。
- **個人のナレッジライブラリを作る。** プロジェクト、テーマ、日々の作業を横断してノートを検索、編集、リンクできます。ノートは Markdown ファイルなので、ほかのエディタでも開けます。
- **次の作業を把握する。** 提案されたタスクを確認し、必要なものを承認して、ボードで進捗を追えます。**Kanban** と **Reports** を切り替えると、プロジェクトと進捗別に整理された日報、週報、月報を閲覧できます。
- **AI ツールに文脈を渡す。** Codex、Claude Code、Claude Desktop、Cursor、OpenCode から、保存したメモリを検索できます。

## プライバシーと管理

- **キャプチャする範囲を選ぶ。** 設定は、範囲（既定はアクティブウインドウ、またはそのディスプレイ）、独立したマウストリガー（マウス移動後5秒以内のクリック、下スクロール後3秒の静止）、キーボードトリガー（既定は英字入力後の Return、または毎回の Return）の 3 グループに分かれています。MyClip を開いている間は自動でキャプチャし、終了すると止まります。特定のアプリを除外でき、ディスプレイ全体のキャプチャでも除外設定を守ります。
- **ライブラリをローカルに保存する。** キャプチャとノートは Mac に保存します。元のキャプチャは既定で 30 日後に期限切れになりますが、保存済みノートは残ります。保存期間は設定で変更できます。
- **AI を使うタイミングを決める。** 整理には選択したエージェントのモデルサービスを使い、キャプチャやノートがクラウドで処理されることがあります。自動整理を無効にすると、自分で処理を選ぶまで新しいキャプチャをローカルに保持できます。

<details>
<summary>ソースからビルドする</summary>

Xcode 26、Swift 6.2、XcodeGen が必要です。

```sh
xcodegen generate
bash Scripts/test.sh
xcodebuild -project MyClip.xcodeproj -scheme MyClip -configuration Debug build
```

DMG を作成するには `Scripts/package_dmg.sh` を実行します。出力先は `dist/MyClip-<version>.dmg` です。

Apple Silicon と Intel 向けに個別のパッケージを作るには、`MYCLIP_ARCH=arm64 bash Scripts/package_dmg.sh` または `MYCLIP_ARCH=x86_64 bash Scripts/package_dmg.sh` を実行します。ファイル名の末尾はそれぞれ `-arm64.dmg` と `-x86_64.dmg` です。`v<version>` タグを push すると、GitHub Actions が両アーキテクチャのテストとビルドを行い、2 つの DMG と `SHA256SUMS` を含む Release を公開します。タグは `CFBundleShortVersionString` と一致させ、リリースノートを `docs/releases/v<version>.md` に置いてください。

</details>
