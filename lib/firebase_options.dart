import 'package:firebase_core/firebase_core.dart' show FirebaseOptions;
import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform;

/// Firebase configuration generated from the Android [google-services.json].
class DefaultFirebaseOptions {
  static FirebaseOptions get currentPlatform {
    if (kIsWeb) {
      throw UnsupportedError('Web Firebase options are not configured.');
    }
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return android;
      case TargetPlatform.iOS:
      case TargetPlatform.macOS:
      case TargetPlatform.windows:
      case TargetPlatform.linux:
        throw UnsupportedError(
          'Firebase is only configured for Android in this project.',
        );
      default:
        throw UnsupportedError('Unsupported platform.');
    }
  }

  static const FirebaseOptions android = FirebaseOptions(
    apiKey: 'AIzaSyCeytoCvHubnin3AMCQX-5L0tin9QwbFMQ',
    appId: '1:204847946991:android:57a303a556f540da68cf1a',
    messagingSenderId: '204847946991',
    projectId: 'guidegrade-470ea',
    storageBucket: 'guidegrade-470ea.firebasestorage.app',
  );
}
