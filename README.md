# codex-usage-statusline

**한국어** · [English](README.en.md) · [日本語](README.ja.md)

Codex CLI 하단에 컨텍스트·5시간·주간 사용량을 막대와 정확한 퍼센트로 표시합니다. 정상 구간은 연보라색, 60% 이상은 노란색, 85% 이상은 빨간색입니다.

```text
gpt-5.6-sol low · 컨텍스트 ██░░░░░░░░ 18% · 사용량 █░░░░░░░░░ 7% (초기화까지 3h 42m) · 주간 █████░░░░░ 49% (초기화까지 2d 23h)
```

## 설치

현재 Codex CLI에 다음 문장을 요청합니다.

```text
https://github.com/LLL-toolkit/codex-usage-statusline 를 현재 컴퓨터에 설치하고 검증까지 완료해줘.
저장소에 포함된 운영체제용 설치기를 사용하고 표시 언어는 한국어로 설정해줘.
```

설치기는 운영체제, CPU, Codex 버전을 확인하고 고정된 GitHub Release에서 사전 빌드 자산을 받습니다. 릴리스 체크섬, manifest, 빌드 메타데이터, 내부 바이너리 해시를 모두 확인한 뒤 공식 Codex와 분리된 사용자 상태 폴더에 설치합니다.

설치 후 현재 Codex와 터미널을 닫고 새 터미널을 엽니다. 공식 Codex 설치는 교체하지 않습니다.

저장소를 직접 실행하는 경우의 명령은 다음과 같습니다.

Apple Silicon macOS:

```sh
git clone https://github.com/LLL-toolkit/codex-usage-statusline.git
cd codex-usage-statusline
./install.sh --language ko
```

Windows x64:

```powershell
git clone https://github.com/LLL-toolkit/codex-usage-statusline.git
cd codex-usage-statusline
powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 -Language ko
```

표시 언어는 한국어 `ko`가 기본이며 영어 `en`, 일본어 `ja`도 선택할 수 있습니다.

## 호환성

- Codex CLI **0.144.1**
- Windows x64 및 Apple Silicon macOS 지원
- Intel Mac은 지원하지 않음

| 플랫폼 | 릴리스 빌드 | 실제 환경 검증 |
|---|---:|---:|
| Windows x64 | 자동화됨 | 지원 |
| Apple Silicon macOS | 자동화됨 | 지원 |

Codex 내부 TUI는 안정된 플러그인 API가 아니므로 버전이 정확히 일치해야 합니다. 버전, 자산, 해시 또는 대상 아키텍처가 다르면 설치기는 아무것도 활성화하지 않고 중단합니다.

macOS 설치기는 현재 사용자에게 활성화된 다음 공식 설치 방식을 탐지합니다.

- OpenAI standalone 설치기
- Homebrew
- npm 전역 설치

## 설치 확인

새 터미널에서 다음을 실행합니다.

```text
command -v codex
codex --version
codex
```

첫 요청 후 하단에 `컨텍스트`, `사용량`, `주간` 막대가 나타나는지 확인합니다. 사용량 데이터가 아직 도착하지 않았다면 5시간·주간 항목은 첫 응답 이후 나타날 수 있습니다.

설치기와 제거기는 `~/.codex/config.toml`을 생성하거나 수정하지 않습니다. 실행기가 호출마다 `CODEX_USAGE_STATUSLINE_LANGUAGE`와 다음 일회성 설정을 전달합니다.

```text
-c tui.status_line=['model-with-reasoning','context-used','five-hour-limit','weekly-limit']
```

## 제거

Apple Silicon macOS:

```sh
./uninstall.sh
```

Windows x64:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\uninstall.ps1
```

제거기는 설치기가 소유한 PATH 관리 블록, 실행기, 커스텀 번들만 제거합니다. 설치 후 번들에 추가되거나 변경된 파일이 있으면 전체 번들을 삭제하지 않고 PATH에서만 비활성화합니다. 프로필의 다른 내용, 공식 Codex 설치, `~/.codex/config.toml`은 보존합니다.

## 작동 방식

```text
저장소 설치기
  └─ 운영체제·CPU·Codex 버전과 공식 설치 방식 확인
      └─ 고정 GitHub Release의 manifest·체크섬·메타데이터 검증
          └─ 공식 Codex 리소스 번들을 사용자 상태 폴더에 복제
              └─ 검증된 커스텀 바이너리와 호출별 설정 실행기를 PATH 앞에 연결
```

공통 상태줄 코드는 하나의 Rust 패치로 관리합니다. 한국어·영어·일본어는 같은 바이너리에서 런타임에 선택합니다.

- Windows 상태: `%LOCALAPPDATA%\codex-usage-statusline`
- macOS 상태: `~/Library/Application Support/codex-usage-statusline`
- macOS PATH 블록: 절대 경로 `$ZDOTDIR/.zprofile`(설정된 경우), 그 외 `~/.zprofile`, 그리고 `~/.bash_profile`

설치와 제거는 잠금, staging 디렉터리, 원자적 프로필 편집, 복구 manifest를 사용합니다. 중단된 설치와 제거 실패는 이전 상태로 롤백하며 반복 설치는 관리 블록을 중복 생성하지 않습니다.

## macOS 서명과 Gatekeeper

Apple Silicon 바이너리는 빌드 후 디버그 정보를 제거하고 ad-hoc 서명한 다음 `codesign --verify --deep --strict`로 검사합니다. 현재 릴리스에는 Apple Developer ID 서명과 공증이 없습니다. 따라서 Finder나 브라우저가 격리 속성을 붙인 복사본은 Gatekeeper의 `spctl` 평가에서 거부될 수 있습니다.

저장소 설치기는 HTTPS 릴리스와 SHA-256 검증을 사용하며 격리 속성을 임의로 제거하지 않습니다. Developer ID와 공증이 추가되기 전까지는 이 제한이 유지됩니다.

## 보안

- 공식 Codex 태그·커밋·트리, Rust 버전, 패치 SHA-256, 대상 아키텍처를 `release-lock.json`에 고정합니다.
- 설치기는 저장소에 고정된 RSA 공개키로 `SHA256SUMS.sig`를 먼저 검증한 뒤 릴리스 아카이브, 내부 바이너리, 대상 메타데이터, `release-manifest.json`, `SHA256SUMS`를 서로 대조합니다.
- 설치기는 원격 릴리스 태그의 peeled commit과 서명된 `customizationCommit`이 정확히 같은지 확인합니다.
- macOS는 arm64 전용 Mach-O와 ad-hoc `codesign` 구조를 추가로 검증합니다.
- 압축 파일은 허용된 일반 파일 네 개만 구조화된 파서로 추출합니다.
- 원본 실행 파일과 영구 Codex 설정을 수정하지 않습니다.
- 이 프로젝트는 OpenAI 공식 배포판이 아닙니다.

유지관리와 검증 기록은 [릴리스 절차](docs/release-process.md)와 [macOS 검증 문서](docs/macos-validation.md)에 있습니다.
