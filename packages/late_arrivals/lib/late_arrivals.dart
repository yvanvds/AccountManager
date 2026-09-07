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
/// Pure Dart — no Flutter, no I/O. The snapshot the index is built from is
/// handed in and the journal's files live behind a [JournalStore]; this package
/// never reaches for application state or for a path.
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
export 'src/journal/school_day.dart' show SchoolDay;
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
