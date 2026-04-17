/// Local loopback demo for `cloudplayplus_agent`.
///
/// Run this in one terminal:
///
/// ```
/// dart run example/main.dart
/// ```
///
/// In another terminal, start Claude Code with the generated `.mcp.json`
/// (see the usage banner printed at startup), then type messages at the
/// Claude prompt. They are delivered here as inbound user messages; replies
/// from CC via the `reply` tool show up in this terminal as `[CC →]`.
///
/// This demo intentionally has zero UI — it just proves the MCP plumbing
/// works. Anything pretty (mobile app, card rendering, permission prompts)
/// belongs in the transport layer, not in this package.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cloudplayplus_agent/cloudplayplus_agent.dart';

const _port = 7823;
const _chatId = 'demo-local';

Future<void> main() async {
  final agent = CloudplayAgent(port: _port);
  await agent.start();

  _printBanner();

  // CC → here. Render whatever CC produces.
  final eventsSub = agent.events.listen((event) {
    switch (event) {
      case AssistantReply e:
        stdout.writeln('\n[CC →] ${e.text}');
        if (e.files.isNotEmpty) {
          stdout.writeln('       (files: ${e.files.join(', ')})');
        }
        stdout.write('you> ');
      case PermissionRequested e:
        stdout.writeln('\n[CC 🔐] ${e.toolName} wants to run:');
        stdout.writeln('        ${e.description}');
        if (e.inputPreview.isNotEmpty) {
          final preview = e.inputPreview.length > 200
              ? '${e.inputPreview.substring(0, 200)}…'
              : e.inputPreview;
          stdout.writeln('        $preview');
        }
        stdout.write('        allow? [y/N] → use: /allow ${e.requestId}'
            ' | /deny ${e.requestId}\nyou> ');
    }
  });

  // Handle Ctrl+C gracefully.
  late StreamSubscription<ProcessSignal> sigintSub;
  sigintSub = ProcessSignal.sigint.watch().listen((_) async {
    stdout.writeln('\nshutting down…');
    await eventsSub.cancel();
    await sigintSub.cancel();
    await agent.stop();
    exit(0);
  });

  // Here → CC. Read lines from stdin and forward as user messages.
  stdout.write('you> ');
  await stdin
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .forEach((line) async {
    final trimmed = line.trim();
    if (trimmed.isEmpty) {
      stdout.write('you> ');
      return;
    }

    if (trimmed.startsWith('/allow ') || trimmed.startsWith('/deny ')) {
      final parts = trimmed.split(' ');
      if (parts.length == 2) {
        final allow = parts[0] == '/allow';
        await agent.replyPermission(requestId: parts[1], allow: allow);
        stdout.writeln('       → ${allow ? 'allowed' : 'denied'}');
      } else {
        stdout.writeln('usage: /allow <request_id> | /deny <request_id>');
      }
      stdout.write('you> ');
      return;
    }

    if (trimmed == '/quit' || trimmed == '/exit') {
      await agent.stop();
      exit(0);
    }

    if (trimmed == '/status') {
      stdout.writeln('connected CC sessions: ${agent.connectedSessions}');
      stdout.write('you> ');
      return;
    }

    if (agent.connectedSessions == 0) {
      stdout.writeln('(no CC session connected yet — your message was '
          'dropped; start `claude` first)');
      stdout.write('you> ');
      return;
    }

    await agent.sendUserMessage(
      chatId: _chatId,
      text: trimmed,
      user: 'local-cli',
    );
    stdout.write('you> ');
  });
}

void _printBanner() {
  final mcpJsonPath =
      '${Directory.current.path}${Platform.pathSeparator}.mcp.json';
  stdout.writeln('''
==========================================================================
  cloudplayplus_agent — local MCP channel demo
  MCP endpoint: http://127.0.0.1:$_port/mcp
==========================================================================

1. In ANOTHER terminal, drop a .mcp.json pointing Claude Code at this
   server, then launch `claude`:

     $mcpJsonPath
     ------------------------------------------------------------
     {
       "mcpServers": {
         "cloudplayplus": {
           "type": "http",
           "url": "http://127.0.0.1:$_port/mcp"
         }
       }
     }
     ------------------------------------------------------------

2. In this terminal, type text and hit Enter — it becomes a user message
   delivered to CC through the channel protocol. CC's replies show up as
   `[CC →]` lines.

   Commands:
     /allow <request_id>   approve a pending permission request
     /deny  <request_id>   deny a pending permission request
     /status               show connected CC session count
     /quit                 exit (Ctrl+C also works)

--------------------------------------------------------------------------
''');
}
