# codex-usage-statusline

[한국어](README.md) · [English](README.en.md) · **日本語**

Windows x64 の Codex CLI フッターに、コンテキスト・5時間・週間の使用量を10区画のバーと正確な使用率で表示します。通常はラベンダー色、60%以上は黄色、85%以上は赤色です。

```text
gpt-5.6-sol low · コンテキスト ██░░░░░░░░ 18% · 使用量 █░░░░░░░░░ 7% (リセットまで 3h 42m) · 週間 █████░░░░░ 49% (リセットまで 2d 23h)
```

## 最も簡単なインストール

現在の Codex CLI に次の文をそのまま依頼してください。

```text
https://github.com/LLL-toolkit/codex-usage-statusline をこの Windows x64 コンピューターにインストールしてください。
Codex のインストール方法を検出し、リポジトリの公式 Windows インストーラーを使用して、表示言語を日本語に設定し、インストール確認まで完了してください。必要なツールは自動で準備し、ユーザーに手動インストールを依頼しないでください。
```

既定のインストーラーは Windows x64 と Codex のバージョンを確認し、固定された GitHub Release から適切なファイルを取得して SHA-256 を検証します。通常はビルドツール不要ですが、保守や将来のプラットフォーム対応で必要なら、AI が Rust とプラットフォームツールを自動で準備できます。ユーザーが途中の導入作業を行う必要はありません。

完了後は現在の Codex と既存のターミナルアプリを完全に終了し、新しいターミナルを一度開いてください。公式 Codex は変更せず、検証済みのカスタム版をユーザー PATH の先頭から実行します。Windows インストーラーは、現在のユーザー範囲で解決できる Codex コマンドに対応します。

## 手動インストール

次のクローン手順を手動で使う場合だけ Git が必要です。

Windows x64:

```powershell
git clone https://github.com/LLL-toolkit/codex-usage-statusline.git
cd codex-usage-statusline
powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 -Language ja
```

既定言語は `ko` です。`-Language` で `en`、`ja` も選択できます。

## 必要条件と互換性

- 動作中の Codex CLI とインターネット接続
- Codex CLI **0.144.1**
- 現在のユーザー範囲でコマンドを解決できる Windows x64 Codex

| プラットフォーム | リリースビルド | 実機検証 |
|---|---:|---:|
| Windows x64 | 自動化済み | 対応 |

macOS のバイナリとインストーラーはまだ配布していません。同じ Rust パッチを Apple Silicon に拡張する後続作業は、[macOS 作業引き継ぎ](docs/macos-validation.md)にまとめています。

Codex のバージョンが完全に一致しない場合やリリースファイルがない場合、何も変更せず終了します。Codex の内部 TUI は安定したプラグイン API ではないため、バージョンごとの検証が必要です。

## 確認

新しいターミナルで次を実行します。

```text
codex --version
codex
```

最初のリクエスト後、フッターに `コンテキスト`、`使用量`、`週間` のバーが表示されることを確認します。使用量データをまだ受信していない場合、5時間・週間の項目は表示されないことがあります。

インストーラーは `~/.codex/config.toml` を作成も編集もしません。自分で色を無効にしたい場合は、Codex の既存オプションを使用できます。

```toml
[tui]
status_line_use_colors = false
```

## アンインストール

Codex にこのステータスラインの削除を依頼するか、次を実行します。

Windows:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\uninstall.ps1
```

管理対象の PATH とカスタムバンドルだけを削除します。公式 Codex と `~/.codex/config.toml` は、インストールから削除まで変更しません。

## 仕組み

```text
リポジトリのインストーラー
  └─ Windows x64 と Codex バージョンを確認
      └─ 固定 GitHub Release と SHA-256 を検証
          └─ 公式 Codex のリソース一式をユーザー領域へ複製
              └─ 言語とステータスラインの -c 上書きを渡すランチャーを PATH の先頭へ追加
```

状態表示の実装は共通の Rust パッチ1つです。韓国語・英語・日本語は同じバイナリで実行時に切り替えます。ランチャーは実行のたびに `CODEX_USAGE_STATUSLINE_LANGUAGE` を設定し、`-c tui.status_line=[...]` の上書きを渡すため、ユーザーの設定ファイルへ状態表示設定を書き込む必要はありません。公式配布バイナリは、リリースタグ作成時に GitHub Actions で再現可能な形でビルドします。

状態は `%LOCALAPPDATA%\codex-usage-statusline` に保存します。

## セキュリティと制限

- 公式 Codex のタグ・コミットとパッチ SHA-256 を `release-lock.json` に固定します。
- CI はアーカイブとバイナリのハッシュを記録し、インストーラーは展開前に SHA-256 を確認します。
- 元の実行ファイルを上書きしないため、Windows で実行中の Codex からも準備できます。
- このプロジェクトは OpenAI の公式配布物ではありません。

[リリース手順](docs/release-process.md)と、将来の[Apple Silicon 実装引き継ぎ](docs/macos-validation.md)も参照してください。
