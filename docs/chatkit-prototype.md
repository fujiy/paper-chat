# ChatKit prototype

The chat interface uses ChatKit for paper and management conversations. Both
share the existing thread IDs, SQLite database and Codex runner. No additional
OpenAI API key or history migration is required.

## Offline reading and chat

After a successful online visit, Recent, Starred, Library and chat overviews are
saved per server. Downloaded PDFs open from local storage before any metadata,
thread, bookmark or structure refresh. Open paper tabs and the active paper are
restored on launch. Reading positions are saved locally, coalesced, and uploaded
on reconnect; an acknowledgement cannot discard a newer local position.

Bookmarks and document structures already retrieved are available offline.
Library search falls back to saved titles and authors; PDF text search remains
local. Star and bookmark mutations, new AI answers, and unsaved PDFs require a
connection. Reading statistics are not queued for offline replay.

ChatKit UI assets (including math/fonts) and successful read-only ChatKit
responses are saved on the device. A loopback-only HTTP server serves the bundled
wrapper and downloaded assets. The iframe uses `127.0.0.1`, while the wrapper uses
`localhost`, preserving their origin boundary. A Content Security Policy blocks
external WebKit requests; authenticated operations still use the native bridge.
The public UI entry script is pinned after its first download, retaining its
matching hashed assets. The `chatkit-ui-v1` directory can be advanced with a future
app release to refresh that pinned version.

Offline conversations use the same ChatKit view and cached protocol responses.
Threads are marked locked, so their composers cannot send. Disconnect/reconnect
recreates ChatKit within the same chat panel to bypass its internal response cache. Only visited history pages
are cached: an unseen conversation, an uncached pagination request or an
incomplete UI cache displays an unavailable message inside the chat panel. There
is no alternate history renderer and no queued message sending. Unsent text in
ChatKit's composer is not exported to native persistent storage and can be lost
on a connection transition. Completed turns are refreshed directly through the
native bridge so ChatKit's internal cache cannot leave the saved history stale.

The first online launch after this update migrates previously downloaded PDFs
identified by Recent into the server-specific document directory. Explicit
sign-out removes that server's offline workspace. PDF/response storage currently
has no automatic quota or eviction; preserving downloaded papers takes priority.
UI assets are shared across server namespaces and contain no conversation data.

## Architecture

- `ChatKit.html` is bundled in the app. `ChatKitAssetServer.swift` downloads and
  serves the official Web Component and its dependencies from the local asset cache.
- `ChatKitView.swift` embeds it in `WKWebView`. A main-frame-only message handler
  forwards fixed `/api/chatkit` requests through `APIClient`. Access and refresh
  tokens stay in native code; the page cannot request arbitrary authenticated URLs.
- The JSON/SSE bridge preserves streaming and delegates token refresh to the same
  API client used by native chat. Destroying the web view cancels its requests.
- `server/paperchat/chatkit_bridge.py` uses the official Python SDK's request,
  response and event types. It adapts the existing message endpoint rather than
  introducing another store or generation lifecycle. Both clients share the same
  duplicate-send guard, thread lock, PDF context and Codex session IDs.
- Request metadata holds the paper scope, page, selection, model and reasoning
  effort. It is validated by the server and paper-scoped history queries cannot
  accidentally load a management or different-paper thread.

Supported operations are `threads.create`, `threads.add_user_message`,
`threads.get_by_id`, `threads.list`, and `items.list`. Unsupported mutation,
attachment, feedback and retry operations are rejected. Their UI features are
not enabled. History uses stable cursor pagination.

## Compatibility findings

- `$...$` inline math was displayed literally by the tested ChatKit release;
  `\(...\)` rendered correctly. The adapter converts the former for display,
  preserving code spans/fences and the original saved message. Block `$$...$$`
  math, tables, highlighted code and page links were exercised with synthetic
  responses. Conversion occurs in loaded history and completed output.
- On the tested macOS 26.1 WKWebView, the ChatKit entry transition left
  `#chatkit-thread-container` at computed opacity zero after transition attributes
  were removed. A narrowly scoped WKUserScript forces only that container's
  opacity to one, inside the official ChatKit frame. Expanded workflow contents
  need the same scoped opacity correction. This depends on internal DOM selectors
  and should be rechecked when ChatKit changes.
- Page citations are presented as `https://paperchat.invalid/page/N` links so the
  renderer retains them. Native navigation intercepts them without fetching that
  hostname. The database keeps the original citation text.
- Progress uses standard ChatKit workflows and custom tasks, separate from the
  answer, with collapsed summaries and running/completed indicators. Repeated
  events update the same task; append events accumulate text. New ChatKit turns
  persist progress in `message_progress` and restore it when history is loaded.
  Older turns and native-only generations have no saved progress to reconstruct.
- History rename/delete remain disabled (the existing app does not expose these
  mutations). Attachments, feedback and retry remain disabled as well.
- Model/effort combinations use the standard model picker's opaque identifier;
  the adapter decodes them before calling Codex. A selection overrides the native
  fallback model and effort for that request. Model and effort are saved on the
  thread when a message is accepted and restored as composer defaults on reopening
  or restarting the app. Each saved user message retains its inference options for
  ChatKit history restoration. Subsequent requests without a picker override use
  the thread's saved selection ahead of native defaults. Existing conversations
  acquire a saved selection on their next send; unsent picker changes are not saved.
- The bundled page uses the SDK's development `local-dev` domain key. A separate
  production web deployment needs its own registered origin/domain configuration.
  Public UI assets are downloaded from OpenAI's CDN once and served locally thereafter.

## Verification

The client checks use synthetic PDFs and conversations. `OfflineReadingCheck`
checks cold restoration, saved PDF opening without network metadata, local PDF
and library searches, missing-file handling, position persistence and reconnect
synchronization, edits during in-flight saves, server isolation and stale writes.
`ChatKitOfflineCheck` uses the production HTML, asset server and response cache.
It warms the public UI cache, tests disconnect/reconnect in the same view, then
creates a new nonpersistent WKWebView and cache actor with networking disabled.
It checks message text, inline/block math, native page links, isolated origins,
a locked composer and zero offline API requests.

Run from the repository root on macOS:

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
swift_options=(-sdk "$(xcrun --sdk macosx --show-sdk-path)" -target "$(uname -m)-apple-macos15.0" \
  -swift-version 6 -module-cache-path /tmp/paperchat-swift-cache)
sources=(client/PaperChat/{Models,APIClient,KeychainStore,OfflineStore,PDFCache,MinerUCache,AppModel}.swift)
xcrun swiftc -parse-as-library "${swift_options[@]}" \
  "${sources[@]}" client/Tests/OfflineReadingCheck.swift -o /tmp/paperchat-offline-reading-check
/tmp/paperchat-offline-reading-check

xcrun swiftc -parse-as-library "${swift_options[@]}" \
  "${sources[@]}" client/PaperChat/ChatKitAssetServer.swift \
  client/Tests/ChatKitOfflineCheck.swift -o /tmp/paperchat-chatkit-offline-check
/tmp/paperchat-chatkit-offline-check /tmp/paperchat-chatkit-check-assets

xcodebuild -project client/PaperChat.xcodeproj -scheme PaperChat \
  -sdk macosx -derivedDataPath /tmp/paperchat-offline-macos CODE_SIGNING_ALLOWED=NO build
xcodebuild -project client/PaperChat.xcodeproj -scheme PaperChat \
  -sdk iphonesimulator -derivedDataPath /tmp/paperchat-offline-ios CODE_SIGNING_ALLOWED=NO build
```

The ChatKit check's initial UI download needs access to the public CDN; no real
API credentials, user papers or LLM calls are used. It saves online/offline
screenshots in the system temporary directory.

For server changes, run the API tests and deployment checks described in
`AGENTS.md`. `scripts/chatkit-smoke-test.py` remains the deployed synthetic
integration check for actual Codex answers and shared server history.
