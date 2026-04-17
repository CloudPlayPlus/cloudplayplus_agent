# cloudplayplus_agent

MCP channel bridge for Claude Code, in pure Dart.

Exposes a local Streamable HTTP MCP server advertising
`experimental.claude/channel` + `experimental.claude/channel/permission` — the
same protocol the official Discord / Telegram plugins use. Host applications
(CloudPlayPlus, any Flutter app, any Dart server) route inbound user messages
and outbound replies through a tiny typed API.

**What this package does not do:** decide how user messages reach the host,
or how replies get back to the user. Transport (WebRTC DataChannel, FCM push,
WebSocket, IM server…) is the caller's problem. This package only speaks MCP.

## Quick start

```dart
import 'package:cloudplayplus_agent/cloudplayplus_agent.dart';

final agent = CloudplayAgent(port: 48989);
await agent.start();

// Route CC-produced events to your transport.
agent.events.listen((event) {
  switch (event) {
    case AssistantReply e:
      myTransport.deliverText(e.chatId, e.text);
    case MessageEditRequested e:
      myTransport.editText(e.chatId, e.messageId, e.text);
    case ReactionRequested e:
      myTransport.addReaction(e.chatId, e.messageId, e.emoji);
    case PermissionRequested e:
      myTransport.showPermissionCard(e);
  }
});

// Feed user messages from your transport into CC.
await agent.sendUserMessage(
  chatId: 'user-device-123',
  text: 'please list files in /tmp',
  user: 'alice',
);

// Deliver the user's permission decision back to CC.
await agent.replyPermission(requestId: '...', allow: true);
```

On the Claude Code side, drop a `.mcp.json` next to where you run `claude`:

```json
{
  "mcpServers": {
    "cloudplayplus": {
      "type": "http",
      "url": "http://127.0.0.1:48989/mcp"
    }
  }
}
```

Then `claude` in that directory connects automatically.

## Try the demo

### Flutter UI (recommended)

```sh
cd example
flutter pub get
flutter run -d windows   # or: -d macos / -d linux
```

You get a chat window with a real input bar, speech bubbles, and inline
permission cards with Allow / Deny buttons. A status chip in the app bar
tracks how many `claude` sessions are currently connected.

In a second terminal, drop this into a scratch project's `.mcp.json` (the
app's copy button will give it to you):

```json
{"mcpServers":{"cloudplayplus":{"type":"http","url":"http://127.0.0.1:48989/mcp"}}}
```

Then run `claude` in that project and start talking.

### Headless CLI

If you don't have Flutter handy, a minimal Dart CLI is at `tool/cli_demo.dart`:

```sh
dart run tool/cli_demo.dart
```

Same protocol, same endpoint, no UI.

## MCP protocol contract

| Direction | Method / Tool | Purpose |
|---|---|---|
| CC → server | tool `reply` | CC sends a chat reply. `chat_id` + `text` required; `reply_to` and `files` optional. Emitted as [`AssistantReply`](lib/src/events.dart). |
| CC → server | tool `edit_message` | CC edits a message it previously sent. Emitted as [`MessageEditRequested`](lib/src/events.dart). |
| CC → server | tool `react` | CC attaches an emoji reaction to a message. Emitted as [`ReactionRequested`](lib/src/events.dart). |
| CC → server | tool `fetch_messages` | CC asks the host for recent chat history. Resolved by the `onFetchMessages` callback. |
| CC → server | tool `download_attachment` | CC asks the host to materialize message attachments as local files. Resolved by the `onDownloadAttachment` callback. |
| CC → server | notification `notifications/claude/channel/permission_request` | CC wants the user to allow/deny a tool call. Emitted as [`PermissionRequested`](lib/src/events.dart). |
| server → CC | notification `notifications/claude/channel` | A user message arrived. Call [`CloudplayAgent.sendUserMessage`]. |
| server → CC | notification `notifications/claude/channel/permission` | Deliver the user's allow/deny decision. Call [`CloudplayAgent.replyPermission`]. |

These experimental capabilities are Claude Code-specific. They are not part
of the MCP standard — the canonical reference implementation lives in
`~/.claude/plugins/cache/claude-plugins-official/discord/0.0.4/server.ts`.

Inbound user messages are delivered purely via
`notifications/claude/channel` (push). There is no fallback long-poll tool,
so Claude Code must be started with `--channels plugin:<name>` (or
`--dangerously-load-development-channels` during development) for delivery
to work.

## Security note

Declaring `experimental.claude/channel/permission` is an implicit assertion
that your server authenticates the replier. The MCP layer has no concept
of who sent `replyPermission` — your transport layer **must** gate inbound
permission replies to authorized users only. Otherwise, any party with
network access to your server could approve dangerous tool calls.

The HTTP server binds to `127.0.0.1` by default. Do not change that unless
you also add authentication (via the `authenticator` option in the
underlying `StreamableMcpServer`).

## License

Apache-2.0
