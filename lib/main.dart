import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app.dart';
import 'core/storage/creds_store.dart';
import 'core/storage/prefs_store.dart';

/// Punto de entrada.
///
/// `FlutterBinding.ensureInitialized()` + orientation portrait (una app de
/// chat: el landscape no aporta y cuesta batería). Después carga preferencias
/// y arranca [OpenHerMobileApp].
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);
  // El composer tiene que quedar visible con el teclado abierto.
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      systemNavigationBarColor: Colors.transparent,
    ),
  );

  final prefs = await PrefsStore.load();
  runApp(OpenHerMobileApp(prefs: prefs, creds: CredsStore()));
}
