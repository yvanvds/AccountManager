/// Redaction shared by everything that may put Smartschool wire text into a
/// log line.
///
/// Its own file because both halves of the SOAP layer need it and neither owns
/// it: the transport redacts a non-2xx **body** (which routinely echoes the
/// request envelope back), and the envelope layer redacts a **faultstring**
/// (which is server-authored text that may quote what we sent). Before #361
/// only the transport had it, so a fault that reached a log line carried
/// whatever Smartschool chose to put in it.
library;

/// Replaces the contents of `<accesscode>…</accesscode>` elements with
/// `[REDACTED]`. Used by the SOAP exceptions and the capture script.
/// Conservative — runs on plain strings, never throws.
String redactAccessCode(String input) {
  return input.replaceAllMapped(
    RegExp(r'(<accesscode[^>]*>).*?(</accesscode>)', dotAll: true),
    (m) => '${m.group(1)}[REDACTED]${m.group(2)}',
  );
}
