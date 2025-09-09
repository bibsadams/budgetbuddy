import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:flutter/foundation.dart';

// Compile-time env (set via --dart-define)
const String _webDebugSiteKey = String.fromEnvironment(
  'APP_CHECK_WEB_DEBUG_KEY',
);
const String _webProdSiteKey = String.fromEnvironment('APP_CHECK_WEB_PROD_KEY');

class FirebaseService {
  static bool _initialized = false;

  static Future<void> init() async {
    if (_initialized) return;
    await Firebase.initializeApp();
    // Enable App Check; in debug use Debug provider to avoid permission issues
    if (kDebugMode) {
      await FirebaseAppCheck.instance.activate(
        androidProvider: AndroidProvider.debug,
        appleProvider: AppleProvider.debug,
        // For web in debug, use provided key when present; otherwise skip
        webProvider: kIsWeb && _webDebugSiteKey.isNotEmpty
            ? ReCaptchaV3Provider(_webDebugSiteKey)
            : null,
      );
    } else {
      // In release, require the web site key when targeting web
      await FirebaseAppCheck.instance.activate(
        androidProvider: AndroidProvider.playIntegrity,
        appleProvider: AppleProvider.appAttest,
        webProvider: kIsWeb
            ? (() {
                if (_webProdSiteKey.isEmpty) {
                  throw StateError(
                    'APP_CHECK_WEB_PROD_KEY is not set. Pass it with --dart-define=APP_CHECK_WEB_PROD_KEY=YOUR_SITE_KEY',
                  );
                }
                return ReCaptchaV3Provider(_webProdSiteKey);
              })()
            : null,
      );
    }
    _initialized = true;
  }
}
