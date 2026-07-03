import 'dart:io';

import 'package:account_state/account_state.dart';
import 'package:test/test.dart';

/// The identity seam is re-exported from `account_state`, so a consumer gets
/// `PersonIdResolver` and its file-backed default without a second import.
void main() {
  test('FilePersonIdResolver is reachable via the barrel and resolves ids',
      () async {
    final tmp = Directory.systemTemp.createTempSync('account_state_pid');
    addTearDown(() => tmp.deleteSync(recursive: true));

    final PersonIdResolver resolver =
        await FilePersonIdResolver.load('${tmp.path}/person_ids.json');
    final id = resolver.resolve('wisa:123');

    expect(id, isA<PersonId>());
    expect(id.value, isNotEmpty);
    expect(resolver.resolve('wisa:123'), equals(id));
  });
}
