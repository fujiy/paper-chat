# ChatKit prototype

The chat interface has a **Native / ChatKit Preview** switch. Native remains the
initial default. The choice is saved on each device. Paper and management chats
use the same existing thread IDs, messages, SQLite database and Codex runner.
No history migration or additional OpenAI API key is required.

## Try it

Build and run the PaperChat Xcode target, open a paper chat or create a management
chat, and select **ChatKit Preview**. The standard ChatKit history panel and header handle conversation selection and
new chats. The standard composer picker lists each available model and reasoning
effort combination. Reload remains a native button. Current PDF page and selected text are sent with each
message. Clicking a page citation calls back into the native PDF reader.

Open the conversation again, or use **Reload**, to fetch saved messages. The
prototype does not subscribe to the real-time thread event endpoint. Native chat
also now refreshes on opening instead of subscribing. A conversation being
answered on another device is locked until a reload observes its completion.

Switch back to **Native** to compare the same saved conversation. Switching is
disabled while the current view is sending. Unsaved text typed into ChatKit is
not exported back to the native input field; send or copy the draft before
switching interfaces or leaving the conversation.

## Architecture

- `ChatKit.html` loads the official ChatKit Web Component. It is bundled in the
  app and loaded with a localhost development base URL.
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
  UI assets are fetched from OpenAI's CDN; this is not an offline UI bundle.

## Verification

```sh
.venv/bin/ruff check server
.venv/bin/pytest -q
xcodebuild -project client/PaperChat.xcodeproj -scheme PaperChat \
  -sdk macosx -derivedDataPath /tmp/paperchat-chatkit-macos build
xcodebuild -project client/PaperChat.xcodeproj -scheme PaperChat \
  -sdk iphonesimulator -derivedDataPath /tmp/paperchat-chatkit-ios \
  CODE_SIGNING_ALLOWED=NO build
```

The API tests cover shared history, a second device opening a thread, cursor
pagination, page/selection context, model/effort forwarding, Codex thread-ID reuse,
authentication, scope isolation, duplicate/concurrent sends, unsupported actions,
failed generation and early stream cancellation.

After `./scripts/deploy-home.sh`, run the synthetic integration check in the API
container, using the configured Docker context/host:

```sh
docker --context ubuntu exec -i paperchat-paperchat-api-1 \
  python - < scripts/chatkit-smoke-test.py
```

This uses temporary SQLite storage and synthetic paper text with the configured
real Codex runner. It verifies two turns, refresh-token rotation, saved history
and Codex conversation reuse without reading or sending real paper contents.
