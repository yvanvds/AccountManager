/// Late-arrival ("te laat") registration support for the Arcadia Account
/// Manager port.
///
/// Two slices so far, and they are the two halves of what happens while the
/// student is still standing at the desk:
///
/// - the **scan resolver** (#401) turns the code a handheld scanner reads off a
///   student card into the student the operator sees and the two identifiers a
///   Smartschool Presence write needs — all from state already in memory, with
///   no network call, because the desk has a queue of students waiting;
/// - the **journal** (#402) appends that registration to disk, flushed, *before*
///   the ticket prints, so a student who walked off with a ticket can never be
///   lost to a crash while the Smartschool write is still queued.
///
/// One slice for what the operator is choosing *between* while they do it:
///
/// - the **reason list** (#405) — a label plus a "counts as a valid reason"
///   flag, ordered, editable, and shared across every desk. The model lives
///   here; the shared document that holds it is `AppSettings`, and the editor
///   is in Instellingen.
///
/// One slice for what the student walks away with:
///
/// - the **ticket** (#406) — name, class, the *scan* time and the school logo,
///   composed into an ESC/POS byte stream by a pure function so the layout can
///   be asserted without a printer on the network. The socket that carries it
///   to port 9100 lives in `account_manager`.
///
/// And one slice for what happens when the machine itself is gone:
///
/// - the **mirror** (#403) copies every journalled record and every status
///   change to the shared store, asynchronously and strictly behind the
///   journal, and reconciles against it at startup — so a colleague on her own
///   laptop can see and finish a queue the dead machine never drained.
///
/// Pure Dart — no Flutter, no I/O. The snapshot the index is built from is
/// handed in, the journal's files live behind a [JournalStore] and the shared
/// copies behind a [LateArrivalMirrorStore]; this package never reaches for
/// application state, for a path, or for the network.
library;

export 'src/journal/journal_store.dart'
    show
        InMemoryJournalStore,
        JournalStore,
        journalFileName,
        schoolDayOfJournalFile;
export 'src/journal/late_arrival_journal.dart'
    show JournalRecovery, LateArrivalJournal;
export 'src/journal/late_arrival_record.dart'
    show LateArrivalRecord, LateArrivalStatus;
export 'src/journal/motivation.dart'
    show composeMotivation, motivationSeparator;
export 'src/journal/record_sink.dart' show LateArrivalRecordSink;
export 'src/journal/school_day.dart' show SchoolDay;
export 'src/mirror/late_arrival_mirror.dart'
    show
        LateArrivalMirror,
        LateArrivalMirrorStatus,
        LateArrivalReconciliation,
        MirrorBackoff;
export 'src/mirror/late_arrival_mirror_store.dart'
    show InMemoryLateArrivalMirrorStore, LateArrivalMirrorStore;
export 'src/mirror/mirrored_registration.dart'
    show MirroredRegistration, normalizeDeskId;
export 'src/reasons/late_arrival_reason.dart'
    show
        LateArrivalReason,
        decodeLateArrivalReasons,
        defaultLateArrivalReasons,
        normalizeLateArrivalReasons;
export 'src/scan_code.dart' show normalizeScanCode;
export 'src/scan_resolver.dart' show ScanResolver;
export 'src/scan_result.dart'
    show
        ScanAmbiguous,
        ScanBlocker,
        ScanEmpty,
        ScanIncomplete,
        ScanRegisterable,
        ScanResult,
        ScanUnknown;
export 'src/scanned_student.dart' show ScannedStudent;
export 'src/ticket/escpos.dart'
    show
        EscPosAlign,
        encodeCp1252,
        esc,
        escPosAlign,
        escPosCharacterSize,
        escPosCodePageWpc1252,
        escPosCut,
        escPosEmphasis,
        escPosFeedLines,
        escPosInitialize,
        escPosRasterImage,
        escPosSelectCodePage,
        gs,
        lf;
export 'src/ticket/late_arrival_ticket.dart'
    show
        composeLateArrivalTicket,
        composeTicketForRecord,
        formatTicketTime,
        ticketClassMagnification,
        ticketNameMagnification,
        ticketTimeMagnification;
export 'src/ticket/ticket_logo.dart'
    show
        TicketLogo,
        defaultTicketLogo,
        defaultTicketLogoArt,
        defaultTicketLogoScale;
export 'src/ticket/ticket_metrics.dart'
    show
        escPosRawPort,
        ticketCutCommandVariant,
        ticketCutFeedDots,
        ticketFeedLinesBeforeCut,
        ticketPaperWidthMm,
        ticketPrintWidthDots;
