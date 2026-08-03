# PaperChat 初期設計書

**版**: 0.2
**作成日**: 2026-07-28
**更新日**: 2026-07-28
**対象**: macOS / iPadOS 向け論文PDF閲覧・質問環境
**位置付け**: Zoteroを文献管理・注釈の基盤として維持しつつ，論文ごとの永続的なチャット体験を追加するMVP設計である．

---

## 1. 背景

現在は，Zotero Library内の論文PDFをChatGPT Atlasで開き，Side Chatから本文について質問する運用を中心としている．
この運用には，次の問題がある．

1. 同じPDFを再度開いても，以前のチャットがPDFに結び付いておらず，会話の再開が面倒である．
2. 同じPDFを複数回開いた際に，既存の閲覧セッションへ確実に復帰できない．
3. iPadでは同等の閲覧・質問体験を得られない．
4. Atlasの提供終了後に，現在の運用をそのまま継続できない．
5. OpenAI APIを用いるとChatGPTサブスクリプションとは別料金になる．

本システムでは，PDF閲覧，論文ごとの会話履歴，端末間同期，Zotero連携を一つの読書環境としてまとめる．
LLM実行基盤には，当面，ChatGPTプランに含まれるCodex枠を利用する．

## 2. 目的

本システムの目的は，Zotero LibraryおよびWeb上のPDFを対象として，次の体験を提供することである．

- 論文PDFとチャットスレッドを恒久的に対応付ける．
- MacとiPadで同じ論文，閲覧位置，チャット履歴を継続する．
- PDFを閲覧しながら，現在ページ，選択範囲，関連ページを文脈として質問する．
- Zoteroの書誌情報，PDF本文，Obsidian reference noteを必要に応じて参照する．
- API従量課金を必須とせず，Codex枠をLLMバックエンドとして利用する．
- 将来，OpenAI API，他社API，ローカルLLMへ切り替えられる構成にする．

## 3. 非目標

MVPでは次を対象外とする．

- Zotero全体の置き換え．
- Zotero Syncの再実装．
- Zotero形式の注釈データベースとの完全な双方向同期．
- Zotero iOSアプリのforkおよび継続保守．
- ChatGPT Webの非公式自動操作や回答DOMの抽出．
- 複数ユーザー向けサービスとしての公開．
- Zotero由来PDFをPaperChat固有の原本として恒久保管すること．
- `zotero-mcp-library`が持つZotero同期，PDF抽出，OCR，および全文索引機能の再実装．

## 4. 基本方針

### 4.1 クライアント

SwiftUIでmacOS / iPadOS共通アプリを作成し，PDF表示にはPDFKitを使用する．

- macOS: PDFとチャットを左右に並べる．
- iPadOS横向き: PDFとチャットを左右に並べる．
- iPadOS縦向き: PDFとチャットをタブまたは切替表示する．
- PDFは端末へキャッシュし，再閲覧時の再ダウンロードを避ける．
- Web上のPDFはURLから取り込み，後からZotero attachmentと統合できるようにする．

### 4.2 サーバー

自宅Ubuntuサーバー上にPaperChatサーバーを配置する．

- Python版Codex SDKを介して`codex app-server`を呼び出す．
- PaperChat DBに会話履歴を保存し，Codex threadとは再開用の対応を保持する．
- 文献ゲートウェイを介して，Zotero文献とPaperChatへ取り込んだ文献を統一的に扱う．
- MacとiPadの間でチャット履歴と閲覧状態を同期する．
- PaperChat固有の認証機能により，クライアントからのAPIアクセスを保護する．
- Docker Composeにより，ローカル環境でサーバー一式を起動できるようにする．

### 4.3 Zoteroとの役割分担

Zoteroは当面，次の役割を維持する．

- 書誌メタデータの管理．
- PDF添付ファイルの正規の保管元．
- 注釈の作成・同期．
- コレクション，タグ，ノートの管理．

PaperChatは次を担当する．

- ローカルPDFキャッシュ．
- 最近読んだ論文一覧．
- 閲覧位置・表示状態．
- 論文ごとのチャット履歴の基準データ．
- 現在ページ・選択範囲を用いた質問．
- Webまたはローカルから取り込んだPDF原本の保管．

### 4.4 `zotero-mcp-library`との役割分担

`zotero-mcp-library`は別リポジトリとして維持し，PaperChatのDocker Composeから固定バージョンのコンテナイメージを起動する．

`zotero-mcp-library`は次を担当する．

- Zotero Web APIからのメタデータ差分同期．
- Zotero PDFのダウンロードおよび削除可能なキャッシュ．
- PyMuPDFによるページ単位の本文抽出．
- 必要なページに対するOCR処理．
- 書誌情報およびページ本文の全文索引．
- citekey，item key，attachment keyによる文献検索およびページ取得．

PaperChatは`zotero-mcp-library`のSQLiteデータベースや保存ディレクトリを直接参照せず，内部APIまたはMCPを介して利用する．
これにより，両リポジトリの独立性を維持しつつ，利用者はPaperChatのDocker Composeから両サービスを一括して起動できる．

### 4.5 資格情報の分離

認証情報は用途ごとに分離する．

1. PaperChatクライアントは，PaperChatのaccess tokenおよびrefresh tokenを用いる．
2. PaperChatサーバーは，内部HTTP API専用のservice tokenを用いて`zotero-mcp-library`へ接続する．
3. `zotero-mcp-library`の同期workerだけがZotero API tokenを保持する．
4. CodexはZotero API tokenおよびOAuth資格情報を保持せず，Docker内部専用のMCP service tokenで`zotero-mcp-library`へ接続する．このtokenはPaperChat内部API用service tokenとも分離する．

## 5. システム構成

```text
┌────────────────────────────────────────┐
│ macOS / iPadOS PaperChat App           │
│ PDFKit Viewer / Chat / Local Cache     │
└───────────────────┬────────────────────┘
                    │ HTTPS + PaperChat auth
                    ▼
┌────────────────────────────────────────┐
│ PaperChat Backend                      │
│                                        │
│ - Authentication                      │
│ - Paper / Thread / Message DB          │
│ - Context Builder                      │
│ - LLM Backend Adapter                  │
│ - PaperChat Library Gateway            │
│ - Imported Document Store              │
└───────────┬────────────────┬───────────┘
            │                │ internal API service token
            ▼                ▼
    Codex SDK/app-server   zotero-mcp-library
            └───────────────▲
              MCP + dedicated service token
                              │ Zotero API token
                              ▼
                         Zotero Web API
```

## 6. 識別子設計

### 6.1 内部識別子

`Paper.id`にはPaperChatが生成するUUIDを用いる．
Zotero由来の識別子，Web URL，およびファイルハッシュは，内部識別子とは別に管理する．

### 6.2 Zotero内PDF

Zotero内PDFの外部識別子には，library type，library ID，およびattachment keyを用いる．

```text
zotero:<library_type>:<library_id>:<attachment_key>
例: zotero:user:1234567:FZYV8SH8
```

この外部識別子を用いる理由は次のとおりである．

- ローカルファイルパスやファイル名の変更に依存しない．
- MacとiPadで同一のPDFを識別できる．
- 個人ライブラリとグループライブラリを区別できる．
- Zotero item，Obsidian note，チャット履歴を結び付けられる．
- ページ抽出APIや既存のZotero連携と整合する．

### 6.3 Web上のPDF

取得時点では正規化URLとファイルハッシュを外部識別子として登録する．

```text
web:<sha256(canonical_url)>
file:<sha256(file_bytes)>
```

後から同一PDFがZoteroへ登録された場合は，DOI，タイトル，ページ数，およびPDFハッシュにより同一候補を提示する．
統合時も`Paper.id`は変更せず，Zotero外部識別子を同じPaperへ追加する．

## 7. 主要ユースケース

### 7.1 Zotero Libraryから論文を開く

1. アプリ内でZotero Libraryを検索する．
2. PaperChatサーバーが`zotero-mcp-library`を介してattachment情報を取得する．
3. ローカルキャッシュを確認する．
4. 未取得または更新済みなら，PaperChat APIからPDFをダウンロードする．
5. 前回のページ，ズーム，アクティブスレッドを復元する．
6. PDFとチャットを表示する．

クライアントはZotero Web APIを直接呼び出さず，Zotero API tokenを保持しない．
PaperChatサーバーは`zotero-mcp-library`がキャッシュしたPDFを内部APIから取得し，HTTP RangeおよびETagに対応した形でクライアントへ配信する．

### 7.2 Web上のPDFを開く

1. Safari共有メニューまたはSafari拡張からURLを受け取る．
2. 公開URLの場合は，PaperChatサーバーがPDFを取得する．
3. Cookieまたは機関認証が必要な場合は，クライアントが取得したPDFをPaperChatサーバーへアップロードする．
4. サーバーはPDFのSHA-256を計算し，重複を確認して原本を保存する．
5. URLおよびファイルハッシュを外部識別子としてPaperを作成する．
6. 本文抽出および索引作成の完了後，論文専用チャットを開始する．
7. 必要に応じてZoteroへ登録する．

サーバーがURLを取得する経路では，接続先IPアドレスおよびリダイレクト先を検証し，ローカルネットワークやクラウドメタデータサービスへの接続を拒否する．

### 7.3 現在ページについて質問する

質問時に次をサーバーへ送る．

- paper ID．
- thread ID．
- 現在ページ番号．
- 選択テキスト．
- 表示中ページの画像（必要な場合のみ）．
- ユーザー質問．

サーバーは必要に応じて次を補う．

- 前後ページの抽出テキスト．
- PDF全文検索結果．
- Zotero書誌情報．
- 過去スレッド要約．
- Obsidian reference note．

### 7.4 別の論文を参照する

現在の論文以外の情報が必要な場合，Codexは`zotero-mcp-library`の読み取り専用MCPツールを直接利用する．登録済みツールは原則すべて利用可能とし，質問に必要な範囲をagentが判断する．

- `search_papers`により，Zoteroライブラリ全体から関連文献を検索する．
- `search_evidence`により，特定文献内の根拠箇所を検索する．
- `fetch`または`fetch_pages`により，必要な文献の限定されたページ範囲を取得する．
- citekey/item key/attachment keyによる書誌情報取得およびページ一覧ツールも利用できる．

### 7.5 以前の会話を再開する

paper IDに対応するスレッド一覧を取得し，最後に使用したスレッドを既定で開く．
論文ごとに複数スレッドを持てるようにする．
PaperChat DBの履歴を優先し，Codex threadを再開できない場合は，保存済みメッセージおよび要約から新しいCodex threadを構成する．

例:

```text
Main
Section 3.2
式 (4.20)
安定性解析
関連文献
```

### 7.6 Zoteroで注釈する

MVPでは「Zoteroで開く」操作を提供する．
PaperChatで閲覧中のページ番号を可能な範囲で引き渡す．
注釈後にPaperChatへ戻った際は，同じPDFキャッシュを再利用する．

## 8. クライアント設計

### 8.1 画面構成

#### Library / Recent

- 最近読んだ論文．
- Zotero Library検索．
- Web PDF取り込み．
- 未読，ピン留め，最近更新された論文．

#### Reader

- PDFKitビューア．
- ページ番号，検索，アウトライン，サムネイル．
- 選択範囲から「質問する」．
- 現在ページを画像として添付．
- 「Zoteroで開く」．

#### Chat

- 論文内のスレッド一覧．
- ストリーミング回答．
- ページ引用をタップして該当ページへ移動．
- 回答の一部をObsidian noteへ保存．
- 新しいスレッドを作成．

### 8.2 ローカルキャッシュ

```text
Application Support/PaperChat/
├── papers/
│   └── zotero-FZYV8SH8/
│       ├── document.pdf
│       ├── metadata.json
│       ├── state.json
│       └── thumbnails/
└── database.sqlite
```

キャッシュ方針:

- Zotero item versionまたはETagを保存する．
- 変更がなければ再ダウンロードしない．
- 手動で「端末から削除」を可能にする．
- ストレージ上限を設定し，LRUで古いPDFを削除できるようにする．
- ピン留めされたPDFは自動削除しない．

### 8.3 オフライン時

- キャッシュ済みPDFの閲覧は可能．
- 閲覧位置，メモ，送信待ち質問はローカル保存する．
- チャット送信はオンライン復帰後に明示的に再実行する．
- サーバー側履歴と競合した場合は，メッセージ単位で追記し，破壊的な上書きを避ける．

## 9. サーバー設計

### 9.1 コンポーネント

- API Server：FastAPIを第一候補とする．
- Database：SQLiteから開始し，必要になった場合にPostgreSQLへ移行する．
- Codex Adapter：Python版Codex SDKをラップし，内部で`codex app-server`を利用する．
- Context Builder：現在ページ，選択範囲，会話履歴，および検索結果から入力文脈を構成する．
- Library Gateway：Zotero文献とPaperChat取り込み文書に対する統一インターフェースを提供する．
- Imported Document Store：Webまたはローカルから取り込んだPDF原本と派生データを管理する．
- Obsidian Adapter：reference noteの検索および追記を任意機能として提供する．

### 9.2 文献リポジトリ境界

PaperChat内では，保存元の違いを次のインターフェースで隠蔽する．

```text
DocumentRepository
- get_document(id)
- get_pdf(id)
- fetch_pages(id, page_range)
- search_documents(query, scope)
- render_page(id, page_index)
```

初期実装は次の2種類とする．

- `ZoteroDocumentRepository`は，`zotero-mcp-library`の内部APIまたはMCPを利用する．
- `ImportedDocumentRepository`は，PaperChatへ取り込んだWebまたはローカルPDFを管理する．

PaperChatは`zotero-mcp-library`のデータベースおよび共有ボリュームを直接参照しない．
PDF本文，PDFファイル，およびページ画像は，認証された内部APIを介して取得する．

### 9.3 クライアント向けAPI案

```text
GET    /api/papers/{paper_id}
GET    /api/papers/{paper_id}/threads
POST   /api/papers/{paper_id}/threads
GET    /api/threads/{thread_id}/messages
POST   /api/threads/{thread_id}/messages
GET    /api/threads/{thread_id}/events
PATCH  /api/papers/{paper_id}/reading-state
POST   /api/papers/resolve
POST   /api/imports/url
POST   /api/imports/upload
GET    /api/papers/{paper_id}/pdf
POST   /api/papers/{paper_id}/note
```

ストリーミングにはSSEを第一候補とする．
イベントIDと`Last-Event-ID`による再接続，生成のキャンセル，および切断後の状態遷移を定義する．
双方向制御が必要になった場合のみWebSocketを追加する．

### 9.4 Codex Adapter

Codex固有の処理を抽象化する．
独自のネイティブアプリからChatGPT Webの利用枠を使う汎用会話APIはないため，ChatGPT認証とCodex枠を利用できるCodex SDKを暫定的に採用する．
Responses APIなどの汎用APIを採用する場合は，ChatGPTサブスクリプションとは別の従量課金が必要になる．
ChatGPT AppsおよびMCPはChatGPT内の機能を拡張する仕組みであり，PaperChat固有のチャット画面へモデル応答を返すAPIとしては使用しない．

```text
LLMBackend
- create_thread(context) -> ThreadReference
- send(thread, request) -> Stream<ChatEvent>
- summarize(thread) -> Summary
- restore(messages, summary) -> ThreadReference
```

次の実装を差し替え可能にする．

- CodexBackend．
- OpenAIAPIBackend．
- LocalLLMBackend．
- 他社API Backend．

MVPではCodexBackendを採用するが，Codexはコーディング用途を主対象とするため，Phase 0で論文質問への適合性を検証する．
PaperChat DBを会話履歴の基準データとし，Codex threadは再開と文脈維持のための外部状態として扱う．

### 9.5 Codex実行権限

PDF質問用途では，Codexの権限を最小化する．

- sandbox: read-only．
- shell実行: 原則無効．
- network: PaperChat文献ゲートウェイなど，必要な内部サービスのみに限定．
- workspace: 専用ディレクトリのみ．
- approval: 外部操作は拒否またはユーザー確認．

CodexにはPDF保存ディレクトリ全体をマウントしない．
通常は抽出本文をテキストとして渡し，図表または数式を確認する場合だけ，サーバーが生成したページ画像を渡す．
別の論文を参照する場合は，`zotero-mcp-library`の読み取り専用MCPツールを利用する．

## 10. データモデル

### 10.1 Paper

```text
Paper
- id: UUID
- title
- authors
- year
- created_at
- updated_at
```

### 10.2 PaperIdentifier

```text
PaperIdentifier
- paper_id
- kind: zotero | canonical_url | file_hash | doi | citekey
- library_type
- library_id
- value
- created_at
```

`Paper.id`は外部識別子の統合時にも変更しない．
Zotero PDFはlibrary type，library ID，およびattachment keyの組で一意に識別する．

### 10.3 ImportedDocumentBlob

```text
ImportedDocumentBlob
- id
- paper_id
- content_hash
- byte_size
- media_type
- storage_policy: cache | retained
- source_version
- etag
- last_accessed_at
- created_at
```

この表はPaperChatが管理するWebまたはローカル由来のPDFに用いる．
Zotero PDFの保存状態は`zotero-mcp-library`が管理し，PaperChat DBにはその内部保存パスを記録しない．
`cache`は公開URLから再取得できるPDFに用い，`retained`は再取得を保証できない取り込み原本に用いる．

### 10.4 ImportedDocumentPage

```text
ImportedDocumentPage
- document_blob_id
- page_index
- printed_page_label
- text
- extraction_method
- text_hash
- extractor_version
- created_at
```

`page_index`は0始まりのPDF内部ページ番号とする．
画面表示には1を加え，論文に印刷されたページ番号は`printed_page_label`として別に保持する．
Zotero PDFのページ本文は`zotero-mcp-library`が管理し，文献ゲートウェイを介して取得する．

### 10.5 ReadingState

```text
ReadingState
- paper_id
- device_id
- page_index
- scroll_offset
- zoom_scale
- display_mode
- active_thread_id
- updated_at
```

ページ位置とアクティブスレッドは端末間で引き継ぐ．
ズーム倍率と表示モードは端末固有の値として扱い，他端末へ強制的に適用しない．

### 10.6 Thread

```text
Thread
- id
- paper_id
- title
- backend_type
- backend_thread_id
- backend_last_synced_message_id
- backend_status
- summary
- is_primary
- last_used_at
- created_at
- updated_at
```

### 10.7 Message

```text
Message
- id
- thread_id
- role
- content
- page_refs
- selected_text
- client_request_id
- backend_turn_id
- status: pending | streaming | completed | failed | cancelled
- created_at
- updated_at
```

`client_request_id`を冪等性キーとして用い，ネットワーク切断後の再送による重複登録を防ぐ．
`page_refs`には内部ページ番号，印刷ページラベル，引用範囲，および必要に応じて矩形座標を保存する．

## 11. PDF本文の扱い

### 11.1 保存方針

Zotero PDFではZoteroを原本の管理元とし，`zotero-mcp-library`が保持するPDFは再取得可能なキャッシュとする．
WebまたはローカルからPaperChatへ取り込んだPDFでは，PaperChatサーバーに保存したファイルを原本とする．
PDFは内容のSHA-256により重複排除し，抽出本文，検索索引，およびページ画像は再生成可能な派生データとして扱う．

PaperChat取り込み文書に対するサーバー上の論理的な保存構造は次のとおりとする．

```text
/data/
├── documents/
│   └── sha256/
│       └── ab/cd/<hash>.pdf
├── renders/
│   └── <hash>/page-0001-144dpi.webp
├── search-index/
├── database/
│   └── paperchat.sqlite3
└── codex/
    ├── home/
    └── workspaces/
```

物理パスはDBの公開識別子として使用しない．
ページ画像には容量上限とLRU削除を適用する．
Zotero PDF，その抽出本文，および検索索引は`zotero-mcp-library`固有の永続ボリュームで管理する．

### 11.2 文脈構成

毎回PDF全体をCodexへ渡さない．
質問に応じて，次の優先順位で文脈を構成する．

1. 選択テキスト．
2. 現在ページ．
3. 前後2〜3ページ．
4. 全文検索の上位結果．
5. 過去会話の要約．
6. ページ画像．

現在の論文以外の文献が必要な場合は，Codexが`zotero-mcp-library`のMCPツールで検索し，必要なページを取得する．

### 11.3 数式・図表

テキスト抽出だけでは不十分な場合，現在ページまたは指定ページをサーバー側で画像化して添付する．
CodexにはPDFファイルの保存領域を直接参照させず，必要なページ画像だけを入力する．

### 11.4 引用

回答にはページ番号を付ける．
ページ参照をタップするとPDFビューアが該当ページへ移動する．
将来，矩形座標まで保持できる場合は，該当箇所を一時的にハイライトする．

## 12. 注釈方針

### MVP

- 注釈の作成はZotero iPad / Desktopへ委ねる．
- PaperChatでは既存PDF注釈を表示できる範囲で表示する．
- 「Zoteroで開く」を提供する．

### 将来候補

1. PDFKitによる標準PDF注釈．
2. Apple Pencilによるインク注釈．
3. Zotero annotation itemへの変換．
4. Zotero注釈DBとの双方向同期．

完全同期は複雑であるため，利用頻度と必要性を確認してから実装する．

## 13. Docker Compose，テスト，およびデプロイ

### 13.1 ローカル起動

PaperChatサーバーは`docker compose up --build`により起動できるようにする．
PaperChatのComposeは，PaperChat API，Codex runtime，取り込み文書処理worker，および固定バージョンの`zotero-mcp-library`サービス群を構成する．
Python版Codex SDKはPaperChat APIコンテナ内で固定バージョンの`codex app-server`を子プロセスとして起動し，実験的なネットワークWebSocket transportには依存しない．
既に`zotero-mcp-library`が稼働している環境では，内部URLとservice tokenを指定して外部サービスとして利用できるようにする．

### 13.2 Compose構成

```text
compose.yaml
├── paperchat-api
├── imported-document-worker
├── zotero-library-app
├── zotero-library-worker
└── zotero-library-extractor

compose.test.yaml
├── test command override
├── FakeLLMBackend
├── Zotero fixture service
└── temporary volumes
```

Zotero API tokenは`zotero-mcp-library`の同期workerだけに渡す．
PaperChat APIと`zotero-mcp-library`の間では，Docker secretとして渡した専用のservice tokenを用いる．
内部サービスは原則としてホストへポートを公開しない．
`zotero-mcp-library`には，Docker secretからの資格情報読み込み，service token認証，PDF Range配信，およびページ画像生成に必要な内部APIを追加する．

### 13.3 ローカルDockerテスト

サーバーの単体テスト，統合テスト，およびAPIテストはローカルDockerで実行する．
通常の自動テストでは`FakeLLMBackend`，固定されたZotero応答，およびPDF fixtureを用い，実際のChatGPT認証およびCodex利用制限に依存しないようにする．
実Codex接続試験は明示的に有効化する試験として分離する．
macOSおよびiPadOSクライアントのテストはLinuxコンテナの対象外とし，Xcode上で実行する．

### 13.4 本番デプロイ

本番デプロイ定義はローカルテスト用Composeと分離する．
本番でも同じ固定バージョンのコンテナイメージを利用するが，secret，永続ボリューム，TLS終端，バックアップ，および公開経路は別のデプロイ設定で管理する．
本番固有のホスト名，資格情報，およびサーバー構成はリポジトリへ記録しない．

## 14. セキュリティ

- サーバーを公衆向けに無認証公開しない．
- PaperChat API全体にPaperChat固有の認証を適用する．
- ネイティブアプリの認証にはAuthorization CodeとPKCEを用いる．
- access tokenは短時間で失効させ，refresh tokenはローテーションする．
- refresh tokenは端末のKeychainに保存し，端末単位で失効できるようにする．
- Codex認証情報をクライアントへ配布しない．
- Zotero API tokenはDocker secretとして`zotero-mcp-library`の同期workerだけに渡す．
- PaperChatと`zotero-mcp-library`の間では，Zotero API tokenとは異なるservice tokenを用いる．
- PDF配信URLには短時間の署名付きURLを用いる．
- ログにはPDF本文，選択テキスト，認証情報を原則として残さない．
- Codex runtimeからホームディレクトリ全体を参照できないようにする．
- Codexコンテナは非rootユーザーで動作させ，Linux capabilityを削除し，Docker socketをマウントしない．
- PDF本文は信頼できない入力として扱い，システム指示およびツール結果と明確に分離する．
- URLによるPDF取得では，SSRF対策，ファイル容量上限，MIME type，およびPDFヘッダーを検証する．

## 15. MVP範囲

### 必須

- macOSアプリ．
- Zotero attachment keyからPDFを取得．
- ローカルキャッシュ．
- PDFKitによる表示．
- 最近読んだ論文一覧．
- 閲覧位置の保存．
- 論文ごとのチャットスレッド．
- Codex SDK経由のストリーミング回答．
- PaperChat DBへの会話履歴保存．
- 現在ページ・選択テキストの送信．
- ページ参照からPDFへ移動．
- 「Zoteroで開く」．
- PaperChat固有の認証および端末単位のセッション失効．
- Docker Composeによるサーバー起動．
- FakeLLMBackendを用いたローカルDockerテスト．

### 可能なら含める

- iPadOS共通アプリ．
- 閲覧位置と履歴の端末間同期．
- Web PDFの取り込み．
- Safari Share Extension．
- Obsidian noteへの保存．
- PaperChat取り込み文書の全文検索．

### MVP後

- 標準PDF注釈．
- Apple Pencil対応．
- Zotero annotation同期．
- 関連文献推薦．
- 高度な論文横断チャット．
- Zotero Sync代替．

## 16. 実装段階

### Phase 0: 技術検証

- Python版Codex SDKをDocker内で起動する．
- ChatGPT認証でCodex枠を利用できることを確認する．
- thread再開，ストリーミング，利用制限の取得を確認する．
- 論文質問，数式，図表，長い会話，および別論文検索の品質を確認する．
- PaperChat DBからCodex threadを再構成できることを確認する．
- 日常利用に必要な応答速度およびCodex利用量を測定する．

### Phase 1: 単一端末MVP

- macOSアプリ．
- PDFKit表示．
- ローカルPDF読み込み．
- 単一論文・単一スレッド．
- Codexとのチャット．
- PaperChat DBへの履歴保存．
- PaperChat固有の認証．
- Docker Composeによるサーバー起動およびテスト．

### Phase 2: Zotero統合

- `zotero-mcp-library`とのサービス間接続．
- Zotero Library検索．
- PaperChat API経由のPDF取得．
- キャッシュ，メタデータ，最近読んだ論文．
- 複数スレッド．
- 読み取り専用の論文横断検索．

### Phase 3: iPad対応

- SwiftUI共通化．
- iPadレイアウト．
- 閲覧位置・履歴同期．
- Safari共有からWeb PDFを取り込む．
- iPadでのログインおよび端末セッション管理．

### Phase 4: 研究ワークフロー統合

- Obsidian reference note連携．
- ページ引用ジャンプ．
- 図表・数式ページ画像．
- `/note`相当の保存操作．

### Phase 5: 注釈拡張

- 利用実績を見てPDFKit注釈を追加する．
- Zotero注釈との互換性を検証する．

## 17. 未決事項

1. `zotero-mcp-library`に追加するPDF Range配信およびページ画像生成のAPI形式．
2. PaperChat固有認証の初回端末登録方法．
3. iPadからZoteroアプリの特定PDFおよび特定ページを開く方法．
4. Web PDFとZotero attachmentの重複候補を自動統合するか，ユーザー確認を必須とするか．
5. PDF注釈をいつ，どの互換レベルで追加するか．
6. Codex枠の実際の消費量，応答速度，および論文質問の品質が日常利用に適するか．
7. Python版Codex SDKのベータ期間中に，どのバージョン更新方針を採用するか．

## 18. 初期判断

MVPでは次を採用する．

- クライアント: SwiftUI + PDFKit．
- 最初の対応OS: macOSとし，iPadOSは次の段階で追加する．
- サーバー: Python + FastAPIを第一候補とする．
- LLMバックエンド: Python版Codex SDKを介した`codex app-server`．
- 文献基盤: Zoteroを継続利用．
- Zotero連携: 別リポジトリの`zotero-mcp-library`を固定バージョンのコンテナとしてComposeから起動する．
- Zotero認証: Zotero API tokenは`zotero-mcp-library`の同期workerだけが保持する．
- サービス間認証: PaperChat専用のservice tokenを使用する．
- クライアント認証: PaperChat固有のaccess tokenおよびrefresh tokenを使用する．
- PDF取得: クライアントはPaperChat APIから取得し，Zotero Web APIを直接呼び出さない．
- PDF保存: Zotero PDFはサーバーおよび端末の削除可能なキャッシュとし，取り込みPDFはPaperChatサーバーに原本を保存する．
- 注釈: Zoteroへ委任．
- チャット履歴: PaperChat DBへ全文を保存して基準データとし，Codex threadは再開用の外部状態として扱う．
- Codex文献アクセス: Docker内部の専用MCP service tokenを用い，`zotero-mcp-library`の読み取り専用ツールを直接利用する．
- サーバー起動: Docker Composeを使用する．
- テスト: サーバー試験はローカルDockerで実行し，本番デプロイ定義は分離する．
- Web連携: Safari Share Extensionを後付けする．
- 将来性: LLM backendを抽象化し，Codex依存を局所化する．

この構成により，PaperChatは会話履歴とクライアント体験を管理し，`zotero-mcp-library`はZotero同期と派生文献データを管理する．
両者をAPI境界で分離することで，既存機能の重複実装を避けながら，単一のDocker Composeによる起動を可能にする．
Codexが論文質問に適さない場合も，PaperChat DBおよび文献ゲートウェイを維持したまま，別のLLMバックエンドへ切り替えられる．
