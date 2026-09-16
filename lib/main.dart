import 'package:flutter/material.dart';

import 'src/ui/app_theme.dart';
import 'src/ui/library_page.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MuseReaderApp());
}

class MuseReaderApp extends StatelessWidget {
  const MuseReaderApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'MuseReader',
      debugShowCheckedModeBanner: false,
      theme: MuseReaderTheme.light,
      darkTheme: MuseReaderTheme.dark,
      themeMode: ThemeMode.system,
      home: const LibraryPage(),
    );
  }
}
