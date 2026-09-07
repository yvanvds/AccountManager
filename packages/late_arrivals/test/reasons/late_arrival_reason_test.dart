import 'package:late_arrivals/late_arrivals.dart';
import 'package:test/test.dart';

void main() {
  group('LateArrivalReason', () {
    test('carries a label and its own validity flag (#405)', () {
      // The whole design in one assertion: the valid/invalid distinction is a
      // property of the reason, not a second thing the operator clicks.
      const LateArrivalReason bus = LateArrivalReason('Bus of trein te laat');
      const LateArrivalReason overslept =
          LateArrivalReason('Verslapen', isValid: false);

      expect(bus.isValid, isTrue);
      expect(bus.withoutValidReason, isFalse);
      expect(overslept.isValid, isFalse);
      // The flag the Presence write carries (#404) is available, negated the
      // way that API names it.
      expect(overslept.withoutValidReason, isTrue);
    });

    test('round-trips through JSON, flag included', () {
      const LateArrivalReason reason =
          LateArrivalReason('Geen reden opgegeven', isValid: false);
      expect(reason.toJson(),
          <String, Object?>{'label': 'Geen reden opgegeven', 'valid': false});
      expect(LateArrivalReason.tryFromJson(reason.toJson()), reason);
    });

    test('a damaged entry decodes as null rather than throwing', () {
      // One bad entry must cost one button, not the shared settings document.
      expect(LateArrivalReason.tryFromJson(<String, Object?>{}), isNull);
      expect(
        LateArrivalReason.tryFromJson(<String, Object?>{'label': 42}),
        isNull,
      );
      expect(
        LateArrivalReason.tryFromJson(<String, Object?>{'label': '   '}),
        isNull,
      );
    });

    test('a missing valid flag reads as a valid reason', () {
      // Far likelier to be an ordinary reason than a document silently marking
      // every arrival unexcused.
      final LateArrivalReason? reason =
          LateArrivalReason.tryFromJson(<String, Object?>{'label': 'Verkeer'});
      expect(reason?.isValid, isTrue);
    });

    test('the key folds case and surrounding whitespace', () {
      expect(const LateArrivalReason(' Bus ').key,
          const LateArrivalReason('BUS').key);
    });
  });

  group('defaultLateArrivalReasons', () {
    test('ships a usable Dutch list with both halves of the flag (#405)', () {
      // The feature has to work before anybody configures anything.
      expect(defaultLateArrivalReasons, isNotEmpty);
      expect(
        defaultLateArrivalReasons.map((LateArrivalReason r) => r.label),
        contains('Verkeer'),
      );
      expect(
        defaultLateArrivalReasons.where((LateArrivalReason r) => r.isValid),
        isNotEmpty,
      );
      // …and at least one entry on the "zonder geldige reden" side, so the
      // distinction is demonstrated rather than merely supported.
      expect(
        defaultLateArrivalReasons.where((LateArrivalReason r) => !r.isValid),
        isNotEmpty,
      );
      // Every shipped entry survives its own normalization — no stray
      // whitespace, no duplicate spelling.
      expect(
        normalizeLateArrivalReasons(defaultLateArrivalReasons),
        defaultLateArrivalReasons,
      );
    });
  });

  group('normalizeLateArrivalReasons', () {
    test('trims labels, drops blanks and keeps the order', () {
      expect(
        normalizeLateArrivalReasons(const <LateArrivalReason>[
          LateArrivalReason('  Verkeer '),
          LateArrivalReason('   '),
          LateArrivalReason('Doktersbezoek'),
        ]),
        const <LateArrivalReason>[
          LateArrivalReason('Verkeer'),
          LateArrivalReason('Doktersbezoek'),
        ],
      );
    });

    test('collapses the spellings the shared list exists to prevent', () {
      // "bus", "Bus " and "BUS" are one reason. Letting them through is exactly
      // how Smartschool ends up unreadable afterwards.
      final List<LateArrivalReason> normalized =
          normalizeLateArrivalReasons(const <LateArrivalReason>[
        LateArrivalReason('Bus'),
        LateArrivalReason('Verkeer'),
        LateArrivalReason('Bus '),
        LateArrivalReason('BUS', isValid: false),
      ]);

      expect(normalized, hasLength(2));
      expect(normalized.first.label, 'Bus');
      // First wins, flag included: a careless duplicate must not flip the
      // standing entry's validity for every desk at once.
      expect(normalized.first.isValid, isTrue);
    });

    test('preserves the operator ordering rather than grouping by flag', () {
      // The order is what the button row renders in (#407).
      final List<LateArrivalReason> normalized =
          normalizeLateArrivalReasons(const <LateArrivalReason>[
        LateArrivalReason('Verslapen', isValid: false),
        LateArrivalReason('Verkeer'),
      ]);
      expect(
        normalized.map((LateArrivalReason r) => r.label),
        <String>['Verslapen', 'Verkeer'],
      );
    });
  });

  group('decodeLateArrivalReasons', () {
    test('reads a stored list back in order', () {
      expect(
        decodeLateArrivalReasons(<Object?>[
          <String, Object?>{'label': 'Trein', 'valid': true},
          <String, Object?>{'label': 'Verslapen', 'valid': false},
        ]),
        const <LateArrivalReason>[
          LateArrivalReason('Trein'),
          LateArrivalReason('Verslapen', isValid: false),
        ],
      );
    });

    test('an absent list adopts the shipped defaults', () {
      expect(decodeLateArrivalReasons(null), defaultLateArrivalReasons);
      expect(decodeLateArrivalReasons('nonsense'), defaultLateArrivalReasons);
    });

    test('an emptied or unusable list adopts them too', () {
      // Deliberately unlike `smartschoolRoots`, where present-but-empty is a
      // choice that is honoured. A desk with no buttons cannot register the
      // student standing in front of it, so there is no reading of "no reasons"
      // worth keeping.
      expect(decodeLateArrivalReasons(<Object?>[]), defaultLateArrivalReasons);
      expect(
        decodeLateArrivalReasons(<Object?>[
          <String, Object?>{'label': '  '},
          'not a map',
        ]),
        defaultLateArrivalReasons,
      );
    });

    test('one damaged entry costs one button, not the list', () {
      expect(
        decodeLateArrivalReasons(<Object?>[
          <String, Object?>{'label': 'Verkeer'},
          <String, Object?>{'valid': false},
          <String, Object?>{'label': 'verkeer', 'valid': false},
        ]),
        const <LateArrivalReason>[LateArrivalReason('Verkeer')],
      );
    });
  });
}
