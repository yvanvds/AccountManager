import 'package:account_manager/src/update/release_notes.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'update_fakes.dart';

/// The small Markdown reader behind **Wat is er nieuw** (#395).
///
/// The claim it has to make is narrow and worth stating: a release body written
/// the way `.github/workflows/release.yml` writes them must not reach an
/// operator as raw `##` and `-`. Everything below is that body's constructs, one
/// at a time, plus the degradation rule — anything it does not understand still
/// renders as the characters the author typed.
void main() {
  group('parseReleaseNotes', () {
    test('an empty body parses to nothing at all', () {
      expect(parseReleaseNotes(''), isEmpty);
      expect(parseReleaseNotes('   \n\n  \n'), isEmpty);
    });

    test('headings carry their depth, without the hashes', () {
      final List<ReleaseNoteBlock> blocks = parseReleaseNotes(
        '# Versie 1.2.0\n## Nieuw\n### Klein\n',
      );
      expect(blocks.map((b) => b.kind),
          everyElement(ReleaseNoteBlockKind.heading));
      expect(blocks.map((b) => b.level), <int>[1, 2, 3]);
      expect(blocks.map((b) => b.plainText),
          <String>['Versie 1.2.0', 'Nieuw', 'Klein']);
    });

    test('bullets keep their nesting and lose their dash', () {
      final List<ReleaseNoteBlock> blocks = parseReleaseNotes(
        '- Wachtwoordbladen tonen de WiFi.\n'
        '  - Ook op de tweede pagina.\n'
        '* Een ster telt ook.\n',
      );
      expect(
          blocks.map((b) => b.kind), everyElement(ReleaseNoteBlockKind.bullet));
      expect(blocks.map((b) => b.level), <int>[0, 1, 0]);
      expect(blocks.map((b) => b.marker), everyElement('•'));
      expect(blocks.first.plainText, 'Wachtwoordbladen tonen de WiFi.');
    });

    test('a numbered list keeps its own numbers', () {
      final List<ReleaseNoteBlock> blocks = parseReleaseNotes(
        '1. Meer informatie\n2. Toch uitvoeren\n',
      );
      expect(blocks.map((b) => b.marker), <String>['1.', '2.']);
      expect(blocks.last.plainText, 'Toch uitvoeren');
    });

    test('hard-wrapped prose becomes one paragraph, not one line each', () {
      // The reason this matters: the dialog wraps at its own width, so a body
      // wrapped at 80 columns must not arrive pre-broken.
      final List<ReleaseNoteBlock> blocks = parseReleaseNotes(
        'De eerste regel\nloopt door op de tweede.\n\nEen tweede alinea.\n',
      );
      expect(blocks, hasLength(2));
      expect(
          blocks.first.plainText, 'De eerste regel loopt door op de tweede.');
      expect(blocks.last.plainText, 'Een tweede alinea.');
    });

    test('a --- rule is a rule, not a bullet', () {
      final List<ReleaseNoteBlock> blocks = parseReleaseNotes('a\n\n---\n\nb');
      expect(blocks.map((b) => b.kind), <ReleaseNoteBlockKind>[
        ReleaseNoteBlockKind.paragraph,
        ReleaseNoteBlockKind.rule,
        ReleaseNoteBlockKind.paragraph,
      ]);
    });

    test('a fenced block is kept verbatim, line breaks and all', () {
      final List<ReleaseNoteBlock> blocks = parseReleaseNotes(
        'Draai:\n\n```powershell\ngit tag v1.1.0\ngit push origin v1.1.0\n```\n',
      );
      expect(blocks.last.kind, ReleaseNoteBlockKind.code);
      expect(blocks.last.text, 'git tag v1.1.0\ngit push origin v1.1.0');
    });

    test('a table it cannot read still reaches the operator as text', () {
      // The degradation rule: unsupported is not invisible.
      final List<ReleaseNoteBlock> blocks =
          parseReleaseNotes('| a | b |\n| - | - |\n');
      expect(blocks.map((b) => b.plainText).join(' '), contains('| a | b |'));
    });
  });

  group('parseReleaseNoteSpans', () {
    test('bold, italic and code come back marked', () {
      expect(
        parseReleaseNoteSpans('**vet** en *schuin* en `code`'),
        <ReleaseNoteSpan>[
          const ReleaseNoteSpan('vet', bold: true),
          const ReleaseNoteSpan(' en '),
          const ReleaseNoteSpan('schuin', italic: true),
          const ReleaseNoteSpan(' en '),
          const ReleaseNoteSpan('code', code: true),
        ],
      );
    });

    test('a Markdown link keeps its label and its target', () {
      final List<ReleaseNoteSpan> spans =
          parseReleaseNoteSpans('Zie [de release](https://example.test/v1).');
      expect(spans[1].text, 'de release');
      expect(spans[1].href, 'https://example.test/v1');
      expect(spans.last.text, '.');
    });

    test('a bare URL becomes a link without being written as one', () {
      final List<ReleaseNoteSpan> spans =
          parseReleaseNoteSpans('Meer op https://example.test/notes vandaag');
      expect(spans[1].href, 'https://example.test/notes');
      expect(spans[1].text, 'https://example.test/notes');
    });

    test('an unclosed ** stays literal instead of emboldening the rest', () {
      final List<ReleaseNoteSpan> spans = parseReleaseNoteSpans('a ** b');
      expect(spans.single, const ReleaseNoteSpan('a ** b'));
    });

    test('an underscore inside an identifier is not emphasis', () {
      // `employee_id` and `SSM_dynamic_lln` appear in these notes far more often
      // than emphasis does.
      final List<ReleaseNoteSpan> spans =
          parseReleaseNoteSpans('zet employee_id op de gebruiker');
      expect(spans.single.text, 'zet employee_id op de gebruiker');
      expect(spans.single.italic, isFalse);
    });

    test('a backslash escapes the character behind it', () {
      expect(parseReleaseNoteSpans(r'2 \* 3').single.text, '2 * 3');
    });
  });

  group('ReleaseNotesDialog', () {
    Widget wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

    testWidgets('renders the version, the notes and the GitHub link',
        (WidgetTester tester) async {
      await tester.pumpWidget(wrap(ReleaseNotesDialog(
        release: fakeRelease(
          '1.2.0',
          notes: '## Nieuw\n\n- Wachtwoordbladen tonen de WiFi.',
          pageUrl: 'https://example.test/v1.2.0',
        ),
      )));
      await tester.pumpAndSettle();

      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('release-notes-version')))
            .data,
        'Versie 1.2.0',
      );
      // The headings and bullets are *rendered*, not echoed.
      expect(find.textContaining('##'), findsNothing);
      expect(find.textContaining('Nieuw', findRichText: true), findsWidgets);
      expect(find.byKey(const ValueKey('release-notes-page')), findsOneWidget);
    });

    testWidgets('the GitHub link opens the release page and nothing else',
        (WidgetTester tester) async {
      final List<Uri> opened = <Uri>[];
      await tester.pumpWidget(wrap(ReleaseNotesDialog(
        release: fakeRelease('1.2.0',
            notes: 'iets', pageUrl: 'https://example.test/v1.2.0'),
        onOpenLink: (Uri url) async => opened.add(url),
      )));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('release-notes-page')));
      await tester.pumpAndSettle();
      expect(opened, <Uri>[Uri.parse('https://example.test/v1.2.0')]);
    });

    testWidgets('a release with no page URL offers no link',
        (WidgetTester tester) async {
      await tester.pumpWidget(wrap(ReleaseNotesDialog(
        release: fakeRelease('1.2.0', notes: 'iets', pageUrl: ''),
      )));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('release-notes-page')), findsNothing);
      expect(find.byKey(const ValueKey('release-notes-close')), findsOneWidget);
    });
  });
}
