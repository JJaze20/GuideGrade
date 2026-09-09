import 'dart:async' show unawaited;

import 'package:flutter/material.dart';
import 'package:local_auth/local_auth.dart';

import '../state/app_state.dart';

/// Requires the device's own fingerprint/face/PIN before showing any
/// screen, every time the app is opened -- a fresh cold start, or coming
/// back from the background -- while a session is signed in. Wraps the
/// whole app via [MaterialApp.builder] so no individual screen has to know
/// about it.
///
/// This is a *local* check (Android/iOS `BiometricPrompt`, entirely
/// on-device) and needs no network, so it doesn't undo offline access —
/// see [AuthService.restoreSession]'s doc comment for the (also local)
/// session restore this layers on top of. Nothing here is a substitute for
/// that restore or for [BatchCryptoService]'s at-rest encryption; each
/// addresses a different threat (see each class's own doc comment).
///
/// Skips locking entirely, rather than blocking the user out, when:
///  - nobody's signed in yet ([AppState.currentUser] null) -- there's
///    nothing to protect before that, and gating the login screen itself
///    would just be a confusing extra hurdle to signing in the first time.
///  - the device reports no supported lock method at all (no fingerprint/
///    face enrolled *and* no PIN/pattern/password set) -- forcing the user
///    to first set up a device lock just to use this app isn't this
///    screen's call to make unilaterally.
class AppLockGate extends StatefulWidget {
  final AppState appState;
  final Widget child;

  const AppLockGate({super.key, required this.appState, required this.child});

  @override
  State<AppLockGate> createState() => _AppLockGateState();
}

class _AppLockGateState extends State<AppLockGate> with WidgetsBindingObserver {
  final _localAuth = LocalAuthentication();

  /// Null until [_checkDeviceSupport] resolves -- nothing is shown/gated
  /// while unknown, since we don't yet know whether locking is even
  /// possible on this device.
  bool? _deviceSupportsLock;

  late bool _locked = widget.appState.currentUser != null;
  bool _authenticating = false;
  String? _error;

  /// Consumes exactly one `resumed` event right after [_authenticate]
  /// finishes -- the prompt it showed is itself what causes the Activity
  /// to regain focus once the user is done with it, and that resume must
  /// not be mistaken for a fresh app-open (see [didChangeAppLifecycleState]).
  /// [_authenticating] alone isn't enough: which of "the auth Future
  /// resolves" vs. "the resume event arrives" happens first isn't
  /// something this code controls, so this covers the case where the
  /// resume lands just *after* [_authenticating] has already flipped back
  /// to false.
  bool _suppressNextResume = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _checkDeviceSupport();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> _checkDeviceSupport() async {
    bool supported;
    try {
      supported = await _localAuth.isDeviceSupported();
    } catch (_) {
      // Can't determine support (platform quirk, plugin error) -- fail
      // open rather than locking the user out of their own data with no
      // way to ever unlock.
      supported = false;
    }
    if (!mounted) return;
    setState(() {
      _deviceSupportsLock = supported;
      if (!supported) _locked = false;
    });
    if (_locked && supported) unawaited(_authenticate());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    debugPrint('AppLockGate: lifecycle -> $state (authenticating=$_authenticating, '
        'suppressNextResume=$_suppressNextResume, locked=$_locked)');
    // Only a real return to the foreground re-locks -- not every lifecycle
    // event (a system dialog or the notification shade briefly firing
    // `inactive` shouldn't force a fresh prompt on its own).
    if (state != AppLifecycleState.resumed) return;
    // The system biometric/PIN prompt shown from _authenticate() below is
    // itself what causes the *next* `resumed` event(s), once the user
    // finishes with it and this Activity regains focus -- without both of
    // these guards, that resume was mistaken for a fresh "app reopened"
    // and re-triggered another lock+prompt on top of the one just
    // resolving, which is exactly what made a successful fingerprint/PIN
    // look like it never let you in: it worked, then immediately got
    // re-locked before the unlocked state ever got a chance to render.
    if (_authenticating) return;
    if (_suppressNextResume) {
      _suppressNextResume = false;
      debugPrint('AppLockGate: suppressed a resume caused by the prompt itself closing');
      return;
    }
    if (widget.appState.currentUser == null) return;
    if (_deviceSupportsLock != true) return;
    setState(() => _locked = true);
    unawaited(_authenticate());
  }

  Future<void> _authenticate() async {
    if (_authenticating) return;
    debugPrint('AppLockGate: showing the system prompt');
    setState(() {
      _authenticating = true;
      _error = null;
    });
    bool ok;
    try {
      ok = await _localAuth.authenticate(
        localizedReason: 'Unlock GuideGrade to continue',
        options: const AuthenticationOptions(
          // Falls back to the device's PIN/pattern/password when
          // biometrics aren't enrolled, still without any of it leaving
          // the device -- exactly "fingerprint or PIN", not fingerprint-only.
          biometricOnly: false,
          stickyAuth: true,
        ),
      );
      debugPrint('AppLockGate: prompt result ok=$ok');
    } catch (e) {
      ok = false;
      _error = 'Could not verify. Try again.';
      debugPrint('AppLockGate: prompt threw: $e');
    }
    if (!mounted) return;
    setState(() {
      _locked = !ok;
      _authenticating = false;
    });
    // The prompt just shown is itself about to cause the next `resumed`
    // event when this Activity regains focus -- consume exactly that one
    // (see didChangeAppLifecycleState).
    _suppressNextResume = true;
  }

  @override
  Widget build(BuildContext context) {
    final showOverlay = _locked && _deviceSupportsLock == true;
    return Stack(
      children: [
        widget.child,
        if (showOverlay)
          _LockScreen(
            authenticating: _authenticating,
            error: _error,
            onUnlock: _authenticate,
          ),
      ],
    );
  }
}

class _LockScreen extends StatelessWidget {
  final bool authenticating;
  final String? error;
  final VoidCallback onUnlock;

  const _LockScreen({required this.authenticating, required this.error, required this.onUnlock});

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: Material(
        color: const Color(0xFF0B1120),
        child: SafeArea(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 72,
                    height: 72,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.08),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(Icons.lock_outline, color: Colors.white, size: 32),
                  ),
                  const SizedBox(height: 20),
                  const Text(
                    'GuideGrade is locked',
                    style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Verify with your fingerprint, face, or device PIN to continue.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.white.withValues(alpha: 0.7), fontSize: 12.5, height: 1.4),
                  ),
                  if (error != null) ...[
                    const SizedBox(height: 14),
                    Text(
                      error!,
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Color(0xFFFCA5A5), fontSize: 12, fontWeight: FontWeight.w600),
                    ),
                  ],
                  const SizedBox(height: 24),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      onPressed: authenticating ? null : onUnlock,
                      icon: authenticating
                          ? const SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                            )
                          : const Icon(Icons.fingerprint, size: 18),
                      label: Text(authenticating ? 'Verifying…' : 'Unlock'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF16A34A),
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 13),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
