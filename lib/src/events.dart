/// Events the host application observes from [CloudplayAgent.events].
///
/// Each event is something Claude Code has produced or requested; the host
/// is responsible for delivering it to the end user (over WebRTC DC, IM,
/// FCM push, etc.) and — for events that expect a response — feeding the
/// user's reaction back in via the matching method on [CloudplayAgent].
library;

/// Base type for all agent events. Use pattern matching:
///
/// ```dart
/// agent.events.listen((e) => switch (e) {
///   AssistantReply r => transport.sendText(r.chatId, r.text),
///   PermissionRequested p => transport.sendPermissionCard(p),
/// });
/// ```
sealed class AgentEvent {
  const AgentEvent();
}

/// Claude Code has produced a chat reply that should reach the user.
///
/// Comes from the CC-side `reply` tool call. The host forwards this to
/// whatever transport is configured (DC, push, etc.).
final class AssistantReply extends AgentEvent {
  const AssistantReply({
    required this.chatId,
    required this.text,
    this.replyToMessageId,
    this.files = const [],
  });

  /// Opaque chat identifier the host gave CC via [sendUserMessage]. CC echoes
  /// it back so the host can route the reply to the right conversation.
  final String chatId;

  final String text;

  /// If set, CC wants this rendered as a threaded reply to an earlier user
  /// message. Null means a normal top-level reply.
  final String? replyToMessageId;

  /// Absolute filesystem paths CC wants attached to the reply. Host is
  /// responsible for reading, uploading, or rejecting these as appropriate.
  final List<String> files;
}

/// Claude Code wants to run a tool that requires user permission. The host
/// must show this to the user and eventually call
/// [CloudplayAgent.replyPermission] with the decision.
///
/// Permission requests time out on the CC side (~minutes). If no reply
/// arrives, CC treats it as deny.
final class PermissionRequested extends AgentEvent {
  const PermissionRequested({
    required this.requestId,
    required this.toolName,
    required this.description,
    required this.inputPreview,
  });

  /// Echo this back via [CloudplayAgent.replyPermission].
  final String requestId;

  /// e.g. "Bash", "Edit", "Write".
  final String toolName;

  /// Short human-readable description, safe to display.
  final String description;

  /// JSON string of the pending tool input. May be large — truncate before
  /// showing on small screens, offer a "See more" expansion.
  final String inputPreview;
}
