# PaperChat 初期設計書

**版**: 0.1  
**作成日**: 2026-07-28  
**対象**: macOS / iPadOS 向け論文PDF閲覧・質問環境  
**位置付け**: MVP設計。Zoteroを文献管理・注釈の基盤として維持しつつ、論文ごとの永続的なチャット体験を追加する。

---

## 1. 背景

現在は、Zotero Library内の論文PDFをChatGPT Atlasで開き、Side Chatから本文について質問する運用を中心としている。この運用には、次の問題がある。

1. 同じPDFを再度開いても、以前のチャットがPDFに結び付いておらず、会話の再開が面倒である。
2. 同じPDFを複数回開いた際に、既存の閲覧セッションへ確実に復帰できない。
3. iPadでは同等の閲覧・質問体験を得られない。
4. Atlasの提供終了後に、現在の運用をそのまま継続できない。
5. OpenAI APIを用いるとChatGPTサブスクリプションとは別料金になる。

本システムでは、PDF閲覧、論文ごとの会話履歴、端末間同期、Zotero連携を一つの読書環境としてまとめる。LLM実行基盤には、当面、ChatGPTプランに含まれるCodex枠を利用する。

## 2. 目的

本システムの目的は、Zotero LibraryおよびWeb上のPDFを対象として、次の体験を提供することである。

- 論文PDFとチャットスレッドを恒久的に対応付ける。
- MacとiPadで同じ論文、閲覧位置、チャット履歴を継続する。
- PDFを閲覧しながら、現在ページ、選択範囲、関連ページを文脈として質問する。
- Zoteroの書誌情報、PDF本文、Obsidian reference noteを必要に応じて参照する。
- API従量課金を必須とせず、Codex枠をLLMバックエンドとして利用する。
- 将来、OpenAI API、他社API、ローカルLLMへ切り替えられる構成にする。

## 3. 非目標

MVPでは次を対象外とする。

- Zotero全体の置き換え。
- Zotero Syncの再実装。
- Zotero形式の注釈データベースとの完全な双方向同期。
- Zotero iOSアプリのforkおよび継続保守。
- ChatGPT Webの非公式自動操作や回答DOMの抽出。
- 複数ユーザー向けサービスとしての公開。
- 論文PDFの恒久的なサーバー保管。

## 4. 基本方針

### 4.1 クライアント

SwiftUIでmacOS / iPadOS共通アプリを作成し、PDF表示にはPDFKitを使用する。

- macOS: PDFとチャットを左右に並べる。
- iPadOS横向き: PDFとチャットを左右に並べる。
- iPadOS縦向き: PDFとチャットをタブまたは切替表示する。
- PDFは端末へキャッシュし、再閲覧時の再ダウンロードを避ける。
- Web上のPDFはURLから取り込み、後からZotero attachmentと統合できるようにする。

### 4.2 サーバー

自宅Ubuntuサーバー上に軽量な中継サービスを配置する。

- Codex SDKまたは`codex app-server`を呼び出す。
- Zotero Library検索、ページ抽出、ページ画像生成を提供する。
- 論文IDとCodex thread IDの対応を保存する。
- Mac・iPad間でチャット履歴と閲覧状態を同期する。
- Cloudflare AccessまたはTailscaleにより本人のみ利用可能にする。

### 4.3 Zoteroとの役割分担

Zoteroは当面、次の役割を維持する。

- 書誌メタデータの管理。
- PDF添付ファイルの正規の保管元。
- 注釈の作成・同期。
- コレクション、タグ、ノートの管理。

PaperChatは次を担当する。

- ローカルPDFキャッシュ。
- 最近読んだ論文一覧。
- 閲覧位置・表示状態。
- 論文ごとのチャット履歴。
- 現在ページ・選択範囲を用いた質問。

## 5. システム構成

```text
┌──────────────────────────────────────┐
│ macOS / iPadOS PaperChat App         │
│                                      │
│  Library / Recent                    │
│  ┌────────────────┬───────────────┐ │
│  │ PDFKit Viewer  │ Chat Panel    │ │
│  │                │               │ │
│  │ page/selection │ thread list   │ │
│  └────────────────┴───────────────┘ │
│       │ local cache         │ HTTPS  │
└───────┼─────────────────────┼────────┘
        │                     │
        ▼                     ▼
┌──────────────────────────────────────┐
│ PaperChat Backend                    │
│                                      │
│ - Authentication                    │
│ - Paper / Thread metadata            │
│ - Codex SDK adapter                  │
│ - Zotero adapter                     │
│ - PDF text / page rendering          │
│ - Obsidian adapter                   │
└──────────────┬───────────────┬───────┘
               │               │
               ▼               ▼
        Codex runtime      Zotero / Obsidian
```

## 6. 識別子設計

### 6.1 Zotero内PDF

Zotero attachment keyを恒久IDとして用いる。

```text
zotero:<attachment_key>
例: zotero:FZYV8SH8
```

attachment keyを主キーにする理由は次のとおりである。

- ローカルファイルパスやファイル名の変更に依存しない。
- MacとiPadで同一のPDFを識別できる。
- Zotero item、Obsidian note、チャット履歴を結び付けられる。
- ページ抽出APIや既存のZotero連携と整合する。

### 6.2 Web上のPDF

取得時点では正規化URLとファイルハッシュを用いる。

```text
web:<sha256(canonical_url)>
file:<sha256(file_bytes)>
```

後から同一PDFがZoteroへ登録された場合は、DOI、タイトル、ページ数、PDFハッシュによりZotero attachmentへ統合する。

## 7. 主要ユースケース

### 7.1 Zotero Libraryから論文を開く

1. アプリ内でZotero Libraryを検索する。
2. attachment keyを取得する。
3. ローカルキャッシュを確認する。
4. 未取得または更新済みならPDFをダウンロードする。
5. 前回のページ、ズーム、アクティブスレッドを復元する。
6. PDFとチャットを表示する。

### 7.2 Web上のPDFを開く

1. Safari共有メニューまたはSafari拡張からURLを受け取る。
2. PDFを端末へ保存する。
3. URLおよびファイルハッシュから一時paper IDを作成する。
4. 論文専用チャットを開始する。
5. 必要に応じてZoteroへ登録する。

### 7.3 現在ページについて質問する

質問時に次をサーバーへ送る。

- paper ID。
- thread ID。
- 現在ページ番号。
- 選択テキスト。
- 表示中ページの画像（必要な場合のみ）。
- ユーザー質問。

サーバーは必要に応じて次を補う。

- 前後ページの抽出テキスト。
- PDF全文検索結果。
- Zotero書誌情報。
- 過去スレッド要約。
- Obsidian reference note。

### 7.4 以前の会話を再開する

paper IDに対応するスレッド一覧を取得し、最後に使用したスレッドを既定で開く。論文ごとに複数スレッドを持てるようにする。

例:

```text
Main
Section 3.2
式 (4.20)
安定性解析
関連文献
```

### 7.5 Zoteroで注釈する

MVPでは「Zoteroで開く」操作を提供する。PaperChatで閲覧中のページ番号を可能な範囲で引き渡す。注釈後にPaperChatへ戻った際は、同じPDFキャッシュを再利用する。

## 8. クライアント設計

### 8.1 画面構成

#### Library / Recent

- 最近読んだ論文。
- Zotero Library検索。
- Web PDF取り込み。
- 未読、ピン留め、最近更新された論文。

#### Reader

- PDFKitビューア。
- ページ番号、検索、アウトライン、サムネイル。
- 選択範囲から「質問する」。
- 現在ページを画像として添付。
- 「Zoteroで開く」。

#### Chat

- 論文内のスレッド一覧。
- ストリーミング回答。
- ページ引用をタップして該当ページへ移動。
- 回答の一部をObsidian noteへ保存。
- 新しいスレッドを作成。

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

- Zotero item versionまたはETagを保存する。
- 変更がなければ再ダウンロードしない。
- 手動で「端末から削除」を可能にする。
- ストレージ上限を設定し、LRUで古いPDFを削除できるようにする。
- ピン留めされたPDFは自動削除しない。

### 8.3 オフライン時

- キャッシュ済みPDFの閲覧は可能。
- 閲覧位置、メモ、送信待ち質問はローカル保存する。
- チャット送信はオンライン復帰後に明示的に再実行する。
- サーバー側履歴と競合した場合は、メッセージ単位で追記し、破壊的な上書きを避ける。

## 9. サーバー設計

### 9.1 コンポーネント

- API Server: FastAPIまたはRust/Axum。
- Database: SQLiteから開始し、必要ならPostgreSQLへ移行。
- Codex Adapter: 公式SDKをラップする。
- Zotero Adapter: Web APIおよび既存Zotero検索基盤を利用する。
- PDF Service: テキスト抽出、全文検索、ページ画像生成。
- Obsidian Adapter: reference note検索・追記。

### 9.2 API案

```text
GET    /api/papers/{paper_id}
GET    /api/papers/{paper_id}/threads
POST   /api/papers/{paper_id}/threads
GET    /api/threads/{thread_id}/messages
POST   /api/threads/{thread_id}/messages
GET    /api/threads/{thread_id}/events
PATCH  /api/papers/{paper_id}/reading-state
POST   /api/papers/resolve
POST   /api/papers/{paper_id}/note
```

ストリーミングにはSSEを第一候補とする。双方向制御が必要になった場合のみWebSocketを追加する。

### 9.3 Codex Adapter

Codex固有の処理を抽象化する。

```swift
protocol LLMBackend {
    func createThread(context: PaperContext) async throws -> ThreadReference
    func send(thread: ThreadReference, request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error>
    func summarize(thread: ThreadReference) async throws -> String
}
```

サーバー実装側でも同等のinterfaceを設け、次を差し替え可能にする。

- CodexBackend。
- OpenAIAPIBackend。
- LocalLLMBackend。
- 他社API Backend。

### 9.4 Codex実行権限

PDF質問用途では、Codexの権限を最小化する。

- sandbox: read-only。
- shell実行: 原則無効。
- network: 必要なZotero / Obsidianサービスのみに限定。
- workspace: 専用ディレクトリのみ。
- approval: 外部操作は拒否またはユーザー確認。

## 10. データモデル

### 10.1 Paper

```text
Paper
- id
- source_type: zotero | web | local
- zotero_attachment_key
- zotero_item_key
- citekey
- canonical_url
- file_hash
- title
- authors
- year
- version
- created_at
- updated_at
```

### 10.2 ReadingState

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

端末別状態を保存しつつ、最終更新状態を他端末の初期値として利用する。

### 10.3 Thread

```text
Thread
- id
- paper_id
- title
- backend_type
- backend_thread_id
- summary
- is_primary
- last_used_at
- created_at
- updated_at
```

### 10.4 Message

```text
Message
- id
- thread_id
- role
- content
- page_refs
- selected_text
- status
- created_at
```

`page_refs`にはページ番号、引用範囲、必要に応じて矩形座標を保存する。

## 11. PDF本文の扱い

### 11.1 基本

毎回PDF全体をCodexへ渡さない。質問に応じて、次の優先順位で文脈を構成する。

1. 選択テキスト。
2. 現在ページ。
3. 前後2〜3ページ。
4. 全文検索の上位結果。
5. 過去会話の要約。
6. ページ画像。

### 11.2 数式・図表

テキスト抽出だけでは不十分な場合、現在ページまたは指定ページを画像化して添付する。画像化は端末側またはサーバー側で行う。

### 11.3 引用

回答にはページ番号を付ける。ページ参照をタップするとPDFビューアが該当ページへ移動する。将来、矩形座標まで保持できる場合は、該当箇所を一時的にハイライトする。

## 12. 注釈方針

### MVP

- 注釈の作成はZotero iPad / Desktopへ委ねる。
- PaperChatでは既存PDF注釈を表示できる範囲で表示する。
- 「Zoteroで開く」を提供する。

### 将来候補

1. PDFKitによる標準PDF注釈。
2. Apple Pencilによるインク注釈。
3. Zotero annotation itemへの変換。
4. Zotero注釈DBとの双方向同期。

完全同期は複雑であるため、利用頻度と必要性を確認してから実装する。

## 14. セキュリティ

- サーバーを公衆向けに無認証公開しない。
- Codex認証情報をクライアントへ配布しない。
- Zotero API tokenは端末のKeychainまたはサーバーのsecret storeへ保存する。
- PDF配信URLには短時間の署名付きURLを用いる。
- ログにはPDF本文、選択テキスト、認証情報を原則として残さない。
- Codex runtimeからホームディレクトリ全体を参照できないようにする。

## 15. MVP範囲

### 必須

- macOS / iPadOS共通アプリ。
- Zotero attachment keyからPDFを取得。
- ローカルキャッシュ。
- PDFKitによる表示。
- 最近読んだ論文一覧。
- 閲覧位置の保存・同期。
- 論文ごとのチャットスレッド。
- Codex SDK経由のストリーミング回答。
- 現在ページ・選択テキストの送信。
- ページ参照からPDFへ移動。
- 「Zoteroで開く」。

### 可能なら含める

- Web PDFの取り込み。
- Safari Share Extension。
- Obsidian noteへの保存。
- 全文検索。

### MVP後

- 標準PDF注釈。
- Apple Pencil対応。
- Zotero annotation同期。
- 関連文献推薦。
- 論文横断チャット。
- Zotero Sync代替。

## 16. 実装段階

### Phase 0: 技術検証

- Codex SDKを自宅サーバーで起動する。
- ChatGPT認証でCodex枠を利用できることを確認する。
- thread再開、ストリーミング、利用制限の取得を確認する。
- 1本のPDFを対象に、ページテキストを含めた質問を往復する。

### Phase 1: 単一端末MVP

- macOSアプリ。
- PDFKit表示。
- ローカルPDF読み込み。
- 単一論文・単一スレッド。
- Codexとのチャット。

### Phase 2: Zotero統合

- Zotero Library検索。
- attachment keyによるPDF取得。
- キャッシュ、メタデータ、最近読んだ論文。
- 複数スレッド。

### Phase 3: iPad対応

- SwiftUI共通化。
- iPadレイアウト。
- 閲覧位置・履歴同期。
- Safari共有からWeb PDFを取り込む。

### Phase 4: 研究ワークフロー統合

- Obsidian reference note連携。
- ページ引用ジャンプ。
- 図表・数式ページ画像。
- `/note`相当の保存操作。

### Phase 5: 注釈拡張

- 利用実績を見てPDFKit注釈を追加する。
- Zotero注釈との互換性を検証する。

## 17. 未決事項

1. サーバー実装をPython/FastAPIとRust/Axumのどちらにするか。
2. Codex SDKと`codex app-server`のどちらを採用するか。
3. チャット履歴の全文をサーバーへ保存するか、要約のみ保存するか。
4. PDF取得をクライアントからZotero Web APIへ直接行うか、サーバー経由にするか。
5. iPadからZoteroアプリの特定PDF・特定ページを開く方法。
6. Web PDFとZotero attachmentの重複統合規則。
7. PDF注釈をいつ、どの互換レベルで追加するか。
8. Codex枠の実際の消費量と応答速度が日常利用に適するか。

## 18. 初期判断

MVPでは次を採用する。

- クライアント: SwiftUI + PDFKit。
- 対応OS: macOS / iPadOS。
- LLMバックエンド: 自宅サーバー上のCodex SDK。
- 文献基盤: Zoteroを継続利用。
- PDF保存: 端末ローカルキャッシュ。
- 注釈: Zoteroへ委任。
- チャット履歴: paper IDとthread IDをサーバー側で対応付ける。
- Web連携: Safari Share Extensionを後付けする。
- 将来性: LLM backendを抽象化し、Codex依存を局所化する。

この構成により、Atlas終了後も、論文ごとの永続的な会話、Mac・iPad間の継続、Zoteroとの連携を維持できる。さらに、初期実装を小さく保ちつつ、注釈、関連文献検索、Zotero Sync代替へ段階的に拡張できる。
