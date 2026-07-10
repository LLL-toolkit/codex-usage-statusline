# 릴리스 절차

공식 릴리스 바이너리는 고정된 소스와 메타데이터를 사용해 GitHub Actions에서 빌드합니다. 개발·플랫폼 검증에 필요한 도구는 자동화된 작업이 준비합니다.

## 단일 기준 파일

`release-lock.json`은 다음 값을 고정합니다.

- 프로젝트 버전과 릴리스 태그
- 지원 Codex 버전
- 공식 Codex 태그 객체·커밋·트리
- Rust 도구 버전
- 공통 Rust 패치 경로와 SHA-256
- RSA-3072 릴리스 공개키 경로·SHA-256과 서명 크기
- Windows x64와 Apple Silicon macOS 대상, runner, 실행 파일명, 아카이브 형식

`VERSION`, Windows 설치기·제거기, macOS 설치기·제거기의 버전도 같은 값이어야 합니다.

```sh
python3 scripts/verify_release_lock.py
```

## 일반 CI

`.github/workflows/ci.yml`은 main push와 pull request에서 다음을 실행합니다.

- 릴리스 잠금, 패치 SHA-256, Python·shell 구문 확인
- 고정 Codex 커밋에 패치 적용 가능 여부 확인
- 구조화된 릴리스 아카이브 보안 테스트
- Windows PowerShell 5.1/7 설치기 테스트
- Apple Silicon runner의 macOS 설치·제거 통합 테스트

macOS 통합 테스트에는 npm·standalone·Homebrew 탐지, 체크섬·서명·네트워크 실패, 경로 공백, 사용자 지정 `ZDOTDIR`, PID 재사용, 강제 중단, 반복 설치, 프로필 보존, 설치·제거 롤백이 포함됩니다.

## 릴리스 후보 빌드

`.github/workflows/release.yml`을 `workflow_dispatch`로 실행하면 릴리스를 게시하지 않고 다음 검증과 `release-bundle` artifact 생성을 완료합니다.

1. 고정 upstream 태그 객체·커밋·트리와 npm 플랫폼 패키지를 확인합니다.
2. 공통 패치를 적용하고 집중 `codex-tui` 상태줄 테스트를 실행합니다.
3. Windows와 macOS 설치기 테스트를 다시 실행합니다.
4. 다음 대상을 빌드합니다.

```text
x86_64-pc-windows-msvc
aarch64-apple-darwin
```

5. macOS 바이너리는 `strip -S`, ad-hoc `codesign`, arm64 전용 검사, `codesign --verify --deep --strict`, `spctl` 평가를 기록합니다.
6. 공통 `scripts/release_assets.py`로 결정적 ZIP/tar.gz, sidecar 체크섬, 대상 메타데이터를 만듭니다.
7. 두 대상의 `customizationCommit`이 workflow를 시작한 정확한 저장소 커밋과 같은지 확인하고 이를 `release-manifest.json`에 기록합니다.
8. 두 대상을 하나의 `release-manifest.json`과 `SHA256SUMS`로 조립하고 `RELEASE_SIGNING_PRIVATE_KEY` secret으로 `SHA256SUMS.sig`를 생성합니다.
9. 저장소에 고정된 공개키로 서명을 검증한 뒤 전체 자산, 소스 커밋, 내부 바이너리 해시를 독립 재검증합니다.

Developer ID와 공증 자격이 없으므로 macOS metadata는 `developerId: false`, `notarized: false`를 기록합니다. 이 값과 README의 Gatekeeper 제한은 자격이 실제로 도입될 때까지 유지합니다.

릴리스 서명 비밀키는 저장소나 artifact에 포함하지 않습니다. 공개키를 교체할 때는 별도 키를 생성하고 GitHub Actions secret, `keys/release-signing-public.pem`, `release-lock.json`의 공개키 SHA-256과 서명 크기를 같은 커밋에서 갱신합니다.

## 릴리스 생성

1. `CHANGELOG.md`, `VERSION`, `release-lock.json`, 설치기·제거기 버전을 함께 갱신합니다.
2. 패치가 바뀌었다면 LF로 저장하고 SHA-256을 다시 기록합니다.
3. 일반 CI와 workflow dispatch 릴리스 후보가 통과한 커밋을 Apple Silicon 실기기에서 검증합니다.
4. `docs/macos-validation.md`의 production URL 이전 게이트를 기록합니다.
5. 고정 커밋에 `release-lock.json`의 태그를 생성하고 push합니다.

```sh
git tag -a v0.3.0 -m "codex-usage-statusline 0.3.0"
git push origin v0.3.0
```

태그 워크플로는 같은 검증과 빌드를 다시 수행하고 prerelease 상태의 draft GitHub Release를 만듭니다. 모든 파일을 업로드한 뒤 다시 다운로드해 전체 자산 집합, RSA 서명, 태그 커밋, SHA-256을 검증해야만 prerelease로 공개합니다. 이미 공개된 동일 태그 릴리스가 있으면 파일을 교체하지 않고 기존 자산이 현재 태그 커밋에 결속됐는지 검증한 뒤 종료합니다.

production Release URL 설치·제거 게이트와 문서 기록이 끝난 뒤 `gh release edit v0.3.0 --prerelease=false --latest`로 정식 릴리스로 승격합니다. 이 승격 전에는 README와 GitHub Release 모두 Apple Silicon 지원 완료를 표시하지 않습니다.

## 릴리스 자산

각 대상은 아카이브, sidecar, 외부 metadata 세 파일을 가집니다.

```text
codex-usage-statusline-<project>-codex-<codex>-x86_64-pc-windows-msvc.zip
codex-usage-statusline-<project>-codex-<codex>-aarch64-apple-darwin.tar.gz
각 아카이브의 .sha256
각 대상의 .metadata.json
release-manifest.json
SHA256SUMS
SHA256SUMS.sig
```

아카이브 안에는 실행 파일, `LICENSE`, `NOTICE.md`, `BUILD-METADATA.json`만 포함합니다. 내부 metadata와 외부 metadata는 JSON 값이 완전히 같아야 합니다.

## 공개 후 확인

GitHub Release가 공개되면 Apple Silicon 실기기에서 기본 HTTPS URL을 사용하는 설치기를 다시 실행합니다.

- 설치 전, 설치 후, 제거 후 `~/.codex/config.toml`의 존재 상태와 SHA-256 기록
- 새 zsh와 bash의 `command -v codex`, `codex --version`
- 세 언어의 실제 TUI 상태줄
- 다운로드 아카이브와 설치 바이너리 SHA-256
- `codesign --verify --deep --strict`와 `spctl` 결과
- 제거 후 공식 Codex 경로 복원

설치기는 production URL을 사용할 때 원격 태그의 peeled commit을 직접 조회해 서명된 `customizationCommit`과 대조합니다. 결과를 `docs/macos-validation.md`와 추적 이슈에 기록한 뒤에만 Apple Silicon 지원 완료를 표시하고 prerelease를 정식 릴리스로 승격합니다.

v0.3.0은 [태그 워크플로 run 29089398011](https://github.com/LLL-toolkit/codex-usage-statusline/actions/runs/29089398011)에서 빌드·서명·게시됐고, [v0.3.0 production Release URL](https://github.com/LLL-toolkit/codex-usage-statusline/releases/tag/v0.3.0)의 Apple Silicon 실기기 설치·실행·제거 게이트를 통과했습니다. 장비, 해시와 Gatekeeper 결과는 [macOS 검증 기록](macos-validation.md)에 고정합니다.

## 새 Codex 버전

1. 새 공식 태그의 객체, peeled commit, tree, Rust 버전과 Windows/macOS npm 플랫폼 게시 상태를 확인합니다.
2. 깨끗한 공식 소스에서 공통 상태줄 변경을 다시 적용하고 upstream 의미가 유지되는지 검토합니다.
3. 패치와 집중 테스트를 갱신합니다.
4. 새 프로젝트 SemVer로 잠금과 모든 설치기 상수를 갱신합니다.
5. 일반 CI, workflow dispatch, 실기기 릴리스 후보, 태그 릴리스, production URL 검증 순서로 진행합니다.

이 프로젝트의 바이너리는 OpenAI 공식 서명이 아닌 독립 수정본입니다. 릴리스 설명과 `NOTICE.md`에서 이 사실을 계속 명시합니다.
