/// MCP capability names that Claude Code recognizes for channel plugins.
///
/// These are *experimental*, non-standard MCP capabilities defined by
/// Anthropic's Claude Code. Declaring them in the `initialize` response
/// tells Claude Code that this server can:
///
/// * receive channel messages via `notifications/claude/channel`
/// * relay permission requests via `notifications/claude/channel/permission_request`
///   (CC → server) and `notifications/claude/channel/permission` (server → CC)
///
/// See the official Discord plugin for the reference implementation:
/// `~/.claude/plugins/cache/claude-plugins-official/discord/0.0.4/server.ts`
library;

/// `experimental` block to pass into [ServerCapabilities.experimental].
///
/// Declaring `claude/channel/permission` is an implicit contract:
/// **the server asserts that it authenticates the replier** before forwarding
/// permission decisions. Any transport layer built on top of this package
/// must enforce that contract (gate inbound `replyPermission` calls).
// Typed as Map<String, dynamic> to align with mcp_dart's
// ServerCapabilities.experimental field.
const kClaudeChannelCapabilities = <String, dynamic>{
  'claude/channel': <String, dynamic>{},
  'claude/channel/permission': <String, dynamic>{},
};

/// MCP notification method names (non-standard, Claude Code-specific).
abstract final class ClaudeChannelMethods {
  /// Server → Client: a new user message arrived on the channel.
  static const inboundMessage = 'notifications/claude/channel';

  /// Client → Server: CC wants the channel to ask the user for permission.
  static const permissionRequest =
      'notifications/claude/channel/permission_request';

  /// Server → Client: the channel delivers the user's permission decision.
  static const permissionReply = 'notifications/claude/channel/permission';
}
