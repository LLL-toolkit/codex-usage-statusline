# codex-usage-statusline

[한국어](README.md) · [English](README.en.md) · **日本語**

Codex CLI のフッターに、コンテキスト・5時間・週間の使用量をバーと正確な使用率で表示します。通常はラベンダー色、60%以上は黄色、85%以上は赤色です。

```text
gpt-5.6-sol low · コンテキスト ██░░░░░░░░ 18% · 使用量 █░░░░░░░░░ 7% (リセットまで 3h 42m) · 週間 █████░░░░░ 49% (リセットまで 2d 23h)
```

## インストール

> Apple Silicon macOS 対応は v0.3.0 リリース候補の検証段階で、まだ一般インストールの対象ではありません。実機でのインストール・削除検証が完了するまでは、以下の macOS コマンドをリリース候補の開発検証だけに使用します。

現在の Codex CLI に次のように依頼します。

```text
https://github.com/LLL-toolkit/codex-usage-statusline をこのコンピューターにインストールし、検証まで完了してください。
この OS 用にリポジトリへ含まれているインストーラーを使い、表示言語を日本語に設定してください。
```

インストーラーは OS、CPU、Codex バージョンを確認し、固定された GitHub Release からビルド済みファイルを取得します。リリースのチェックサム、manifest、ビルドメタデータ、内部バイナリのハッシュをすべて検証してから、公式 Codex とは別のユーザー領域へ配置します。

完了後は現在の Codex とターミナルを閉じ、新しいターミナルを開いてください。公式 Codex は置き換えません。

リポジトリのインストーラーを直接実行する場合:

Apple Silicon macOS v0.3.0 リリース候補の開発検証用:

```sh
git clone https://github.com/LLL-toolkit/codex-usage-statusline.git
cd codex-usage-statusline
./install.sh --language ja
```

Windows x64:

```powershell
git clone https://github.com/LLL-toolkit/codex-usage-statusline.git
cd codex-usage-statusline
powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 -Language ja
```

既定言語は韓国語 `ko` です。英語 `en` と日本語 `ja` も選択できます。

## 互換性

- Codex CLI **0.144.1**
- Windows x64 は対応済み、Apple Silicon macOS v0.3.0 はリリース候補を検証中
- Intel Mac は非対応

| プラットフォーム | リリースビルド | 実機検証 |
|---|---:|---:|
| Windows x64 | 自動化済み | 対応 |
| Apple Silicon macOS | 自動化済み | v0.3.0 リリース候補を検証中 |

Codex の内部 TUI は安定したプラグイン API ではないため、バージョンの完全一致が必要です。バージョン、ファイル、ハッシュ、対象アーキテクチャが異なる場合は何も有効化せず終了します。

macOS インストーラーは、現在のユーザーで有効な公式 Codex を次の方式から検出します。

- OpenAI standalone インストーラー
- Homebrew
- npm のグローバルインストール

## 確認

新しいターミナルで次を実行します。

```text
command -v codex
codex --version
codex
```

最初のリクエスト後、フッターに `コンテキスト`、`使用量`、`週間` のバーが表示されることを確認します。5時間・週間の項目は、最初の使用量レスポンスまで表示されない場合があります。

インストーラーとアンインストーラーは `~/.codex/config.toml` を作成も編集もしません。ランチャーが呼び出しごとに `CODEX_USAGE_STATUSLINE_LANGUAGE` と次の設定を渡します。

```text
-c tui.status_line=['model-with-reasoning','context-used','five-hour-limit','weekly-limit']
```

## アンインストール

Apple Silicon macOS v0.3.0 リリース候補の開発検証用:

```sh
./uninstall.sh
```

Windows x64:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\uninstall.ps1
```

管理対象の PATH ブロック、ランチャー、カスタムバンドルだけを削除します。インストール後にバンドル内のファイルが追加または変更されていた場合は、バンドル全体を削除せず PATH だけを無効化します。プロファイルの他の内容、公式 Codex、`~/.codex/config.toml` は保持します。

## 仕組み

```text
リポジトリのインストーラー
  └─ OS・CPU・Codex バージョン・公式インストール方式を確認
      └─ 固定 Release の manifest・チェックサム・メタデータを検証
          └─ 公式 Codex のリソース一式をユーザー領域へ複製
              └─ 検証済みバイナリと呼び出し単位のランチャーを PATH の先頭へ追加
```

状態表示は共通の Rust パッチ1つで実装します。韓国語・英語・日本語は同じバイナリで実行時に選択します。

- Windows の状態: `%LOCALAPPDATA%\codex-usage-statusline`
- macOS の状態: `~/Library/Application Support/codex-usage-statusline`
- macOS の PATH ブロック: 設定時は絶対パスの `$ZDOTDIR/.zprofile`、それ以外は `~/.zprofile`、および `~/.bash_profile`

インストールと削除は、操作ロック、staging ディレクトリ、プロファイルの原子的編集、復旧 manifest を使用します。中断時は以前の状態へ戻り、再インストールでも管理ブロックを重複させません。

## macOS の署名と Gatekeeper

Apple Silicon バイナリはデバッグ情報を除去し、ad-hoc 署名後に `codesign --verify --deep --strict` で検査します。このリリースには Apple Developer ID 署名と公証がありません。そのため Finder やブラウザが隔離属性を付けたコピーは、Gatekeeper の `spctl` 評価で拒否される場合があります。

リポジトリのインストーラーは HTTPS Release と SHA-256 検証を使い、隔離属性を勝手に削除しません。Developer ID 署名と公証を利用できるまで、この制限は残ります。

## セキュリティ

- `release-lock.json` に公式 Codex のタグ・コミット・ツリー、Rust バージョン、パッチ SHA-256、対象アーキテクチャを固定します。
- インストーラーはリポジトリに固定した RSA 公開鍵で `SHA256SUMS.sig` を先に検証し、その後アーカイブ、内部バイナリ、対象メタデータ、`release-manifest.json`、`SHA256SUMS` を相互検証します。
- インストーラーはリモートのリリースタグの peeled commit と署名済み `customizationCommit` の完全一致を必須とします。
- macOS では arm64 専用 Mach-O と ad-hoc `codesign` 構造も検証します。
- 構造化パーサーは許可された通常ファイル4個だけを展開します。
- 元の実行ファイルと Codex の永続設定は変更しません。
- このプロジェクトは OpenAI の公式配布物ではありません。

[リリース手順](docs/release-process.md)と [macOS 検証記録](docs/macos-validation.md)も参照してください。
