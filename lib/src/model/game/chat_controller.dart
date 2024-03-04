import 'dart:async';

import 'package:deep_pick/deep_pick.dart';
import 'package:fast_immutable_collections/fast_immutable_collections.dart';
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:lichess_mobile/src/db/database.dart';
import 'package:lichess_mobile/src/model/common/id.dart';
import 'package:lichess_mobile/src/model/common/socket.dart';
import 'package:lichess_mobile/src/model/game/game_controller.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:sqflite/sqflite.dart';

part 'chat_controller.freezed.dart';
part 'chat_controller.g.dart';

const _tableName = 'chat_read_messages';
String _storeKey(GameFullId id) => 'game.$id';

@riverpod
class ChatController extends _$ChatController {
  StreamSubscription<SocketEvent>? _subscription;

  late SocketClient _socketClient;

  @override
  Future<ChatState> build(GameFullId id) async {
    _socketClient =
        ref.read(socketPoolProvider).connect(GameController.gameSocketUri(id));

    _subscription?.cancel();
    _subscription = _socketClient.stream.listen(_handleSocketEvent);

    ref.onDispose(() {
      _subscription?.cancel();
    });

    final messages = await _socketClient.stream
        .firstWhere((event) => event.topic == 'full')
        .then(
          (event) => pick(event.data, 'chat', 'lines')
              .asListOrNull(_messageFromPick)
              ?.toIList(),
        );

    final readMessagesCount = await _getReadMessagesCount();

    return ChatState(
      messages: messages ?? IList(),
      unreadMessages: (messages?.length ?? 0) - readMessagesCount,
    );
  }

  /// Sends a message to the chat.
  void sendMessage(String message) {
    _socketClient.send(
      'talk',
      message,
    );
  }

  /// Resets the unread messages count to 0 and saves the number of read messages.
  Future<void> markMessagesAsRead() async {
    if (state.hasValue) {
      await _setReadMessagesCount(state.requireValue.messages.length);
    }
    state = state.whenData(
      (s) => s.copyWith(unreadMessages: 0),
    );
  }

  Future<int> _getReadMessagesCount() async {
    final db = ref.read(databaseProvider);
    final result = await db.query(
      _tableName,
      columns: ['nbRead'],
      where: 'id = ?',
      whereArgs: [_storeKey(id)],
    );
    return result.firstOrNull?['nbRead'] as int? ?? 0;
  }

  Future<void> _setReadMessagesCount(int count) async {
    final db = ref.read(databaseProvider);
    await db.insert(
      _tableName,
      {
        'id': _storeKey(id),
        'lastModified': DateTime.now().toIso8601String(),
        'nbRead': count,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> _setMessages(IList<Message> messages) async {
    final readMessagesCount = await _getReadMessagesCount();

    state = state.whenData(
      (s) => s.copyWith(
        messages: messages,
        unreadMessages: messages.length - readMessagesCount,
      ),
    );
  }

  void _addMessage(Message message) {
    state = state.whenData(
      (s) => s.copyWith(
        messages: s.messages.add(message),
        unreadMessages: s.unreadMessages + 1,
      ),
    );
  }

  void _handleSocketEvent(SocketEvent event) {
    if (!state.hasValue) return;

    if (event.topic == 'full') {
      final messages = pick(event.data, 'chat', 'lines')
          .asListOrNull(_messageFromPick)
          ?.toIList();
      if (messages != null) {
        _setMessages(messages);
      }
    } else if (event.topic == 'message') {
      final data = event.data as Map<String, dynamic>;
      final message = data['t'] as String;
      final username = data['u'] as String?;
      _addMessage(
        (
          message: message,
          username: username,
        ),
      );
    }
  }
}

@freezed
class ChatState with _$ChatState {
  const ChatState._();

  const factory ChatState({
    required IList<Message> messages,
    required int unreadMessages,
  }) = _ChatState;
}

typedef Message = ({String? username, String message});

Message _messageFromPick(RequiredPick pick) {
  return (
    message: pick('t').asStringOrThrow(),
    username: pick('u').asStringOrNull(),
  );
}
