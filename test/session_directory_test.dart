/// El `location[directory]` que el chat manda al server.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:openher_mobile/domain/models/message.dart';
import 'package:openher_mobile/domain/models/session.dart';

SessionInfo _ses({String directory = '', String? legacy}) => SessionInfo(
  id: 'ses_1',
  projectID: 'prj_1',
  title: 't',
  cost: 0,
  tokens: const TokenUsage(),
  time: const SessionTime(createdMs: 0, updatedMs: 0),
  location: SessionLocation(directory: directory),
  legacyDirectory: legacy,
);

void main() {
  group('SessionInfo.chatDirectory', () {
    test('location.directory manda', () {
      expect(
        _ses(directory: r'C:\Users\perca').chatDirectory,
        r'C:\Users\perca',
      );
    });

    test('vacio cae al legacy', () {
      expect(_ses(legacy: r'D:\proy').chatDirectory, r'D:\proy');
    });

    test('sin nada es null (el server resuelve)', () {
      expect(_ses().chatDirectory, isNull);
    });
  });
}
