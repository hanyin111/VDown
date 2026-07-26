import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'services/download_manager.dart';
import 'services/engine/video_engine.dart';
import 'services/settings_service.dart';
import 'theme/app_theme.dart';
import 'ui/home_shell.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final settings = SettingsService();
  await settings.init();
  runApp(VDownApp(settings: settings));
}

class VDownApp extends StatelessWidget {
  final SettingsService settings;

  const VDownApp({super.key, required this.settings});

  @override
  Widget build(BuildContext context) {
    final engine = createEngine(settings);
    return MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: settings),
        Provider<VideoEngine>.value(value: engine),
        ChangeNotifierProvider(create: (_) => DownloadManager(settings, engine)),
      ],
      child: Consumer<SettingsService>(
        builder: (context, s, _) => MaterialApp(
          title: 'VDown',
          debugShowCheckedModeBanner: false,
          theme: AppTheme.light(),
          darkTheme: AppTheme.dark(),
          themeMode: s.themeMode,
          home: const HomeShell(),
        ),
      ),
    );
  }
}
