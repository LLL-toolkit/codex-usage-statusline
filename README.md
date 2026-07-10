# codex-usage-statusline

**한국어** · [English](README.en.md) · [日本語](README.ja.md)

Windows용 Codex CLI 사용량 상태 줄입니다. 단순한 잔여 한도 텍스트를 사용량 막대, 정확한 백분율, 초기화 시간, 연보라색 중심의 색상 단계로 바꿉니다.

```text
gpt-5.6-sol low · 컨텍스트 ██░░░░░░░░ 18% · 사용량 █░░░░░░░░░ 7% (초기화 in 3h 42m) · 주간 █████░░░░░ 49% (초기화 in 2d 23h)
```

정상 구간은 연보라색, 60% 이상은 노란색, 85% 이상은 빨간색으로 표시됩니다. 모든 숫자는 **사용한 비율**을 뜻하므로 컨텍스트, 5시간 한도, 주간 한도를 바로 비교할 수 있습니다.

## 설치

### 준비 사항

- Windows x64
- `npm install -g @openai/codex`로 설치한 Codex CLI
- Git, Node.js/npm, Rust 도구 모음(`cargo`)
- Codex 릴리스 빌드를 위한 약 10GB의 임시 여유 공간

실행 중인 Codex를 모두 종료한 뒤 저장소를 클론하고 설치기를 실행합니다.

```powershell
git clone https://github.com/LLL-toolkit/codex-usage-statusline.git
cd codex-usage-statusline
powershell -ExecutionPolicy Bypass -File .\install.ps1
```

설치기는 Codex 버전을 감지하고, 맞는 패치를 선택하고, 공식 태그 소스를 빌드합니다. 집중 테스트가 통과한 다음 기존 실행 파일을 백업하고 새 파일로 교체합니다. 완료 후 Codex를 다시 시작하세요.

한국어가 기본입니다. 영어와 일본어도 선택할 수 있습니다.

```powershell
.\install.ps1 -Language en
.\install.ps1 -Language ja
```

## 확인

새 Codex 세션을 시작합니다.

```powershell
codex
```

하단 상태 줄에 `컨텍스트`, `사용량`, `주간` 막대가 보여야 합니다. 한도 데이터가 아직 도착하지 않았다면 첫 요청 후 사용량과 주간 항목이 나타날 수 있습니다.

## 설치 옵션

```powershell
# 이전 소스 디렉터리가 있어도 새로 빌드
.\install.ps1 -ForceRebuild

# 설치 후 클론한 Codex 소스 보존
.\install.ps1 -KeepSource

# 테스트 러너 문제를 진단할 때만 테스트 생략(권장하지 않음)
.\install.ps1 -SkipTests

# 지원되는 특정 버전 빌드
.\install.ps1 -CodexVersion 0.144.1

# 한국어(기본), 영어, 일본어 라벨 선택
.\install.ps1 -Language ko
.\install.ps1 -Language en
.\install.ps1 -Language ja
```

`-SkipTests`를 사용해도 릴리스 빌드와 설치 후 버전 검사는 생략하지 않습니다. 기존 실행 파일도 항상 백업하며 설치 실패 시 자동 복구합니다.

## 제거

Codex를 종료한 뒤 가장 최근 백업을 복원합니다.

```powershell
powershell -ExecutionPolicy Bypass -File .\uninstall.ps1
```

공식 npm 패키지를 다시 설치해도 됩니다.

```powershell
npm install -g @openai/codex@latest
```

## 호환성

Codex 내부 TUI는 안정된 공개 확장 API가 아니므로 패치는 버전별로 관리합니다.

| Codex CLI | 플랫폼 | 상태 |
|---|---|---|
| 0.144.1 | Windows x64, npm 설치 | 지원 |

Codex를 업데이트하면 사용자 지정 실행 파일이 덮어써질 수 있습니다. 새 버전용 패치가 추가된 뒤 설치기를 다시 실행하세요. 설치기는 알 수 없는 버전에 패치를 억지로 적용하지 않고 중단합니다.

## 동작 방식

```text
설치된 Codex 버전
        │
        ▼
버전별 패치 ──► 공식 Codex 태그 소스
                        │
                        ▼
                  테스트 + 릴리스 빌드
                        │
                        ▼
              원본 백업 ──► 실행 파일 교체
```

패치는 Codex TUI 상태 줄 포매터와 관련 테스트만 변경합니다. 자격 증명을 읽거나 텔레메트리를 전송하거나 API 요청을 바꾸지 않습니다. 빌드 파일은 `%LOCALAPPDATA%\codex-usage-statusline` 아래에 두며, `-KeepSource`를 지정하지 않으면 성공 후 클론한 소스를 제거합니다.

## 문제 해결

### Codex 버전을 지원하지 않음

`patches/`에 해당 버전 패치가 추가될 때까지 기다리거나 지원 버전의 Codex를 설치하세요. 이전 패치의 파일명만 바꾸면 안 됩니다.

### 설치된 실행 파일이 사용 중임

모든 Codex 프로세스를 종료하고 `-ForceRebuild` 옵션으로 다시 실행하세요.

### 빌드 실패

`rustc --version`, `cargo --version`, `git --version`, `npm --version`이 모두 실행되는지 확인하세요. 진단용 소스를 남기려면 `-KeepSource`를 사용합니다.

### 색상 끄기

`%USERPROFILE%\.codex\config.toml`에서 Codex의 기존 색상 옵션을 끕니다.

```toml
[tui]
status_line_use_colors = false
```

## 보안과 복구

- `https://github.com/openai/codex.git`의 설치 버전과 동일한 태그만 클론합니다.
- 소스를 바꾸기 전에 `git apply --check`가 통과해야 합니다.
- 교체 전 원본은 `%LOCALAPPDATA%\codex-usage-statusline\backups`에 저장합니다.
- 설치 후 버전 검사가 실패하면 즉시 원본을 복구합니다.

