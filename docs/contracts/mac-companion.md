# Mac Companion Contract

## Purpose

CodeAnywhere Mac is the desktop owner of the LAN Codex app-server lifecycle and
the completion-to-Bark delivery path. The iOS app remains a thin LAN client and
must not depend on background execution for completion delivery.

## Participants

- Producer: CodeAnywhere iOS (`turn/start`, deep-link consumer)
- Coordinator: CodeAnywhere Mac (process owner, status monitor, Bark sender)
- Upstream: Codex `app-server` WebSocket JSON-RPC v2
- Delivery provider: Bark Server and the Bark iOS app

## Server lifecycle contract

- CodeAnywhere Mac launches `codex app-server` directly with `Process`; no shell
  interpolation is allowed.
- The server listens on `ws://0.0.0.0:<configured-port>` using capability-token
  authentication compatible with the existing iOS client.
- The UI presents a preferred active, non-loopback IPv4 address as
  `ws://<lan-ip>:<configured-port>` for iPhone entry; it does not present the
  `0.0.0.0` bind address as a client endpoint.
- The capability-token file is created with mode `0600` outside the repository
  and deleted after the owned process exits.
- The Mac app stores the exact `Process` instance and PID it created. Stop and
  quit actions may terminate only that owned process; they must not use broad
  process-name matching or terminate an externally started Codex server.
- Process exit, launch errors, and recent redacted output are visible in the Mac
  UI. No credential or notification device key may be logged.
- The Codex dashboard reports the resolved CLI path and version. An explicit
  update action executes that exact binary with the `update` argument directly,
  without shell interpolation, and refreshes the version after success. The UI
  requires the owned app-server to be stopped before updating, and prevents the
  server from starting while an update or version check is in progress.

## Completion monitoring contract

- The Mac app establishes its own authenticated app-server client after launch.
- A received `turn/completed` server notification is parsed from
  `params.threadId` and `params.turn.id/status`, then enters the same persisted,
  deduplicated Bark delivery path immediately for completed or failed turns.
- Polling remains the fallback for turns whose server notification is not
  broadcast to this WebSocket session: `thread/list` finds changed threads and
  `thread/read(includeTurns: true)` reads the authoritative latest Turn.
- A notification candidate must have a latest Turn whose status is `completed`
  or `failed`. Interrupted, idle, and unrelated thread timestamp updates never
  create a Bark delivery. When a failed Turn provides `error.message` or
  `error.additionalDetails`, the redacted detail is retained with the pending
  delivery and included in the Bark body.
- Interrupted Turns are permanently ignored, including interruptions caused by
  steering a thread with a new user message.
- Delivery identity is derived from the Codex Turn ID, so one terminal Turn is
  sent at most once while a later terminal Turn in the same thread remains a
  distinct event.
- Active observations and delivered event identifiers are persisted locally so
  an app restart does not lose an in-flight completion or duplicate a delivery.
- Polling failures retain the last-good state and retry with bounded delay.

## Bark delivery contract

- Server URL is user-configurable; its default is the currently configured
  self-hosted Bark server.
- The Bark device key is stored in macOS Keychain under service
  `bark-notify-device-key` and never written to UserDefaults, source, logs, or a
  URL.
- Requests use JSON `POST /push` with `device_key` in the body.
- Payload fields always include `title`, `group`, `level`, `url`, and a stable
  `id`; plain notifications use `body`, while Markdown notifications use
  `markdown` and omit `body`. Optional official Bark fields are `subtitle`,
  `volume`, `sound`, and `icon`.
- Notification format templates may substitute `{thread}`, `{status}`, `{time}`,
  and `{detail}`. Format, group, interruption level, sound, icon, and Markdown
  choices are persisted in UserDefaults; the device key remains Keychain-only.
- Delivery is recorded only after HTTP success and Bark business `code: 200`.
  Server acceptance is not reported as proof that iOS displayed the message.
- A failed delivery retries at most five times with bounded backoff. Further
  attempts require the explicit retry action and never form an unbounded loop.

## Process log contract

- Real Codex warnings and all errors remain visible after secret redaction.
- Expected client disconnect noise (`Connection reset without closing
  handshake` and delivery to an already disconnected connection) is omitted
  from the Mac dashboard log because iOS termination and network transitions
  cannot guarantee a WebSocket closing handshake.

## macOS application lifecycle contract

- Closing the main window does not quit the app or stop its owned app-server.
- The regular Dock presence is retained and a menu bar item exposes server and
  monitor status, main-window reopening, start/stop, and explicit quit.
- Explicit Quit remains the only UI action that shuts down the monitor and the
  app-server process owned by this app.
- The main window uses four stable sidebar destinations: Codex, Notify, Logs,
  and Settings. Closing or switching destinations does not alter server or
  monitoring state.

## Deep-link contract

- Identifier: `codeanywhere://thread/<percent-encoded-thread-id>`
- The iOS app accepts only scheme `codeanywhere`, host `thread`, and one nonempty
  path component within a bounded length.
- Opening a valid link selects the Conversations tab, persists the requested
  thread ID, connects if configured, refreshes threads, and navigates when the
  thread becomes available.
- The deep link carries no prompt text, filesystem path, credential, or Bark
  device key.

## Ownership and verification

- `project.yml` is the Xcode project source of truth; generated `.pbxproj` files
  are never hand-edited.
- Required verification: macOS unit tests, iOS unit tests, Mac app build, iOS
  simulator tests, signed generic iOS build, Bark dry run, and an explicitly
  authorized real-device end-to-end push test.
