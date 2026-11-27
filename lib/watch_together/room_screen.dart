import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../main.dart';
import 'room_service.dart';
import 'user_store.dart';

const Color _roomBackground = Color(0xFF06070B);
const Color _roomPanel = Color(0xFF12161F);
const Color _roomLine = Color(0xFF252C3B);
const Color _roomAccent = Color(0xFF8B9DFF);

class RoomScreen extends StatefulWidget {
  const RoomScreen({super.key, required this.code, required this.isHost});

  final String code;
  final bool isHost;

  @override
  State<RoomScreen> createState() => _RoomScreenState();
}

class _RoomScreenState extends State<RoomScreen> {
  final TextEditingController _chatController = TextEditingController();
  final List<String> _messages = <String>[];

  String _name = 'Guest';
  int _members = 1;
  String? _floatingEmoji;

  @override
  void initState() {
    super.initState();
    UserStore.getName().then((name) {
      if (name != null && mounted) setState(() => _name = name);
    });
    RoomService.instance.on('chat', _onChat);
    RoomService.instance.on('presence', _onPresence);
    RoomService.instance.on('reaction', _onReaction);
  }

  @override
  void dispose() {
    RoomService.instance.off('chat');
    RoomService.instance.off('presence');
    RoomService.instance.off('reaction');
    _chatController.dispose();
    super.dispose();
  }

  void _onChat(Map<String, dynamic> payload) {
    final text = payload['text']?.toString();
    if (text == null || text.isEmpty || !mounted) return;
    setState(() {
      _messages.add('${payload['name'] ?? 'Guest'}: $text');
      if (_messages.length > 30) _messages.removeAt(0);
    });
  }

  void _onPresence(Map<String, dynamic> payload) {
    if (!mounted) return;
    setState(() => _members = (payload['count'] as num?)?.toInt() ?? 1);
  }

  void _onReaction(Map<String, dynamic> payload) {
    final emoji = payload['emoji']?.toString();
    if (emoji == null || !mounted) return;
    setState(() => _floatingEmoji = emoji);
    unawaited(
      Future<void>.delayed(const Duration(seconds: 2), () {
        if (mounted) setState(() => _floatingEmoji = null);
      }),
    );
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _copyCode() async {
    await Clipboard.setData(ClipboardData(text: widget.code));
    _showMessage('Room code ${widget.code} copied.');
  }

  Future<void> _openBrowser() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => BrowserScreen(roomCode: widget.code),
      ),
    );
  }

  Future<void> _leave() async {
    await RoomService.instance.leave();
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _sendChat() async {
    final text = _chatController.text.trim();
    if (text.isEmpty) return;
    _chatController.clear();
    await RoomService.instance.send('chat', <String, dynamic>{
      'name': _name,
      'text': text,
      'at': DateTime.now().toIso8601String(),
    });
  }

  Widget _control(IconData icon, String tooltip) {
    return IconButton(
      onPressed: null,
      icon: Icon(icon, size: 20, color: Colors.white38),
      tooltip: '$tooltip (next step)',
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _roomBackground,
      body: SafeArea(
        child: Column(
          children: [
            Container(
              height: 52,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              decoration: const BoxDecoration(
                color: _roomPanel,
                border: Border(bottom: BorderSide(color: _roomLine)),
              ),
              child: Row(
                children: [
                  IconButton(
                    onPressed: _copyCode,
                    tooltip: 'Copy room code',
                    icon: const Icon(Icons.copy_rounded, size: 19),
                  ),
                  Text(
                    widget.code,
                    style: const TextStyle(
                      color: _roomAccent,
                      letterSpacing: 3,
                      fontWeight: FontWeight.bold,
                      fontSize: 13,
                    ),
                  ),
                  IconButton(
                    onPressed: _openBrowser,
                    tooltip: 'Open browser',
                    icon: const Icon(Icons.public_rounded, size: 20),
                  ),
                  const Spacer(),
                  IconButton(
                    onPressed: _openBrowser,
                    tooltip: 'Browse a video site',
                    icon: const Icon(Icons.add_to_photos_rounded, size: 19),
                  ),
                  IconButton(
                    onPressed: _leave,
                    tooltip: 'Back / leave room',
                    icon: const Icon(Icons.arrow_back_rounded),
                  ),
                ],
              ),
            ),
            AspectRatio(
              aspectRatio: 16 / 9,
              child: Container(
                color: Colors.black,
                alignment: Alignment.center,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.video_library_outlined,
                          size: 54,
                          color: Colors.white24,
                        ),
                        const SizedBox(height: 10),
                        const Text(
                          'Video will appear here',
                          style: TextStyle(color: Colors.white38, fontSize: 14),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'Room ${widget.code} · $_members watching',
                          style: const TextStyle(
                            color: Colors.white24,
                            fontSize: 11,
                          ),
                        ),
                      ],
                    ),
                    if (_floatingEmoji != null)
                      Text(
                        _floatingEmoji!,
                        style: const TextStyle(fontSize: 60),
                      ),
                  ],
                ),
              ),
            ),
            Container(
              height: 52,
              padding: const EdgeInsets.symmetric(horizontal: 10),
              decoration: const BoxDecoration(
                color: _roomPanel,
                border: Border(
                  bottom: BorderSide(color: _roomLine),
                  top: BorderSide(color: _roomLine),
                ),
              ),
              child: Row(
                children: [
                  _control(Icons.play_arrow_rounded, 'Play'),
                  _control(Icons.pause_rounded, 'Pause'),
                  _control(Icons.replay_10_rounded, 'Back 10s'),
                  _control(Icons.forward_10_rounded, 'Forward 10s'),
                  _control(Icons.volume_up_rounded, 'Volume'),
                  _control(Icons.fullscreen_rounded, 'Fullscreen'),
                  const Spacer(),
                  Text(
                    widget.isHost ? 'Host controls' : 'Viewer',
                    style: const TextStyle(color: Colors.white38, fontSize: 12),
                  ),
                ],
              ),
            ),
            Expanded(
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
                    child: Row(
                      children: [
                        const Icon(
                          Icons.chat_bubble_outline_rounded,
                          size: 16,
                          color: Colors.white38,
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            _messages.isEmpty
                                ? 'No messages yet'
                                : _messages.last,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white54,
                              fontSize: 13,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: ListView.builder(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      itemCount: _messages.length,
                      itemBuilder: (context, index) => Padding(
                        padding: const EdgeInsets.symmetric(vertical: 3),
                        child: Text(
                          _messages[index],
                          style: const TextStyle(
                            fontSize: 13,
                            color: Colors.white70,
                          ),
                        ),
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(10, 6, 10, 10),
                    child: Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _chatController,
                            onSubmitted: (_) => _sendChat(),
                            decoration: InputDecoration(
                              isDense: true,
                              hintText: 'Message as $_name',
                              border: const OutlineInputBorder(),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        IconButton.filled(
                          onPressed: _sendChat,
                          icon: const Icon(Icons.send_rounded),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
