# PaperChat

PaperChatは、Zoteroの論文PDFをmacOS・iPadOS・iOSで読み、論文ごとの会話と閲覧位置を自宅サーバーへ保存するUniversal Appです。

## MVPの構成

- SwiftUI + PDFKitの単一Xcodeターゲット（macOS 15 / iOS・iPadOS 18以降）
- FastAPI + SQLiteのPaperChat API
- access token、ローテーションするrefresh token、端末単位の失効
- Zotero検索、PDF Range配信、端末キャッシュ、閲覧位置同期
- 複数チャットスレッド、SSE回答、ページ引用ジャンプ、Zoteroで開く
- `codex app-server`とテスト用`FakeLLMBackend`の交換可能なバックエンド
- PaperChatと`zotero-mcp-library`をまとめたDocker Compose

Web PDF取り込み、Safari Share Extension、Obsidian保存、PDF注釈はMVP後の範囲です。

## ローカルテスト

```sh
uv sync
uv run pytest
uv run ruff check server

xcodebuild -project client/PaperChat.xcodeproj -scheme PaperChat \
  -sdk macosx -derivedDataPath /tmp/paperchat-macos \
  CODE_SIGNING_ALLOWED=NO build

xcodebuild -project client/PaperChat.xcodeproj -scheme PaperChat \
  -sdk iphonesimulator -derivedDataPath /tmp/paperchat-ios \
  CODE_SIGNING_ALLOWED=NO build
```

サーバーのDockerテストでは実Codex資格情報を使いません。

```sh
docker compose -f compose.yaml -f compose.test.yaml \
  run --build --rm --no-deps paperchat-api
```

## 既存Zotero環境からのデプロイ

前提として、このリポジトリと`zotero-mcp-library`を同じ親ディレクトリに配置し、後者の`.env`にZotero設定を保存します。実際のホスト名や資格情報はGitへ追加しません。

`scripts/deploy-home.sh`は次を行います。

1. 既存のZotero永続ボリュームとDBを読み取り確認する
2. PaperChat用secretをリモートの専用named volumeへ配置する
3. 旧`zotero-mcp-library` Composeをボリューム削除なしで停止する
4. 同じZoteroボリュームをPaperChat Composeへ接続して一式を起動する

Docker contextを使う場合:

```sh
cp .env.example .env
./scripts/prepare-secrets.sh
DOCKER_CONTEXT=home ./scripts/deploy-home.sh
```

SSH Docker hostを直接使う場合:

```sh
DOCKER_HOST_URL=ssh://user@server.example \
PAPERCHAT_BIND_ADDRESS=0.0.0.0 \
PAPERCHAT_PUBLIC_BASE_URL=http://server.local:8001 \
./scripts/deploy-home.sh
```

`down`に`--volumes`を付けないでください。既定では既存の`zotero-mcp-library_zotero_data`をexternal volumeとして再利用します。

## Codex認証

デプロイ先で対話的なdevice authを行うのが安全です。

```sh
docker exec -it -e CODEX_HOME=/data/codex/home \
  paperchat-paperchat-api-1 codex login --device-auth
docker exec -e CODEX_HOME=/data/codex/home \
  paperchat-paperchat-api-1 codex login status
```

認証後、`LLM_BACKEND=codex`でPaperChat APIを再作成します。通常のE2E検証だけなら`LLM_BACKEND=fake`を使用できます。

`scripts/prepare-secrets.sh`は、内部REST用の`zotero_service_token`とは別に、CodexからZotero MCPへ接続するための`zotero_mcp_token`を生成します。専用トークンはDocker Secretとして両コンテナへ渡され、Codex子プロセスのBearer認証にだけ使用されます。MCP URLの既定値はCompose内部の`http://zotero-library-app:8000/mcp`です。

実論文の本文を送らずに、Codex接続・ストリーミング・thread再開だけを確認できます。

```sh
docker exec -i paperchat-paperchat-api-1 /app/.venv/bin/python - \
  < scripts/codex-smoke-test.py

docker exec -i paperchat-paperchat-api-1 /app/.venv/bin/python - \
  < scripts/codex-api-smoke-test.py
```

後者は、一時SQLite上で認証、synthetic paper、HTTP/SSE、会話保存、Codex thread ID保存まで確認します。実論文を使ったCodex E2E試験は、PDF本文がOpenAIへ送信されることを確認したうえで実行してください。

## アプリの接続

Xcodeで[PaperChat.xcodeproj](client/PaperChat.xcodeproj)を開き、Mac、iPad、またはiPhoneを実行先にします。初回画面へ次を入力します。

- Server URL: PaperChat APIのLANまたはHTTPS URL
- Bootstrap token: `.secrets/paperchat_bootstrap_token`の内容

端末用tokenはKeychainへ保存され、access token失効時は自動更新されます。「Sign Out」はサーバー側の該当端末セッションも失効させます。

## デプロイスモークテスト

コンテナ内のbootstrap tokenを使い、秘密値を出力せずに主要APIを確認できます。

```sh
docker exec -i paperchat-paperchat-api-1 \
  python - http://127.0.0.1:8000 ATTACHMENT_KEY \
  < scripts/smoke-test.py
```

検索、論文解決、PDF Range、閲覧位置、SSEチャット、履歴永続化、refresh tokenローテーションを検証します。
