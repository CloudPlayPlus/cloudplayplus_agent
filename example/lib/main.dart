/// Interactive Flutter demo for `cloudplayplus_agent`.
///
/// Starts a local MCP channel server, then gives you a chat UI that speaks to
/// whichever Claude Code instance connects to it. Permission prompts from CC
/// show up as inline cards with Allow/Deny buttons.
///
/// Run:
///   cd example
///   flutter run -d windows
///
/// Then in another terminal, drop the `.mcp.json` shown in the app header
/// into a directory and run `claude` there.
library;

import 'dart:async';

import 'package:cloudplayplus_agent/cloudplayplus_agent.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

const _port = 48989;
const _chatId = 'flutter-demo';

void main() {
  runApp(const DemoApp());
}

class DemoApp extends StatelessWidget {
  const DemoApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'CloudPlayPlus Agent Demo',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorSchemeSeed: const Color(0xFF4A6DFF),
        useMaterial3: true,
        brightness: Brightness.light,
      ),
      darkTheme: ThemeData(
        colorSchemeSeed: const Color(0xFF4A6DFF),
        useMaterial3: true,
        brightness: Brightness.dark,
      ),
      home: const HomePage(),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Message model
// ─────────────────────────────────────────────────────────────────────────────

sealed class ChatItem {
  ChatItem()
      : ts = DateTime.now(),
        id = DateTime.now().microsecondsSinceEpoch.toString();
  final DateTime ts;
  final String id;
}

class UserBubble extends ChatItem {
  UserBubble(this.text);
  String text;
  final List<String> reactions = [];
}

class AssistantBubble extends ChatItem {
  AssistantBubble({required this.text, this.files = const []});
  String text;
  List<String> files;
  final List<String> reactions = [];
}

class PermissionCard extends ChatItem {
  PermissionCard({
    required this.requestId,
    required this.toolName,
    required this.description,
    required this.inputPreview,
  });
  final String requestId;
  final String toolName;
  final String description;
  final String inputPreview;
  bool resolved = false;
  bool? allowed;
}

class SystemLine extends ChatItem {
  SystemLine(this.text);
  final String text;
}

// ─────────────────────────────────────────────────────────────────────────────
// Home page — owns the agent, renders chat, sends messages.
// ─────────────────────────────────────────────────────────────────────────────

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  late final CloudplayAgent _agent;
  StreamSubscription<AgentEvent>? _eventsSub;
  Timer? _statusTimer;

  final List<ChatItem> _items = [];
  final TextEditingController _input = TextEditingController();
  final ScrollController _scroll = ScrollController();
  final FocusNode _inputFocus = FocusNode();

  String? _startupError;
  bool _started = false;
  int _connectedSessions = 0;

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    _agent = CloudplayAgent(
      port: _port,
      onFetchMessages: _fetchHistory,
    );
    try {
      await _agent.start();
    } catch (e) {
      setState(() => _startupError = e.toString());
      return;
    }

    _eventsSub = _agent.events.listen(_handleEvent);

    _statusTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      if (_connectedSessions != _agent.connectedSessions) {
        setState(() => _connectedSessions = _agent.connectedSessions);
      }
    });

    setState(() {
      _started = true;
      _items.add(SystemLine(
        'Local MCP server ready on http://127.0.0.1:$_port/mcp — waiting for '
        'Claude Code to connect. Copy the .mcp.json from the banner above '
        'into your project, then run `claude` there.',
      ));
    });
  }

  void _handleEvent(AgentEvent event) {
    if (!mounted) return;
    setState(() {
      switch (event) {
        case AssistantReply e:
          _items.add(AssistantBubble(text: e.text, files: e.files));
        case MessageEditRequested e:
          final target = _items.firstWhere(
            (it) => it.id == e.messageId,
            orElse: () => SystemLine(
              'edit_message: id ${e.messageId} not found',
            ),
          );
          if (target is AssistantBubble) {
            target.text = e.text;
          } else if (target is UserBubble) {
            target.text = e.text;
          }
        case ReactionRequested e:
          final target = _items.firstWhere(
            (it) => it.id == e.messageId,
            orElse: () => SystemLine(
              'react: id ${e.messageId} not found',
            ),
          );
          if (target is AssistantBubble) {
            target.reactions.add(e.emoji);
          } else if (target is UserBubble) {
            target.reactions.add(e.emoji);
          }
        case PermissionRequested e:
          _items.add(PermissionCard(
            requestId: e.requestId,
            toolName: e.toolName,
            description: e.description,
            inputPreview: e.inputPreview,
          ));
      }
    });
    _scrollToEnd();
  }

  Future<List<HistoryMessage>> _fetchHistory(String chatId, int limit) async {
    if (chatId != _chatId) return const [];
    final relevant = _items
        .where((it) => it is UserBubble || it is AssistantBubble)
        .toList();
    final tail = relevant.length > limit
        ? relevant.sublist(relevant.length - limit)
        : relevant;
    return [
      for (final it in tail)
        if (it is UserBubble)
          HistoryMessage(
            messageId: it.id,
            text: it.text,
            author: 'flutter-demo',
            ts: it.ts,
          )
        else if (it is AssistantBubble)
          HistoryMessage(
            messageId: it.id,
            text: it.text,
            author: 'claude',
            ts: it.ts,
          ),
    ];
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty) return;
    _input.clear();
    _inputFocus.requestFocus();

    final bubble = UserBubble(text);
    setState(() => _items.add(bubble));
    _scrollToEnd();

    if (_agent.connectedSessions == 0) {
      setState(() => _items.add(SystemLine(
            'No Claude Code session connected — message queued in UI only.',
          )));
      return;
    }

    try {
      await _agent.sendUserMessage(
        chatId: _chatId,
        text: text,
        messageId: bubble.id,
        user: 'flutter-demo',
      );
    } catch (e) {
      setState(() => _items.add(SystemLine('send failed: $e')));
    }
  }

  Future<void> _resolvePermission(PermissionCard card, bool allow) async {
    await _agent.replyPermission(requestId: card.requestId, allow: allow);
    setState(() {
      card.resolved = true;
      card.allowed = allow;
    });
  }

  void _scrollToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      _scroll.animateTo(
        _scroll.position.maxScrollExtent,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    });
  }

  @override
  void dispose() {
    _statusTimer?.cancel();
    _eventsSub?.cancel();
    _agent.stop();
    _input.dispose();
    _inputFocus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_startupError != null) {
      return Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.error_outline, size: 48, color: Colors.red),
                const SizedBox(height: 16),
                Text('Failed to start MCP server on port $_port',
                    style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 8),
                Text(_startupError!,
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
          ),
        ),
      );
    }

    if (!_started) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('CloudPlayPlus Agent — Demo'),
        actions: [
          _ConnectionChip(count: _connectedSessions),
          const SizedBox(width: 8),
          IconButton(
            tooltip: 'Copy .mcp.json config',
            icon: const Icon(Icons.content_copy),
            onPressed: _copyConfig,
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: Column(
        children: [
          const _ConfigBanner(port: _port),
          Expanded(
            child: _items.isEmpty
                ? const Center(
                    child: Text('Nothing yet. Type below to send a message.'),
                  )
                : ListView.builder(
                    controller: _scroll,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 12),
                    itemCount: _items.length,
                    itemBuilder: (ctx, i) => _renderItem(_items[i]),
                  ),
          ),
          const Divider(height: 1),
          _InputBar(
            controller: _input,
            focusNode: _inputFocus,
            onSend: _send,
          ),
        ],
      ),
    );
  }

  Widget _renderItem(ChatItem item) => switch (item) {
        UserBubble u =>
          _Bubble(text: u.text, isUser: true, reactions: u.reactions),
        AssistantBubble a => _Bubble(
            text: a.text,
            isUser: false,
            files: a.files,
            reactions: a.reactions,
          ),
        PermissionCard c => _PermissionCardView(
            card: c,
            onAllow: () => _resolvePermission(c, true),
            onDeny: () => _resolvePermission(c, false),
          ),
        SystemLine s => _SystemLine(s.text),
      };

  Future<void> _copyConfig() async {
    final cfg = '{"mcpServers":{"cloudplayplus":{"type":"http",'
        '"url":"http://127.0.0.1:$_port/mcp"}}}';
    await Clipboard.setData(ClipboardData(text: cfg));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
          content: Text('.mcp.json snippet copied to clipboard'),
          duration: Duration(seconds: 2)),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Subwidgets
// ─────────────────────────────────────────────────────────────────────────────

class _ConnectionChip extends StatelessWidget {
  const _ConnectionChip({required this.count});
  final int count;

  @override
  Widget build(BuildContext context) {
    final connected = count > 0;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: connected
            ? Colors.green.withValues(alpha: 0.15)
            : Colors.grey.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.circle,
              size: 8, color: connected ? Colors.green : Colors.grey),
          const SizedBox(width: 6),
          Text(connected
              ? '$count CC session${count > 1 ? 's' : ''}'
              : 'no CC connected'),
        ],
      ),
    );
  }
}

class _ConfigBanner extends StatelessWidget {
  const _ConfigBanner({required this.port});
  final int port;

  @override
  Widget build(BuildContext context) {
    final mono = Theme.of(context).textTheme.bodySmall?.copyWith(
          fontFamily: 'monospace',
          height: 1.4,
        );
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Row(
        children: [
          const Icon(Icons.link, size: 16),
          const SizedBox(width: 8),
          Expanded(
            child: SelectableText(
              'MCP endpoint: http://127.0.0.1:$port/mcp  —  drop this into '
              '.mcp.json next to where you run `claude`',
              style: mono,
            ),
          ),
        ],
      ),
    );
  }
}

class _Bubble extends StatelessWidget {
  const _Bubble({
    required this.text,
    required this.isUser,
    this.files = const [],
    this.reactions = const [],
  });
  final String text;
  final bool isUser;
  final List<String> files;
  final List<String> reactions;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final bg = isUser ? scheme.primary : scheme.surfaceContainerHigh;
    final fg = isUser ? scheme.onPrimary : scheme.onSurface;
    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        constraints: const BoxConstraints(maxWidth: 560),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(14),
            topRight: const Radius.circular(14),
            bottomLeft: Radius.circular(isUser ? 14 : 4),
            bottomRight: Radius.circular(isUser ? 4 : 14),
          ),
        ),
        child: Column(
          crossAxisAlignment:
              isUser ? CrossAxisAlignment.end : CrossAxisAlignment.start,
          children: [
            if (!isUser)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text(
                  'Claude',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: fg.withValues(alpha: 0.7),
                  ),
                ),
              ),
            SelectableText(text, style: TextStyle(color: fg, height: 1.35)),
            if (files.isNotEmpty) ...[
              const SizedBox(height: 6),
              ...files.map((f) => Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.attach_file,
                          size: 14, color: fg.withValues(alpha: 0.7)),
                      const SizedBox(width: 4),
                      Text(f,
                          style: TextStyle(
                              fontSize: 12,
                              color: fg.withValues(alpha: 0.8))),
                    ],
                  )),
            ],
            if (reactions.isNotEmpty) ...[
              const SizedBox(height: 6),
              Wrap(
                spacing: 4,
                runSpacing: 4,
                children: [
                  for (final emoji in reactions)
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: fg.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text(emoji,
                          style: const TextStyle(fontSize: 14)),
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _PermissionCardView extends StatelessWidget {
  const _PermissionCardView({
    required this.card,
    required this.onAllow,
    required this.onDeny,
  });
  final PermissionCard card;
  final VoidCallback onAllow;
  final VoidCallback onDeny;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final resolved = card.resolved;
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 8),
      decoration: BoxDecoration(
        color: scheme.tertiaryContainer.withValues(alpha: resolved ? 0.3 : 0.6),
        border: Border.all(
          color: scheme.tertiary.withValues(alpha: resolved ? 0.2 : 0.6),
          width: 1,
        ),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.lock_outline, size: 18),
                const SizedBox(width: 6),
                Text(
                  'Permission: ${card.toolName}',
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                ),
                const Spacer(),
                if (resolved)
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: (card.allowed! ? Colors.green : Colors.red)
                          .withValues(alpha: 0.2),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      card.allowed! ? '✓ Allowed' : '✗ Denied',
                      style: TextStyle(
                        fontSize: 11,
                        color: card.allowed! ? Colors.green : Colors.red,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
              ],
            ),
            if (card.description.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(card.description,
                  style: Theme.of(context).textTheme.bodyMedium),
            ],
            if (card.inputPreview.isNotEmpty) ...[
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: scheme.surface.withValues(alpha: 0.6),
                  borderRadius: BorderRadius.circular(6),
                ),
                width: double.infinity,
                child: SelectableText(
                  card.inputPreview,
                  style: const TextStyle(
                      fontFamily: 'monospace', fontSize: 12, height: 1.4),
                ),
              ),
            ],
            if (!resolved) ...[
              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  OutlinedButton.icon(
                    onPressed: onDeny,
                    icon: const Icon(Icons.close, size: 16),
                    label: const Text('Deny'),
                    style: OutlinedButton.styleFrom(foregroundColor: Colors.red),
                  ),
                  const SizedBox(width: 10),
                  FilledButton.icon(
                    onPressed: onAllow,
                    icon: const Icon(Icons.check, size: 16),
                    label: const Text('Allow'),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _SystemLine extends StatelessWidget {
  const _SystemLine(this.text);
  final String text;
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Center(
        child: Text(
          text,
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context)
                    .colorScheme
                    .onSurface
                    .withValues(alpha: 0.6),
                fontStyle: FontStyle.italic,
              ),
        ),
      ),
    );
  }
}

class _InputBar extends StatelessWidget {
  const _InputBar({
    required this.controller,
    required this.focusNode,
    required this.onSend,
  });
  final TextEditingController controller;
  final FocusNode focusNode;
  final VoidCallback onSend;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: TextField(
              controller: controller,
              focusNode: focusNode,
              autofocus: true,
              minLines: 1,
              maxLines: 4,
              textInputAction: TextInputAction.send,
              onSubmitted: (_) => onSend(),
              decoration: InputDecoration(
                hintText: 'Say something to Claude…',
                filled: true,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(22),
                  borderSide: BorderSide.none,
                ),
                contentPadding: const EdgeInsets.symmetric(
                    horizontal: 16, vertical: 12),
              ),
            ),
          ),
          const SizedBox(width: 8),
          FilledButton(
            onPressed: onSend,
            style: FilledButton.styleFrom(
              shape: const CircleBorder(),
              padding: const EdgeInsets.all(14),
            ),
            child: const Icon(Icons.send, size: 18),
          ),
        ],
      ),
    );
  }
}
