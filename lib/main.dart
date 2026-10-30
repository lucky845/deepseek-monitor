import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'providers/auth_provider.dart';
import 'providers/glass_provider.dart';
import 'providers/usage_provider.dart';
import 'screens/dashboard_screen.dart';
import 'theme.dart';

void main() {
  // Reading preferences needs a binding, and the glass setting is loaded before
  // the first frame. Without this the very first run throws
  // "Binding has not yet been initialized." and the setting quietly never loads.
  WidgetsFlutterBinding.ensureInitialized();
  final glass = GlassProvider();
  glass.load();
  runApp(
    // Above MaterialApp so every pane on every page — including the ones pushed
    // as sheets — reads the same thickness.
    GlassScope(
      notifier: glass,
      child: DeepSeekMonitorApp(glass: glass),
    ),
  );
}

class DeepSeekMonitorApp extends StatelessWidget {
  const DeepSeekMonitorApp({super.key, this.glass});

  /// Supplied by [main]; tests may leave it out and every pane falls back to
  /// the untouched 1.0 look.
  final GlassProvider? glass;

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => AuthProvider()),
        ChangeNotifierProvider(create: (_) => UsageProvider()),
        if (glass != null)
          ChangeNotifierProvider<GlassProvider>.value(value: glass!),
      ],
      child: MaterialApp(
        title: 'DeepSeek 用量监控',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          useMaterial3: true,
          brightness: Brightness.dark,
          scaffoldBackgroundColor: kBg,
          colorScheme: const ColorScheme.dark(
            primary: kAccent,
            secondary: kAccent2,
            surface: kSurface,
            onSurface: kText,
            error: kDanger,
          ),
          fontFamily: null,
          dividerTheme: const DividerThemeData(color: kSurface2),
          textSelectionTheme: const TextSelectionThemeData(
            cursorColor: kAccent,
            selectionColor: Color(0x555B7CFF),
            selectionHandleColor: kAccent,
          ),
          snackBarTheme: const SnackBarThemeData(
            backgroundColor: kSurface2,
            contentTextStyle: TextStyle(color: kText),
            behavior: SnackBarBehavior.floating,
          ),
        ),
        home: const DashboardScreen(),
      ),
    );
  }
}
