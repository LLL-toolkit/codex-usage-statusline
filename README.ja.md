# codex-usage-statusline

[한국어](README.md) · [English](README.en.md) · **日本語**

Windows版Codex CLIの使用状況ステータスラインです。残り上限のテキストを、使用量バー、正確なパーセント、リセット時刻、ラベンダーを基調とした警告色に置き換えます。

```text
gpt-5.6-sol low · コンテキスト ██░░░░░░░░ 18% · 使用量 █░░░░░░░░░ 7% (リセット in 3h 42m) · 週間 █████░░░░░ 49% (リセット in 2d 23h)
```

通常はラベンダー、60%以上は黄色、85%以上は赤で表示します。すべての数値は**使用済みの割合**です。

## インストール

### 必要なもの

- Windows x64
- `npm install -g @openai/codex`でインストールしたCodex CLI
- Git、Node.js/npm、Rustツールチェーン（`cargo`）
- リリースビルド用の約10GBの一時空き容量

実行中のCodexを終了してから、リポジトリをクローンしてインストーラーを実行します。

```powershell
git clone https://github.com/LLL-toolkit/codex-usage-statusline.git
cd codex-usage-statusline
powershell -ExecutionPolicy Bypass -File .\install.ps1 -Language ja
```

インストーラーはCodexのバージョンを検出し、対応するパッチを選び、公式タグのソースをテスト・ビルドします。既存の実行ファイルをバックアップしてから置き換えます。完了後にCodexを再起動してください。

## 確認

```powershell
codex
```

フッターに`コンテキスト`、`使用量`、`週間`のバーが表示されます。上限データが未取得の場合は、最初のリクエスト後に表示されることがあります。

## オプション

```powershell
.\install.ps1 -ForceRebuild
.\install.ps1 -KeepSource
.\install.ps1 -SkipTests       # 非推奨
.\install.ps1 -CodexVersion 0.144.1
.\install.ps1 -Language ko     # 韓国語（既定）
.\install.ps1 -Language en     # 英語
.\install.ps1 -Language ja     # 日本語
```

## アンインストール

Codexを終了してから最新のバックアップを復元します。

```powershell
powershell -ExecutionPolicy Bypass -File .\uninstall.ps1
```

## 互換性

| Codex CLI | プラットフォーム | 状態 |
|---|---|---|
| 0.144.1 | Windows x64、npm版 | 対応 |

Codexの内部TUIは安定した公開APIではないため、パッチはバージョンごとに管理します。未対応バージョンには安全のため適用しません。

## トラブルシューティング

- バージョン未対応: `patches/`に対応パッチが追加されるまで待つか、対応版を使用してください。
- ファイル使用中: すべてのCodexプロセスを終了して`-ForceRebuild`で再実行してください。
- ビルド失敗: `rustc`、`cargo`、`git`、`npm`の各コマンドを確認してください。
- 色を無効化: `%USERPROFILE%\.codex\config.toml`の`[tui]`に`status_line_use_colors = false`を設定してください。

ソースは公式OpenAIリポジトリの同一バージョンタグから取得します。置き換え前に元の実行ファイルをバックアップし、インストール検証に失敗した場合は自動的に復元します。
