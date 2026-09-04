/// Gegenstueck zum ``Fact`` des Gateways.
///
/// Ein Wert kommt nie nackt, sondern mit Sicherheitsgrad und Begruendung.
/// Damit kann das UI "wissen wir nicht" von "gibt es hier nicht" und von
/// "ist tatsaechlich 0" unterscheiden, statt eine Null zu erfinden.
enum Certainty {
  known,
  unknown,
  unsupported;

  static Certainty parse(String? raw) => switch (raw) {
        'known' => Certainty.known,
        'unsupported' => Certainty.unsupported,
        _ => Certainty.unknown,
      };
}

class Fact<T> {
  const Fact({this.value, this.certainty = Certainty.known, this.note});

  final T? value;
  final Certainty certainty;
  final String? note;

  bool get isKnown => certainty == Certainty.known && value != null;

  /// Kurzform fuer die Anzeige, wenn kein Wert vorliegt.
  String get placeholder => '—';

  static Fact<T> _parse<T>(dynamic json, T Function(dynamic) cast) {
    if (json is! Map) {
      return Fact<T>(
        certainty: Certainty.unknown,
        note: 'Feld fehlt in der Antwort des Gateways',
      );
    }
    final raw = json['value'];
    T? parsed;
    if (raw != null) {
      try {
        parsed = cast(raw);
      } catch (_) {
        return Fact<T>(
          certainty: Certainty.unknown,
          note: 'Wert konnte nicht gelesen werden: $raw',
        );
      }
    }
    return Fact<T>(
      value: parsed,
      certainty: Certainty.parse(json['certainty'] as String?),
      note: json['note'] as String?,
    );
  }

  static Fact<double> asDouble(dynamic j) =>
      _parse<double>(j, (v) => (v as num).toDouble());

  static Fact<int> asInt(dynamic j) => _parse<int>(j, (v) => (v as num).toInt());

  static Fact<String> asString(dynamic j) =>
      _parse<String>(j, (v) => v.toString());

  static Fact<bool> asBool(dynamic j) => _parse<bool>(j, (v) => v as bool);

  static Fact<DateTime> asDate(dynamic j) =>
      _parse<DateTime>(j, (v) => DateTime.parse(v as String).toLocal());

  static Fact<T> missing<T>(String note) =>
      Fact<T>(certainty: Certainty.unknown, note: note);
}
