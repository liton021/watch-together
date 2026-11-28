import 'dart:collection';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import 'home_screen.dart';
import 'watch_together/room_service.dart';

const Color _background = Color(0xFF0B0E14);
const Color _panel = Color(0xFF12161F);
const Color _field = Color(0xFF1B2130);
const Color _line = Color(0xFF252C3B);
const Color _accent = Color(0xFF8B9DFF);

/// Known ad / tracking hosts. Requests to these are dropped while the
/// blocker is on. This is deliberately a small, conservative list.
const List<String> _adHosts = <String>[
  'doubleclick.net',
  'googlesyndication.com',
  'googleadservices.com',
  'adservice.google',
  'admob.com',
  'adnxs.com',
  'amazon-adsystem.com',
  'adform.net',
  'criteo.com',
  'taboola.com',
  'outbrain.com',
  'pubmatic.com',
  'rubiconproject.com',
  'openx.net',
  'adcolony.com',
  'chartbeat.net',
  'scorecardresearch.com',
  'quantserve.com',
  'connect.facebook.net',
  'smartadserver.com',
  'yieldmo.com',
  'sovrn.com',
  'ads-twitter.com',
  'doubleverify.net',
  // Popunder / redirect networks that movie sites commonly use.
  'popads.net',
  'popcash.net',
  'propellerads.com',
  'propellerclick.com',
  'onclickads.net',
  'onclickalgo.com',
  'adsterra.com',
  'exoclick.com',
  'exosrv.com',
  'juicyads.com',
  'trafficjunky.net',
  'hilltopads.net',
  'clickadu.com',
  'adcash.com',
  'mgid.com',
  'zedo.com',
  'bidvertiser.com',
  'revcontent.com',
  'popmyads.com',
  // Analytics and session recording endpoints that profile taps/clicks.
  'google-analytics.com',
  'analytics.google.com',
  'googletagmanager.com',
  'hotjar.com',
  'clarity.ms',
  'mixpanel.com',
  'segment.io',
  'amplitude.com',
  'fullstory.com',
  'mouseflow.com',
  'smartlook.com',
  'luckyorange.com',
];

/// Injected at document start: hides ad-like elements, keeps `target="_blank"`
/// links inside this WebView, and routes `window.open` through Flutter.
///
/// Movie sites usually reach the player with a popup link. Android drops
/// those when multiple windows are off, so `window.open` is sent to Flutter
/// (`wtOpenUrl`) and loaded in the same page after the ad check. Flutter
/// syncs the on/off state by calling `window.__wtApplyAds()`.
const String _adBlockerScript = r'''
(function () {
  window.__wtAdsEnabled = true;
  window.__wtOriginalOpen = window.open;

  function absolute(url) {
    try {
      return new URL(String(url), location.href).href;
    } catch (_) {
      return String(url);
    }
  }

  function hostOf(url) {
    try {
      return new URL(String(url), location.href).host;
    } catch (_) {
      return '';
    }
  }

  // A popup may only stay in this app when it points at the same site or at
  // the link the user just tapped. Everything else is an ad/popunder.
  function mayOpen(host) {
    if (!host) { return false; }
    if (host === location.host) { return true; }
    var tap = window.__wtLastTap;
    if (!tap || Date.now() - tap.at > 3000) { return false; }
    if (tap.host && tap.host === host) { return true; }
    // A real button (play/server) may legitimately open an external player.
    if (!tap.href && tap.control) { return true; }
    return false;
  }

  function stubWindow() {
    var stub = {
      closed: false,
      focus: function () {},
      close: function () {},
      document: { write: function () {}, close: function () {} }
    };
    Object.defineProperty(stub, 'location', {
      get: function () { return location.href; },
      set: function (value) { openHere(value && value.href ? value.href : value); }
    });
    return stub;
  }

  function openHere(url) {
    if (!url) { return; }
    var target = absolute(url);
    if (!mayOpen(hostOf(target))) {
      try {
        window.flutter_inappwebview.callHandler('wtBlockedPopup', target);
      } catch (_) {}
      return;
    }
    try {
      window.flutter_inappwebview.callHandler('wtOpenUrl', target);
    } catch (_) {
      try { location.href = target; } catch (__) {}
    }
  }

  window.__wtOpenSamePage = function (url) {
    if (url) { openHere(url); }
    // Some sites keep using the returned window, so hand back a harmless
    // stand-in instead of null.
    return stubWindow();
  };

  function keepInThisTab(el) {
    if (!el || !el.getAttribute) { return; }
    var target = el.getAttribute('target');
    if (target === '_blank' || target === '_new') {
      el.setAttribute('target', '_self');
    }
  }

  function fixTargets() {
    var nodes = document.querySelectorAll(
      'a[target="_blank"], a[target="_new"], form[target="_blank"]'
    );
    for (var i = 0; i < nodes.length; i++) {
      nodes[i].setAttribute('target', '_self');
    }
  }

  function closestAnchor(el) {
    while (el && el !== document) {
      if (el.tagName === 'A' && el.getAttribute) { return el; }
      el = el.parentElement;
    }
    return null;
  }

  function hrefOf(a) {
    if (!a || !a.getAttribute) { return ''; }
    if (a.hasAttribute('download')) { return ''; }
    var raw = a.getAttribute('href') || '';
    if (!raw || raw.charAt(0) === '#') { return ''; }
    if (/^(javascript|mailto|tel|blob|data):/i.test(raw)) { return ''; }
    try {
      var url = new URL(raw, location.href);
      return /^https?:$/i.test(url.protocol) ? url.href : '';
    } catch (_) {
      return '';
    }
  }

  function isControl(el) {
    while (el && el !== document) {
      var tag = (el.tagName || '').toUpperCase();
      if (tag === 'BUTTON' || tag === 'INPUT' || tag === 'SELECT' ||
          tag === 'TEXTAREA' || tag === 'VIDEO' || tag === 'AUDIO') {
        return true;
      }
      var role = el.getAttribute ? el.getAttribute('role') : null;
      if (role === 'button' || role === 'tab' || role === 'switch') {
        return true;
      }
      el = el.parentElement;
    }
    return false;
  }

  // Records the link the user is aiming at. If a transparent ad overlay sits
  // on top of a poster, look through it for the real <a> underneath.
  function recordTap(event) {
    if (event.button !== undefined && event.button !== 0) { return ''; }
    // An anchor without a usable href is still an intentional link tap.
    var control = isControl(event.target) || !!closestAnchor(event.target);
    var a = closestAnchor(event.target);
    if (!a && !control && event.clientX != null &&
        document.elementsFromPoint) {
      var stack = document.elementsFromPoint(event.clientX, event.clientY) || [];
      for (var i = 0; i < stack.length; i++) {
        a = closestAnchor(stack[i]);
        if (a) { break; }
      }
    }
    var href = hrefOf(a);
    window.__wtLastTap = {
      href: href,
      host: href ? hostOf(href) : '',
      control: control,
      at: Date.now()
    };
    return href;
  }

  window.__wtApplyAds = function () {
    var on = window.__wtAdsEnabled !== false;
    var style = document.getElementById('__wt_adblocker_style');
    if (style) {
      style.disabled = !on;
    }
    window.open = on ? window.__wtOpenSamePage : window.__wtOriginalOpen;
  };

  var style = document.createElement('style');
  style.id = '__wt_adblocker_style';
  style.textContent = [
    'ins.adsbygoogle,',
    'iframe[src*="doubleclick" i],',
    'iframe[src*="googlesyndication" i],',
    'iframe[src*="adservice.google" i],',
    '[class~="advertisement"],',
    '[class~="advert"],',
    '[class~="ad"],',
    '[id="ad"],',
    '[id^="ad-"],',
    '[id^="ads-"],',
    '[class*="ad-banner" i],',
    '[id*="ad-banner" i],',
    '[class*="ad-container" i],',
    '[id*="ad-container" i],',
    '[class*="advert" i],',
    '[id*="advert" i],',
    '[class*="sponsor" i],',
    '[id*="sponsor" i],',
    '[data-ad-slot],',
    '[data-ad-client],',
    '[aria-label*="advertisement" i]',
    '{ display: none !important; }'
  ].join('\n');

  (document.head || document.documentElement).appendChild(style);
  window.__wtApplyAds();
  fixTargets();
  setInterval(fixTargets, 1500);

  window.addEventListener('pointerdown', function (event) {
    if (window.__wtAdsEnabled === false) { return; }
    recordTap(event);
  }, true);

  window.addEventListener('click', function (event) {
    if (window.__wtAdsEnabled === false) { return; }
    if (event.button !== 0 || event.metaKey || event.ctrlKey ||
        event.shiftKey || event.altKey) {
      return;
    }
    var href = recordTap(event);
    if (!href) { return; }
    // A real link was clicked. Follow it directly and stop the site's tap
    // tracking listeners from redirecting the click to an ad.
    event.stopImmediatePropagation();
    event.preventDefault();
    try { location.assign(href); } catch (_) {}
  }, true);

  document.addEventListener('click', function (event) {
    var el = event.target;
    while (el && el !== document) {
      keepInThisTab(el);
      el = el.parentElement;
    }
  }, true);
})();
''';

/// Watches the host's <video> element so play/pause/seek can be broadcast.
const String _videoHookScript = r'''
(function () {
  function hook(v) {
    if (!v || v.__wtHooked) { return; }
    v.__wtHooked = true;
    v.__wtIndex = Array.prototype.indexOf.call(
      document.querySelectorAll('video'), v
    );
    ['play', 'pause', 'seeked'].forEach(function (event) {
      v.addEventListener(event, function () {
        try {
          window.flutter_inappwebview.callHandler('wtVideoEvent', {
            event: event,
            position: v.currentTime,
            kind: 'video',
            index: v.__wtIndex,
            url: location.href
          });
        } catch (_) {}
      });
    });
  }
  setInterval(function () {
    document.querySelectorAll('video').forEach(hook);
  }, 500);
})();
''';

bool isAdUri(WebUri? uri) {
  if (uri == null) return false;
  final host = uri.host.toLowerCase();
  for (final adHost in _adHosts) {
    if (host.contains(adHost)) return true;
  }
  return false;
}

const String _homePageHtml = r'''
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Watch Together</title>
<style>
  :root { color-scheme: dark; }
  * { box-sizing: border-box; }
  body {
    margin: 0;
    min-height: 100vh;
    display: flex;
    align-items: center;
    justify-content: center;
    padding: 32px 20px;
    font-family: "Segoe UI", system-ui, -apple-system, Roboto, sans-serif;
    color: #e8eaf2;
    background: radial-gradient(circle at 15% 10%, #1d2745 0%, #0b0e14 52%, #06070b 100%);
  }
  .card { width: 100%; max-width: 560px; text-align: center; }
  .logo { font-size: 44px; margin-bottom: 12px; }
  h1 {
    margin: 0 0 10px;
    font-size: 30px;
    letter-spacing: -0.5px;
    background: linear-gradient(90deg, #8b9dff, #e879f9);
    -webkit-background-clip: text;
    background-clip: text;
    color: transparent;
  }
  p { margin: 0 0 26px; color: #98a1b3; font-size: 15px; line-height: 1.65; }
  .links { display: flex; flex-wrap: wrap; gap: 10px; justify-content: center; }
  a {
    color: #dbe3ff;
    text-decoration: none;
    font-size: 14px;
    padding: 10px 16px;
    border-radius: 999px;
    background: rgba(255, 255, 255, 0.06);
    border: 1px solid rgba(255, 255, 255, 0.1);
  }
  a:hover { background: rgba(255, 255, 255, 0.12); }
  .tip { margin-top: 26px; font-size: 12px; color: #5f687a; }
</style>
</head>
<body>
  <div class="card">
    <div class="logo">🎬</div>
    <h1>Watch Together Browser</h1>
    <p>Type any website in the address bar above and press Enter.<br>
       Back, forward, home and bookmarks are ready when you are.</p>
    <div class="links">
      <a href="https://www.youtube.com">YouTube</a>
      <a href="https://www.wikipedia.org">Wikipedia</a>
      <a href="https://www.google.com">Google</a>
      <a href="https://www.netflix.com">Netflix</a>
    </div>
    <div class="tip">Ad blocker is on by default — tap the shield in the bar to toggle it.</div>
  </div>
</body>
</html>
''';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await RoomService.instance.initialize();
  runApp(const WatchTogetherApp());
}

class WatchTogetherApp extends StatelessWidget {
  const WatchTogetherApp({super.key});

  @override
  Widget build(BuildContext context) {
    final colorScheme = ColorScheme.fromSeed(
      seedColor: _accent,
      brightness: Brightness.dark,
    ).copyWith(surface: _background);

    return MaterialApp(
      title: 'Watch Together',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: colorScheme,
        scaffoldBackgroundColor: _background,
        snackBarTheme: const SnackBarThemeData(
          behavior: SnackBarBehavior.floating,
          backgroundColor: Color(0xFF232A3A),
        ),
      ),
      home: const HomeScreen(),
    );
  }
}

/// Turns whatever the user typed into a URL.
///
/// - `https://example.com` is kept as-is
/// - `example.com` becomes `https://example.com`
/// - anything else becomes a Google search
String normalizeUrl(String input) {
  final text = input.trim();
  if (text.isEmpty) return '';

  final lower = text.toLowerCase();
  if (lower.startsWith('http://') || lower.startsWith('https://')) {
    return text;
  }

  // Keep explicit schemes such as file://, about:, chrome:// untouched.
  if (RegExp(r'^[a-z][a-z0-9+.-]*://').hasMatch(lower)) {
    return text;
  }

  final host = text.split('/').first;
  final looksLikeHost =
      !text.contains(' ') &&
      (host.contains('.') ||
          host == 'localhost' ||
          host.startsWith('localhost:') ||
          host.contains(':'));
  if (looksLikeHost) {
    return 'https://$text';
  }

  return 'https://www.google.com/search?q=${Uri.encodeQueryComponent(text)}';
}

class _Bookmark {
  const _Bookmark(this.label, this.url);

  final String label;
  final String url;
}

class BrowserScreen extends StatefulWidget {
  const BrowserScreen({super.key, this.roomCode});

  final String? roomCode;

  @override
  State<BrowserScreen> createState() => _BrowserScreenState();
}

class _BrowserScreenState extends State<BrowserScreen> {
  InAppWebViewController? _controller;

  final TextEditingController _addressController = TextEditingController();
  final FocusNode _addressFocus = FocusNode();

  bool _isLoading = false;
  int _progress = 0;
  bool _canGoBack = false;
  bool _canGoForward = false;
  String _currentUrl = '';
  bool _adBlockerEnabled = true;
  int _blockedCount = 0;
  String? _pendingUrl;

  final List<_Bookmark> _bookmarks = <_Bookmark>[
    const _Bookmark('YouTube', 'https://www.youtube.com'),
    const _Bookmark('Wikipedia', 'https://www.wikipedia.org'),
    const _Bookmark('Google', 'https://www.google.com'),
    const _Bookmark('Netflix', 'https://www.netflix.com'),
  ];

  @override
  void initState() {
    super.initState();
    _addressFocus.addListener(_handleAddressFocus);
  }

  @override
  void dispose() {
    _addressFocus.removeListener(_handleAddressFocus);
    _addressFocus.dispose();
    _addressController.dispose();
    super.dispose();
  }

  void _handleAddressFocus() {
    if (_addressFocus.hasFocus) {
      _addressController.selection = TextSelection(
        baseOffset: 0,
        extentOffset: _addressController.text.length,
      );
    } else {
      _addressController.text = _currentUrl;
    }
  }

  bool _isWebUrl(String url) =>
      url.startsWith('http://') || url.startsWith('https://');

  void _applyUrl(WebUri? uri) {
    final raw = uri?.toString() ?? '';
    if (raw.isEmpty) return;

    _currentUrl = _isWebUrl(raw) ? raw : '';
    if (!_addressFocus.hasFocus) {
      _addressController.text = _currentUrl;
    }
  }

  Future<void> _syncNavigationState() async {
    final controller = _controller;
    if (controller == null) return;

    try {
      final canGoBack = await controller.canGoBack();
      final canGoForward = await controller.canGoForward();
      final url = await controller.getUrl();
      if (!mounted) return;

      setState(() {
        _canGoBack = canGoBack;
        _canGoForward = canGoForward;
        _applyUrl(url);
      });
    } catch (_) {
      // Some platforms (web iframes in particular) restrict history access.
    }
  }

  Future<void> _openUrl(String raw) async {
    final target = normalizeUrl(raw);
    if (target.isEmpty) {
      _showMessage('Type a website or search first.');
      return;
    }
    final controller = _controller;
    if (controller == null) {
      // Keep the address ready; it will load as soon as the WebView is created.
      _pendingUrl = target;
      _showMessage('Browser is still starting — opening $target shortly.');
      return;
    }

    _pendingUrl = target;
    _addressFocus.unfocus();
    setState(() {
      _isLoading = true;
      _progress = 0;
      // Show the destination immediately. On Android the WebView will report
      // the final URL once the page starts loading; on the web preview the
      // cross-origin iframe cannot report it back to us.
      _currentUrl = target;
      if (!_addressFocus.hasFocus) {
        _addressController.text = target;
      }
    });

    try {
      await controller.loadUrl(urlRequest: URLRequest(url: WebUri(target)));
    } catch (error) {
      if (mounted) _showMessage('Could not open this link: $error');
      return;
    }

    if (kIsWeb && mounted) {
      // The web build uses an iframe, and cross-origin pages do not report
      // load completion. Don't leave the toolbar stuck in a loading state.
      setState(() {
        _isLoading = false;
        _progress = 100;
      });
    }
  }

  Future<void> _goHome() async {
    final controller = _controller;
    if (controller == null) return;

    _addressFocus.unfocus();
    setState(() {
      _currentUrl = '';
      _pendingUrl = null;
      _addressController.text = '';
      _isLoading = true;
      _progress = 0;
    });

    await controller.loadData(data: _homePageHtml, mimeType: 'text/html');

    if (kIsWeb && mounted) {
      setState(() {
        _isLoading = false;
        _progress = 100;
      });
    }
  }

  Future<void> _goBack() async {
    final controller = _controller;
    if (controller == null) return;
    if (await controller.canGoBack()) {
      await controller.goBack();
    }
  }

  Future<void> _goForward() async {
    final controller = _controller;
    if (controller == null) return;
    if (await controller.canGoForward()) {
      await controller.goForward();
    }
  }

  Future<void> _reloadOrStop() async {
    final controller = _controller;
    if (controller == null) return;

    if (_isLoading) {
      await controller.stopLoading();
      if (mounted) {
        setState(() {
          _isLoading = false;
          _progress = 0;
        });
      }
    } else {
      await controller.reload();
    }
  }

  Future<void> _bookmarkCurrentPage() async {
    final controller = _controller;
    if (controller == null) return;

    final uri = await controller.getUrl();
    final current = uri?.toString() ?? '';
    if (current.isEmpty || !_isWebUrl(current)) {
      _showMessage('Open a website first, then bookmark it.');
      return;
    }

    if (_bookmarks.any((bookmark) => bookmark.url == current)) {
      _showMessage('This page is already bookmarked.');
      return;
    }

    final title = (await controller.getTitle())?.trim() ?? '';
    final label = _shorten(title.isEmpty ? (uri?.host ?? 'Bookmark') : title);
    if (!mounted) return;

    setState(() {
      _bookmarks.add(_Bookmark(label, current));
    });
    _showMessage('Bookmarked "$label".');
  }

  void _removeBookmark(_Bookmark bookmark) {
    final index = _bookmarks.indexOf(bookmark);
    if (index < 0) return;

    setState(() => _bookmarks.removeAt(index));

    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text('Removed "${bookmark.label}".'),
          action: SnackBarAction(
            label: 'Undo',
            onPressed: () {
              if (!mounted) return;
              final insertAt = index <= _bookmarks.length
                  ? index
                  : _bookmarks.length;
              setState(() => _bookmarks.insert(insertAt, bookmark));
            },
          ),
        ),
      );
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text(message), duration: const Duration(seconds: 4)),
      );
  }

  /// Pushes the current on/off state into the already-loaded page.
  Future<void> _syncAdBlockerToPage() async {
    final controller = _controller;
    if (controller == null) return;
    try {
      await controller.evaluateJavascript(
        source:
            'if (window.__wtApplyAds) { '
            'window.__wtAdsEnabled = $_adBlockerEnabled; '
            'window.__wtApplyAds(); }',
      );
    } catch (_) {
      // Cross-origin iframes on the web preview cannot be scripted.
    }
  }

  Future<void> _toggleAdBlocker() async {
    setState(() => _adBlockerEnabled = !_adBlockerEnabled);
    _showMessage(_adBlockerEnabled ? 'Ad blocker on.' : 'Ad blocker off.');
    await _syncAdBlockerToPage();
  }

  bool get _isHosting =>
      RoomService.instance.isHost && RoomService.instance.code != null;

  Future<void> _openWatchEntry() async {
    await Navigator.of(
      context,
    ).push(MaterialPageRoute<void>(builder: (_) => const HomeScreen()));
    if (mounted) setState(() {});
  }

  /// User scripts are injected at document start on mobile. Web previews use
  /// an iframe that ignores them, so inject again after the page loads.
  Future<void> _injectVideoScripts() async {
    final controller = _controller;
    if (controller == null) return;
    try {
      await controller.evaluateJavascript(source: _videoHookScript);
    } catch (_) {
      // Cross-origin pages cannot be scripted from the web preview.
    }
  }

  /// Loads a URL that the page tried to open in a new window. Movie sites
  /// reach the player through `window.open`, which Android WebView drops when
  /// multiple windows are off. Known ad hosts are still filtered out.
  Future<void> _openPageFromScript(String raw) async {
    final controller = _controller;
    if (controller == null) return;

    var target = raw;
    if (!_isWebUrl(target)) {
      try {
        target = Uri.parse(_currentUrl).resolve(target).toString();
      } catch (_) {
        return;
      }
    }

    final WebUri uri;
    try {
      uri = WebUri(target);
    } catch (_) {
      return;
    }

    if (_adBlockerEnabled && isAdUri(uri)) {
      if (mounted) setState(() => _blockedCount++);
      return;
    }

    try {
      await controller.loadUrl(urlRequest: URLRequest(url: uri));
    } catch (_) {
      // Ignore malformed popup URLs.
    }
  }

  Future<void> _sendFrameToRoom({
    required String kind,
    required String url,
    int index = 0,
    double position = 0,
  }) async {
    await RoomService.instance.send('playback', <String, dynamic>{
      'kind': kind,
      'url': url,
      'index': index,
      'position': position,
      'event': 'play',
      'at': DateTime.now().toIso8601String(),
    });
    _showMessage('Sent to room ${RoomService.instance.code}.');
  }

  /// The top-right button is a trigger: send the current page itself to the
  /// room. Every viewer keeps only the player part of that page and hides the
  /// rest with injected CSS/JS.
  Future<void> _shareVideoFrame() async {
    if (!_isHosting) {
      _showMessage('Create or join a room first.');
      return;
    }
    final controller = _controller;
    if (controller == null) {
      _showMessage('Browser is not ready yet.');
      return;
    }

    // Always give immediate feedback, even if reading the URL takes a moment
    // or a site dialog is in the way.
    _showMessage('Sending this page to the room…');

    try {
      final actualUri = await controller.getUrl();
      final actual = actualUri?.toString() ?? '';
      final pageUrl = _isWebUrl(actual) ? actual : _currentUrl;

      if (pageUrl.isEmpty || !_isWebUrl(pageUrl)) {
        _showMessage('Open a website first, then press the cast button.');
        return;
      }

      await _sendFrameToRoom(kind: 'video', url: pageUrl);
    } catch (error) {
      _showMessage('Could not share this page: $error');
    }
  }

  /// Drops requests to known ad hosts. Returning null lets them through.
  Future<WebResourceResponse?> _handleAdRequest(
    InAppWebViewController controller,
    WebResourceRequest request,
  ) async {
    // Never replace the main document — that would look like a broken browser.
    if (request.isForMainFrame ?? false) return null;
    if (_adBlockerEnabled && isAdUri(request.url)) {
      _blockedCount++;
      return WebResourceResponse(
        contentType: 'text/plain',
        contentEncoding: 'utf-8',
        data: Uint8List(0),
      );
    }
    return null;
  }

  /// Reads the link recorded by the page's last tap, if it is still fresh.
  Future<Map<String, dynamic>?> _recentTap() async {
    final controller = _controller;
    if (controller == null) return null;
    try {
      final raw = await controller.evaluateJavascript(
        source:
            'window.__wtLastTap ? JSON.stringify(window.__wtLastTap) : null',
      );
      if (raw is! String || raw.isEmpty || raw == 'null') return null;
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      final at = decoded['at'];
      if (at is! num) return null;
      final age = DateTime.now().millisecondsSinceEpoch - at.toInt();
      if (age < 0 || age > 3000) return null;
      return Map<String, dynamic>.from(decoded);
    } catch (_) {
      return null;
    }
  }

  Future<void> _clearTap() async {
    final controller = _controller;
    if (controller == null) return;
    try {
      await controller.evaluateJavascript(source: 'window.__wtLastTap = null');
    } catch (_) {
      // The page may already be navigating away.
    }
  }

  /// Blocks known ad hosts and tap-hijack redirects: a click on a poster may
  /// only go to that poster's own link or stay on the current site.
  Future<NavigationActionPolicy?> _handleAdNavigation(
    InAppWebViewController controller,
    NavigationAction action,
  ) async {
    final uri = action.request.url;
    if (uri == null) return NavigationActionPolicy.ALLOW;

    if (_adBlockerEnabled && isAdUri(uri)) {
      if (mounted) setState(() => _blockedCount++);
      return NavigationActionPolicy.CANCEL;
    }

    if (!_adBlockerEnabled || !action.isForMainFrame || uri.host.isEmpty) {
      return NavigationActionPolicy.ALLOW;
    }

    String currentHost = '';
    try {
      currentHost = WebUri(_currentUrl).host;
    } catch (_) {
      currentHost = '';
    }
    if (currentHost.isEmpty || uri.host == currentHost) {
      // A normal in-site link. Consume the tap so a later redirect is not
      // mistaken for a hijacked click.
      _clearTap();
      return NavigationActionPolicy.ALLOW;
    }

    final tap = await _recentTap();
    if (tap == null) return NavigationActionPolicy.ALLOW;

    _clearTap();

    final tapHref = tap['href']?.toString() ?? '';
    final tapHost = tap['host']?.toString() ?? '';
    final tapControl = tap['control'] == true;
    if (tapHref.isEmpty) {
      if (tapControl) {
        // A real button (for example a player or server button). Let the
        // site navigate; blocking here would break external players.
        return NavigationActionPolicy.ALLOW;
      }
      // A touch on plain page content tried to leave the site: hijack.
      if (mounted) setState(() => _blockedCount++);
      return NavigationActionPolicy.CANCEL;
    }
    if (tapHost.isNotEmpty && tapHost == uri.host) {
      // This is exactly the link the user clicked.
      return NavigationActionPolicy.ALLOW;
    }

    // The click tried to leave the site for an unrelated host.
    if (mounted) setState(() => _blockedCount++);
    if (tapHref.isNotEmpty && tapHref != uri.toString()) {
      final target = tapHref;
      Future<void>.delayed(
        const Duration(milliseconds: 150),
        () => _openPageFromScript(target),
      );
    }
    return NavigationActionPolicy.CANCEL;
  }

  static String _shorten(String text, [int max = 24]) {
    if (text.runes.length <= max) return text;
    return '${String.fromCharCodes(text.runes.take(max))}…';
  }

  static String _initial(String label) {
    final trimmed = label.trim();
    if (trimmed.isEmpty) return '?';
    return String.fromCharCodes(trimmed.runes.take(1)).toUpperCase();
  }

  Widget _toolbarButton({
    required IconData icon,
    required String tooltip,
    VoidCallback? onPressed,
  }) {
    return IconButton(
      onPressed: onPressed,
      icon: Icon(icon, size: 20),
      tooltip: tooltip,
      visualDensity: VisualDensity.compact,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
      color: Colors.white,
      disabledColor: Colors.white24,
    );
  }

  Widget _buildToolbar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(6, 8, 8, 6),
      child: Row(
        children: [
          _toolbarButton(
            icon: Icons.arrow_back_rounded,
            tooltip: 'Back',
            onPressed: _canGoBack ? _goBack : null,
          ),
          _toolbarButton(
            icon: Icons.arrow_forward_rounded,
            tooltip: 'Forward',
            onPressed: _canGoForward ? _goForward : null,
          ),
          _toolbarButton(
            icon: Icons.home_rounded,
            tooltip: 'Home',
            onPressed: _goHome,
          ),
          _toolbarButton(
            icon: _isLoading ? Icons.close_rounded : Icons.refresh_rounded,
            tooltip: _isLoading ? 'Stop loading' : 'Reload',
            onPressed: _reloadOrStop,
          ),
          const SizedBox(width: 4),
          Expanded(
            child: TextField(
              controller: _addressController,
              focusNode: _addressFocus,
              keyboardType: TextInputType.url,
              textInputAction: TextInputAction.go,
              autocorrect: false,
              enableSuggestions: false,
              style: const TextStyle(fontSize: 13.5, color: Colors.white),
              onSubmitted: _openUrl,
              decoration: InputDecoration(
                isDense: true,
                hintText: 'Search or enter website',
                hintStyle: const TextStyle(fontSize: 13, color: Colors.white38),
                prefixIcon: Icon(
                  _currentUrl.startsWith('https://')
                      ? Icons.lock_outline_rounded
                      : (_currentUrl.startsWith('http://')
                            ? Icons.language_rounded
                            : Icons.search_rounded),
                  size: 16,
                  color: Colors.white38,
                ),
                prefixIconConstraints: const BoxConstraints(
                  minWidth: 34,
                  minHeight: 34,
                ),
                contentPadding: const EdgeInsets.symmetric(
                  vertical: 10,
                  horizontal: 8,
                ),
                filled: true,
                fillColor: _field,
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(20),
                  borderSide: const BorderSide(color: _line),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(20),
                  borderSide: BorderSide(color: _accent.withValues(alpha: 0.8)),
                ),
              ),
            ),
          ),
          const SizedBox(width: 2),
          _toolbarButton(
            icon: Icons.cast_rounded,
            tooltip: 'Send this page to the room',
            onPressed: _shareVideoFrame,
          ),
        ],
      ),
    );
  }

  Widget _buildProgressBar() {
    return SizedBox(
      height: 2,
      child: _isLoading
          ? LinearProgressIndicator(
              value: _progress > 0 && _progress < 100 ? _progress / 100 : null,
              minHeight: 2,
              backgroundColor: Colors.transparent,
              color: _accent,
            )
          : null,
    );
  }

  Widget _buildSimpleChip({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) {
    return Tooltip(
      message: label,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(9),
          child: Container(
            height: 30,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.05),
              borderRadius: BorderRadius.circular(9),
              border: Border.all(color: Colors.white12),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 15, color: Colors.white54),
                const SizedBox(width: 5),
                Text(
                  label,
                  style: const TextStyle(fontSize: 12, color: Colors.white70),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildAdBlockChip() {
    final on = _adBlockerEnabled;
    return Tooltip(
      message: on
          ? 'Ad blocker on — $_blockedCount blocked — tap to turn off'
          : 'Ad blocker off — tap to turn on',
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: _toggleAdBlocker,
          borderRadius: BorderRadius.circular(9),
          child: Container(
            height: 30,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            decoration: BoxDecoration(
              color: on
                  ? _accent.withValues(alpha: 0.14)
                  : Colors.white.withValues(alpha: 0.05),
              borderRadius: BorderRadius.circular(9),
              border: Border.all(
                color: on ? _accent.withValues(alpha: 0.45) : Colors.white12,
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.shield_rounded,
                  size: 15,
                  color: on ? _accent : Colors.white54,
                ),
                const SizedBox(width: 5),
                Text(
                  on ? 'Ads: blocked' : 'Ads: allowed',
                  style: TextStyle(
                    fontSize: 12,
                    color: on ? _accent : Colors.white54,
                  ),
                ),
                if (_blockedCount > 0) ...[
                  const SizedBox(width: 5),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 5,
                      vertical: 1,
                    ),
                    decoration: BoxDecoration(
                      color: on
                          ? _accent.withValues(alpha: 0.22)
                          : Colors.white12,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      '$_blockedCount',
                      style: TextStyle(
                        fontSize: 10,
                        color: on ? _accent : Colors.white70,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildBookmarkBar() {
    return SizedBox(
      height: 42,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(10, 6, 10, 6),
        children: [
          if (widget.roomCode != null) ...[
            _buildSimpleChip(
              icon: Icons.arrow_back_rounded,
              label: 'Back to room',
              onTap: () => Navigator.of(context).pop(),
            ),
            const SizedBox(width: 8),
          ],
          _buildAdBlockChip(),
          const SizedBox(width: 8),
          _buildSimpleChip(
            icon: Icons.groups_rounded,
            label: _isHosting ? 'Room ${RoomService.instance.code}' : 'Watch',
            onTap: _openWatchEntry,
          ),
          const SizedBox(width: 8),
          if (_isHosting) ...[
            _buildSimpleChip(
              icon: Icons.cast_rounded,
              label: 'Share',
              onTap: _shareVideoFrame,
            ),
            const SizedBox(width: 8),
          ],
          for (final bookmark in _bookmarks) ...[
            _BookmarkChip(
              bookmark: bookmark,
              onTap: () => _openUrl(bookmark.url),
              onLongPress: () => _removeBookmark(bookmark),
            ),
            const SizedBox(width: 8),
          ],
          _AddBookmarkChip(onTap: _bookmarkCurrentPage),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_canGoBack,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop && _canGoBack) {
          _goBack();
        }
      },
      child: Scaffold(
        body: SafeArea(
          bottom: false,
          child: Column(
            children: [
              Container(
                decoration: const BoxDecoration(
                  color: _panel,
                  border: Border(bottom: BorderSide(color: _line)),
                ),
                child: Column(
                  children: [
                    _buildToolbar(),
                    _buildProgressBar(),
                    _buildBookmarkBar(),
                  ],
                ),
              ),
              Expanded(
                child: InAppWebView(
                  initialData: InAppWebViewInitialData(data: _homePageHtml),
                  initialUserScripts: UnmodifiableListView<UserScript>(<
                    UserScript
                  >[
                    UserScript(
                      source: _adBlockerScript,
                      injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
                    ),
                    UserScript(
                      source: _videoHookScript,
                      injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
                    ),
                  ]),
                  initialSettings: InAppWebViewSettings(
                    javaScriptEnabled: true,
                    supportMultipleWindows: false,
                    mediaPlaybackRequiresUserGesture: false,
                    allowsInlineMediaPlayback: true,
                    supportZoom: true,
                    iframeAllow:
                        'autoplay; encrypted-media; fullscreen; picture-in-picture; clipboard-read; clipboard-write',
                    iframeAllowFullscreen: true,
                  ),
                  onWebViewCreated: (controller) {
                    _controller = controller;
                    // JS handlers are supported on mobile WebViews only;
                    // the web preview uses an iframe without that API.
                    if (!kIsWeb) {
                      controller.addJavaScriptHandler(
                        handlerName: 'wtVideoEvent',
                        callback: (arguments) {
                          if (!RoomService.instance.isHost) return;
                          final data = arguments.isNotEmpty
                              ? arguments.first
                              : null;
                          if (data is! Map) return;
                          RoomService.instance
                              .send('playback', <String, dynamic>{
                                'kind': data['kind']?.toString() ?? 'video',
                                'url': data['url']?.toString() ?? _currentUrl,
                                'index': data['index'] ?? 0,
                                'event': data['event']?.toString() ?? 'play',
                                'position': data['position'],
                                'at': DateTime.now().toIso8601String(),
                              });
                        },
                      );

                      // Movie sites open the player in a new window. Load
                      // that link in this WebView instead of losing it.
                      controller.addJavaScriptHandler(
                        handlerName: 'wtOpenUrl',
                        callback: (arguments) {
                          final raw = arguments.isNotEmpty
                              ? arguments.first?.toString()
                              : null;
                          if (raw != null && raw.isNotEmpty) {
                            _openPageFromScript(raw);
                          }
                          return null;
                        },
                      );

                      // A popup to an unrelated host was stopped in JS.
                      controller.addJavaScriptHandler(
                        handlerName: 'wtBlockedPopup',
                        callback: (arguments) {
                          if (mounted) setState(() => _blockedCount++);
                          return null;
                        },
                      );
                    }

                    final pending = _pendingUrl;
                    if (pending != null) {
                      _pendingUrl = null;
                      controller.loadUrl(
                        urlRequest: URLRequest(url: WebUri(pending)),
                      );
                    }
                  },
                  onLoadStart: (controller, url) {
                    if (!mounted) return;
                    setState(() {
                      _isLoading = true;
                      _progress = 0;
                      _applyUrl(url);
                    });
                  },
                  onLoadStop: (controller, url) {
                    if (!mounted) return;
                    setState(() {
                      _isLoading = false;
                      _progress = 100;
                    });
                    _syncNavigationState();
                    _syncAdBlockerToPage();
                    _injectVideoScripts();
                  },
                  // A confirm() means the site is asking permission, so the
                  // next navigation is intentional rather than a hijacked tap.
                  onJsConfirm: (controller, request) async {
                    _clearTap();
                    return JsConfirmResponse(handledByClient: false);
                  },
                  onProgressChanged: (controller, progress) {
                    if (!mounted) return;
                    setState(() => _progress = progress);
                  },
                  onReceivedError: (controller, request, error) {
                    if (!mounted) return;
                    if (request.isForMainFrame ?? false) {
                      setState(() {
                        _isLoading = false;
                        _progress = 0;
                      });
                      _showMessage('Could not load this page.');
                    }
                  },
                  shouldInterceptRequest: _handleAdRequest,
                  shouldOverrideUrlLoading: _handleAdNavigation,
                  onUpdateVisitedHistory: (controller, url, isReload) {
                    _syncNavigationState();
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _BookmarkChip extends StatelessWidget {
  const _BookmarkChip({
    required this.bookmark,
    required this.onTap,
    required this.onLongPress,
  });

  final _Bookmark bookmark;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: '${bookmark.url}\nLong-press to remove',
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          onLongPress: onLongPress,
          borderRadius: BorderRadius.circular(9),
          child: Container(
            height: 30,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.05),
              borderRadius: BorderRadius.circular(9),
              border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 16,
                  height: 16,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: _accent.withValues(alpha: 0.18),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    _BrowserScreenState._initial(bookmark.label),
                    style: const TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                      color: _accent,
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  bookmark.label,
                  style: const TextStyle(fontSize: 12, color: Colors.white70),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _AddBookmarkChip extends StatelessWidget {
  const _AddBookmarkChip({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: 'Bookmark this page',
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(9),
          child: Container(
            height: 30,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(9),
              border: Border.all(color: Colors.white12),
            ),
            child: const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.add_rounded, size: 15, color: Colors.white54),
                SizedBox(width: 4),
                Text(
                  'Bookmark',
                  style: TextStyle(fontSize: 12, color: Colors.white54),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
