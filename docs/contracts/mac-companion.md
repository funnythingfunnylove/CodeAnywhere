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
- The capability-token file is created with mode `0600` outside the repository
  and deleted after the owned process exits.
- The Mac app stores the exact `Process` instance and PID it created. Stop and
  quit actions may terminate only that owned process; they must not use broad
  process-name matching or terminate an externally started Codex server.
- Process exit, launch errors, and recent redacted output are visible in the Mac
  UI. No credential or notification device key may be logged.

## Completion monitoring contract

- The Mac app establishes its own authenticated app-server client after launch.
- The monitor reads authoritative thread state through `thread/list`; it does
  not assume notifications from a different WebSocket session are broadcast.
- A completion candidate is a thread observed as `active` and later observed in
  a terminal state, or a thread updated after the monitor baseline that first
  appears terminal.
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
- Payload fields are `title`, `body`, `group`, `url`, and a stable `id`.
- Delivery is recorded only after HTTP success and Bark business `code: 200`.
  Server acceptance is not reported as proof that iOS displayed the message.
- A failed delivery remains retryable and must not create an unbounded retry
  loop.

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
