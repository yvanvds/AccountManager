/// The **Wat is er nieuw** dialog and the small Markdown reader behind it
/// (#395).
///
/// The updater (#371) already applies a new version and drops the operator back
/// into an app that looks identical; everything that changed had to be told to
/// them out of band. This is the in-app half of that: after an update, the first
/// launch of the new version shows the release's own notes, once.
///
/// Three decisions worth reading before changing anything here:
///
/// - **The notes are not translated.** They are written once, on the release,
///   in whatever language they were written in. A translation layer for a
///   handful of operators would cost more than it returns.
/// - **Markdown, but only just.** Release bodies are written in it — `##`
///   headings, `-` bullets, `**bold**`, links — and rendering those raw reads as
///   broken rather than as plain text. So the reader below handles exactly that
///   list and nothing else. It is deliberately *not* a Markdown package: the
///   only author of these documents is our own release workflow, the surface it
///   has to cover is one dialog, and the alternative (`flutter_markdown`) is
///   discontinued.
/// - **Anything it cannot parse still reads.** Every unrecognised construct
///   falls through to its own literal text, so an unsupported table or image
///   degrades to the characters the author typed rather than to nothing.
library;

import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:plink_design_system/plink_design_system.dart';

import 'app_release.dart';

// ---------------------------------------------------------------------------
// The document
// ---------------------------------------------------------------------------

/// One run of text inside a block, with whatever emphasis was around it.
@immutable
class ReleaseNoteSpan {
  const ReleaseNoteSpan(
    this.text, {
    this.bold = false,
    this.italic = false,
    this.code = false,
    this.href,
  });

  final String text;
  final bool bold;
  final bool italic;
  final bool code;

  /// Where this run points, for a `[label](url)` or a bare URL — `null` for
  /// ordinary text.
  final String? href;

  @override
  bool operator ==(Object other) =>
      other is ReleaseNoteSpan &&
      other.text == text &&
      other.bold == bold &&
      other.italic == italic &&
      other.code == code &&
      other.href == href;

  @override
  int get hashCode => Object.hash(text, bold, italic, code, href);

  @override
  String toString() => 'ReleaseNoteSpan("$text"'
      '${bold ? ', bold' : ''}${italic ? ', italic' : ''}'
      '${code ? ', code' : ''}${href == null ? '' : ', href: $href'})';
}

/// What kind of block a line (or run of lines) turned out to be.
enum ReleaseNoteBlockKind {
  /// A `#`…`######` heading. [ReleaseNoteBlock.level] carries how deep.
  heading,

  /// A run of ordinary prose.
  paragraph,

  /// A `-`, `*`, `+` or `1.` list item. [ReleaseNoteBlock.marker] carries the
  /// bullet or number to draw, [ReleaseNoteBlock.level] the nesting depth.
  bullet,

  /// A fenced (```` ``` ````) block, kept verbatim.
  code,

  /// A `---` horizontal rule.
  rule,
}

/// One parsed block of a release body.
@immutable
class ReleaseNoteBlock {
  const ReleaseNoteBlock({
    required this.kind,
    this.spans = const <ReleaseNoteSpan>[],
    this.level = 0,
    this.marker = '',
    this.text = '',
  });

  final ReleaseNoteBlockKind kind;

  /// The block's inline content — empty for [ReleaseNoteBlockKind.code] and
  /// [ReleaseNoteBlockKind.rule].
  final List<ReleaseNoteSpan> spans;

  /// Heading depth (1..6) or list nesting depth (0-based).
  final int level;

  /// What a bullet draws in its gutter: `•` for an unordered item, `1.` for an
  /// ordered one.
  final String marker;

  /// The verbatim body of a code block.
  final String text;

  /// This block's content as plain text, which is what a test asserts on and
  /// what the dialog's semantics fall back to.
  String get plainText => kind == ReleaseNoteBlockKind.code
      ? text
      : spans.map((s) => s.text).join();

  @override
  String toString() => 'ReleaseNoteBlock($kind, level: $level, "$plainText")';
}

// ---------------------------------------------------------------------------
// The reader
// ---------------------------------------------------------------------------

final RegExp _headingPattern = RegExp(r'^(#{1,6})\s+(.*)$');
final RegExp _bulletPattern = RegExp(r'^(\s*)[-*+]\s+(.*)$');
final RegExp _orderedPattern = RegExp(r'^(\s*)(\d{1,3})[.)]\s+(.*)$');
final RegExp _rulePattern = RegExp(r'^\s*(-{3,}|\*{3,}|_{3,})\s*$');
final RegExp _fencePattern = RegExp('^\\s*(```|~~~)');
final RegExp _linkPattern = RegExp(r'\[([^\]]*)\]\(([^)\s]+)\)');
final RegExp _bareUrlPattern = RegExp(r'https?://[^\s<>()\[\]]+');

/// Reads a release body into blocks the dialog can draw.
///
/// Never throws and never returns `null`: an unparseable body is still a body,
/// and a "what's new" that could fail is worse than one that renders oddly.
List<ReleaseNoteBlock> parseReleaseNotes(String source) {
  final List<ReleaseNoteBlock> blocks = <ReleaseNoteBlock>[];
  final List<String> lines = source.replaceAll('\r\n', '\n').split('\n');

  // Consecutive prose lines are one paragraph — Markdown's soft wrap, and the
  // reason a hard-wrapped release body must not render as one line per source
  // line inside a dialog that wraps at its own width.
  final List<String> paragraph = <String>[];
  void flushParagraph() {
    if (paragraph.isEmpty) return;
    blocks.add(ReleaseNoteBlock(
      kind: ReleaseNoteBlockKind.paragraph,
      spans: parseReleaseNoteSpans(paragraph.join(' ')),
    ));
    paragraph.clear();
  }

  for (var i = 0; i < lines.length; i++) {
    final String line = lines[i];
    final String trimmed = line.trim();

    if (_fencePattern.hasMatch(line)) {
      flushParagraph();
      final List<String> body = <String>[];
      i++;
      while (i < lines.length && !_fencePattern.hasMatch(lines[i])) {
        body.add(lines[i]);
        i++;
      }
      blocks.add(ReleaseNoteBlock(
        kind: ReleaseNoteBlockKind.code,
        text: body.join('\n'),
      ));
      continue;
    }

    if (trimmed.isEmpty) {
      flushParagraph();
      continue;
    }

    // Before the bullet pattern: `***` and `---` are rules, not list items.
    if (_rulePattern.hasMatch(line)) {
      flushParagraph();
      blocks.add(const ReleaseNoteBlock(kind: ReleaseNoteBlockKind.rule));
      continue;
    }

    final RegExpMatch? heading = _headingPattern.firstMatch(trimmed);
    if (heading != null) {
      flushParagraph();
      blocks.add(ReleaseNoteBlock(
        kind: ReleaseNoteBlockKind.heading,
        level: heading.group(1)!.length,
        spans: parseReleaseNoteSpans(heading.group(2)!.trim()),
      ));
      continue;
    }

    final RegExpMatch? bullet = _bulletPattern.firstMatch(line);
    if (bullet != null) {
      flushParagraph();
      blocks.add(ReleaseNoteBlock(
        kind: ReleaseNoteBlockKind.bullet,
        level: bullet.group(1)!.length ~/ 2,
        marker: '•',
        spans: parseReleaseNoteSpans(bullet.group(2)!.trim()),
      ));
      continue;
    }

    final RegExpMatch? ordered = _orderedPattern.firstMatch(line);
    if (ordered != null) {
      flushParagraph();
      blocks.add(ReleaseNoteBlock(
        kind: ReleaseNoteBlockKind.bullet,
        level: ordered.group(1)!.length ~/ 2,
        marker: '${ordered.group(2)}.',
        spans: parseReleaseNoteSpans(ordered.group(3)!.trim()),
      ));
      continue;
    }

    paragraph.add(trimmed);
  }
  flushParagraph();
  return blocks;
}

/// Reads one line's inline Markdown: `` `code` ``, `**bold**`, `*italic*`,
/// `[label](url)`, and bare `http(s)://` URLs.
///
/// An opener with no closer stays literal — a stray `**` in prose must not
/// embolden the rest of the release.
List<ReleaseNoteSpan> parseReleaseNoteSpans(String source) {
  final List<ReleaseNoteSpan> spans = <ReleaseNoteSpan>[];
  final StringBuffer buffer = StringBuffer();
  var bold = false;
  var italic = false;
  // Which of `**` / `__` opened the current bold run, so its *closer* is read as
  // a closer rather than re-tested as a fresh opener — the second `**` of a pair
  // has no third one after it, and without this it fell through to the
  // single-`*` italic branch.
  String? boldFence;

  void flush() {
    if (buffer.isEmpty) return;
    spans.add(ReleaseNoteSpan(buffer.toString(), bold: bold, italic: italic));
    buffer.clear();
  }

  var i = 0;
  while (i < source.length) {
    final String char = source[i];

    if (char == r'\' && i + 1 < source.length) {
      buffer.write(source[i + 1]);
      i += 2;
      continue;
    }

    if (char == '`') {
      final int end = source.indexOf('`', i + 1);
      if (end > i + 1) {
        flush();
        spans.add(ReleaseNoteSpan(source.substring(i + 1, end), code: true));
        i = end + 1;
        continue;
      }
    }

    if (char == '[') {
      final Match? link = _linkPattern.matchAsPrefix(source, i);
      if (link != null) {
        flush();
        spans.add(ReleaseNoteSpan(
          link.group(1)!.isEmpty ? link.group(2)! : link.group(1)!,
          bold: bold,
          italic: italic,
          href: link.group(2),
        ));
        i = link.end;
        continue;
      }
    }

    if (char == 'h') {
      final Match? url = _bareUrlPattern.matchAsPrefix(source, i);
      if (url != null) {
        flush();
        final String text = url.group(0)!;
        spans.add(ReleaseNoteSpan(text, href: text));
        i = url.end;
        continue;
      }
    }

    if (source.startsWith('**', i) || source.startsWith('__', i)) {
      final String fence = source.substring(i, i + 2);
      if (boldFence == fence) {
        flush();
        bold = false;
        boldFence = null;
        i += 2;
        continue;
      }
      if (boldFence == null && source.indexOf(fence, i + 2) > 0) {
        flush();
        bold = true;
        boldFence = fence;
        i += 2;
        continue;
      }
      // An opener with no closer: both characters stay literal, and — the point
      // of writing them here rather than falling through — the second one does
      // not get read as an italic marker either.
      buffer.write(fence);
      i += 2;
      continue;
    }

    // Single `*` only. A lone `_` stays literal on purpose: `employee_id` and
    // `SSM_dynamic_lln` appear in these notes far more often than emphasis does.
    if (char == '*' && (italic || source.indexOf('*', i + 1) > 0)) {
      flush();
      italic = !italic;
      i += 1;
      continue;
    }

    buffer.write(char);
    i += 1;
  }
  flush();
  return spans;
}

// ---------------------------------------------------------------------------
// The dialog
// ---------------------------------------------------------------------------

/// Opens [url] in the operator's default browser.
///
/// Best effort and deliberately silent: a link in a "what's new" that will not
/// open is a disappointment, not a failure worth a second dialog on top of the
/// first.
Future<void> openReleasePage(Uri url) async {
  try {
    if (Platform.isWindows) {
      await Process.start('rundll32', <String>[
        'url.dll,FileProtocolHandler',
        url.toString(),
      ]);
      return;
    }
    await Process.start(
      Platform.isMacOS ? 'open' : 'xdg-open',
      <String>[url.toString()],
    );
  } on Object {
    // See above.
  }
}

/// Draws a parsed release body.
class ReleaseNotesBody extends StatelessWidget {
  const ReleaseNotesBody({
    super.key,
    required this.notes,
    this.onOpenLink,
  });

  /// The release body, as written on the release.
  final String notes;

  /// What a tapped link does; defaults to [openReleasePage]. A seam so a test
  /// can prove the link points where it says without launching a browser.
  final Future<void> Function(Uri url)? onOpenLink;

  @override
  Widget build(BuildContext context) {
    final List<ReleaseNoteBlock> blocks = parseReleaseNotes(notes);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        for (final ReleaseNoteBlock block in blocks) _block(context, block),
      ],
    );
  }

  Widget _block(BuildContext context, ReleaseNoteBlock block) {
    final TextTheme text = Theme.of(context).textTheme;
    final ColorScheme colors = Theme.of(context).colorScheme;

    switch (block.kind) {
      case ReleaseNoteBlockKind.rule:
        return const Padding(
          padding: EdgeInsets.symmetric(vertical: PlinkSpacing.s3),
          child: Divider(height: 1),
        );
      case ReleaseNoteBlockKind.code:
        return Padding(
          padding: const EdgeInsets.only(bottom: PlinkSpacing.s3),
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.all(PlinkSpacing.s3),
            decoration: BoxDecoration(
              color: colors.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(4),
            ),
            child: SelectableText(
              block.text,
              style: text.bodySmall?.copyWith(fontFamily: 'monospace'),
            ),
          ),
        );
      case ReleaseNoteBlockKind.heading:
        return Padding(
          padding: const EdgeInsets.only(
            top: PlinkSpacing.s3,
            bottom: PlinkSpacing.s2,
          ),
          child: Text.rich(
            _inline(
              context,
              block.spans,
              base: (block.level <= 2 ? text.titleMedium : text.titleSmall)
                  ?.copyWith(color: colors.onSurface),
            ),
          ),
        );
      case ReleaseNoteBlockKind.paragraph:
        return Padding(
          padding: const EdgeInsets.only(bottom: PlinkSpacing.s3),
          child:
              Text.rich(_inline(context, block.spans, base: text.bodyMedium)),
        );
      case ReleaseNoteBlockKind.bullet:
        return Padding(
          padding: EdgeInsets.only(
            left: PlinkSpacing.s3 + block.level * PlinkSpacing.s4,
            bottom: PlinkSpacing.s2,
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              SizedBox(
                width: PlinkSpacing.s5,
                child: Text(block.marker, style: text.bodyMedium),
              ),
              Expanded(
                child: Text.rich(
                  _inline(context, block.spans, base: text.bodyMedium),
                ),
              ),
            ],
          ),
        );
    }
  }

  InlineSpan _inline(
    BuildContext context,
    List<ReleaseNoteSpan> spans, {
    TextStyle? base,
  }) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    return TextSpan(
      style: base,
      children: <InlineSpan>[
        for (final ReleaseNoteSpan span in spans)
          TextSpan(
            text: span.text,
            style: (base ?? const TextStyle()).copyWith(
              fontWeight: span.bold ? FontWeight.w600 : null,
              fontStyle: span.italic ? FontStyle.italic : null,
              fontFamily: span.code ? 'monospace' : null,
              color: span.href != null ? colors.primary : null,
              decoration: span.href != null ? TextDecoration.underline : null,
            ),
            recognizer: span.href == null ? null : _tap(span.href!),
          ),
      ],
    );
  }

  TapGestureRecognizer? _tap(String href) {
    final Uri? url = Uri.tryParse(href);
    if (url == null) return null;
    return TapGestureRecognizer()
      ..onTap = () => (onOpenLink ?? openReleasePage)(url);
  }
}

/// **Wat is er nieuw** — the release notes of the version now running (#395).
///
/// Deliberately an ordinary dismissible dialog and nothing cleverer. It appears
/// once per version, after the update that produced it, and the operator closes
/// it and gets on with the session. It is never a gate: `barrierDismissible` is
/// on, `Sluiten` is the only thing it asks for, and nothing waits on the answer.
class ReleaseNotesDialog extends StatelessWidget {
  const ReleaseNotesDialog({
    super.key,
    required this.release,
    this.onOpenLink,
  });

  /// The release whose notes are shown — its version titles the dialog and its
  /// `pageUrl` is what the GitHub link points at.
  final AppRelease release;

  /// Where a tapped link goes; defaults to the operator's browser.
  final Future<void> Function(Uri url)? onOpenLink;

  /// Shows this dialog over [context], returning when it is closed.
  static Future<void> show(
    BuildContext context,
    AppRelease release, {
    Future<void> Function(Uri url)? onOpenLink,
  }) =>
      showDialog<void>(
        context: context,
        builder: (BuildContext dialogContext) => ReleaseNotesDialog(
          release: release,
          onOpenLink: onOpenLink,
        ),
      );

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    final ColorScheme colors = Theme.of(context).colorScheme;
    final Uri? page = release.pageUrl.trim().isEmpty
        ? null
        : Uri.tryParse(release.pageUrl.trim());

    return AlertDialog(
      key: const ValueKey('release-notes-dialog'),
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          const Text('Wat is er nieuw'),
          const SizedBox(height: PlinkSpacing.s1),
          Text(
            'Versie ${release.version}',
            key: const ValueKey('release-notes-version'),
            style: text.bodyMedium?.copyWith(color: colors.onSurfaceVariant),
          ),
        ],
      ),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          key: const ValueKey('release-notes-body'),
          child: ReleaseNotesBody(
            notes: release.notes,
            onOpenLink: onOpenLink,
          ),
        ),
      ),
      actions: <Widget>[
        if (page != null)
          TextButton.icon(
            key: const ValueKey('release-notes-page'),
            onPressed: () => (onOpenLink ?? openReleasePage)(page),
            icon: const Icon(Icons.open_in_new, size: 18),
            label: const Text('Lees op GitHub'),
          ),
        FilledButton(
          key: const ValueKey('release-notes-close'),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Sluiten'),
        ),
      ],
    );
  }
}
