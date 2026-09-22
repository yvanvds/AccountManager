import 'dart:math';

/// One entry in the shared ticket-printer list (#435): a named printer that any
/// reception desk can be pointed at, with the header its tickets carry.
///
/// **Shared rather than machine-local, and that is the whole point.** #406
/// stored one address per machine, on the reasoning that a printer is a box on
/// a table in one room. True, but the conclusion was wrong: the school has two
/// reception desks and may get more, and operators do not stand at the same
/// desk every day. One address per machine means every desk — and every laptop
/// an operator brings along — has to be configured by hand, and moving desks
/// means retyping an IP. An administrator enters each printer once here, every
/// desk sees the list, and the desk only *picks* one (#436).
///
/// The [header] rides on the entry for the same reason one step removed (#429).
/// It was machine-local because "a desk prints for one school" — but the thing
/// that stands at one school is the *printer*, not the laptop. Attaching it
/// here means an operator who picks a different printer automatically prints
/// the right school code.
///
/// **[id] is minted once and never edited.** It is what a desk's choice is
/// stored as (#436), so relabelling "Balie A" or re-addressing it to a new IP
/// leaves every desk that selected it still selected. Nothing the operator can
/// see is stable enough to key on: the label is exactly what gets corrected,
/// and a printer's address is exactly what gets changed.
final class TicketPrinter {
  const TicketPrinter({
    required this.id,
    required this.label,
    required this.host,
    this.header = '',
  });

  /// Mints a new entry with a fresh [id] — what the Instellingen editor calls
  /// when the operator adds a printer.
  ///
  /// [random] is injectable so a test can pin the id; production draws from
  /// [Random.secure].
  factory TicketPrinter.create({
    required String label,
    required String host,
    String header = '',
    Random? random,
  }) =>
      TicketPrinter(
        id: newTicketPrinterId(random),
        label: label,
        host: host,
        header: header,
      );

  /// The stable identity a desk's selection is stored as (#436). Opaque, minted
  /// by [newTicketPrinterId], never shown and never edited.
  final String id;

  /// What the list and the desk's selector call this printer — "Balie A".
  final String label;

  /// The host name or IP the ticket is POSTed to over IPP. The one field that
  /// must not be blank: an entry with no address is not a printer.
  final String host;

  /// The few characters printed large at the top of every ticket this printer
  /// produces (#429) — the school's code, typically. Empty prints no header
  /// line, which is a decision rather than a gap.
  final String header;

  /// Whether this entry can be printed on at all.
  ///
  /// The address alone decides. A blank label is survivable — [displayName]
  /// falls back to the address — but a blank host is an entry that can only
  /// ever fail.
  bool get isUsable => host.trim().isNotEmpty;

  /// What to put in front of the operator: the label, or the address when
  /// nobody has bothered to name the printer.
  String get displayName => label.trim().isEmpty ? host.trim() : label.trim();

  TicketPrinter copyWith({
    String? id,
    String? label,
    String? host,
    String? header,
  }) =>
      TicketPrinter(
        id: id ?? this.id,
        label: label ?? this.label,
        host: host ?? this.host,
        header: header ?? this.header,
      );

  /// This entry with every text field trimmed — what the shared document should
  /// hold, and what [normalizeTicketPrinters] applies to each entry.
  TicketPrinter trimmed() => TicketPrinter(
        id: id.trim(),
        label: label.trim(),
        host: host.trim(),
        header: header.trim(),
      );

  Map<String, Object?> toJson() => <String, Object?>{
        'id': id,
        'label': label,
        'host': host,
        'header': header,
      };

  /// Reads one entry back. `null` — never an exception — when the address is
  /// missing or of the wrong type, so one damaged entry costs one printer and
  /// not the shared settings document.
  ///
  /// A missing or blank `id` decodes to the empty string rather than to `null`:
  /// [normalizeTicketPrinters] is what mints one, so a hand-edited document
  /// that left the id out still loads and simply gets an id on the way in.
  static TicketPrinter? tryFromJson(Map<String, Object?> json) {
    final Object? host = json['host'];
    if (host is! String || host.trim().isEmpty) return null;
    final Object? id = json['id'];
    final Object? label = json['label'];
    final Object? header = json['header'];
    return TicketPrinter(
      id: id is String ? id.trim() : '',
      label: label is String ? label.trim() : '',
      host: host.trim(),
      header: header is String ? header.trim() : '',
    );
  }

  @override
  bool operator ==(Object other) =>
      other is TicketPrinter &&
      other.id == id &&
      other.label == label &&
      other.host == host &&
      other.header == header;

  @override
  int get hashCode => Object.hash(id, label, host, header);

  @override
  String toString() => 'TicketPrinter($id, $label, $host'
      '${header.isEmpty ? '' : ', $header'})';
}

/// How many hex characters a minted [TicketPrinter.id] carries.
///
/// Sixteen — 64 bits. The list is a handful of printers typed in by hand, so
/// this is not fighting a birthday bound; it is only wide enough that two
/// administrators adding a printer at two desks in the same minute cannot
/// collide, which a counter or a timestamp would.
const int ticketPrinterIdLength = 16;

/// Mints an opaque id for a new [TicketPrinter].
///
/// A random hex string rather than a UUID: this package is deliberately
/// dependency-free beyond the domain, the value is never parsed by anything,
/// and a shorter id keeps the settings document readable when somebody has to
/// look at it by hand.
String newTicketPrinterId([Random? random]) {
  final Random r = random ?? Random.secure();
  final StringBuffer out = StringBuffer();
  for (var i = 0; i < ticketPrinterIdLength; i++) {
    out.write(r.nextInt(16).toRadixString(16));
  }
  return out.toString();
}

/// Cleans a printer list the way the shared document should hold it: every
/// field trimmed, entries with a blank address dropped, and every entry left
/// holding an id no other entry holds — **order preserved**, first occurrence
/// winning.
///
/// Order is the operator's: entries appear in the editor, and in the desk's
/// selector, in the order they were added. There is deliberately no sort here.
///
/// **Ids are repaired rather than the entries dropped.** A document that lost
/// an id, or that grew two entries carrying the same one — a hand edit, a
/// copy-paste, an older build — still describes real printers standing in real
/// rooms, and throwing them away would cost more than re-minting. The *first*
/// holder keeps the id, so a desk that already selected it stays pointed at the
/// printer it chose; the later claimant is the one that gets a fresh id.
///
/// [mintId] is injectable so a test can pin what a repair produces.
List<TicketPrinter> normalizeTicketPrinters(
  Iterable<TicketPrinter> printers, {
  String Function()? mintId,
}) {
  final String Function() mint = mintId ?? newTicketPrinterId;
  final List<TicketPrinter> out = <TicketPrinter>[];
  final Set<String> seen = <String>{};
  for (final TicketPrinter printer in printers) {
    final TicketPrinter clean = printer.trimmed();
    if (!clean.isUsable) continue;
    String id = clean.id;
    if (id.isEmpty || !seen.add(id)) {
      do {
        id = mint();
      } while (!seen.add(id));
    }
    out.add(clean.copyWith(id: id));
  }
  return out;
}

/// Decodes the printer list out of a settings document.
///
/// **Absent or unusable decodes to an empty list**, which is where this parts
/// company with [decodeLateArrivalReasons]: there is no shipped default and an
/// emptied list is honoured. "No printers configured yet" is a legitimate
/// state — it is what every install is before an administrator has entered one,
/// and what a school that registers late arrivals without handing out tickets
/// stays. A reason list with no entries leaves the desk unable to register
/// anybody; a printer list with no entries only means no paper comes out.
List<TicketPrinter> decodeTicketPrinters(Object? raw) {
  if (raw is! List) return const <TicketPrinter>[];
  final List<TicketPrinter> decoded = <TicketPrinter>[];
  for (final Object? entry in raw) {
    if (entry is! Map) continue;
    final TicketPrinter? printer = TicketPrinter.tryFromJson(
      entry.map((Object? k, Object? v) => MapEntry<String, Object?>('$k', v)),
    );
    if (printer != null) decoded.add(printer);
  }
  return normalizeTicketPrinters(decoded);
}

/// The printer [id] names, or `null` when the list holds no such entry.
///
/// The one lookup a desk needs (#436): a machine stores which printer it prints
/// on as an id in its own preferences, and has to turn that back into a host
/// and a header every time the shared list changes underneath it. `null` is the
/// ordinary answer, not an error — it is what a desk gets when the printer it
/// had selected has since been removed from the shared list, and what an
/// unconfigured desk gets by passing `null`. The caller decides what to do with
/// it; here, "no printer" is simply "no ticket".
TicketPrinter? findTicketPrinter(Iterable<TicketPrinter> printers, String? id) {
  final String? wanted = id?.trim();
  if (wanted == null || wanted.isEmpty) return null;
  for (final TicketPrinter printer in printers) {
    if (printer.id == wanted) return printer;
  }
  return null;
}
