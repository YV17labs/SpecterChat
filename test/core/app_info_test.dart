import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:specterchat/core/app_info.dart';
import 'package:specterchat/core/user_agent_client.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    PackageInfo.setMockInitialValues(
      appName: 'SpecterChat',
      packageName: 'com.yv17labs.specterchat',
      version: '1.2.3',
      buildNumber: '42',
      buildSignature: '',
    );
    await AppInfo.init();
  });

  group('AppInfo', () {
    test('exposes the bundle version', () {
      expect(AppInfo.version, '1.2.3');
      expect(AppInfo.buildNumber, '42');
      expect(AppInfo.versionLabel, '1.2.3 (build 42)');
    });

    test('user agent carries name, version, OS and Dart runtime', () {
      expect(
        AppInfo.userAgent,
        matches(RegExp(r'^SpecterChat/1\.2\.3 \(\w+\) Dart/\d+\.\d+\.\d+')),
      );
    });
  });

  group('UserAgentClient', () {
    test('stamps User-Agent on every request', () async {
      String? seen;
      final client = UserAgentClient(
        MockClient((req) async {
          seen = req.headers['User-Agent'];
          return http.Response('', 200);
        }),
      );
      await client.get(Uri.parse('http://localhost/'));
      expect(seen, AppInfo.userAgent);
    });

    test('keeps a caller-provided User-Agent', () async {
      String? seen;
      final client = UserAgentClient(
        MockClient((req) async {
          seen = req.headers['user-agent'];
          return http.Response('', 200);
        }),
      );
      await client.get(
        Uri.parse('http://localhost/'),
        headers: {'user-agent': 'custom/1.0'},
      );
      expect(seen, 'custom/1.0');
    });
  });
}
