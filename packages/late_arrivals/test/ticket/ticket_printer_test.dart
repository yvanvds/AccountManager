import 'dart:math';

import 'package:late_arrivals/late_arrivals.dart';
import 'package:test/test.dart';

/// A counter dressed as a minter, so a test can say exactly which ids a repair
/// handed out.
String Function() _seq([String prefix = 'mint']) {
  var n = 0;
  return () => '$prefix-${++n}';
}

void main() {
  group('TicketPrinter', () {
    test('carries a label, an address and its own ticket header (#435)', () {
      const TicketPrinter balie = TicketPrinter(
        id: 'p1',
        label: 'Balie A',
        host: '10.0.1.20',
        header: 'SMA',
      );

      expect(balie.label, 'Balie A');
      expect(balie.host, '10.0.1.20');
      // The header rides on the printer rather than on the machine (#429): the
      // thing that stands at one school is the printer.
      expect(balie.header, 'SMA');
      expect(balie.isUsable, isTrue);
    });

    test('an entry with no address is not a printer', () {
      // The one field that decides usability. A blank label is survivable; a
      // blank address is an entry that can only ever fail.
      expect(
        const TicketPrinter(id: 'p1', label: 'Balie A', host: '   ').isUsable,
        isFalse,
      );
      expect(
        const TicketPrinter(id: 'p1', label: '', host: '10.0.1.20').isUsable,
        isTrue,
      );
    });

    test('an unnamed printer shows its address instead', () {
      // What the editor's row and the desk's selector put in front of the
      // operator, so a printer nobody bothered to name is still pickable.
      expect(
        const TicketPrinter(id: 'p1', label: '  ', host: ' 10.0.1.20 ')
            .displayName,
        '10.0.1.20',
      );
      expect(
        const TicketPrinter(id: 'p1', label: ' Balie A ', host: '10.0.1.20')
            .displayName,
        'Balie A',
      );
    });

    test('round-trips through JSON, id and header included', () {
      const TicketPrinter printer = TicketPrinter(
        id: 'abc123',
        label: 'Balie B',
        host: 'bonprinter-2.school.local',
        header: 'SSM',
      );
      expect(printer.toJson(), <String, Object?>{
        'id': 'abc123',
        'label': 'Balie B',
        'host': 'bonprinter-2.school.local',
        'header': 'SSM',
      });
      expect(TicketPrinter.tryFromJson(printer.toJson()), printer);
    });

    test('a damaged entry decodes as null rather than throwing', () {
      // One bad entry must cost one printer, not the shared settings document.
      expect(TicketPrinter.tryFromJson(<String, Object?>{}), isNull);
      expect(
        TicketPrinter.tryFromJson(<String, Object?>{'host': 9100}),
        isNull,
      );
      expect(
        TicketPrinter.tryFromJson(<String, Object?>{'host': '   '}),
        isNull,
      );
    });

    test('a hand-edited entry with no id still loads, and trims', () {
      // The id is minted by the editor; a document somebody typed by hand has
      // no reason to carry one, and losing the printer over it would be the
      // wrong trade. `normalizeTicketPrinters` is what fills it in.
      final TicketPrinter? printer = TicketPrinter.tryFromJson(
        <String, Object?>{'label': ' Balie A ', 'host': ' 10.0.1.20 '},
      );
      expect(printer, isNotNull);
      expect(printer!.id, '');
      expect(printer.label, 'Balie A');
      expect(printer.host, '10.0.1.20');
      expect(printer.header, '');
    });

    test('an id is minted once at creation and survives every edit', () {
      // The acceptance criterion the follow-up selector stands on (#436): a
      // desk stores its choice as an id, so relabelling or re-addressing a
      // printer must leave that desk pointed at the same box.
      final TicketPrinter created = TicketPrinter.create(
        label: 'Balie A',
        host: '10.0.1.20',
        random: Random(7),
      );
      expect(created.id, isNotEmpty);

      final TicketPrinter edited =
          created.copyWith(label: 'Onthaal', host: '10.0.1.99', header: 'SMA');
      expect(edited.id, created.id);
      expect(edited.label, 'Onthaal');
      expect(edited.host, '10.0.1.99');
    });

    test('a minted id is opaque hex of a fixed width', () {
      final String id = newTicketPrinterId(Random(1));
      expect(id.length, ticketPrinterIdLength);
      expect(id, matches(RegExp('^[0-9a-f]{$ticketPrinterIdLength}\$')));
      // Two mints from two sources do not collide.
      expect(newTicketPrinterId(Random(1)) == newTicketPrinterId(Random(2)),
          isFalse);
    });
  });

  group('normalizeTicketPrinters', () {
    test('trims every field and preserves the operator\'s order', () {
      final List<TicketPrinter> clean = normalizeTicketPrinters(
        const <TicketPrinter>[
          TicketPrinter(
              id: ' p2 ',
              label: '  Balie B ',
              host: ' 10.0.1.21 ',
              header: ' SSM '),
          TicketPrinter(id: 'p1', label: 'Balie A', host: '10.0.1.20'),
        ],
      );

      expect(clean.map((TicketPrinter p) => p.label), <String>[
        'Balie B',
        'Balie A',
      ]);
      expect(clean.first.id, 'p2');
      expect(clean.first.host, '10.0.1.21');
      expect(clean.first.header, 'SSM');
    });

    test('drops entries with a blank address', () {
      final List<TicketPrinter> clean = normalizeTicketPrinters(
        const <TicketPrinter>[
          TicketPrinter(id: 'p1', label: 'Balie A', host: '10.0.1.20'),
          TicketPrinter(id: 'p2', label: 'Halfweg ingetypt', host: '   '),
        ],
      );

      expect(clean.map((TicketPrinter p) => p.id), <String>['p1']);
    });

    test('mints an id for an entry that has none', () {
      final List<TicketPrinter> clean = normalizeTicketPrinters(
        const <TicketPrinter>[
          TicketPrinter(id: '', label: 'Balie A', host: '10.0.1.20'),
        ],
        mintId: _seq(),
      );

      expect(clean.single.id, 'mint-1');
      expect(clean.single.label, 'Balie A');
    });

    test('a duplicate id is re-minted, and the first holder keeps it', () {
      // The repair direction matters. A desk that already selected the first
      // entry stays pointed at the printer it chose; the later claimant — the
      // copy-paste, the older build, the hand edit — is the one that moves.
      final List<TicketPrinter> clean = normalizeTicketPrinters(
        const <TicketPrinter>[
          TicketPrinter(id: 'same', label: 'Balie A', host: '10.0.1.20'),
          TicketPrinter(id: 'same', label: 'Balie B', host: '10.0.1.21'),
        ],
        mintId: _seq(),
      );

      expect(clean.map((TicketPrinter p) => p.label),
          <String>['Balie A', 'Balie B']);
      expect(clean[0].id, 'same');
      expect(clean[1].id, 'mint-1');
    });

    test('a repair never hands out an id already in the list', () {
      // The minter here is rigged to collide on its first try, which is what a
      // real random source can do and what the retry loop exists for.
      var n = 0;
      String collidingMint() {
        n++;
        return n == 1 ? 'taken' : 'fresh-$n';
      }

      final List<TicketPrinter> clean = normalizeTicketPrinters(
        const <TicketPrinter>[
          TicketPrinter(id: 'taken', label: 'Balie A', host: '10.0.1.20'),
          TicketPrinter(id: '', label: 'Balie B', host: '10.0.1.21'),
        ],
        mintId: collidingMint,
      );

      expect(clean[0].id, 'taken');
      expect(clean[1].id, 'fresh-2');
    });

    test('an entry that duplicates another address is kept', () {
      // Unlike the reason list, which collapses "bus" and "Bus": two entries on
      // one address are a real configuration — the same printer under two
      // school headers, which is exactly what a shared building looks like.
      final List<TicketPrinter> clean = normalizeTicketPrinters(
        const <TicketPrinter>[
          TicketPrinter(
              id: 'p1', label: 'Balie SMA', host: '10.0.1.20', header: 'SMA'),
          TicketPrinter(
              id: 'p2', label: 'Balie SSM', host: '10.0.1.20', header: 'SSM'),
        ],
      );

      expect(clean, hasLength(2));
    });
  });

  group('decodeTicketPrinters', () {
    test('an absent or unusable list decodes to no printers at all', () {
      // Where this parts company with the reason list: there is no plausible
      // printer address to ship, and a desk with no printer is a desk that
      // registers without handing out paper — not a dead screen.
      expect(decodeTicketPrinters(null), isEmpty);
      expect(decodeTicketPrinters('10.0.1.20'), isEmpty);
      expect(decodeTicketPrinters(<Object?>[]), isEmpty);
      expect(decodeTicketPrinters(<Object?>['nonsense', 42]), isEmpty);
    });

    test('an emptied list is honoured rather than re-defaulted', () {
      // An administrator who removed the last printer meant it.
      expect(decodeTicketPrinters(<Object?>[]), isEmpty);
    });

    test('decodes what toJson wrote, in order', () {
      final List<Map<String, Object?>> raw = <Map<String, Object?>>[
        const TicketPrinter(
                id: 'p1', label: 'Balie A', host: '10.0.1.20', header: 'SMA')
            .toJson(),
        const TicketPrinter(id: 'p2', label: 'Balie B', host: '10.0.1.21')
            .toJson(),
      ];

      final List<TicketPrinter> decoded = decodeTicketPrinters(raw);
      expect(decoded.map((TicketPrinter p) => p.id), <String>['p1', 'p2']);
      expect(decoded.first.header, 'SMA');
    });

    test('one damaged entry costs one printer, not the document', () {
      final List<TicketPrinter> decoded = decodeTicketPrinters(<Object?>[
        <String, Object?>{'id': 'p1', 'label': 'Balie A', 'host': '10.0.1.20'},
        <String, Object?>{'id': 'p2', 'label': 'Kapot'},
        'not a map',
      ]);

      expect(decoded.map((TicketPrinter p) => p.id), <String>['p1']);
    });
  });

  group('findTicketPrinter', () {
    const List<TicketPrinter> list = <TicketPrinter>[
      TicketPrinter(
          id: 'p1', label: 'Balie A', host: '10.0.1.20', header: 'SMA'),
      TicketPrinter(
          id: 'p2', label: 'Balie B', host: '10.0.1.21', header: 'SSM'),
    ];

    test('resolves the id a desk stored into a host and a header (#436)', () {
      final TicketPrinter? found = findTicketPrinter(list, 'p2');
      expect(found?.host, '10.0.1.21');
      expect(found?.header, 'SSM');
    });

    test('ignores surrounding whitespace on the stored id', () {
      expect(findTicketPrinter(list, ' p1 ')?.label, 'Balie A');
    });

    test('a desk that selected nothing, or a printer since removed, gets null',
        () {
      // Both are ordinary states, not errors: "no printer" is "no ticket".
      expect(findTicketPrinter(list, null), isNull);
      expect(findTicketPrinter(list, '   '), isNull);
      expect(findTicketPrinter(list, 'gone'), isNull);
      expect(findTicketPrinter(const <TicketPrinter>[], 'p1'), isNull);
    });
  });
}
