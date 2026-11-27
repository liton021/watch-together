import 'dart:async';
import 'dart:collection';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import 'room_service.dart';

const Color _background = Color(0xFF0B0E14);
const Color _panel = Color(0xFF12161F);
const Color _line = Color(0xFF252C3B);
const Color _accent = Color(0xFF8B9DFF);

/// Loads the host's page and hides everything except the video element.
/// Also exposes __wtSync so Flutter can mirror play/pause/seek.
const String _focusVideoScript = r'''
(function () {
  function focusVideo() {
    var videos = document.querySelectorAll('video');
    if (!videos.length) { return; }
    var v = videos[0];

    document.querySelectorAll('body *').forEach(function (el) {
      if (el === v || v.contains(el) || el.contains(v)) {
        if (el !== v) {
          el.style.setProperty('overflow', 'visible', 'important');
        }
        return;
      }
      el.style.setProperty('display', 'none', 'important');
    });

    v.style.setProperty('position', 'fixed', 'important');
    v.style.setProperty('left', '0', 'important');
    v.style.setProperty('top', '0', 'important');
    v.style.setProperty('width', '100vw', 'important');
    v.style.setProperty('height', '100vh', 'important');
    v.style.setProperty('object-fit', 'contain', 'important');
    v.style.setProperty('background', '#000', 'important');
    v.style.setProperty('z-index', '2147483647', 'important');
  }

  window.__wtSync = function (event, position) {
    var v = document.querySelector('video');
    if (!v) {
      setTimeout(function () { window.__wtSync(event, position); }, 400);
      return;
    }
    focusVideo();
    if (event === 'pause') {
      v.pause();
    } else {
      v.play().catch(function () {});
    }
    if (typeof position === 'number' &&
        Math.abs(v.currentTime - position) > 1.5) {
      try { v.currentTime = position; } catch (_) {}
    }
  };

  setInterval(focusVideo, 1200);
})();
''';

const String _waitingHtml = r'''
<!DOCTYPE html>
<html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<style>
  :root { color-scheme: dark; }
  body { margin:0; height:100vh; display:flex; align-items:center; justify-content:center;
    background:#06070b; color:#98a1b3; font-family:system-ui, sans-serif; text-align:center; }
  .box { max-width:320px; }
  .icon { font-size:42px; margin-bottom:12px; }
</style></head>
<body><div class="box"><div class="icon">📺</div>
Waiting for the host to start a video…</div></body></html>
''';

class _ChatMessage {
  const _ChatMessage(this.name, this.text);

  final String name;
  final String text;
}

class ViewerScreen extends StatefulWidget {
  const ViewerScreen({super.key, required this.code});

  final String code;

  @override
  State<ViewerScreen> createState() => _ViewerScreenState();
}

class _ViewerScreenState extends State<ViewerScreen> {
  static const List<String> _reactions = <String>['❤️', '😂', '👏', '🔥', '😮'];

  InAppWebViewController? _controller;
  final TextEditingController _chatController = TextEditingController();

  String? _videoUrl;
  String? _pendingAction;
  double? _pendingPosition;

  final List<_ChatMessage> _messages = <_ChatMessage>[];
  String? _floatingEmoji;
  int _memberCount = 0;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    RoomService.instance.on('playback', _onPlayback);
    RoomService.instance.on('chat', _onChat);
    RoomService.instance.on('reaction', _onReaction);
    RoomService.instance.on('presence', _onPresence);
  }

  @override
  void dispose() {
    RoomService.instance.off('playback');
    RoomService.instance.off('chat');
    RoomService.instance.off('reaction');
    RoomService.instance.off('presence');
    _chatController.dispose();
    super.dispose();
  }

  void _onPresence(Map<String, dynamic> payload) {
    if (!mounted) return;
    setState(() => _memberCount = (payload['count'] as num?)?.toInt() ?? 0);
  }

  void _onChat(Map<String, dynamic> payload) {
    final text = payload['text']?.toString();
    if (text == null || text.isEmpty) return;
    if (!mounted) return;
    setState(() {
      _messages.add(_ChatMessage(payload['name']?.toString() ?? 'Guest', text));
      if (_messages.length > 50) _messages.removeAt(0);
    });
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

  void _onPlayback(Map<String, dynamic> payload) {
    final url = payload['url']?.toString();
    final event = payload['event']?.toString() ?? 'play';
    final position = (payload['position'] as num?)?.toDouble();

    if (url != null && url != _videoUrl) {
      _pendingAction = event;
      _pendingPosition = position;
      setState(() => _videoUrl = url);
      _load(url);
    } else {
      _applySync(event, position);
    }
  }

  void _load(String url) {
    final controller = _controller;
    if (controller == null) return;
    controller.loadUrl(urlRequest: URLRequest(url: WebUri(url)));
  }

  Future<void> _applySync(String event, double? position) async {
    final controller = _controller;
    if (controller == null) return;
    final value = position == null ? 'null' : position.toString();
    try {
      await controller.evaluateJavascript(
        source: 'if (window.__wtSync) window.__wtSync(\'$event\', $value);',
      );
    } catch (_) {
      // Cross-origin restrictions can block scripting on a few sites.
    }
  }

  Future<void> _sendChat() async {
    final text = _chatController.text.trim();
    if (text.isEmpty) return;
    _chatController.clear();
    await RoomService.instance.send('chat', <String, dynamic>{
      'name': 'Guest',
      'text': text,
      'at': DateTime.now().toIso8601String(),
    });
  }

  Future<void> _sendReaction(String emoji) {
    return RoomService.instance.send('reaction', <String, dynamic>{
      'emoji': emoji,
      'at': DateTime.now().toIso8601String(),
    });
  }

  Future<void> _leave() async {
    await RoomService.instance.leave();
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _background,
      body: SafeArea(
        child: Column(
          children: [
            Container(
              height: 52,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              decoration: const BoxDecoration(
                color: _panel,
                border: Border(bottom: BorderSide(color: _line)),
              ),
              child: Row(
                children: [
                  IconButton(
                    onPressed: _leave,
                    tooltip: 'Leave room',
                    icon: const Icon(Icons.arrow_back_rounded),
                  ),
                  const SizedBox(width: 4),
                  Text(
                    'Room ${widget.code}',
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                  const Spacer(),
                  Icon(
                    Icons.visibility_rounded,
                    size: 16,
                    color: Colors.white54,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    '$_memberCount',
                    style: const TextStyle(color: Colors.white70),
                  ),
                  const SizedBox(width: 12),
                ],
              ),
            ),
            Expanded(
              child: Stack(
                children: [
                  InAppWebView(
                    key: ValueKey<String?>(_videoUrl),
                    initialData: InAppWebViewInitialData(data: _waitingHtml),
                    initialUserScripts:
                        UnmodifiableListView<UserScript>(<UserScript>[
                          UserScript(
                            source: _focusVideoScript,
                            injectionTime:
                                UserScriptInjectionTime.AT_DOCUMENT_START,
                          ),
                        ]),
                    initialSettings: InAppWebViewSettings(
                      javaScriptEnabled: true,
                      mediaPlaybackRequiresUserGesture: false,
                      allowsInlineMediaPlayback: true,
                      supportZoom: false,
                      iframeAllow:
                          'autoplay; encrypted-media; fullscreen; picture-in-picture',
                      iframeAllowFullscreen: true,
                    ),
                    onWebViewCreated: (controller) {
                      _controller = controller;
                      final url = _videoUrl;
                      if (url != null) _load(url);
                    },
                    onLoadStop: (controller, url) {
                      if (!mounted) return;
                      setState(() => _loading = false);
                      final action = _pendingAction;
                      if (action != null) {
                        _applySync(action, _pendingPosition);
                        _pendingAction = null;
                        _pendingPosition = null;
                      }
                    },
                  ),
                  if (_loading && _videoUrl != null)
                    const Center(
                      child: CircularProgressIndicator(color: _accent),
                    ),
                  if (_floatingEmoji != null)
                    Center(
                      child: Text(
                        _floatingEmoji!,
                        style: const TextStyle(fontSize: 72),
                      ),
                    ),
                ],
              ),
            ),
            Container(
              height: 196,
              decoration: const BoxDecoration(
                color: _panel,
                border: Border(top: BorderSide(color: _line)),
              ),
              child: Column(
                children: [
                  Expanded(
                    child: ListView.builder(
                      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
                      itemCount: _messages.length,
                      itemBuilder: (context, index) {
                        final message = _messages[index];
                        return Padding(
                          padding: const EdgeInsets.symmetric(vertical: 2),
                          child: Text(
                            '${message.name}: ${message.text}',
                            style: const TextStyle(
                              fontSize: 13,
                              color: Colors.white70,
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                  SizedBox(
                    height: 38,
                    child: ListView(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      children: [
                        for (final emoji in _reactions) ...[
                          IconButton(
                            onPressed: () => _sendReaction(emoji),
                            tooltip: 'Send $emoji',
                            icon: Text(
                              emoji,
                              style: const TextStyle(fontSize: 20),
                            ),
                          ),
                          const SizedBox(width: 2),
                        ],
                      ],
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(10, 4, 10, 10),
                    child: Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _chatController,
                            onSubmitted: (_) => _sendChat(),
                            decoration: const InputDecoration(
                              isDense: true,
                              hintText: 'Say something…',
                              border: OutlineInputBorder(),
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
