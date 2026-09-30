import 'package:flutter/material.dart';

import '../../../core/constants/app_colors.dart';
import '../../../core/constants/app_text_styles.dart';
import '../../../core/routes/app_routes.dart';
import '../../../core/services/firestore_service.dart';
import '../../../core/state/app_state.dart';
import '../../../models/guidance_position.dart';
import '../../../models/user.dart';
import '../../../shared/widgets/primary_button.dart';

/// Mobile Profile Setup -- mandatory completion of a Guidance Council
/// account's personal profile (First Name / Last Name / Middle Initial /
/// Display Name / Position) before the dashboard is reachable.
///
/// Reached ONLY via [AppRoutes.onGenerateRoute]/[AppRoutes._landingScreen]
/// redirecting an authorized-but-incomplete `guidance_council` account here
/// (see [UserModel.isProfileComplete]) -- never linked to directly from
/// anywhere else in the app. There is deliberately no Cancel/Skip action and
/// [PopScope] blocks the Android back gesture, so completing the profile is
/// the only way out of this screen once reached.
///
/// This is an UPDATE to the caller's own, already-existing `users/{uid}`
/// document (via [FirestoreService.updateOwnProfile]) -- it never creates a
/// document, never changes the signed-in Firebase UID, and never touches
/// `role`/`isActive`/`email`/`createdBy` (that write is not even attempted;
/// `firestore.rules`' self-update allowlist would reject it anyway).
class ProfileSetupScreen extends StatefulWidget {
  /// [firestoreService] is only for tests; the app uses the real one.
  const ProfileSetupScreen({super.key, this.firestoreService});

  final FirestoreService? firestoreService;

  @override
  State<ProfileSetupScreen> createState() => _ProfileSetupScreenState();
}

class _ProfileSetupScreenState extends State<ProfileSetupScreen> {
  late final FirestoreService _firestoreService =
      widget.firestoreService ?? FirestoreService();

  final _formKey = GlobalKey<FormState>();

  late final TextEditingController _firstNameController;
  late final TextEditingController _lastNameController;
  late final TextEditingController _middleInitialController;
  late final TextEditingController _displayNameController;

  String? _guidancePosition;
  bool _isSaving = false;
  String? _error;
  bool _initialized = false;
  bool _positionsLoading = true;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_initialized) return;
    _initialized = true;
    // Pre-fill from whatever this account already has -- a partially
    // completed profile (e.g. name set but no Position yet) never has to
    // re-enter what it already provided. Mirrors EditUserScreen's own
    // "empty for an older account that has no structured name yet" pattern.
    final user = AppStateScope.of(context).currentUser;
    _firstNameController = TextEditingController(text: user?.firstName ?? '');
    _lastNameController = TextEditingController(text: user?.lastName ?? '');
    _middleInitialController = TextEditingController(text: user?.middleInitial ?? '');
    _displayNameController = TextEditingController(text: user?.displayName ?? '');
    // Trusted as-is, with no membership check against the loaded/fallback
    // position list -- an already-saved position (including one a System
    // Admin added after the original three) must never be silently
    // discarded just because the Position dropdown hasn't finished loading
    // it yet. `_buildDropdown` below guarantees this value is always a
    // selectable item via `GuidancePositions.ensureIncludes`.
    _guidancePosition = user?.guidancePosition;
    _loadPositions();
  }

  /// Refreshes [AppState.guidancePositions] from Firestore -- fire-and-
  /// forget relative to the rest of this screen's (synchronous) setup, so
  /// Profile Setup's own routing/validation never depends on this
  /// completing. [_positionsLoading] only drives a small loading caption
  /// under the Position field; [FirestoreService.loadGuidancePositions]
  /// already falls back to [GuidancePositions.defaults] on any failure, so
  /// this never leaves the dropdown empty even if it never truly loads.
  Future<void> _loadPositions() async {
    final appState = AppStateScope.of(context);
    try {
      await appState.loadGuidancePositions(_firestoreService);
    } finally {
      if (mounted) setState(() => _positionsLoading = false);
    }
  }

  @override
  void dispose() {
    _firstNameController.dispose();
    _lastNameController.dispose();
    _middleInitialController.dispose();
    _displayNameController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_isSaving) return; // prevent duplicate submissions
    // The Position dropdown has its own validator ("Position is required"),
    // so Form.validate() already covers it -- no separate check needed.
    if (!_formKey.currentState!.validate()) return;

    final appState = AppStateScope.of(context);
    final current = appState.currentUser;
    if (current == null) {
      setState(() => _error = 'Unable to verify your session. Please sign in again.');
      return;
    }

    setState(() {
      _isSaving = true;
      _error = null;
    });

    final firstName = _firstNameController.text.trim();
    final lastName = _lastNameController.text.trim();
    final middleInitial = UserNameRules.normalizeMiddleInitial(_middleInitialController.text);
    final displayName = _displayNameController.text.trim();
    final position = _guidancePosition!;

    try {
      await _firestoreService.updateOwnProfile(
        firstName: firstName,
        lastName: lastName,
        middleInitial: middleInitial,
        displayName: displayName,
        guidancePosition: position,
      );
      if (!mounted) return;
      // Update AppState in place -- the existing single source of truth --
      // so the dashboard and every other screen see the completed profile
      // immediately, with no re-login and no second read required.
      appState.setCurrentUser(current.copyWith(
        firstName: firstName,
        lastName: lastName,
        middleInitial: middleInitial,
        displayName: displayName,
        guidancePosition: position,
      ));
      Navigator.of(context).pushNamedAndRemoveUntil(AppRoutes.staffHome, (route) => false);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Could not save your profile. Please check your connection and try again.';
      });
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      child: Scaffold(
        backgroundColor: AppColors.lightBg,
        appBar: AppBar(
          backgroundColor: Colors.white,
          foregroundColor: AppColors.textDark,
          elevation: 0.5,
          automaticallyImplyLeading: false,
          title: Text('Complete Your Profile', style: AppTextStyles.heading(size: 13)),
        ),
        body: SafeArea(
          child: Form(
            key: _formKey,
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: AppColors.emerald100,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    'Please complete your profile before continuing. This information is '
                    'required and only needs to be entered once.',
                    style: AppTextStyles.body(size: 10, color: const Color(0xFF065F46)),
                  ),
                ),
                const SizedBox(height: 16),
                _buildTextField(
                  label: 'First Name',
                  controller: _firstNameController,
                  hint: 'e.g., Juan',
                  required: true,
                  fieldKey: const Key('profileSetup.firstName'),
                  validator: UserNameRules.validateFirstName,
                ),
                const SizedBox(height: 12),
                _buildTextField(
                  label: 'Last Name',
                  controller: _lastNameController,
                  hint: 'e.g., Dela Cruz',
                  required: true,
                  fieldKey: const Key('profileSetup.lastName'),
                  validator: UserNameRules.validateLastName,
                ),
                const SizedBox(height: 12),
                Align(
                  alignment: Alignment.centerLeft,
                  child: SizedBox(
                    width: 200,
                    child: _buildTextField(
                      label: 'Middle Initial',
                      controller: _middleInitialController,
                      hint: 'e.g., D.',
                      required: true,
                      fieldKey: const Key('profileSetup.middleInitial'),
                      validator: UserNameRules.validateMiddleInitial,
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                _buildTextField(
                  label: 'Display Name',
                  controller: _displayNameController,
                  hint: 'e.g., Juan Dela Cruz',
                  required: true,
                  fieldKey: const Key('profileSetup.displayName'),
                ),
                const SizedBox(height: 12),
                _buildDropdown(),
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Text(_error!, style: AppTextStyles.body(size: 11, color: AppColors.warmRedOrange)),
                ],
                const SizedBox(height: 24),
                PrimaryButton(
                  label: _isSaving ? 'Saving...' : 'Save and Continue',
                  onPressed: _isSaving ? null : _save,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTextField({
    required String label,
    required TextEditingController controller,
    String? hint,
    bool required = false,
    String? Function(String?)? validator,
    Key? fieldKey,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(label, style: AppTextStyles.body(size: 10.5, weight: FontWeight.w600)),
            if (required) Text(' *', style: AppTextStyles.body(size: 10.5, color: Colors.red)),
          ],
        ),
        const SizedBox(height: 6),
        TextFormField(
          key: fieldKey,
          controller: controller,
          enabled: !_isSaving,
          decoration: InputDecoration(
            hintText: hint,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide(color: AppColors.cardBorder),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide(color: AppColors.cardBorder),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide(color: AppColors.primaryGreen),
            ),
            contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          ),
          validator: validator ??
              (required
                  ? (value) {
                      if (value == null || value.trim().isEmpty) return 'This field is required';
                      return null;
                    }
                  : null),
        ),
      ],
    );
  }

  Widget _buildDropdown() {
    final positions = GuidancePositions.ensureIncludes(
      AppStateScope.of(context).guidancePositions,
      _guidancePosition,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text('Position', style: AppTextStyles.body(size: 10.5, weight: FontWeight.w600)),
            Text(' *', style: AppTextStyles.body(size: 10.5, color: Colors.red)),
          ],
        ),
        const SizedBox(height: 6),
        if (_positionsLoading) ...[
          Text('Loading available positions...', style: AppTextStyles.body(size: 9.5, color: AppColors.textGray)),
          const SizedBox(height: 4),
        ],
        DropdownButtonFormField<String>(
          key: const Key('profileSetup.position'),
          initialValue: _guidancePosition,
          decoration: InputDecoration(
            hintText: 'Select your position',
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide(color: AppColors.cardBorder),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide(color: AppColors.cardBorder),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide(color: AppColors.primaryGreen),
            ),
            contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          ),
          items: positions
              .map((p) => DropdownMenuItem(value: p.value, child: Text(p.label, style: AppTextStyles.body(size: 11))))
              .toList(),
          onChanged: _isSaving
              ? null
              : (value) => setState(() {
                    _guidancePosition = value;
                    _error = null;
                  }),
          validator: (value) => value == null ? 'Position is required' : null,
        ),
      ],
    );
  }
}
