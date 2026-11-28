import 'package:supabase_flutter/supabase_flutter.dart';

import '../config.dart';

/// Thin wrapper around one Supabase Realtime channel per room.
///
/// Everything is sent as broadcast events (ephemeral), so no database tables
/// or RLS policies are needed for the first version.
class RoomService {
  RoomService._();

  static final RoomService instance = RoomService._();

  RealtimeChannel? _channel;
  String? _code;
  bool _isHost = false;

  /// Kept so the host also sees what they just sent (self-echo).
  Map<String, dynamic>? lastPlayback;

  final Map<String, void Function(Map<String, dynamic>)> _listeners =
      <String, void Function(Map<String, dynamic>)>{};

  String? get code => _code;
  bool get isHost => _isHost;
  bool get isConnected => _channel != null;
  int get memberCount => _channel?.presenceState().length ?? 0;

  Future<void> initialize() async {
    await Supabase.initialize(
      url: SupabaseConfig.url,
      publishableKey: SupabaseConfig.anonKey,
    );
  }

  void on(String event, void Function(Map<String, dynamic>) listener) {
    _listeners[event] = listener;
  }

  void off(String event) => _listeners.remove(event);

  void _emit(String event, Map<String, dynamic> payload) {
    if (event == 'playback') lastPlayback = payload;
    _listeners[event]?.call(payload);
  }

  Future<void> join(
    String code, {
    required bool asHost,
    required String userId,
  }) async {
    await leave();

    _code = code.trim().toUpperCase();
    _isHost = asHost;

    // self: true makes broadcasts come back to the sender too, so the host's
    // own room screen shows the video they just shared.
    final channel = Supabase.instance.client.channel(
      'watch:$_code',
      opts: const RealtimeChannelConfig(self: true),
    );
    _channel = channel;

    for (final event in <String>['playback', 'chat', 'reaction', 'leave']) {
      channel.onBroadcast(
        event: event,
        callback: (payload) => _emit(event, payload),
      );
    }

    channel.onPresenceSync((_) {
      _emit('presence', <String, dynamic>{'count': memberCount});
    });

    channel.subscribe((status, error) {
      _emit('status', <String, dynamic>{
        'status': status.name,
        'error': error?.toString(),
      });
      if (status == RealtimeSubscribeStatus.subscribed) {
        channel.track(<String, dynamic>{
          'uid': userId,
          'role': asHost ? 'host' : 'viewer',
          'joined_at': DateTime.now().toIso8601String(),
        });
      }
    });
  }

  Future<void> send(String event, Map<String, dynamic> payload) async {
    final channel = _channel;
    if (channel == null) return;
    if (event == 'playback') lastPlayback = payload;
    await channel.sendBroadcastMessage(event: event, payload: payload);
  }

  Future<void> leave() async {
    final channel = _channel;
    _channel = null;
    _code = null;
    _isHost = false;
    lastPlayback = null;
    _listeners.clear();

    if (channel != null) {
      await Supabase.instance.client.removeChannel(channel);
    }
  }
}
