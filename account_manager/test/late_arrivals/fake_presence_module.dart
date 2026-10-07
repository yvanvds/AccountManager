/// Smartschool's Presence module behind a *real* `SmartschoolClient` (#468).
///
/// The other fakes of the Te laat layer stand in for the library: they throw
/// the library's error types, built by hand. This one stands in for
/// Smartschool. It is the `dio` adapter of a client the library made, so every
/// request the library's own `PresenceService` sends ends here, and the error
/// that comes out of a write is the one the library throws for that answer.
/// That is the thing a bump of `flutter_smartschool` can move under the drain:
/// until dartschool#143 a `500` with a JSON body was read as the module's
/// answer, and the drain gave the registration up as refused.
///
/// Nothing reaches the network: a path the module does not know is answered
/// with a `404` here, never sent on. The answers have the shapes of the
/// library's own offline tests of the module (dartschool
/// `test/presence_unreadable_answer_test.dart`); the pupils are made up.
///
/// Shared by the writer's unit tests and the `Te laat` end-to-end group, so
/// both read the same module.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_smartschool/flutter_smartschool.dart' as ss;

/// One answer of the module, as the wire carries it.
typedef PresenceAnswer = ({int status, String body});

/// A Presence module that holds one class, records nothing until it is sent a
/// save, and carries out every save it is sent unless told otherwise.
class FakePresenceModule implements HttpClientAdapter {
  FakePresenceModule({
    this.classGroupId = 77,
    this.className = '3MTa',
    Iterable<int> pupils = const <int>[12016, 12017],
  }) : pupils = List<int>.unmodifiable(pupils);

  static const String getConfigPath = '/Presence/Main/getConfig';
  static const String getAllCodesPath = '/Presence/Code/getAllCodes';
  static const String getClassPath = '/Presence/Class/getClass';
  static const String savePath = '/Presence/Class/savePupilsPresences';

  /// A JSON body with an error status: what dartschool#143 is about. The body
  /// decodes, so before that fix the library read it as the module's answer.
  static const PresenceAnswer internalServerError = (
    status: 500,
    body: '{"message":"Internal Server Error"}',
  );

  /// A save the module refuses with its own `errors[]`, under an error status:
  /// still a refused save after dartschool#143, whatever the status.
  static PresenceAnswer refusedSave(String message, {int status = 500}) => (
        status: status,
        body: jsonEncode(<String, Object?>{
          'hasErrors': true,
          'errors': <Object?>[
            <String, Object?>{'message': message},
          ],
          'pupils': <Object?>[],
        }),
      );

  /// The official class the module lists, by its Presence group id.
  final int classGroupId;
  final String className;

  /// The internal user ids of the class's pupils.
  final List<int> pupils;

  /// The answers the next requests to a path get instead of the module's own,
  /// first one first.
  final Map<String, List<PresenceAnswer>> _instead =
      <String, List<PresenceAnswer>>{};

  /// Every request, as `METHOD path`.
  final List<String> requests = <String>[];

  /// The internal user ids of the saves the module carried out, in order.
  final List<int> saved = <int>[];

  /// Every client [createClient] made, for a test to dispose of.
  final List<ss.SmartschoolClient> clients = <ss.SmartschoolClient>[];

  int _nextPresenceId = 95001;

  /// The requests to [path] so far.
  int requestsTo(String path) =>
      requests.where((String r) => r.endsWith(' $path')).length;

  /// Answers the next [times] requests to [path] with [answer] instead of the
  /// module's own. A save answered this way is not carried out.
  void answerNext(String path, PresenceAnswer answer, {int times = 1}) {
    (_instead[path] ??= <PresenceAnswer>[])
        .addAll(List<PresenceAnswer>.filled(times, answer));
  }

  /// A client of the library's own making whose requests come here: a
  /// `SmartschoolClientFactory`, for `LiveSmartschoolPresenceSession`.
  Future<ss.SmartschoolClient> createClient(
    ss.Credentials credentials, {
    String? cacheDir,
  }) async {
    final ss.SmartschoolClient client =
        await ss.SmartschoolClient.create(credentials, cacheDir: cacheDir);
    // Before anything is sent: nothing the client does may reach the network.
    client.dio.httpClientAdapter = this;
    clients.add(client);
    return client;
  }

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final String path = options.uri.path;
    requests.add('${options.method} $path');
    final List<PresenceAnswer>? instead = _instead[path];
    if (instead != null && instead.isNotEmpty) {
      final PresenceAnswer answer = instead.removeAt(0);
      return _json(answer.body, status: answer.status);
    }
    final Object? data = options.data;
    final Map<String, String> form = <String, String>{
      if (data is Map)
        for (final MapEntry<Object?, Object?> e in data.entries)
          '${e.key}': '${e.value}',
    };
    return switch (path) {
      getConfigPath => _json(_config()),
      getAllCodesPath => _json(_codes),
      getClassPath => _json(jsonEncode(_class())),
      savePath => _json(jsonEncode(_carryOut(form['pupils'] ?? '[]'))),
      _ => _json('{}', status: 404),
    };
  }

  @override
  void close({bool force = false}) {}

  static ResponseBody _json(String body, {int status = 200}) =>
      ResponseBody.fromString(
        body,
        status,
        headers: <String, List<String>>{
          Headers.contentTypeHeader: <String>[Headers.jsonContentType],
        },
      );

  String _config() => jsonEncode(<String, Object?>{
        'hasErrors': false,
        'errors': <Object?>[],
        'state': <String, Object?>{
          'activeClass': <String, Object?>{
            'groupID': -2,
            'name': 'Uit Planner',
            'structID': null,
          },
          'schoolyear': '2026-09-01',
        },
        'main': <String, Object?>{
          'allowedClasses': <Object?>[
            <String, Object?>{
              'groupID': classGroupId,
              'name': className,
              'isOfficial': 1,
              'userCanConfirm': true,
              'userCanRecord': true,
              'structID': 311,
            },
          ],
        },
      });

  static const String _codes = '''
[{"codeID":70,"code":"|","name":"Aanwezig","structID":311,"alias":[]},
 {"codeID":497,"code":"L","name":"Te laat","structID":311,"alias":[
   {"aliasID":14,"codeID":497,"code":"  ","name":"Te laat zonder geldige reden",
    "dateDeleted":null,"codeOrder":0}]}]
''';

  /// The class as `getClass` lists it: every pupil, nothing recorded yet.
  Map<String, Object?> _class() => <String, Object?>{
        'groupID': classGroupId,
        'name': className,
        'structID': 311,
        'errorMessage': '',
        'saveIsAllowed': true,
        'pupils': <Object?>[
          for (final int userId in pupils)
            <String, Object?>{
              'movementID': userId + 100000,
              'userID': userId,
              'name': 'Leerling $userId',
              'presence': <Object?>[],
            },
        ],
      };

  /// Carries out the save of [pupilsJson] and answers it as the module does:
  /// the records as stored, and no errors.
  Map<String, Object?> _carryOut(String pupilsJson) {
    final List<Map<String, Object?>> sent =
        (jsonDecode(pupilsJson) as List<Object?>).cast<Map<String, Object?>>();
    return <String, Object?>{
      'hasErrors': false,
      'errors': <Object?>[],
      'pupils': <Object?>[
        for (final Map<String, Object?> pupil in sent)
          <String, Object?>{
            'userID': pupil['userID'],
            'movementID': pupil['movementID'],
            'presence': <Object?>[
              for (final Map<String, Object?> presence
                  in (pupil['presence']! as List<Object?>)
                      .cast<Map<String, Object?>>())
                _store(pupil['userID']! as int, presence),
            ],
          },
      ],
    };
  }

  Map<String, Object?> _store(int userId, Map<String, Object?> presence) {
    saved.add(userId);
    return <String, Object?>{
      ...presence,
      'presenceID': presence['presenceID'] ?? _nextPresenceId++,
      'studentID': userId,
    };
  }
}
