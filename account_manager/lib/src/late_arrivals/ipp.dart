/// Just enough IPP to hand one document to one printer (#424).
///
/// Not an IPP library. IPP/1.1 (RFC 8011) is a large protocol with job
/// management, subscriptions and a hundred printer attributes; a reception desk
/// needs exactly one operation — `Print-Job` — and needs to know whether it
/// worked. Everything here is that operation and that answer, encoded by hand
/// so the whole wire format stays readable in one screen and assertable without
/// a printer on the network.
///
/// **The document is opaque.** The ESC/POS bytes `composeLateArrivalTicket`
/// produces ride through unchanged as `application/octet-stream`; IPP is a
/// wrapper, not a translation. That is what makes this a transport swap rather
/// than a redesign of the ticket.
library;

import 'dart:convert';
import 'dart:typed_data';

/// IPP `Print-Job`. The one operation this app performs.
const int ippPrintJobOperation = 0x0002;

/// IPP `successful-ok`. Anything else is a refusal, however cheerful the HTTP
/// status was — see [ippStatusOf].
const int ippSuccessfulOk = 0x0000;

/// The IPP version this speaks: 1.1, as major/minor bytes.
const int ippVersionMajor = 0x01;
const int ippVersionMinor = 0x01;

/// Delimiter tags (RFC 8011 §4.1.4).
const int _operationAttributesTag = 0x01;
const int _endOfAttributesTag = 0x03;

/// The value tags this needs (RFC 8011 §4.1.6).
const int _tagNameWithoutLanguage = 0x42;
const int _tagUri = 0x45;
const int _tagCharset = 0x47;
const int _tagNaturalLanguage = 0x48;
const int _tagMimeMediaType = 0x49;

/// The MIME type the ticket is declared as.
///
/// `application/octet-stream` on purpose: it tells the printer "do not
/// interpret this, hand it to the print engine", which is what makes the
/// ESC/POS stream come out as the ticket it was composed to be. Declaring it as
/// anything the printer thinks it understands invites a raster pipeline that
/// would reflow the layout.
const String ippOctetStream = 'application/octet-stream';

/// Builds the complete IPP `Print-Job` request body for [document].
///
/// The result is the IPP header, the operation attributes, and then the
/// document itself — one buffer, POSTed as a whole, because the printer answers
/// only after the last byte and a chunked write buys nothing on a LAN.
///
/// Attribute order is not decorative: RFC 8011 §4.1.4 requires
/// `attributes-charset` first and `attributes-natural-language` second, and
/// several embedded IPP servers reject a group that arrives in any other order.
Uint8List buildIppPrintJobRequest({
  required String printerUri,
  required String requestingUserName,
  required List<int> document,
  int requestId = 1,
  String documentFormat = ippOctetStream,
}) {
  final BytesBuilder out = BytesBuilder(copy: false);
  out
    ..addByte(ippVersionMajor)
    ..addByte(ippVersionMinor)
    ..add(_uint16(ippPrintJobOperation))
    ..add(_uint32(requestId))
    ..addByte(_operationAttributesTag);
  _attribute(out, _tagCharset, 'attributes-charset', 'utf-8');
  _attribute(out, _tagNaturalLanguage, 'attributes-natural-language', 'en');
  _attribute(out, _tagUri, 'printer-uri', printerUri);
  _attribute(
    out,
    _tagNameWithoutLanguage,
    'requesting-user-name',
    requestingUserName,
  );
  _attribute(out, _tagMimeMediaType, 'document-format', documentFormat);
  out
    ..addByte(_endOfAttributesTag)
    ..add(document);
  return out.takeBytes();
}

/// The IPP status code in an IPP response, or `null` when [response] is too
/// short to carry one.
///
/// **This is the check that matters.** The TM-m30III answers HTTP 200 to a
/// request it then refuses; success is the two bytes at offset 2–3 being
/// [ippSuccessfulOk], and nothing else says so. A `null` here means the printer
/// answered with something that is not an IPP response at all — a proxy page, a
/// truncated body — which is a failure too, just a less specific one.
int? ippStatusOf(List<int> response) {
  if (response.length < 4) return null;
  return (response[2] << 8) | response[3];
}

/// Whether an IPP status code is one of the `successful-*` codes.
///
/// 0x0000–0x00ff is the successful range (RFC 8011 §14.1.1);
/// `successful-ok-ignored-or-substituted-attributes` (0x0001) lands there, and
/// it means the ticket printed while some attribute was quietly ignored —
/// which is not something to fail a student's ticket over.
bool isIppSuccess(int? status) =>
    status != null && status >= 0x0000 && status <= 0x00ff;

/// The `printer-uri` for a printer reached over TLS at [host]:[port].
///
/// `ipps` rather than `ipp`, because the transport is HTTPS: RFC 8011 §4.1.5
/// ties the scheme to how the request actually travelled, and the printer
/// refuses plain HTTP on 631 outright.
String ippsPrinterUri({
  required String host,
  required int port,
  required String path,
}) =>
    'ipps://$host:$port$path';

/// One IPP attribute: value tag, name, value — each length-prefixed.
void _attribute(BytesBuilder out, int tag, String name, String value) {
  final List<int> nameBytes = utf8.encode(name);
  final List<int> valueBytes = utf8.encode(value);
  out
    ..addByte(tag)
    ..add(_uint16(nameBytes.length))
    ..add(nameBytes)
    ..add(_uint16(valueBytes.length))
    ..add(valueBytes);
}

Uint8List _uint16(int value) =>
    Uint8List.fromList(<int>[(value >> 8) & 0xff, value & 0xff]);

Uint8List _uint32(int value) => Uint8List.fromList(<int>[
      (value >> 24) & 0xff,
      (value >> 16) & 0xff,
      (value >> 8) & 0xff,
      value & 0xff,
    ]);
