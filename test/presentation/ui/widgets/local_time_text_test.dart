import 'package:flutter_test/flutter_test.dart';
import 'package:specterchat/presentation/ui/widgets/local_time_text.dart';

void main() {
  // A time zone is whatever the machine running the tests is in, so the
  // cases below fix `now` relative to the formatted time instead.
  final time = DateTime(2026, 9, 22, 14, 32, 5);

  test('today is just the clock', () {
    expect(
      shortLocalTimestamp(
        time,
        locale: 'en',
        now: time.add(const Duration(hours: 1)),
      ),
      '2:32\u202fPM',
    );
  });

  test('earlier this year keeps the day, an older one the year', () {
    expect(
      shortLocalTimestamp(time, locale: 'en', now: DateTime(2026, 12, 4)),
      'Sep 22, 2:32\u202fPM',
    );
    expect(
      shortLocalTimestamp(time, locale: 'en', now: DateTime(2027, 3, 4)),
      'Sep 22, 2026, 2:32\u202fPM',
    );
  });

  test('a UTC time is shown in the local zone', () {
    final utc = DateTime.utc(2026, 9, 22, 14, 32, 5);
    expect(
      fullLocalTimestamp(utc, locale: 'en'),
      fullLocalTimestamp(utc.toLocal(), locale: 'en'),
    );
    expect(
      fullLocalTimestamp(time, locale: 'en'),
      'Sep 22, 2026, 2:32:05\u202fPM',
    );
  });

  test('the date follows the locale, unknown ones fall back to English', () {
    expect(
      shortLocalTimestamp(time, locale: 'fr-FR', now: DateTime(2027, 3, 4)),
      contains('sept.'),
    );
    expect(intlLocale('zz-ZZ'), 'en');
  });
}
