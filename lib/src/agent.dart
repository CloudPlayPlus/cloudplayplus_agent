import 'dart:async';
import 'dart:convert';

import 'package:mcp_dart/mcp_dart.dart';

import 'capabilities.dart';
import 'events.dart';
import 'instructions.dart';

/// Host callback: resolve the last [limit] messages on [chatId] for CC.
///
/// Returned list must be oldest-first. May throw — the thrown message is
/// forwarded to CC as a tool error.
typedef FetchMessagesHandler = Future<List<HistoryMessage>> Function(
  String chatId,
  int limit,
);

/// Host callback: download attachments for a specific message and return
/// absolute local paths CC can `Read`.
///
/// Returning [AttachmentDownload.paths] empty is valid (= message had no
/// attachments). May throw — the thrown message is forwarded to CC.
typedef DownloadAttachmentHandler = Future<AttachmentDownload> Function(
  String chatId,
  String messageId,
);

/// MCP channel bridge for Claude Code.
///
/// Starts a local Streamable HTTP MCP server. Claude Code connects as a
/// regular MCP client, sees the `reply` / `react` / `edit_message` /
/// `fetch_messages` / `download_attachment` tools plus the
/// `experimental.claude/channel` capability, and drives the channel from
/// there.
///
/// Delivery is push-only via `notifications/claude/channel`. CC builds
/// without native `--channels` support won't receive inbound messages —
/// run `claude --channels plugin:<your-plugin>` or
/// `--dangerously-load-development-channels` during development.
class CloudplayAgent {
  CloudplayAgent({
    this.host = '127.0.0.1',
    this.port = 48989,
    this.path = '/mcp',
    this.serverName = 'cloudplayplus',
    this.serverVersion = '0.0.1',
    String? instructions,
    this.onFetchMessages,
    this.onDownloadAttachment,
  }) : instructions = instructions ?? kChannelInstructions;

  /// Bind address. Defaults to loopback — do NOT expose this to LAN/WAN
  /// without also wiring an authenticator. The MCP server has no auth of
  /// its own.
  final String host;
  final int port;
  final String path;
  final String serverName;
  final String serverVersion;
  final String instructions;

  /// Host-supplied history provider. Called when CC invokes
  /// `fetch_messages`. If null, the tool still exists but returns an
  /// empty list.
  final FetchMessagesHandler? onFetchMessages;

  /// Host-supplied attachment provider. Called when CC invokes
  /// `download_attachment`. If null, the tool returns an empty path list
  /// with a note that downloads aren't configured.
  final DownloadAttachmentHandler? onDownloadAttachment;

  final _events = StreamController<AgentEvent>.broadcast();

  /// All sessions whose POST `initialize` handshake has been accepted.
  /// Used purely for routing — `_broadcast` needs to find the transports
  /// to deliver notifications. A session can exist here without a client
  /// currently listening (see [_listeners]).
  final Map<String, McpServer> _sessions = {};

  /// Sessions whose standalone GET SSE stream is currently open. This is
  /// the right set to use for "is anyone receiving my broadcasts" checks
  /// and for the UI connection count. Driven by the mcp_dart fork's
  /// `onClientConnected` / `onClientDisconnected` callbacks.
  final Set<String> _listeners = {};

  StreamableMcpServer? _httpServer;

  /// CC-initiated events the host should route to the user.
  Stream<AgentEvent> get events => _events.stream;

  /// Number of Claude Code sessions currently listening for pushed
  /// events (i.e. with an active standalone SSE GET stream). Sessions
  /// that only completed a POST initialize but never opened the stream
  /// are NOT counted.
  int get connectedSessions => _listeners.length;

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
      onClientConnected: _listeners.add,
      onClientDisconnected: _listeners.remove,
    );
    await http.start();
    _httpServer = http;
  }

  Future<void> stop() async {
    await _httpServer?.stop();
    _httpServer = null;
    _sessions.clear();
    _listeners.clear();
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

    // Fires on MCP DELETE, server-side shutdown, and (with our mcp_dart
    // fork) on raw TCP disconnect of the standalone SSE GET stream.
    srv.server.onclose = () {
      _sessions.remove(sessionId);
    };

    srv.registerTool(
      'reply',
      description:
          'Reply on the CloudPlayPlus channel. Pass chat_id from the '
          'incoming <channel> tag. Optionally pass reply_to (message_id) '
          'for threading, and files (absolute paths) to attach images or '
          'other files.',
      inputSchema: JsonSchema.object(
        properties: {
          'chat_id': JsonSchema.string(
            description: 'chat_id echoed from the inbound message.',
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

    srv.registerTool(
      'react',
      description:
          'Attach an emoji reaction to an existing message. Unicode '
          'emoji work directly. Use this for quick acknowledgements '
          '(👀 = "seen, working on it", ✅ = "done") instead of sending '
          'a whole new reply.',
      inputSchema: JsonSchema.object(
        properties: {
          'chat_id': JsonSchema.string(),
          'message_id': JsonSchema.string(
            description:
                'message_id of the message to react to. Usually the '
                'incoming user message id.',
          ),
          'emoji': JsonSchema.string(
            description: 'Unicode emoji, e.g. "👍".',
          ),
        },
        required: ['chat_id', 'message_id', 'emoji'],
      ),
      callback: (args, extra) async {
        _events.add(ReactionRequested(
          chatId: args['chat_id'] as String,
          messageId: args['message_id'] as String,
          emoji: args['emoji'] as String,
        ));
        return CallToolResult.fromContent(
          [TextContent(text: 'reacted')],
        );
      },
    );

    srv.registerTool(
      'edit_message',
      description:
          'Edit a message previously sent via `reply`. Useful for interim '
          'progress updates. Edits usually do not re-notify the user, so '
          'send a fresh `reply` when a long task completes.',
      inputSchema: JsonSchema.object(
        properties: {
          'chat_id': JsonSchema.string(),
          'message_id': JsonSchema.string(
            description: 'message_id returned to you from an earlier reply.',
          ),
          'text': JsonSchema.string(
            description: 'Full replacement body (not a diff).',
          ),
        },
        required: ['chat_id', 'message_id', 'text'],
      ),
      callback: (args, extra) async {
        _events.add(MessageEditRequested(
          chatId: args['chat_id'] as String,
          messageId: args['message_id'] as String,
          text: args['text'] as String,
        ));
        return CallToolResult.fromContent(
          [TextContent(text: 'edited')],
        );
      },
    );

    srv.registerTool(
      'fetch_messages',
      description:
          'Fetch recent messages from a chat. Returns oldest-first with '
          'message_ids so you can `reply_to` or `edit_message` them.',
      inputSchema: JsonSchema.object(
        properties: {
          'chat_id': JsonSchema.string(
            description:
                'chat_id to look up. Use the same value you see on '
                'inbound <channel> tags.',
          ),
          'limit': JsonSchema.integer(
            description: 'Max messages (default 20, capped at 100).',
          ),
        },
        required: ['chat_id'],
      ),
      callback: (args, extra) async {
        final chatId = args['chat_id'] as String;
        final rawLimit = args['limit'];
        final limit = switch (rawLimit) {
          int i => i,
          num n => n.toInt(),
          _ => 20,
        }
            .clamp(1, 100);

        final provider = onFetchMessages;
        if (provider == null) {
          return CallToolResult.fromContent([
            TextContent(
              text: jsonEncode({
                'messages': <Map<String, Object?>>[],
                'note': 'history is not configured on this host',
              }),
            ),
          ]);
        }

        try {
          final msgs = await provider(chatId, limit);
          return CallToolResult.fromContent([
            TextContent(
              text: jsonEncode({
                'messages': msgs.map((m) => m.toJson()).toList(),
              }),
            ),
          ]);
        } catch (e) {
          return CallToolResult(
            content: [TextContent(text: 'fetch_messages failed: $e')],
            isError: true,
          );
        }
      },
    );

    srv.registerTool(
      'download_attachment',
      description:
          'Download the attachments of a specific message to local files '
          'and return their absolute paths. Call this before `Read` on '
          'any attachment you need to inspect.',
      inputSchema: JsonSchema.object(
        properties: {
          'chat_id': JsonSchema.string(),
          'message_id': JsonSchema.string(),
        },
        required: ['chat_id', 'message_id'],
      ),
      callback: (args, extra) async {
        final chatId = args['chat_id'] as String;
        final messageId = args['message_id'] as String;

        final provider = onDownloadAttachment;
        if (provider == null) {
          return CallToolResult.fromContent([
            TextContent(
              text: jsonEncode({
                'paths': <String>[],
                'note': 'attachment download is not configured on this host',
              }),
            ),
          ]);
        }

        try {
          final result = await provider(chatId, messageId);
          return CallToolResult.fromContent([
            TextContent(
              text: jsonEncode({
                'paths': result.paths,
                if (result.note != null) 'note': result.note,
              }),
            ),
          ]);
        } catch (e) {
          return CallToolResult(
            content: [TextContent(text: 'download_attachment failed: $e')],
            isError: true,
          );
        }
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

  /// Push a user message into Claude Code as a channel notification.
  ///
  /// [chatId] is an opaque routing key; CC echoes it back in
  /// [AssistantReply] / [ReactionRequested] / [MessageEditRequested] so
  /// the host can thread replies to the right conversation.
  Future<void> sendUserMessage({
    required String chatId,
    required String text,
    String? messageId,
    String? user,
    String? userId,
    DateTime? ts,
    Map<String, String>? extraMeta,
  }) async {
    final meta = <String, dynamic>{
      'chat_id': chatId,
      'message_id': ?messageId,
      'user': ?user,
      'user_id': ?userId,
      'ts': (ts ?? DateTime.now().toUtc()).toIso8601String(),
      if (extraMeta != null) ...extraMeta,
    };

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
