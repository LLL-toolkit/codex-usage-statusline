# macOS Apple Silicon 검증 기록

> 현재 상태: **v0.3.0 Apple Silicon 지원 검증 완료**. GitHub Actions 릴리스 후보와 태그 릴리스의 production HTTPS URL을 모두 Apple Silicon 실기기에서 설치·실행·제거 검증했습니다. Intel Mac은 지원하지 않습니다.

## 구현 기준

- 대상은 `aarch64-apple-darwin` 하나이며 Intel Mac을 포함하지 않습니다.
- Windows와 같은 Codex 0.144.1 Rust 패치, 상태줄 항목, 연보라색 스타일, 한국어·영어·일본어 런타임 선택을 사용합니다.
- 공식 Codex 설치를 덮어쓰지 않고 `~/Library/Application Support/codex-usage-statusline`에 리소스 번들을 복제합니다.
- 실행기는 매 호출마다 `CODEX_USAGE_STATUSLINE_LANGUAGE`와 `-c tui.status_line=[...]`을 전달합니다.
- `~/.codex/config.toml`은 설치·반복 설치·제거·롤백 중 생성하거나 수정하지 않습니다.
- OpenAI standalone, Homebrew, npm의 현재 사용자 설치를 탐지하고 네이티브 바이너리 버전과 arm64 아키텍처를 확인합니다.
- zsh는 설정된 절대 경로 `$ZDOTDIR/.zprofile` 또는 기본 `~/.zprofile`, bash는 `~/.bash_profile`에 정확히 하나의 관리 블록을 원자적으로 추가하며, 제거 시 manifest에 기록한 경로에서 블록 밖의 변경을 보존합니다.

## 실패 폐쇄 검증

macOS 설치기는 다음 파일을 고정된 HTTPS Release에서 가져옵니다.

```text
codex-usage-statusline-<project>-codex-<codex>-aarch64-apple-darwin.tar.gz
동일 파일명.sha256
동일 기본명.metadata.json
release-manifest.json
SHA256SUMS
SHA256SUMS.sig
```

`scripts/release_assets.py`는 저장소에 해시와 함께 고정한 RSA-3072 공개키로 `SHA256SUMS.sig`를 먼저 검증합니다. 그 뒤 원격 릴리스 태그의 peeled commit, 서명된 `customizationCommit`, 전체 파일 집합과 aggregate 체크섬, 대상별 sidecar, 외부·내부 빌드 메타데이터, 아카이브 및 바이너리 SHA-256을 서로 대조합니다. 압축 파일에서는 `codex`, `LICENSE`, `NOTICE.md`, `BUILD-METADATA.json` 네 일반 파일만 추출하며 경로 이동, 링크, 중복 항목, 크기 초과를 거부합니다.

설치 전 활성 Codex와 릴리스 바이너리에서 0.144.1을 각각 확인합니다. 실제 릴리스 바이너리는 `lipo -archs` 결과가 `arm64` 하나인지 확인하고 `codesign --verify --deep --strict`를 통과해야 합니다.

## 트랜잭션과 복구

- 상태 폴더별 operation lock은 macOS `lockf`의 커널 advisory lock으로 동시 설치·제거를 차단합니다. 프로세스가 종료되면 커널이 잠금을 해제하므로 남은 lock 파일 내용이나 PID 재사용에 의존하지 않습니다.
- 다운로드와 번들 복제는 `.staging.*` 아래에서 수행합니다.
- 프로필 원본은 작업 중 백업하며 활성 manifest를 마지막에 원자적으로 게시합니다.
- 설치 실패는 프로필, 실행기, 버전 번들을 이전 상태로 되돌립니다.
- 제거는 프로필 블록을 제거한 뒤 payload를 staging으로 이동하고, 실패하면 payload와 프로필을 모두 복원합니다.
- SIGKILL로 남은 staging은 다음 작업이 복구하며, `lockf` 잠금은 프로세스 종료 시 커널이 자동 해제합니다.
- 설치 시 실행기와 커스텀 번들의 모든 디렉터리, 일반 파일 경로·모드·SHA-256 inventory를 기록합니다. 파일 추가·삭제·변경, 링크나 특수 파일이 발견되면 전체 payload를 제거하지 않고 PATH에서만 비활성화합니다.

## 자동 테스트 기록

2026-07-10 Apple Silicon Mac에서 `tests/macos-installer.tests.sh`로 다음 격리 시나리오를 통과했습니다.

- npm, OpenAI standalone, Homebrew 레이아웃 탐지
- 홈·상태 경로 공백과 실행기 인자 보존
- zsh와 bash의 새 로그인 셸 명령 해석
- 사용자 지정 `ZDOTDIR` 설치, 환경 변수가 없는 반복 설치·제거, 정확한 프로필 복원
- 잘못된 아카이브 체크섬과 네트워크 연결 실패
- 잘못된 `SHA256SUMS.sig`와 서명 파일 여분 바이트
- 유효하게 서명됐지만 다른 `customizationCommit`을 가진 릴리스
- 두 프로필 변경 후 설치 롤백
- 프로필 활성화 후 SIGKILL과 다음 설치의 정확한 stale 상태 복구
- payload 이동 후 SIGKILL과 다음 제거의 정확한 payload·프로필 복구
- 남은 lock 파일 내용 무시와 실제 동시 작업 차단
- 설치·제거 manifest 커밋 경계에서 종료 신호를 받은 경우의 전체 롤백
- 반복 설치의 PATH 블록 중복 방지
- 프로필 외부 사용자 변경 보존
- 번들 내부 추가 파일 탐지와 payload 전체 보존
- payload 이동 후 제거 롤백
- 설치 전후와 제거 후 테스트 `config.toml` SHA-256 불변

`tests/release_assets_tests.py`는 tar 경로 이동, tar 심볼릭 링크, ZIP 중복 항목, 잘못된 macOS 서명 메타데이터를 거부하고, 임시 RSA 키로 full·selected release bundle 조립·서명·추출과 소스 커밋 결속을 직접 검증합니다. 같은 파일에서 프로필 블록 경계 편집과 custom `ZDOTDIR` manifest도 단위 테스트합니다.

## 서명과 Gatekeeper

현재 환경에는 유효한 Apple 코드 서명 identity가 없습니다. GitHub Actions는 arm64 바이너리의 디버그 정보를 제거하고 ad-hoc 서명한 뒤 `codesign --verify --deep --strict`를 실행합니다.

Apple 코드 서명과 별개로 릴리스 체크섬은 프로젝트 RSA 키로 서명합니다. 공개키와 SHA-256은 `release-lock.json`에 고정하며 비밀키는 `RELEASE_SIGNING_PRIVATE_KEY` GitHub Actions secret으로만 사용합니다. 서명된 manifest는 모든 대상의 `customizationCommit`을 태그가 가리키는 정확한 저장소 커밋에 결속합니다. 이는 릴리스 자산 변조를 검출하지만 Apple Developer ID 신원이나 공증을 대신하지 않습니다.

ad-hoc 서명은 Apple Developer ID 신원이나 공증을 제공하지 않습니다. 따라서 Finder나 브라우저가 격리 속성을 붙인 파일은 Gatekeeper의 `spctl` 평가에서 거부될 수 있습니다. 설치기는 이 제한을 숨기기 위해 격리 속성을 삭제하지 않습니다.

## 릴리스 후보 실기기 기록

2026-07-10 20:09~20:22 KST에 다음 환경에서 테스트 모드가 아닌 로컬 릴리스 후보 흐름을 실행했습니다.

- 장비: Mac14,15, Apple M2, arm64
- 운영체제: macOS 26.5.2 (25F84)
- 공식 설치: npm, `/opt/homebrew/bin/codex`, `codex-cli 0.144.1`
- customization commit: `e62540439c74609e4f10d18d0957d4e320267c77`
- 일반 CI: [run 29084361212](https://github.com/LLL-toolkit/codex-usage-statusline/actions/runs/29084361212)
- 릴리스 후보 빌드: [run 29084373395](https://github.com/LLL-toolkit/codex-usage-statusline/actions/runs/29084373395)

RSA 서명을 먼저 확인한 뒤 두 대상의 전체 release bundle을 재검증했습니다. Apple Silicon 아카이브 SHA-256은 `345b0b549b2ccc347b59b08fab902cf664ab6e0a19839001fff5ff637fb78db8`, 아카이브 내부와 설치 후 커스텀 바이너리 SHA-256은 모두 `e42302d800f6932326f4502614f1f012be2e94d75b97fbefd031079b7c15cc14`였습니다. 바이너리는 `arm64` 하나만 포함했고 `codex-cli 0.144.1`을 반환했습니다.

설치 후 새 zsh와 bash는 모두 `~/Library/Application Support/codex-usage-statusline/bin/codex`를 해석했습니다. 같은 언어의 반복 설치는 두 프로필의 SHA-256을 바꾸지 않았고 각 프로필에 시작·종료 marker를 하나씩만 유지했습니다. 한국어 `컨텍스트·사용량·주간`, 영어 `Context·Usage·Weekly`, 일본어 `コンテキスト·使用量·週間`과 각 reset 문구, 실제 퍼센트, 10칸 막대를 180열 true-color TUI에서 확인했습니다. 정상 구간의 실제 전경색은 세 언어 모두 `#c4b5fd`였습니다.

실제 `~/.codex/config.toml`은 설치 전, 각 언어 설치 후, 반복 설치 후, 각 제거 후 모두 `present:908af63a3cbda50f47bbb084d873706fd613466245029e75efa067e200a187b5`로 동일했습니다. 제거 후 `~/.zprofile`은 설치 전 SHA-256 `aa7829da6536e747ae3a45666ea5c0392dee0f45da0cac36a1d26643d5af2bb3`으로 복원됐고, 원래 없던 `~/.bash_profile`은 다시 없어졌습니다. 활성 manifest, 실행기와 버전 payload가 제거됐으며 새 zsh와 bash 모두 공식 `/opt/homebrew/bin/codex`와 `codex-cli 0.144.1`로 복원됐습니다.

추출 직후와 설치 후 바이너리 모두 `codesign --verify --deep --strict --verbose=2`를 통과했습니다. Developer ID와 공증이 없으므로 `spctl --assess --type execute --verbose=2`는 예상대로 상태 3과 `rejected`를 반환했습니다.

## Production URL 실기기 기록

2026-07-10 21:55~22:06 KST에 [v0.3.0 GitHub Release](https://github.com/LLL-toolkit/codex-usage-statusline/releases/tag/v0.3.0)의 기본 HTTPS URL만 사용하는 설치 흐름을 같은 장비에서 다시 실행했습니다.

- 태그 commit: `7fc7ff68312b85c97242044847d3c5085f43c812`
- 태그 빌드·서명·게시: [run 29089398011](https://github.com/LLL-toolkit/codex-usage-statusline/actions/runs/29089398011)
- 게시 상태: 검증 시 draft가 아닌 prerelease, 자산 9개 모두 업로드 완료
- Apple Silicon 아카이브 SHA-256: `3b7750b79e28bcd329a8f775d1f5a2500e289416bf96891c7e165b5b4ff3ac2d`
- 아카이브 내부와 설치 바이너리 SHA-256: `b3d1d2dbb0ab4575355ec1a15f2683c77368245943fbffb12937f6ccc54a3365`

게시된 9개 자산을 별도 디렉터리에 다시 다운로드해 RSA 서명, 전체 파일 집합, aggregate·sidecar 체크섬, 태그의 peeled commit, 외부·내부 metadata와 두 대상의 바이너리 해시를 재검증했습니다. 별도 후보 환경 변수나 로컬 자산 옵션 없이 `./install.sh`를 실행했고, manifest의 `customizationCommit`이 태그 commit과 일치하는지 확인했습니다.

한국어 기본 설치와 같은 언어 반복 설치, 제거 후 영어 설치, 제거 후 일본어 설치를 production URL에서 순서대로 실행했습니다. 새 zsh와 bash는 설치 중 side-by-side 실행기와 `codex-cli 0.144.1`을 해석했습니다. 세 언어 모두 실제 reset 문구, 퍼센트, 10칸 막대 세 개와 정상 구간 `#c4b5fd`를 true-color PTY 기록에서 다시 확인했습니다.

실제 `~/.codex/config.toml`은 전체 production 흐름 전후와 각 설치·제거 사이에 모두 `present:908af63a3cbda50f47bbb084d873706fd613466245029e75efa067e200a187b5`였습니다. 최종 제거 후 `~/.zprofile`은 원래 SHA-256 `aa7829da6536e747ae3a45666ea5c0392dee0f45da0cac36a1d26643d5af2bb3`으로 복원됐고 `~/.bash_profile`은 다시 없어졌습니다. 활성 manifest, 실행기와 버전 payload가 제거됐으며 zsh와 bash 모두 공식 `/opt/homebrew/bin/codex`와 `codex-cli 0.144.1`로 복원됐습니다.

게시된 바이너리도 추출 직후와 설치 후 `arm64` 하나만 포함했고 `codesign --verify --deep --strict --verbose=2`를 통과했습니다. Developer ID와 공증이 없으므로 `spctl`은 후보와 동일하게 상태 3과 `rejected`를 반환했습니다.

## 검증 게이트

- [x] 일반 push CI에서 macOS 설치기 테스트 통과
- [x] workflow dispatch에서 실제 arm64 빌드·strip·codesign·집중 Rust 테스트 통과
- [x] 완성된 release bundle의 전체 파일 집합과 SHA-256 재검증
- [x] npm 설치의 공식 Codex 0.144.1에서 릴리스 후보 설치
- [x] 새 zsh와 bash에서 `command -v codex`, `codex --version` 확인
- [x] 한국어·영어·일본어의 실제 TUI 라벨과 숫자·그래프 확인
- [x] 설치 전후와 제거 후 실제 `~/.codex/config.toml` 존재 여부 및 SHA-256 불변 확인
- [x] 실제 아카이브와 설치된 내부 바이너리 SHA-256 대조
- [x] 제거 후 공식 Codex 명령 복원
- [x] v0.3.0 production GitHub Release URL에서 동일 흐름 재확인

모든 게이트를 통과해 v0.3.0부터 Apple Silicon macOS 지원 상태로 전환했습니다. Developer ID와 공증이 도입되기 전까지 위 Gatekeeper 제한은 계속 적용됩니다.

관련 문서: [README](../README.md), [릴리스 절차](release-process.md).
