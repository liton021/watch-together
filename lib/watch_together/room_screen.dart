import 'dart:async';
import 'dart:collection';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../main.dart';
import 'room_service.dart';
import 'user_store.dart';

const Color _roomBackground = Color(0xFF06070B);
const Color _roomPanel = Color(0xFF12161F);
const Color _roomLine = Color(0xFF252C3B);
const Color _roomAccent = Color(0xFF8B9DFF);

/// Keeps only the player portion of the host's page: a visible <video> or,
/// when the player lives in another frame, that <iframe> element. Everything
/// else is hidden and the player is expanded to fill the 16:9 screen.
const String _focusVideoScript = r'''
(function () {
  function bestVideo() {
    var v = null, best = -1;
    Array.prototype.slice.call(document.querySelectorAll('video')).forEach(function (c) {
      var r = c.getBoundingClientRect();
      if (r.width < 10 || r.height < 10) { return; }
      var score = r.width * r.height +
        ((!c.paused && c.currentTime > 0) ? 1000000 : 0);
      if (score > best) { best = score; v = c; }
    });
    return v;
  }

  function bestIframe() {
    var f = null, best = -1;
    Array.prototype.slice.call(document.querySelectorAll('iframe')).forEach(function (c) {
      var r = c.getBoundingClientRect();
      if (r.width < 10 || r.height < 10) { return; }
      if (!/^https?:\/\//i.test(c.src || '')) { return; }
      if (r.width * r.height > best) { best = r.width * r.height; f = c; }
    });
    return f;
  }

  function focusPlayer() {
    var target = bestVideo() || bestIframe();
    if (!target) { return; }
    document.querySelectorAll('body *').forEach(function (el) {
      if (el === target || target.contains(el) || el.contains(target)) {
        if (el !== target) {
          el.style.setProperty('overflow', 'visible', 'important');
        }
        return;
      }
      el.style.setProperty('display', 'none', 'important');
    });
    target.style.setProperty('position', 'fixed', 'important');
    target.style.setProperty('left', '0', 'important');
    target.style.setProperty('top', '0', 'important');
    target.style.setProperty('width', '100vw', 'important');
    target.style.setProperty('height', '100vh', 'important');
    target.style.setProperty('background', '#000', 'important');
    target.style.setProperty('z-index', '2147483647', 'important');
    if (target.tagName === 'VIDEO') {
      target.style.setProperty('object-fit', 'contain', 'important');
    }
  }

  window.__wtSync = function (event, position) {
    var v = bestVideo();
    if (!v) { setTimeout(function () { window.__wtSync(event, position); }, 400); return; }
    focusPlayer();
    if (event === 'pause') { v.pause(); }
    else { v.play().catch(function () {}); }
    if (typeof position === 'number' && Math.abs(v.currentTime - position) > 1.5) {
      try { v.currentTime = position; } catch (_) {}
    }
  };

  setInterval(focusPlayer, 1200);
})();
''';

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

  InAppWebViewController? _playerController;
  DateTime? _playerSettledAt;
  String? _sharedKind;
  String? _sharedUrl;
  String? _syncEvent;
  double? _syncPosition;

  @override
  void initState() {
    super.initState();
    UserStore.getName().then((name) {
      if (name != null && mounted) setState(() => _name = name);
    });
    RoomService.instance.on('chat', _onChat);
    RoomService.instance.on('presence', _onPresence);
    RoomService.instance.on('reaction', _onReaction);
    RoomService.instance.on('playback', _onPlayback);

    // If the host already shared something before this screen was opened,
    // restore it from the service instead of showing "waiting" forever.
    final existing = RoomService.instance.lastPlayback;
    if (existing != null) _onPlayback(existing);
  }

  @override
  void dispose() {
    RoomService.instance.off('chat');
    RoomService.instance.off('presence');
    RoomService.instance.off('reaction');
    RoomService.instance.off('playback');
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

  void _onPlayback(Map<String, dynamic> payload) {
    if (!mounted) return;

    final kind = payload['kind']?.toString();
    final url = payload['url']?.toString();
    if (kind != null && url != null && url.isNotEmpty) {
      if (kind != _sharedKind || url != _sharedUrl) {
        setState(() {
          _sharedKind = kind;
          _sharedUrl = url;
          _playerSettledAt = null;
          _syncEvent = payload['event']?.toString() ?? 'play';
          _syncPosition = (payload['position'] as num?)?.toDouble();
        });
      } else {
        _applySync(
          payload['event']?.toString(),
          (payload['position'] as num?)?.toDouble(),
        );
      }
      return;
    }

    _applySync(
      payload['event']?.toString(),
      (payload['position'] as num?)?.toDouble(),
    );
  }

  String _playerUrl(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return url;
    if (uri.host.contains('youtube.com') &&
        !uri.queryParameters.containsKey('autoplay')) {
      return uri
          .replace(
            queryParameters: <String, String>{
              ...uri.queryParameters,
              'autoplay': '1',
              'playsinline': '1',
            },
          )
          .toString();
    }
    return url;
  }

  Future<void> _applySync(String? event, double? position) async {
    if (event == null || _sharedKind != 'video') return;
    final controller = _playerController;
    if (controller == null) return;
    final value = position == null ? 'null' : position.toString();
    try {
      await controller.evaluateJavascript(
        source: 'if (window.__wtSync) window.__wtSync(\'$event\', $value);',
      );
    } catch (_) {}
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

  Future<void> _sendControl(String event) async {
    await RoomService.instance.send('playback', <String, dynamic>{
      'event': event,
      'position': _syncPosition ?? 0,
      'at': DateTime.now().toIso8601String(),
    });
  }

  Widget _control(IconData icon, String tooltip, {VoidCallback? onPressed}) {
    return IconButton(
      onPressed: onPressed,
      icon: Icon(
        icon,
        size: 20,
        color: onPressed == null ? Colors.white38 : Colors.white,
      ),
      tooltip: tooltip,
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
                child: _sharedUrl == null
                    ? Stack(
                        alignment: Alignment.center,
                        children: [
                          Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(
                                Icons.video_library_outlined,
                                size: 54,
                                color: Colors.white24,
                              ),
                              const SizedBox(height: 10),
                              const Text(
                                'Waiting for the host to send a video',
                                style: TextStyle(
                                  color: Colors.white38,
                                  fontSize: 14,
                                ),
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
                      )
                    : Stack(
                        children: [
                          // Platform views need tight constraints; a bare
                          // Stack child can collapse to zero height on Android.
                          Positioned.fill(
                            child: InAppWebView(
                              key: ValueKey<String>('$_sharedKind|$_sharedUrl'),
                              initialUrlRequest: URLRequest(
                                url: WebUri(_playerUrl(_sharedUrl!)),
                              ),
                              initialUserScripts:
                                  UnmodifiableListView<UserScript>(<UserScript>[
                                    UserScript(
                                      source: adBlockerScript(viewer: true),
                                      injectionTime: UserScriptInjectionTime
                                          .AT_DOCUMENT_START,
                                    ),
                                    if (_sharedKind == 'video')
                                      UserScript(
                                        source: _focusVideoScript,
                                        injectionTime: UserScriptInjectionTime
                                            .AT_DOCUMENT_START,
                                      ),
                                  ]),
                              initialSettings: InAppWebViewSettings(
                                javaScriptEnabled: true,
                                javaScriptCanOpenWindowsAutomatically: false,
                                supportMultipleWindows: false,
                                useShouldInterceptRequest: true,
                                useShouldOverrideUrlLoading: true,
                                mediaPlaybackRequiresUserGesture: false,
                                allowsInlineMediaPlayback: true,
                                supportZoom: false,
                                iframeAllow:
                                    'autoplay; encrypted-media; fullscreen; picture-in-picture',
                                iframeAllowFullscreen: true,
                              ),
                              shouldInterceptRequest: blockAdResource,
                              shouldOverrideUrlLoading: (controller, action) {
                                return viewerNavigationPolicy(
                                  controller,
                                  action,
                                  settledAt: _playerSettledAt,
                                );
                              },
                              onWebViewCreated: (controller) {
                                _playerController = controller;
                              },
                              // Movie sites often gate the player behind a
                              // confirm() dialog. Viewers should not have to
                              // tap through it, so accept it automatically.
                              onJsConfirm: (controller, request) async {
                                return JsConfirmResponse(
                                  handledByClient: true,
                                  action: JsConfirmResponseAction.CONFIRM,
                                );
                              },
                              onJsAlert: (controller, request) async {
                                return JsAlertResponse(handledByClient: true);
                              },
                              onLoadStop: (controller, url) {
                                _playerSettledAt = DateTime.now();
                                final event = _syncEvent;
                                if (event != null) {
                                  _applySync(event, _syncPosition);
                                }
                              },
                            ),
                          ),
                          if (_floatingEmoji != null)
                            Center(
                              child: Text(
                                _floatingEmoji!,
                                style: const TextStyle(fontSize: 60),
                              ),
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
                  _control(
                    Icons.play_arrow_rounded,
                    'Play',
                    onPressed: widget.isHost
                        ? () => _sendControl('play')
                        : null,
                  ),
                  _control(
                    Icons.pause_rounded,
                    'Pause',
                    onPressed: widget.isHost
                        ? () => _sendControl('pause')
                        : null,
                  ),
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
