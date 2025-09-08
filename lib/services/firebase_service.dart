import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:flutter/foundation.dart';

class FirebaseService {
  static bool _initialized = false;

  static Future<void> init() async {
    if (_initialized) return;
    await Firebase.initializeApp();
    // Enable App Check on Android with Play Integrity
    await FirebaseAppCheck.instance.activate(
      androidProvider: AndroidProvider.playIntegrity,
      appleProvider: AppleProvider.appAttest,
      webProvider: ReCaptchaV3Provider('recaptcha-v3-site-key'),
    );
    _initialized = true;
    if (kDebugMode) {
      // Optionally set up local emulators here if needed.
    }
  }
}
