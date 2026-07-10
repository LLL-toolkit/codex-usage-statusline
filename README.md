# codex-usage-statusline

**한국어** · [English](README.en.md) · [日本語](README.ja.md)

Windows x64용 Codex CLI 하단에 컨텍스트·5시간·주간 사용량을 막대와 정확한 퍼센트로 표시합니다. 정상 구간은 연보라색, 60% 이상은 노란색, 85% 이상은 빨간색입니다.

```text
gpt-5.6-sol low · 컨텍스트 ██░░░░░░░░ 18% · 사용량 █░░░░░░░░░ 7% (초기화까지 3h 42m) · 주간 █████░░░░░ 49% (초기화까지 2d 23h)
```

## 가장 쉬운 설치

현재 Codex CLI에 다음 문장을 그대로 요청합니다.

```text
https://github.com/LLL-toolkit/codex-usage-statusline 를 이 Windows x64 컴퓨터에 설치해줘.
Codex 설치 방식을 감지해 저장소의 공식 Windows 설치기를 사용하고, 표시 언어는 한국어로 설정한 뒤 설치 검증까지 완료해줘. 필요한 도구가 있다면 직접 준비하고 사용자에게 수동 설치를 시키지 마.
```

기본 설치기는 Windows x64와 Codex 버전을 확인하고, 고정된 GitHub Release에서 맞는 바이너리를 내려받아 SHA-256을 확인합니다. 그래서 보통은 추가 빌드 도구가 필요 없지만, 유지관리나 후속 플랫폼 작업에서 필요하면 AI가 Rust·플랫폼 도구를 자동으로 준비해도 됩니다. 핵심은 사용자가 중간 설치 작업을 직접 하지 않는 것입니다.

설치가 끝나면 현재 Codex와 기존 터미널 프로그램을 완전히 닫고 새 터미널을 한 번 엽니다. 공식 Codex 설치는 수정하지 않으며, 검증된 커스텀 버전을 사용자 PATH 앞쪽에서 실행합니다. Windows 설치기는 현재 사용자 범위에서 확인되는 Codex 명령만 지원합니다.

## 직접 설치

직접 클론하는 경우에만 Git이 필요합니다.

Windows x64:

```powershell
git clone https://github.com/LLL-toolkit/codex-usage-statusline.git
cd codex-usage-statusline
powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 -Language ko
```

표시 언어는 `ko`가 기본이며 `en`, `ja`도 선택할 수 있습니다.

```powershell
.\install.ps1 -Language en
.\install.ps1 -Language ja
```

## 요구 사항과 호환성

- 이미 실행 가능한 Codex CLI와 인터넷 연결
- Codex CLI **0.144.1**
- 현재 사용자 범위에서 명령이 확인되는 Windows x64 Codex

| 플랫폼 | 릴리스 빌드 | 실제 환경 검증 |
|---|---:|---:|
| Windows x64 | 자동화됨 | 지원 |

macOS 바이너리와 설치기는 아직 배포하지 않습니다. 같은 Rust 패치를 Apple Silicon으로 확장하는 후속 작업은 [macOS 작업 인계 문서](docs/macos-validation.md)에 정리되어 있습니다.

버전이 정확히 맞지 않거나 릴리스 파일이 없으면 설치기는 아무것도 변경하지 않고 중단합니다. Codex 내부 TUI는 안정된 플러그인 API가 아니므로 버전별 검증이 필요합니다.

## 설치 확인

새 터미널에서 다음을 실행합니다.

```text
codex --version
codex
```

첫 요청을 보낸 뒤 하단에 `컨텍스트`, `사용량`, `주간` 막대가 나타나는지 확인합니다. 사용량 데이터가 아직 도착하지 않았다면 5시간·주간 항목은 첫 요청 이후 나타날 수 있습니다.

설치기는 `~/.codex/config.toml`을 만들거나 수정하지 않습니다. 색상을 끄고 싶다면 사용자가 직접 기존 Codex 옵션을 설정할 수 있습니다.

```toml
[tui]
status_line_use_colors = false
```

## 제거

Codex에 저장소 링크와 함께 “이 상태줄을 제거해줘”라고 요청하거나 직접 실행합니다.

Windows:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\uninstall.ps1
```

제거기는 관리 중인 PATH 항목과 커스텀 번들만 제거합니다. 공식 Codex 설치와 `~/.codex/config.toml`은 설치부터 제거까지 건드리지 않습니다.

## 작동 방식

```text
저장소 설치기
  └─ Windows x64와 Codex 버전 확인
      └─ 고정된 GitHub Release 파일 + SHA-256 검증
          └─ 공식 Codex 리소스 번들을 사용자 상태 폴더에 복제
              └─ 언어 환경 변수와 상태줄 -c 재정의를 전달하는 실행기를 PATH 앞에 연결
```

공통 상태줄 코드는 하나의 Rust 패치로 관리합니다. 한국어·영어·일본어는 같은 바이너리에서 런타임에 선택하므로 운영체제나 언어마다 기능 코드를 복제하지 않습니다. 실행기는 호출할 때마다 `CODEX_USAGE_STATUSLINE_LANGUAGE`를 설정하고 `-c tui.status_line=[...]` 재정의를 전달하므로 사용자의 영구 설정 파일을 바꿀 필요가 없습니다. 공식 배포 바이너리는 릴리스 태그가 생성될 때 GitHub Actions에서 재현 가능하게 빌드합니다.

Windows 상태는 `%LOCALAPPDATA%\codex-usage-statusline`에 저장됩니다.

## 보안과 제한

- 공식 OpenAI Codex의 고정 태그와 커밋을 사용하며, 패치 SHA-256도 `release-lock.json`에 고정합니다.
- 릴리스 아카이브와 내부 바이너리 해시는 CI가 기록하고 설치기가 아카이브 SHA-256을 확인합니다.
- 원본 실행 파일을 덮어쓰지 않아 실행 중인 Windows Codex에서도 설치 준비가 가능합니다.
- 이 프로젝트는 OpenAI 공식 배포판이 아닙니다.

유지관리 절차는 [릴리스 문서](docs/release-process.md), Apple Silicon 지원을 이어서 만들 때는 [macOS 작업 인계 문서](docs/macos-validation.md)를 참고하세요.
