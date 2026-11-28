import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_together/main.dart';

void main() {
  group('normalizeUrl', () {
    test('returns empty input unchanged', () {
      expect(normalizeUrl('   '), '');
    });

    test('keeps absolute http and https urls', () {
      expect(
        normalizeUrl('https://example.com/movie'),
        'https://example.com/movie',
      );
      expect(normalizeUrl('http://example.com'), 'http://example.com');
    });

    test('adds https to bare domains', () {
      expect(normalizeUrl('example.com'), 'https://example.com');
      expect(normalizeUrl('www.youtube.com'), 'https://www.youtube.com');
    });

    test('keeps paths and query strings on bare domains', () {
      expect(
        normalizeUrl('youtube.com/watch?v=abc123'),
        'https://youtube.com/watch?v=abc123',
      );
    });

    test('supports localhost and ports', () {
      expect(normalizeUrl('localhost:8080'), 'https://localhost:8080');
      expect(normalizeUrl('192.168.1.10:3000'), 'https://192.168.1.10:3000');
    });

    test('turns plain text into a Google search', () {
      const query = 'best movies to watch together';
      expect(
        normalizeUrl(query),
        'https://www.google.com/search?q=${Uri.encodeQueryComponent(query)}',
      );
    });

    test('keeps other explicit schemes', () {
      expect(
        normalizeUrl('file:///C:/movies/demo.mp4'),
        'file:///C:/movies/demo.mp4',
      );
    });
  });

  group('isAdUri', () {
    test('matches ad and tracker hosts, including subdomains', () {
      expect(
        isAdUri(WebUri('https://googleads.g.doubleclick.net/ads')),
        isTrue,
      );
      expect(
        isAdUri(WebUri('https://pagead2.googlesyndication.com/ad.js')),
        isTrue,
      );
      expect(isAdUri(WebUri('https://yandex.popads.net/pop.js')), isTrue);
      expect(
        isAdUri(WebUri('https://www.google-analytics.com/collect')),
        isTrue,
      );
      expect(isAdUri(WebUri('https://streamtape.com/e/abc')), isFalse);
      expect(isAdUri(WebUri('https://www.youtube.com')), isFalse);
      expect(isAdUri(null), isFalse);
    });
  });

  group('full ad host list', () {
    test('blocks real-world ad and popunder hosts', () {
      expect(isBlockedAdHost('ads.pubmatic.com'), isTrue);
      expect(isBlockedAdHost('cdn.popcash.net'), isTrue);
      expect(isBlockedAdHost('2mdn.net'), isTrue);
      expect(isBlockedAdHost('WWW.ADNXS.COM'), isTrue);
    });

    test('keeps legitimate hosts and link shorteners usable', () {
      expect(isBlockedAdHost('t.co'), isFalse);
      expect(isBlockedAdHost('www.youtube.com'), isFalse);
      expect(isBlockedAdHost('streamtape.com'), isFalse);
      expect(isBlockedAdHost(''), isFalse);
    });
  });

  group('isBlockedNavigationUri', () {
    test('blocks app-scheme redirects but allows web navigation', () {
      expect(
        isBlockedNavigationUri(WebUri('intent://ad/#Intent;scheme=http;end')),
        isTrue,
      );
      expect(isBlockedNavigationUri(WebUri('market://details?id=ad')), isTrue);
      expect(isBlockedNavigationUri(WebUri('https://example.com')), isFalse);
      expect(isBlockedNavigationUri(WebUri('about:blank')), isFalse);
    });
  });

  group('adBlockerScript', () {
    test('viewers never allow popups', () {
      expect(adBlockerScript(viewer: true), contains('var viewerMode = true;'));
      expect(adBlockerScript(), contains('var viewerMode = false;'));
    });
  });
}
