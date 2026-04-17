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
///   MessageEditRequested e => transport.editText(e.chatId, e.messageId, e.text),
///   ReactionRequested r => transport.react(r.chatId, r.messageId, r.emoji),
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

/// Claude Code wants to edit a message it previously sent. Edits are
/// silent on the transport level — no push/notification — so the host
/// should update the existing bubble in place.
final class MessageEditRequested extends AgentEvent {
  const MessageEditRequested({
    required this.chatId,
    required this.messageId,
    required this.text,
  });

  final String chatId;

  /// The message_id the host originally assigned to an earlier
  /// [AssistantReply] (or that was surfaced via `fetch_messages`).
  final String messageId;

  /// Full replacement body.
  final String text;
}

/// Claude Code wants to attach an emoji reaction to an existing message.
final class ReactionRequested extends AgentEvent {
  const ReactionRequested({
    required this.chatId,
    required this.messageId,
    required this.emoji,
  });

  final String chatId;

  /// The message being reacted to. Can be either an inbound user message
  /// (that arrived via [CloudplayAgent.sendUserMessage]) or an earlier
  /// assistant reply.
  final String messageId;

  /// Usually a Unicode emoji like "👍" or "🎉". The host decides whether
  /// to accept custom-platform forms.
  final String emoji;
}

/// Result of a `download_attachment` tool call, returned by the host.
///
/// CC asks for one by `chat_id` + `message_id`; the host resolves the
/// attachments it knows about for that message and writes them to local
/// files it controls, then returns the absolute paths so CC can `Read`
/// them.
final class AttachmentDownload {
  const AttachmentDownload({
    required this.paths,
    this.note,
  });

  /// Absolute filesystem paths CC can read. Empty list is valid (= message
  /// had no attachments). The host is responsible for cleanup / lifetime.
  final List<String> paths;

  /// Optional human-readable note forwarded to CC (e.g. "message had no
  /// attachments", or "2 of 3 skipped due to size").
  final String? note;
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

/// One message returned by the host's history provider in response to a
/// `fetch_messages` tool call. Shape matches what CC sees as a plain
/// JSON object, so you can pass any extra fields through via [extra].
final class HistoryMessage {
  const HistoryMessage({
    required this.messageId,
    required this.text,
    this.author,
    this.ts,
    this.extra = const {},
  });

  final String messageId;
  final String text;

  /// Display name / handle of whoever sent it. Null for system messages.
  final String? author;

  /// UTC timestamp. Null if unknown.
  final DateTime? ts;

  /// Any additional fields to forward to CC (e.g. `reply_to`, attachments
  /// summary). Keys must be JSON-serializable.
  final Map<String, Object?> extra;

  Map<String, Object?> toJson() => {
        'message_id': messageId,
        'text': text,
        if (author != null) 'author': author,
        if (ts != null) 'ts': ts!.toUtc().toIso8601String(),
        ...extra,
      };
}
