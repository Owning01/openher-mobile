import 'dart:async' show unawaited;
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';

import 'app.dart';
import 'core/storage/creds_store.dart';
import 'core/storage/prefs_store.dart';

/// Punto de entrada.
///
/// En móvil se fija portrait (una app de chat: el landscape no aporta y
/// cuesta batería). En Windows se oculta la barra de título nativa (los
/// botones min/max/cerrar y el resize los conserva el sistema) para dibujar
/// las pestañas de chats arriba, estilo Chrome, y se arranca maximizado.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (!kIsWeb && (Platform.isAndroid || Platform.isIOS)) {
    await SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
      DeviceOrientation.portraitDown,
    ]);
  }
  if (!kIsWeb && Platform.isWindows) {
    await windowManager.ensureInitialized();
    await windowManager.setTitle('OpenHer');
    // Oculta el título pero conserva los 3 botones y el marco
    // redimensionable nativos: las pestañas van en ese hueco.
    await windowManager.setTitleBarStyle(TitleBarStyle.hidden);
    await windowManager.setMinimumSize(const Size(720, 480));
    // Maximizar recién cuando hay primer frame: antes la ventana todavía no
    // existe para el sistema y el llamado se pierde (abría restaurada).
    unawaited(
      windowManager.waitUntilReadyToShow().then((_) async {
        await windowManager.show();
        await windowManager.maximize();
      }),
    );
  }
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
