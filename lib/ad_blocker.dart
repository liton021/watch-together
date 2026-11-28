import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import 'ad_blocklist.dart';

export 'ad_blocklist.dart';

/// True for ad, popunder and tracking URLs. Uses the full generated list and
/// recognises the shape of obfuscated redirect chains (many `*` separators
/// plus an `md=` payload).
bool isAdUri(WebUri? uri) {
  if (uri == null) return false;
  if (isBlockedAdHost(uri.host)) return true;
  return isTrackerUri(uri);
}

/// Some networks hide the real destination in a long, delimiter-filled path
/// and a base64 `md=` query parameter. Those links are never a real site.
bool isTrackerUri(WebUri? uri) {
  if (uri == null) return false;
  final raw = uri.toString();
  final separators = '*'.allMatches(raw).length;
  if (separators < 2) return false;
  return RegExp(r'[?&]md=', caseSensitive: false).hasMatch(raw);
}

/// Recovers the original URL carried inside a tracker's `md=` payload.
///
/// The payload is base64 JSON, sometimes with `%` and `*` characters injected
/// to defeat naive decoders. Returns null when no safe HTTP(S) URL is found.
String? decodeTrackerTarget(String raw) {
  final match = RegExp(r'[?&]md=([^&]*)', caseSensitive: false).firstMatch(raw);
  if (match == null) return null;

  final captured = match.group(1)!;
  final candidates = <String>{captured.replaceAll('%', '').replaceAll('*', '')};
  try {
    candidates.add(Uri.decodeFull(captured).replaceAll('%', ''));
  } catch (_) {
    // Invalid percent escapes are common in obfuscated payloads.
  }

  for (var candidate in candidates) {
    candidate = candidate.replaceAll('-', '+').replaceAll('_', '/');
    final padded = candidate + '=' * ((4 - candidate.length % 4) % 4);
    final whole = candidate.length - candidate.length % 4;
    final attempts = <String>[
      padded,
      if (whole != candidate.length) candidate.substring(0, whole),
    ];
    for (final attempt in attempts) {
      try {
        final text = utf8.decode(base64.decode(attempt), allowMalformed: true);
        final urlMatch = RegExp(r'https?://[\x21-\x7e]+').firstMatch(text);
        if (urlMatch == null) continue;
        var found = urlMatch.group(0)!;
        var end = found.length;
        while (end > 0) {
          final code = found.codeUnitAt(end - 1);
          if (code == 0x22 ||
              code == 0x27 ||
              code == 0x5c ||
              code == 0x7d ||
              code == 0x5d ||
              code == 0x2c ||
              code == 0x20) {
            end--;
          } else {
            break;
          }
        }
        found = found.substring(0, end);
        final parsed = Uri.tryParse(found);
        if (parsed == null ||
            (parsed.scheme != 'http' && parsed.scheme != 'https') ||
            isBlockedAdHost(parsed.host)) {
          continue;
        }
        return parsed.toString();
      } catch (_) {
        // Try the next decoding variant.
      }
    }
  }
  return null;
}

/// True for hosts that are blocked and for schemes that ad scripts abuse to
/// leave the app (intent, market, data, javascript, ...).
bool isBlockedNavigationUri(WebUri? uri) {
  if (uri == null) return false;
  if (isAdUri(uri)) return true;
  final scheme = uri.scheme.toLowerCase();
  return scheme.isNotEmpty &&
      scheme != 'http' &&
      scheme != 'https' &&
      scheme != 'about';
}

/// Empty response used to swallow a blocked sub-resource request.
WebResourceResponse blockedAdResponse() {
  return WebResourceResponse(
    contentType: 'text/plain',
    contentEncoding: 'utf-8',
    data: Uint8List(0),
  );
}

/// Drops ad/tracker sub-resource requests while leaving the main document alone.
Future<WebResourceResponse?> blockAdResource(
  InAppWebViewController controller,
  WebResourceRequest request,
) async {
  if (request.isForMainFrame ?? false) return null;
  if (isAdUri(request.url)) return blockedAdResponse();
  return null;
}

/// Keeps a viewer on the page the host shared. Initial redirect chains are
/// allowed; once the page has settled, cross-host jumps are popups/ads.
Future<NavigationActionPolicy?> viewerNavigationPolicy(
  InAppWebViewController controller,
  NavigationAction action, {
  DateTime? settledAt,
}) async {
  final uri = action.request.url;
  if (uri == null) return NavigationActionPolicy.ALLOW;
  if (isBlockedNavigationUri(uri)) return NavigationActionPolicy.CANCEL;
  if (!action.isForMainFrame) return NavigationActionPolicy.ALLOW;

  final scheme = uri.scheme.toLowerCase();
  if (scheme.isNotEmpty && scheme != 'http' && scheme != 'https') {
    return NavigationActionPolicy.CANCEL;
  }
  if (settledAt == null) return NavigationActionPolicy.ALLOW;

  final current = await controller.getUrl();
  final host = current?.host ?? '';
  if (host.isNotEmpty && uri.host.isNotEmpty && host != uri.host) {
    return NavigationActionPolicy.CANCEL;
  }
  return NavigationActionPolicy.ALLOW;
}

/// JavaScript injected at document start in every WebView that loads a site.
///
/// [viewer] disables every popup and external player link: viewers only watch
/// the page the host shared, so they must never be taken somewhere else.
String adBlockerScript({bool viewer = false}) {
  return _adBlockerScript.replaceFirst(
    '__WT_VIEWER_MODE__',
    viewer ? 'true' : 'false',
  );
}

const String _adBlockerScript = r'''
(function () {
  var viewerMode = __WT_VIEWER_MODE__;
  window.__wtAdsEnabled = true;
  window.__wtLastTap = null;
  window.__wtOriginalOpen = window.open;
  window.__wtOriginalAlert = window.alert;
  window.__wtOriginalConfirm = window.confirm;
  window.__wtOriginalPrint = window.print;

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

  function pointOf(event) {
    if (event.clientX != null) { return event; }
    var touch = event.changedTouches && event.changedTouches[0];
    return touch || event;
  }

  function closestAnchor(el) {
    while (el && el !== document) {
      if (el.tagName === 'A' && el.getAttribute) { return el; }
      el = el.parentElement;
    }
    return null;
  }

  // Popunder networks hide the destination in a long path full of `*` and a
  // base64 md= payload. Strip the hop so taps land on the real movie page.
  function looksLikeTracker(url) {
    var text = String(url);
    return /\.qpon(?:[/?#]|$)/i.test(text) ||
      (text.indexOf('*') >= 0 && /[?&]md=/i.test(text));
  }

  function decodeTrackerTarget(raw) {
    try {
      var match = /[?&]md=([^&]*)/i.exec(String(raw));
      if (!match) { return ''; }
      var value = match[1].replace(/%/g, '').replace(/\*/g, '');
      var variants = [value];
      try { variants.push(decodeURIComponent(match[1]).replace(/%/g, '')); } catch (_) {}
      for (var v = 0; v < variants.length; v++) {
        var candidate = variants[v].replace(/-/g, '+').replace(/_/g, '/');
        var padded = candidate;
        while (padded.length % 4) { padded += '='; }
        var whole = candidate.length - (candidate.length % 4);
        var attempts = [padded];
        if (whole !== candidate.length) {
          attempts.push(candidate.substring(0, whole));
        }
        for (var a = 0; a < attempts.length; a++) {
          try {
            var text = atob(attempts[a]);
            var hit = /https?:\/\/[^\x00-\x1f\s"'\\}]+/.exec(text);
            if (!hit) { continue; }
            var u = new URL(hit[0]);
            if (/^https?:$/i.test(u.protocol) && !/\.qpon$/i.test(u.host)) {
              return u.href;
            }
          } catch (_) {}
        }
      }
    } catch (_) {}
    return '';
  }

  function unwrapTracker(url) {
    if (!looksLikeTracker(url)) { return url; }
    var real = decodeTrackerTarget(url);
    return real || url;
  }

  function hrefOf(a) {
    if (!a || !a.getAttribute) { return ''; }
    if (a.hasAttribute('download')) { return ''; }
    var raw = unwrapTracker(a.getAttribute('href') || '');
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

  // Player/server controls usually carry these words. Only such a control is
  // allowed to open an external player; ordinary links cannot become popups.
  function playerLike(el) {
    var node = el;
    for (var depth = 0; node && depth < 5; depth++) {
      var cls = node.className && node.className.toString
        ? node.className.toString() : '';
      var text = [
        node.innerText || node.textContent || '',
        node.getAttribute ? (node.getAttribute('aria-label') || '') : '',
        node.getAttribute ? (node.getAttribute('title') || '') : '',
        cls, node.id || ''
      ].join(' ').toLowerCase();
      if (/\b(play|player|watch|server|stream|episode|embed|mirror|movie|video|source)\b/.test(text)) {
        return true;
      }
      if (node.tagName === 'VIDEO') { return true; }
      node = node.parentElement;
    }
    return false;
  }

  function mayOpen(host) {
    if (!host) { return false; }
    if (viewerMode) { return false; }
    if (host === location.host) { return true; }
    var tap = window.__wtLastTap;
    if (!tap || Date.now() - tap.at > 3000) { return false; }
    return tap.player === true;
  }

  function reportBlocked(url, player) {
    try {
      window.flutter_inappwebview.callHandler('wtBlockedPopup', {
        url: url,
        player: !!player
      });
    } catch (_) {}
  }

  function openHere(url, player) {
    if (!url) { return; }
    var target = absolute(unwrapTracker(url));
    if (!mayOpen(hostOf(target))) {
      reportBlocked(target, player);
      return;
    }
    try {
      window.flutter_inappwebview.callHandler('wtOpenUrl', target);
    } catch (_) {
      try { location.href = target; } catch (__) {}
    }
  }

  function stubWindow() {
    var stub = {
      closed: false,
      focus: function () {},
      blur: function () {},
      close: function () {},
      postMessage: function () {},
      document: { write: function () {}, close: function () {} }
    };
    Object.defineProperty(stub, 'location', {
      get: function () { return location.href; },
      set: function (value) {
        var tap = window.__wtLastTap;
        openHere(value && value.href ? value.href : value, tap && tap.player);
      }
    });
    return stub;
  }

  window.__wtOpenSamePage = function (url) {
    if (url) {
      var tap = window.__wtLastTap;
      openHere(url, tap && tap.player);
    }
    // Sites keep using the returned handle, so never hand back null.
    return stubWindow();
  };

  function fixTargets() {
    var nodes = document.querySelectorAll(
      'a[href], area[href], a[target], area[target], form[target], base[target]'
    );
    for (var i = 0; i < nodes.length; i++) {
      var target = nodes[i].getAttribute('target');
      if (target && target !== '_self') {
        nodes[i].setAttribute('target', '_self');
      }
      var href = nodes[i].getAttribute('href');
      if (href) {
        var real = unwrapTracker(href);
        if (real !== href) { nodes[i].setAttribute('href', real); }
      }
    }
  }

  var hiddenElements = [];

  function showHiddenElements() {
    for (var i = 0; i < hiddenElements.length; i++) {
      hiddenElements[i].style.removeProperty('display');
      delete hiddenElements[i].__wtHidden;
    }
    hiddenElements = [];
  }

  function hideElement(el) {
    if (!el || el.__wtHidden) { return; }
    el.__wtHidden = true;
    el.style.setProperty('display', 'none', 'important');
    hiddenElements.push(el);
  }

  function isPlayerContainer(el) {
    if (!el.querySelector) { return false; }
    try {
      return !!(el.style.zIndex === '2147483647' ||
        el.querySelector('video') ||
        el.querySelector('iframe[allowfullscreen]') ||
        el.querySelector('iframe[allow*="autoplay"]') ||
        el.querySelector('[id*="player" i], [class*="player" i]'));
    } catch (_) {
      return false;
    }
  }

  // In-page interstitials are not windows, so window.open cannot catch them.
  // Hide only overlays that look like ads or contain external iframe/links.
  function killAdOverlays() {
    if (!window.__wtAdsEnabled) { showHiddenElements(); return; }
    var nodes = document.querySelectorAll('div, section, iframe, span');
    for (var i = 0; i < nodes.length; i++) {
      var el = nodes[i];
      if (el.__wtHidden) { continue; }
      var id = (el.id || '').toLowerCase();
      var cls = el.className && el.className.toString
        ? el.className.toString().toLowerCase() : '';
      if (/(popunder|popup-ad|ad-popup|adpopup|interstitial|overlay-ad|ad-overlay|ads-overlay|ad-modal|admodal|ad-slot|adsbox|ad-unit|preroll|poptart|ad-banner)/.test(id + ' ' + cls)) {
        if (!isPlayerContainer(el)) { hideElement(el); }
        continue;
      }
      var style = window.getComputedStyle(el);
      if (style.position !== 'fixed' && style.position !== 'absolute') { continue; }
      var z = parseInt(style.zIndex, 10);
      if (isNaN(z) || z < 100) { continue; }
      var rect = el.getBoundingClientRect();
      if (rect.width < window.innerWidth * 0.7 ||
          rect.height < window.innerHeight * 0.5) { continue; }
      // A large iframe is the shared player, not a banner ad.
      if (el.tagName === 'IFRAME') { continue; }
      if (isPlayerContainer(el)) { continue; }
      var hasFrame = el.tagName === 'IFRAME' ||
        (el.querySelector && el.querySelector('iframe'));
      var externalLink = false;
      var links = el.querySelectorAll ? el.querySelectorAll('a[href]') : [];
      for (var j = 0; j < links.length; j++) {
        var linkHost = hostOf(hrefOf(links[j]));
        if (linkHost && linkHost !== location.host) { externalLink = true; break; }
      }
      if (hasFrame || externalLink) { hideElement(el); }
    }
  }

  function recordTap(event) {
    if (event.button !== undefined && event.button !== 0) { return ''; }
    var source = pointOf(event);
    var anchor = closestAnchor(event.target);
    var player = playerLike(event.target) || (anchor ? playerLike(anchor) : false);
    var control = isControl(event.target) || !!anchor || player;
    if (!anchor && !control && source.clientX != null &&
        document.elementsFromPoint) {
      var stack = document.elementsFromPoint(source.clientX, source.clientY) || [];
      for (var i = 0; i < stack.length; i++) {
        anchor = closestAnchor(stack[i]);
        if (anchor) { break; }
      }
    }
    var href = hrefOf(anchor);
    window.__wtLastTap = {
      href: href,
      host: href ? hostOf(href) : '',
      control: control,
      player: player,
      followed: false,
      at: Date.now()
    };
    return href;
  }

  window.__wtApplyAds = function () {
    var on = window.__wtAdsEnabled !== false;
    var style = document.getElementById('__wt_adblocker_style');
    if (style) { style.disabled = !on; }
    window.open = on ? window.__wtOpenSamePage : window.__wtOriginalOpen;
    window.alert = on ? function () {} : window.__wtOriginalAlert;
    window.confirm = on ? function () { return true; } : window.__wtOriginalConfirm;
    window.print = on ? function () {} : window.__wtOriginalPrint;
    if (!on) { showHiddenElements(); }
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
    '[class*="popunder" i],',
    '[id*="popunder" i],',
    '[class*="interstitial" i],',
    '[id*="interstitial" i],',
    '[class*="ad-overlay" i],',
    '[id*="ad-overlay" i],',
    '[class*="ads-overlay" i],',
    '[id*="ads-overlay" i],',
    '[data-ad-slot],',
    '[data-ad-client],',
    '[aria-label*="advertisement" i]',
    '{ display: none !important; }'
  ].join('\n');

  (document.head || document.documentElement).appendChild(style);
  window.__wtApplyAds();
  fixTargets();
  setInterval(fixTargets, 1500);
  killAdOverlays();
  setInterval(killAdOverlays, 1200);

  function onTap(event) {
    if (!window.__wtAdsEnabled) { return; }
    recordTap(event);
  }
  window.addEventListener('pointerdown', onTap, true);
  window.addEventListener('touchstart', onTap, true);
  window.addEventListener('mousedown', onTap, true);

  window.addEventListener('click', function (event) {
    if (!window.__wtAdsEnabled) { return; }
    if (event.button !== 0 || event.metaKey || event.ctrlKey ||
        event.shiftKey || event.altKey) { return; }
    var href = recordTap(event);
    if (!href) { return; }
    // Go straight to the real link; site trackers never see this click.
    window.__wtLastTap.followed = true;
    event.stopImmediatePropagation();
    event.preventDefault();
    try { location.assign(href); } catch (_) {}
  }, true);

  document.addEventListener('click', function (event) {
    var el = event.target;
    while (el && el !== document) {
      var target = el.getAttribute ? el.getAttribute('target') : null;
      if (target && target !== '_self') { el.setAttribute('target', '_self'); }
      el = el.parentElement;
    }
  }, true);

  if (window.Notification && window.Notification.requestPermission) {
    try {
      window.Notification.requestPermission = function () {
        return Promise.resolve('denied');
      };
    } catch (_) {}
  }
})();
''';
