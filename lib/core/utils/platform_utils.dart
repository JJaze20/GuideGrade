import 'package:flutter/foundation.dart' show kIsWeb;

/// Platform detection utility for GuideGrade.
/// 
/// This app has different login screens based on platform:
/// - Web: Admin login screen only
/// - Mobile (Android/iOS): Staff/Guidance Council login screen
class PlatformUtils {
  PlatformUtils._();

  /// Returns true if running on web platform
  static bool get isWeb => kIsWeb;

  /// Returns true if running on mobile (Android or iOS)
  static bool get isMobile => !kIsWeb;

  /// Returns the platform type for routing decisions
  static PlatformType get platformType => kIsWeb ? PlatformType.web : PlatformType.mobile;
}

enum PlatformType {
  web,
  mobile,
}
