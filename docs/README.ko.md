<div align="center">
  <img src="../MyClip/Assets.xcassets/AppIcon.appiconset/icon_256x256.png" alt="MyClip 아이콘" width="120" height="120">
  <h1 align="center">MyClip</h1>
  <p align="center">MyClip은 하던 일을 다시 떠올릴 수 있도록 도와줍니다. Mac에서 활성 창이나 해당 창이 있는 디스플레이를 캡처하고, Codex 또는 Claude를 사용해 검색 가능한 노트, 연결된 지식, 추천 작업으로 정리합니다.</p>
</div>

<p align="center">
  <a href="../README.md">English</a> · <a href="README.zh-CN.md">简体中文</a> · <a href="README.es.md">Español</a> · <a href="README.fr.md">Français</a> · <a href="README.de.md">Deutsch</a> · <a href="README.ja.md">日本語</a> · <strong>한국어</strong>
</p>

[macOS용 다운로드](https://github.com/section9-lab/MyClip/releases) (Apple Silicon / Intel). macOS 13 이상, Codex 또는 Claude 계정, 에이전트 커넥터용 Node.js 22 이상이 필요합니다. [자체 서명 버전 열기](release-signing.md).

<p align="center">
  <a href="https://section9-lab.github.io/MyClip/demo/"><img src="images/myclip-demo.gif" alt="MyClip 데스크톱 데모: 온보딩, Memory, Timeline, Kanban, Reports, Backstage, 설정 및 Codex와 Claude의 메모리 검색" width="1000"></a>
</p>
<p align="center"><a href="https://section9-lab.github.io/MyClip/demo/">HD 영상 보기</a> · <a href="images/myclip-demo.mp4">MP4 다운로드</a></p>
<p align="center"><sub>45초 HTML 데모 · 샘플 데이터 · 중국어 UI.</sub></p>

## 할 수 있는 일

- **작업을 되짚어 보세요.** 캡처 타임라인을 탐색하고 노트의 근거가 된 자료를 확인할 수 있습니다. 각 캡처에는 읽거나 복사하거나 열 수 있는 로컬 OCR 텍스트 문서가 있습니다.
- **개인 지식 라이브러리를 만드세요.** 프로젝트, 주제, 일상 작업에 걸쳐 노트를 검색하고 편집하고 연결할 수 있습니다. 노트는 Markdown 파일이므로 다른 편집기에서도 열 수 있습니다.
- **다음 할 일을 추적하세요.** 추천 작업을 검토하고 필요한 항목을 확정한 뒤 보드에서 진행 상황을 확인할 수 있습니다. **Kanban**과 **Reports** 사이를 전환해 프로젝트와 진행 상황별로 정리된 일간, 주간, 월간 업무 보고서를 볼 수 있습니다.
- **AI 도구에 맥락을 제공하세요.** Codex, Claude Code, Claude Desktop, Cursor, OpenCode에서 저장된 메모리를 검색하도록 할 수 있습니다.

## 개인정보 보호와 제어

- **무엇을 캡처할지 선택하세요.** 설정은 범위(기본값은 활성 창 또는 해당 창이 있는 디스플레이), 독립적인 마우스 트리거(마우스 이동 후 5초 이내 클릭, 아래로 스크롤한 후 3초 정지), 키보드 트리거(기본값은 영문자 입력 후 Return 또는 모든 Return)의 세 그룹으로 나뉩니다. MyClip이 열려 있는 동안 자동 캡처하며, 앱을 종료하면 멈춥니다. 특정 앱을 제외할 수 있고 전체 디스플레이 캡처에도 제외 규칙을 적용합니다.
- **라이브러리를 로컬에 보관하세요.** 캡처와 노트는 Mac에 저장됩니다. 원본 캡처는 기본적으로 30일 후 만료되지만 저장한 노트는 남습니다. 보관 기간은 설정에서 바꿀 수 있습니다.
- **AI를 사용할 시점을 결정하세요.** 정리는 선택한 에이전트의 모델 서비스를 사용하며, 캡처와 노트를 클라우드에서 처리할 수 있습니다. 자동 정리를 끄면 처리하기로 선택할 때까지 새 캡처를 로컬에 보관합니다.

<details>
<summary>소스에서 빌드하기</summary>

Xcode 26, Swift 6.2, XcodeGen이 필요합니다.

```sh
xcodegen generate
bash Scripts/test.sh
xcodebuild -project MyClip.xcodeproj -scheme MyClip -configuration Debug build
```

DMG를 만들려면 `Scripts/package_dmg.sh`를 실행하세요. 출력 파일은 `dist/MyClip-<version>.dmg`입니다.

Apple Silicon과 Intel용 패키지를 각각 만들려면 `MYCLIP_ARCH=arm64 bash Scripts/package_dmg.sh` 또는 `MYCLIP_ARCH=x86_64 bash Scripts/package_dmg.sh`를 실행하세요. 파일 이름은 각각 `-arm64.dmg`와 `-x86_64.dmg`로 끝납니다. `v<version>` 태그를 push하면 GitHub Actions가 두 아키텍처를 테스트하고 빌드한 뒤, 두 DMG와 `SHA256SUMS`를 포함하는 Release를 게시합니다. 태그는 `CFBundleShortVersionString`과 일치해야 하며 릴리스 노트는 `docs/releases/v<version>.md`에 저장합니다.

</details>
