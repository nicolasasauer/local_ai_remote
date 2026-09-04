/// Anzeigeformate. Bewusst knapp: die Werte stehen in engen Instrumenten,
/// und bei 1 Hz Aktualisierung stört jede wechselnde Stellenzahl.
library;

String formatBytes(num bytes, {int decimals = 1}) {
  const units = ['B', 'KiB', 'MiB', 'GiB', 'TiB'];
  var value = bytes.toDouble();
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  final digits = unit >= 3 ? decimals : 0;
  return '${value.toStringAsFixed(digits)} ${units[unit]}';
}

String formatGiB(num bytes) => (bytes / (1024 * 1024 * 1024)).toStringAsFixed(1);

/// Tausendertrennung mit Punkt, wie im Deutschen üblich.
String formatCount(int value) {
  final digits = value.abs().toString();
  final buffer = StringBuffer(value < 0 ? '-' : '');
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) buffer.write('.');
    buffer.write(digits[i]);
  }
  return buffer.toString();
}

String formatPercent(num value, {int decimals = 0}) =>
    '${value.toStringAsFixed(decimals)} %';

String formatMillis(num ms) =>
    ms >= 1000 ? '${(ms / 1000).toStringAsFixed(1)} s' : '${ms.round()} ms';

String formatDuration(Duration d) {
  if (d.inSeconds < 60) return '${d.inSeconds} s';
  final minutes = d.inMinutes;
  final seconds = d.inSeconds % 60;
  if (minutes < 60) return '$minutes:${seconds.toString().padLeft(2, '0')} min';
  return '${d.inHours} h ${minutes % 60} min';
}

/// Relative Zeit für Listen und Veraltet-Hinweise.
String formatAgo(Duration d) {
  if (d.inSeconds < 5) return 'gerade eben';
  if (d.inSeconds < 60) return 'vor ${d.inSeconds} s';
  if (d.inMinutes < 60) return 'vor ${d.inMinutes} min';
  if (d.inHours < 24) return 'vor ${d.inHours} h';
  return 'vor ${d.inDays} d';
}

String formatClock(DateTime t) =>
    '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

String formatCountdown(DateTime target) {
  final left = target.difference(DateTime.now());
  if (left.isNegative) return 'jetzt';
  return formatDuration(left);
}
