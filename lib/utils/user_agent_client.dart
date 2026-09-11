import 'package:http/http.dart' as http;

import 'app_info.dart';

/// `package:http` client that stamps [AppInfo.userAgent] on every request
/// unless the caller already set a `User-Agent` (header names are matched
/// case-insensitively by [http.BaseRequest]).
class UserAgentClient extends http.BaseClient {
  final http.Client _inner;

  UserAgentClient([http.Client? inner]) : _inner = inner ?? http.Client();

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    request.headers.putIfAbsent('User-Agent', () => AppInfo.userAgent);
    return _inner.send(request);
  }

  @override
  void close() => _inner.close();
}
