package com.team.guidegrade

import io.flutter.embedding.android.FlutterFragmentActivity

// FlutterFragmentActivity (an AndroidX FragmentActivity), not plain
// FlutterActivity -- local_auth's Android implementation shows the system
// BiometricPrompt, which requires the host Activity to be a
// FragmentActivity. Fully compatible with every other plugin already in
// use; this is the officially recommended base class for that reason.
class MainActivity : FlutterFragmentActivity()