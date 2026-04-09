// ── main.dart ──────────────────────────────────────────────────────────────────
// Entry point of the NavStudy app.
// Responsibilities:
//   1. Bootstrap Flutter bindings before runApp() is called.
//   2. Style the Android status bar and navigation bar so they look transparent
//      and use light (white) icons — matching the dark theme.
//   3. Lock the orientation to portrait-up so the map UI never rotates sideways.
//   4. Mount the root widget tree (NavStudyApp → AppShell).

import 'package:flutter/material.dart';
import 'package:flutter/services.dart'; // For SystemChrome and SystemUiOverlayStyle
import 'app_shell.dart';
import 'theme.dart'; // Gives us the C colour constants (C.bg, etc.)

// ── App entry point ────────────────────────────────────────────────────────────

void main() {
  // Must be called before any platform-channel work (like SystemChrome) to
  // make sure the Flutter engine is fully initialised.
  WidgetsFlutterBinding.ensureInitialized();

  // Configure how the Android system status bar and navigation bar look.
  // statusBarColor: transparent — our content draws edge-to-edge.
  // Brightness.light — white icons on the status bar (suits dark backgrounds).
  // systemNavigationBarColor: matches our app background so there's no jarring strip.
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.light,
    systemNavigationBarColor: C.bg,
    systemNavigationBarIconBrightness: Brightness.light,
  ));

  // Allow all orientations — layouts adapt via MediaQuery in each overlay.
  SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ]);

  // Hand control over to Flutter's widget system.
  runApp(const NavStudyApp());
}

// ── Root widget ────────────────────────────────────────────────────────────────

// NavStudyApp is a StatelessWidget because all mutable state lives deeper in the
// tree (inside AppShell). This widget just wires up MaterialApp theming.
class NavStudyApp extends StatelessWidget {
  const NavStudyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'NavStudy',

      // Hide the red "DEBUG" banner that appears in the top-right corner during
      // development builds — keeps screenshots clean.
      debugShowCheckedModeBanner: false,

      // Start from Material 3's built-in dark theme and then patch only what we
      // need so the rest of the app inherits sensible dark-mode defaults.
      theme: ThemeData.dark(useMaterial3: true).copyWith(
        // Fill the Scaffold body with our custom near-black background.
        scaffoldBackgroundColor: C.bg,

        // Override the colour scheme so widgets that read primary / secondary /
        // surface colours (buttons, chips, cards) use our palette.
        colorScheme: const ColorScheme.dark(
          primary: C.blue,
          secondary: C.accent,
          surface: C.bg,
        ),
      ),

      // AppShell is the single full-screen page — it renders the map and
      // conditionally overlays the home panel, nav panel, or completion card.
      home: const AppShell(),
    );
  }
}
