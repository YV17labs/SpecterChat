import 'package:flutter_test/flutter_test.dart';
import 'package:specterchat/application/links/link_follower.dart';

import '../../support/fakes.dart';

void main() {
  test('web pages and addresses are followed', () {
    for (final href in [
      'https://example.com/a?b=c#d',
      'http://example.com',
      'mailto:someone@example.com',
      ' HTTPS://Example.com ',
    ]) {
      expect(followableLink(href), Uri.parse(href.trim()), reason: href);
    }
  });

  test('anything that would open or run something local is not', () {
    for (final href in [
      'file:///etc/passwd',
      'javascript:alert(1)',
      'vscode://file/Users/me/.ssh/config',
      'x-apple.systempreferences:com.apple.preference.security',
      'smb://server/share',
      'data:text/html,<b>hi</b>',
    ]) {
      expect(followableLink(href), isNull, reason: href);
    }
  });

  test('links with nowhere to go are not followed', () {
    for (final href in [
      null,
      '',
      '#section',
      'docs/readme.md',
      '/absolute/path',
      'example.com',
      'https:',
      'https:///path',
      'mailto:',
      'http://[',
    ]) {
      expect(followableLink(href), isNull, reason: '$href');
    }
  });

  test('the follower opens only what followableLink lets through', () async {
    final opener = FakeLinkOpener();
    final follower = LinkFollower(opener);
    await follower.follow('https://example.com');
    await follower.follow('file:///etc/passwd');
    expect(opener.opened, [Uri.parse('https://example.com')]);
  });
}
