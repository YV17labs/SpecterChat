import 'package:flutter/widgets.dart';
import 'package:intl/intl.dart';

/// Where a date's language comes from ([systemLocaleOf]), how it is
/// written ([localDate], [localClock]), and the times of the app's own
/// events (when a reply was generated). A stored time is UTC; every
/// formatter here takes it local first, so a conversation read months
/// later still says when each turn happened, wherever it is read from.
///
/// The formats `main` loads (`initializeDateFormatting`) are in the
/// system's language; the rest of the UI stays English.

/// The system's language, for dates: `fr-FR`. Not `Localizations.localeOf`,
/// which is always English — the app declares no other locale.
String systemLocaleOf(BuildContext context) =>
    View.of(context).platformDispatcher.locale.toLanguageTag();

/// [locale] as intl knows it — `fr-CA` is `fr_CA`, a region without formats
/// of its own falls back to its language — else English.
String intlLocale(String locale) => Intl.verifiedLocale(
  locale,
  DateFormat.localeExists,
  onFailure: (_) => 'en',
)!;

/// One locale's formatters, built on first use and kept: constructing a
/// `DateFormat` re-parses its pattern, and the stats line under a reply is
/// rebuilt on every streaming tick. `format` is stateless, so one instance
/// serves every call — and a run has one locale in practice.
class _Formats {
  _Formats(String locale)
    : clock = DateFormat.jm(locale),
      preciseClock = DateFormat.jms(locale),
      dayMonth = DateFormat.MMMd(locale),
      date = DateFormat.yMMMd(locale);

  final DateFormat clock;
  final DateFormat preciseClock;
  final DateFormat dayMonth;
  final DateFormat date;
}

final _formats = <String, _Formats>{};

_Formats _formatsOf(String locale) =>
    _formats.putIfAbsent(locale, () => _Formats(intlLocale(locale)));

/// `5 juil. 2026`, `Jul 5, 2026` — how the app writes a date, everywhere.
String localDate(DateTime time, {required String locale}) =>
    _formatsOf(locale).date.format(time);

/// `19:41`, `7:41 PM` — the clock alone, in the locale's hour cycle.
String localClock(DateTime time, {required String locale}) =>
    _formatsOf(locale).clock.format(time);

/// Short, for a line already full of numbers: `14:32` today, `Sep 22,
/// 14:32` earlier this year, `Sep 22, 2025, 14:32` before that.
String shortLocalTimestamp(
  DateTime time, {
  required String locale,
  DateTime? now,
}) {
  final formats = _formatsOf(locale);
  final t = time.toLocal();
  final today = (now ?? DateTime.now()).toLocal();
  final clock = formats.clock.format(t);
  if (t.year == today.year && t.month == today.month && t.day == today.day) {
    return clock;
  }
  final date = t.year == today.year
      ? formats.dayMonth.format(t)
      : formats.date.format(t);
  return '$date, $clock';
}

/// The whole moment, for a tooltip: `Sep 22, 2026, 2:32:05 PM`.
String fullLocalTimestamp(DateTime time, {required String locale}) {
  final formats = _formatsOf(locale);
  final t = time.toLocal();
  return '${formats.date.format(t)}, ${formats.preciseClock.format(t)}';
}
