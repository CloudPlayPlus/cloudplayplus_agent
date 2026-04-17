import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:mcp_dart/mcp_dart.dart';

import 'capabilities.dart';
import 'events.dart';
import 'instructions.dart';

/// MCP channel bridge for Claude Code.
///
/// Starts a local Streamable HTTP MCP server. Claude Code connects to it as
/// a regular MCP client, sees the `wait_for_message` + `reply` tools, and
/// drives a long-poll loop driven by the server instructions:
///
///   1. CC calls `wait_for_message` (blocks up to 25s)
///   2. When a user message arrives, [sendUserMessage] pushes it to the
///      inbox and the tool call returns with the message body
///   3. CC processes the message and calls `reply` to respond
///   4. The `reply` tool emits an [AssistantReply] event the host can route
///   5. CC calls `wait_for_message` again — loop repeats
///
/// Why pull instead of push? Testing showed that CC builds without the
/// `--channels` flag do NOT subscribe to `notifications/claude/channel`
/// events, so server-initiated pushes are dropped. Long-poll works on any
/// MCP-speaking CC build. Notifications are still broadcast on a best-effort
/// basis for channel-aware CC versions that might be listening.
class CloudplayAgent {
  CloudplayAgent({
    this.host = '127.0.0.1',
    this.port = 7823,
    this.path = '/mcp',
    this.serverName = 'cloudplayplus',
    this.serverVersion = '0.0.1',
    this.pollTimeout = const Duration(seconds: 25),
    this.exposeLongPollTool = true,
    String? instructions,
  }) : instructions = instructions ??
            (exposeLongPollTool ? kPollingInstructions : kPushInstructions);

  /// Bind address. Defaults to loopback — do NOT expose this to LAN/WAN
  /// without also wiring an authenticator. The MCP server has no auth of
  /// its own.
  final String host;
  final int port;
  final String path;
  final String serverName;
  final String serverVersion;
  final String instructions;

  /// How long each `wait_for_message` call blocks before returning an idle
  /// signal. Short enough that MCP transports don't time out; long enough
  /// that CC isn't spamming polls.
  final Duration pollTimeout;

  /// Whether to expose the `wait_for_message` long-poll tool to CC.
  ///
  /// Set to `false` to force push-only delivery (via
  /// `notifications/claude/channel`). Useful for verifying whether CC's
  /// native channel listener is active: with the long-poll tool removed, CC
  /// has no alternative path to receive messages, so any successful delivery
  /// proves the push path works.
  final bool exposeLongPollTool;

  final _events = StreamController<AgentEvent>.broadcast();
  final _inbox = _Inbox();
  final Map<String, McpServer> _sessions = {};
  StreamableMcpServer? _httpServer;

  /// CC-initiated events the host should route to the user.
  Stream<AgentEvent> get events => _events.stream;

  /// Number of Claude Code sessions currently connected.
  int get connectedSessions => _sessions.length;

  /// Starts the local MCP HTTP server. Safe to await before CC is started.
  Future<void> start() async {
    if (_httpServer != null) {
      throw StateError('CloudplayAgent already started');
    }

    final http = StreamableMcpServer(
      serverFactory: _buildServer,
      host: host,
      port: port,
      path: path,
    );
    await http.start();
    _httpServer = http;
  }

  Future<void> stop() async {
    _inbox.clear();
    await _httpServer?.stop();
    _httpServer = null;
    _sessions.clear();
    await _events.close();
  }

  McpServer _buildServer(String sessionId) {
    final srv = McpServer(
      Implementation(name: serverName, version: serverVersion),
      options: McpServerOptions(
        capabilities: const ServerCapabilities(
          tools: ServerCapabilitiesTools(),
          experimental: kClaudeChannelCapabilities,
        ),
        instructions: instructions,
      ),
    );

    _sessions[sessionId] = srv;

    // Tool: wait_for_message — the long-poll. CC sits here until we have
    // something to say, or until the timeout fires (then it re-calls).
    // Skipped when push-only mode is requested.
    if (exposeLongPollTool) {
      srv.registerTool(
        'wait_for_message',
        description:
            'Block up to ~25 seconds waiting for the next user message on '
            'the CloudPlayPlus channel.\n\n'
            'Returns either:\n'
            '  • a message object {"chat_id":"...", "text":"...", '
            '"message_id":"...", "user":"...", "ts":"..."}\n'
            '  • an idle signal {"status":"idle"} when no message arrived '
            'within the poll window — call again immediately to keep listening.\n\n'
            'Call this in a loop: wait → process → reply → wait. See server '
            'instructions for the full protocol.',
        inputSchema: JsonSchema.object(properties: const {}),
        callback: (args, extra) async {
          final msg = await _inbox.pull(timeout: pollTimeout);
          final body = msg ?? const {'status': 'idle'};
          return CallToolResult.fromContent(
            [TextContent(text: jsonEncode(body))],
          );
        },
      );
    }

    // Tool: reply — CC calls this to send a chat message back to the user.
    srv.registerTool(
      'reply',
      description:
          'Reply on the CloudPlayPlus channel. Pass chat_id from the '
          'incoming message you received via wait_for_message. Optionally '
          'pass reply_to (message_id) for threading, and files (absolute '
          'paths) to attach images or other files.',
      inputSchema: JsonSchema.object(
        properties: {
          'chat_id': JsonSchema.string(
            description:
                'chat_id echoed from the message returned by wait_for_message',
          ),
          'text': JsonSchema.string(
            description: 'Reply body. Markdown is fine.',
          ),
          'reply_to': JsonSchema.string(
            description:
                'Optional: message_id of an earlier inbound message to '
                'thread under. Omit for a normal top-level reply.',
          ),
          'files': JsonSchema.array(
            items: JsonSchema.string(),
            description:
                'Optional: absolute file paths to attach. The host may '
                'reject or transform these before delivery.',
          ),
        },
        required: ['chat_id', 'text'],
      ),
      callback: (args, extra) async {
        final chatId = args['chat_id'] as String;
        final text = args['text'] as String;
        final replyTo = args['reply_to'] as String?;
        final rawFiles = args['files'];
        final files = rawFiles is List
            ? rawFiles.whereType<String>().toList(growable: false)
            : const <String>[];

        _events.add(AssistantReply(
          chatId: chatId,
          text: text,
          replyToMessageId: replyTo,
          files: files,
        ));

        return CallToolResult.fromContent(
          [TextContent(text: 'delivered')],
        );
      },
    );

    // Notification handler: CC → us when it wants to ask for permission.
    // Only fires on CC builds that expose the permission-relay capability.
    srv.server.setNotificationHandler<JsonRpcNotification>(
      ClaudeChannelMethods.permissionRequest,
      (n) async {
        final params = n.params ?? const <String, dynamic>{};
        final reqId = params['request_id'];
        final tool = params['tool_name'];
        if (reqId is! String || tool is! String) return;
        _events.add(PermissionRequested(
          requestId: reqId,
          toolName: tool,
          description: params['description'] as String? ?? '',
          inputPreview: params['input_preview'] as String? ?? '',
        ));
      },
      (params, meta) => JsonRpcNotification(
        method: ClaudeChannelMethods.permissionRequest,
        params: params,
        meta: meta,
      ),
    );

    return srv;
  }

  /// Queue a user message for Claude Code to pick up on its next
  /// `wait_for_message` call. Also broadcasts a channel notification for
  /// CC builds that auto-subscribe (best-effort, no harm if dropped).
  ///
  /// [chatId] is an opaque routing key; CC echoes it back in [AssistantReply]
  /// so the host can thread replies to the right conversation.
  Future<void> sendUserMessage({
    required String chatId,
    required String text,
    String? messageId,
    String? user,
    String? userId,
    DateTime? ts,
    Map<String, String>? extraMeta,
  }) async {
    final body = <String, dynamic>{
      'chat_id': chatId,
      'text': text,
      'message_id': ?messageId,
      'user': ?user,
      'user_id': ?userId,
      'ts': (ts ?? DateTime.now().toUtc()).toIso8601String(),
      if (extraMeta != null) ...extraMeta,
    };

    // Primary delivery path: unblock whoever is sitting in wait_for_message.
    _inbox.push(body);

    // Secondary: push a channel notification. CC builds with native channel
    // support will pick it up; others ignore it. We don't rely on this.
    final meta = Map<String, dynamic>.of(body)..remove('text');
    await _broadcast(JsonRpcNotification(
      method: ClaudeChannelMethods.inboundMessage,
      params: {'content': text, 'meta': meta},
    ));
  }

  /// Deliver the user's permission decision back to CC.
  Future<void> replyPermission({
    required String requestId,
    required bool allow,
  }) async {
    await _broadcast(JsonRpcNotification(
      method: ClaudeChannelMethods.permissionReply,
      params: {
        'request_id': requestId,
        'behavior': allow ? 'allow' : 'deny',
      },
    ));
  }

  Future<void> _broadcast(JsonRpcNotification notification) async {
    if (_sessions.isEmpty) return;

    // Snapshot first — notification() may trigger session cleanup that
    // mutates _sessions mid-iteration.
    final snapshot = List.of(_sessions.entries);
    final dead = <String>[];
    for (final entry in snapshot) {
      try {
        await entry.value.server.notification(notification);
      } catch (_) {
        dead.add(entry.key);
      }
    }
    for (final id in dead) {
      _sessions.remove(id);
    }
  }
}

/// Single-slot long-poll inbox. Messages push in, a single consumer pulls.
/// If multiple CC sessions ever race on `wait_for_message`, the most recent
/// caller wins the next message — which is fine for Flutter's typical
/// one-CC scenario. A richer design would queue waiters.
class _Inbox {
  final Queue<Map<String, dynamic>> _pending = Queue();
  Completer<Map<String, dynamic>?>? _waiter;

  void push(Map<String, dynamic> msg) {
    final w = _waiter;
    if (w != null && !w.isCompleted) {
      _waiter = null;
      w.complete(msg);
    } else {
      _pending.add(msg);
    }
  }

  /// Returns the next message, or null if [timeout] elapses first.
  Future<Map<String, dynamic>?> pull({
    required Duration timeout,
  }) async {
    if (_pending.isNotEmpty) return _pending.removeFirst();
    final completer = _waiter = Completer<Map<String, dynamic>?>();
    try {
      return await completer.future.timeout(timeout);
    } on TimeoutException {
      if (identical(_waiter, completer)) _waiter = null;
      return null;
    }
  }

  void clear() {
    _pending.clear();
    final w = _waiter;
    _waiter = null;
    if (w != null && !w.isCompleted) w.complete(null);
  }
}
