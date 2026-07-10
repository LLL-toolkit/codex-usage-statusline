# 릴리스 절차

공식 릴리스 빌드는 재현성과 해시 기록을 위해 GitHub Actions에서 수행합니다. 다만 개발·플랫폼 이식 과정에서 AI가 필요한 도구를 자동 설치하고 로컬 빌드를 수행하는 것은 허용합니다. 사용자가 도구 설치를 수동으로 처리하게 만들지 않는 것이 원칙입니다.

## 단일 기준 파일

`release-lock.json`은 다음 값을 한곳에 고정합니다.

- 프로젝트 버전과 릴리스 태그
- 지원 Codex 버전
- 공식 Codex 태그·태그 객체·커밋·트리
- Rust 도구 버전
- 패치 경로와 SHA-256
- Windows x64 대상

`VERSION`과 `install.ps1`의 버전 상수도 같은 값이어야 합니다. 다음 명령이 불일치를 검사합니다.

```sh
python3 scripts/verify_release_lock.py
```

## 변경 검증

일반 push와 pull request에서는 `.github/workflows/ci.yml`이 다음 가벼운 검사를 실행합니다.

- 릴리스 잠금과 패치 해시 확인
- 공식 고정 커밋에 `git apply --check`
- Windows PowerShell 5.1/7 설치기 테스트
- Windows 실행기가 언어 환경 변수와 상태줄 `-c` 재정의를 전달하고 사용자 `config.toml`을 수정하지 않는지 확인

필수 Rust 테스트와 공식 릴리스 빌드는 태그 워크플로에 있습니다. 개발 환경에서 같은 고정 도구 버전으로 추가 `cargo` 검증을 실행해도 되지만, 공식 결과는 CI 기록을 기준으로 합니다.

## 릴리스 생성

1. `CHANGELOG.md`, `VERSION`, `release-lock.json`, Windows 설치기의 버전을 함께 갱신합니다.
2. 패치를 갱신했다면 LF 줄바꿈으로 저장하고 SHA-256을 다시 기록합니다.
3. 가벼운 CI가 통과한 커밋에 `release-lock.json`의 태그를 생성합니다.
4. 태그를 push합니다.

```sh
git tag -a v0.2.0 -m "codex-usage-statusline 0.2.0"
git push origin v0.2.0
```

`.github/workflows/release.yml`은 공식 Codex 커밋을 워크스페이스 루트에 체크아웃하고 공통 패치를 적용합니다. 이어서 집중 TUI 테스트를 실행하고 다음 Windows 바이너리를 빌드합니다.

- `x86_64-pc-windows-msvc`

최종 작업은 아카이브 체크섬, 바이너리 체크섬, `BUILD-METADATA.json`, `release-manifest.json`, `SHA256SUMS`를 만들고 기존 릴리스를 덮어쓰지 않은 채 GitHub Release를 생성합니다. 이번 릴리스에는 macOS 자산을 포함하지 않습니다.

## 릴리스 확인

GitHub Release에서 각 대상에 대해 다음 네 종류가 있는지 확인합니다.

```text
codex-usage-statusline-<project>-codex-<codex>-x86_64-pc-windows-msvc.zip
동일 파일명.sha256
동일 기본명.metadata.json
release-manifest.json / SHA256SUMS
```

Windows에서 먼저 `install.ps1 -DryRun`, 그다음 실제 설치·제거와 `~/.codex/config.toml` 무변경을 확인합니다. Apple Silicon 지원은 현재 릴리스와 분리된 [후속 작업](macos-validation.md)이며, 해당 구현과 실기기 확인이 끝나기 전에는 macOS 자산이나 지원 표기를 추가하지 않습니다.

## 새 Codex 버전 추가

1. 새 공식 태그의 객체, peeled commit, tree, Rust 버전과 npm 플랫폼 게시 상태를 확인합니다.
2. 깨끗한 공식 소스에서 상태줄 변경을 다시 적용하고 기존 Codex 의미를 바꾸지 않았는지 검토합니다.
3. 패치 파일과 집중 테스트를 갱신합니다.
4. 새 프로젝트 버전으로 릴리스 잠금과 설치기 상수를 갱신합니다.
5. 일반 CI, 릴리스 CI, Windows 실제 설치 순서로 검증합니다.

이 프로젝트의 바이너리는 OpenAI 공식 서명이 아닌 독립 수정본입니다. 릴리스 설명과 `NOTICE.md`에서 이 사실을 계속 명시해야 합니다.
