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
}
