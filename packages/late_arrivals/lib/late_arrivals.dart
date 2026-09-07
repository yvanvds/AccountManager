/// Late-arrival ("te laat") registration support for the Arcadia Account
/// Manager port.
///
/// This first slice is the **scan resolver** (#401): it turns the code a
/// handheld scanner reads off a student card into the student the reception
/// desk sees and the two identifiers a Smartschool Presence write needs — all
/// from state already in memory, with no network call, because the desk has a
/// queue of students waiting (epic #399).
///
/// Pure Dart — no Flutter, no I/O. The snapshot the index is built from is
/// handed in; this package never reaches for application state.
library;

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
