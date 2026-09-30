import 'dart:async';

import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

import '../../../core/constants/app_colors.dart';
import '../../../core/constants/app_text_styles.dart';
import '../../../core/services/firestore_service.dart';
import '../../../core/state/app_state.dart';
import '../../../models/guidance_position.dart';
import '../../../models/user.dart';
import '../../../shared/utils/logout_helper.dart';
import '../../../shared/widgets/primary_button.dart';

/// Profile — shows the signed-in user's info, lets a Guidance Council user
/// edit their own personal information, and lets them log out.
/// Reached by tapping the profile icon on Staff Home.
class ProfileScreen extends StatefulWidget {
  /// [firestoreService] is only for tests; the app uses the real one.
  const ProfileScreen({super.key, this.firestoreService});

  final FirestoreService? firestoreService;

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  late final FirestoreService _firestoreService =
      widget.firestoreService ?? FirestoreService();

  final _formKey = GlobalKey<FormState>();

  TextEditingController? _firstNameController;
  TextEditingController? _lastNameController;
  TextEditingController? _middleInitialController;
  TextEditingController? _displayNameController;
  String? _guidancePosition;

  bool _isEditing = false;
  bool _isSaving = false;
  String? _error;

  bool _positionsInitialized = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Guarded, one-time trigger -- didChangeDependencies can run more than
    // once, but this must only fire the load a single time per screen.
    // AppStateScope.of(context) is only safe here (or in build()), never in
    // initState() itself -- Flutter asserts if an inherited widget is
    // looked up before initState() has completed.
    if (_positionsInitialized) return;
    _positionsInitialized = true;
    // Fire-and-forget: refreshes AppState.guidancePositions so both the
    // read-only label and the edit-mode dropdown below reflect the current
    // configuration, including anything a System Admin has added. A
    // Guidance Council session only ever reads this -- never seeds or
    // writes it (that's System-Admin-only; see CreateUserScreen/
    // EditUserScreen's own _loadPositions). Never blocks this screen:
    // AppState.guidancePositions already starts at GuidancePositions.
    // defaults and FirestoreService.loadGuidancePositions falls back to the
    // same on any failure.
    unawaited(AppStateScope.of(context).loadGuidancePositions(_firestoreService));
  }

  /// Enters edit mode, pre-filled with this account's current values -- the
  /// same "populate from what's already there" convention
  /// `ProfileSetupScreen` uses, so a user editing an already-complete
  /// profile never has to retype fields they're not changing.
  void _startEditing(UserModel user) {
    _firstNameController = TextEditingController(text: user.firstName ?? '');
    _lastNameController = TextEditingController(text: user.lastName ?? '');
    _middleInitialController = TextEditingController(text: user.middleInitial ?? '');
    _displayNameController = TextEditingController(text: user.displayName);
    // Trusted as-is, with no membership check against the loaded/fallback
    // position list -- an already-saved position (including one a System
    // Admin added after the original three) must never be silently
    // discarded here. _buildPositionDropdown guarantees this value is
    // always a selectable item via GuidancePositions.ensureIncludes.
    _guidancePosition = user.guidancePosition;
    setState(() {
      _isEditing = true;
      _error = null;
    });
  }

  /// Discards whatever was typed -- no Firestore write, no AppState change.
  void _cancelEditing() {
    _disposeFormControllers();
    setState(() {
      _isEditing = false;
      _error = null;
    });
  }

  void _disposeFormControllers() {
    _firstNameController?.dispose();
    _lastNameController?.dispose();
    _middleInitialController?.dispose();
    _displayNameController?.dispose();
    _firstNameController = null;
    _lastNameController = null;
    _middleInitialController = null;
    _displayNameController = null;
  }

  @override
  void dispose() {
    _disposeFormControllers();
    super.dispose();
  }

  /// Saves this account's own profile via the same
  /// [FirestoreService.updateOwnProfile] call and field set `ProfileSetup`
  /// uses -- the `firestore.rules` self-update allowlist already covers
  /// exactly these 5 fields, so no rule change is needed here. Never writes
  /// `role`/`isActive`/`email`/`createdBy`/`uid`/`createdAt` -- this call
  /// doesn't even accept them.
  Future<void> _save() async {
    if (_isSaving) return; // prevent duplicate submissions
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

    final firstName = _firstNameController!.text.trim();
    final lastName = _lastNameController!.text.trim();
    final middleInitial = UserNameRules.normalizeMiddleInitial(_middleInitialController!.text);
    final displayName = _displayNameController!.text.trim();
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
      // so this screen (and every other screen) reflects the change
      // immediately, with no re-login and no second read required.
      appState.setCurrentUser(current.copyWith(
        firstName: firstName,
        lastName: lastName,
        middleInitial: middleInitial,
        displayName: displayName,
        guidancePosition: position,
      ));
      _disposeFormControllers();
      setState(() => _isEditing = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Profile updated.')),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = FirestoreService.messageFor(
          e,
          fallback: 'Could not save your profile. Please try again.',
        );
      });
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    // The Firestore-approved UserModel (AppState.currentUser), not
    // FirebaseAuth's own User.displayName -- that Firebase Auth property is
    // never set anywhere in this app (no updateDisplayName call exists), so
    // reading it here always showed the "NDMU Staff Officer" fallback
    // instead of the account's real, Guidance-Council-maintained profile.
    final user = AppStateScope.of(context).currentUser;
    final displayName = user?.displayName.trim();
    final name = (displayName != null && displayName.isNotEmpty) ? displayName : 'NDMU Staff Officer';
    final email = user?.email;

    return Scaffold(
      backgroundColor: AppColors.lightBg,
      appBar: AppBar(
        backgroundColor: Colors.white,
        foregroundColor: AppColors.textDark,
        elevation: 0.5,
        title: Text('Profile', style: AppTextStyles.heading(size: 13)),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Form(
            key: _formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Container(
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: AppColors.cardBorder),
                  ),
                  child: Column(
                    children: [
                      Container(
                        width: 72,
                        height: 72,
                        alignment: Alignment.center,
                        decoration: const BoxDecoration(color: Color(0xFF1B5E20), shape: BoxShape.circle),
                        child: const FaIcon(FontAwesomeIcons.userTie, size: 28, color: Colors.white),
                      ),
                      const SizedBox(height: 14),
                      Text(name, style: AppTextStyles.heading(size: 15), textAlign: TextAlign.center),
                      if (email != null) ...[
                        const SizedBox(height: 4),
                        Text(email, style: AppTextStyles.body(size: 11, color: AppColors.textGray)),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                Container(
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: AppColors.cardBorder),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text('Profile Information', style: AppTextStyles.heading(size: 12)),
                          if (!_isEditing && user != null)
                            InkWell(
                              key: const Key('profile.editButton'),
                              onTap: () => _startEditing(user),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    const FaIcon(FontAwesomeIcons.penToSquare, size: 11, color: AppColors.primaryGreen),
                                    const SizedBox(width: 4),
                                    Text('Edit', style: AppTextStyles.body(size: 10.5, color: AppColors.primaryGreen, weight: FontWeight.w600)),
                                  ],
                                ),
                              ),
                            ),
                        ],
                      ),
                      const SizedBox(height: 14),
                      if (_isEditing) _buildEditForm() else _buildReadOnlyInfo(user),
                      if (_error != null) ...[
                        const SizedBox(height: 12),
                        Text(_error!, style: AppTextStyles.body(size: 11, color: AppColors.warmRedOrange)),
                      ],
                      if (_isEditing) ...[
                        const SizedBox(height: 16),
                        Row(
                          children: [
                            Expanded(
                              child: SecondaryButton(
                                key: const Key('profile.cancelButton'),
                                label: 'CANCEL',
                                onPressed: _isSaving ? null : _cancelEditing,
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: PrimaryButton(
                                key: const Key('profile.saveButton'),
                                label: _isSaving ? 'Saving...' : 'SAVE',
                                onPressed: _isSaving ? null : _save,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: 24),
                PrimaryButton(
                  label: 'LOG OUT',
                  icon: FontAwesomeIcons.rightFromBracket,
                  color: AppColors.warmRedOrange,
                  onPressed: () => confirmLogout(context),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// The read-only "Field: value" display shown when not editing.
  Widget _buildReadOnlyInfo(UserModel? user) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildInfoRow('First Name', user?.firstName),
        _buildInfoRow('Middle Initial', user?.middleInitial),
        _buildInfoRow('Last Name', user?.lastName),
        _buildInfoRow('Display Name', user?.displayName),
        _buildInfoRow('Position', _positionLabel(user?.guidancePosition)),
      ],
    );
  }

  /// The human-readable label for a stored `guidancePosition` value, from
  /// the current session's loaded/fallback position list (see
  /// [AppState.guidancePositions]) -- no hardcoded map. A value this list
  /// doesn't (yet, or ever) recognize still shows as the raw stored value
  /// rather than "Not set": that wording is reserved for a genuinely
  /// missing/blank position (see [_buildInfoRow]), never for one that's
  /// simply unrecognized by this call site's current position list.
  String? _positionLabel(String? value) {
    if (value == null || value.trim().isEmpty) return null;
    final positions = AppStateScope.of(context).guidancePositions;
    return GuidancePositions.labelFor(value, positions) ?? value;
  }

  /// A single labeled "Field: value" row on the Profile Information card.
  /// [value] is shown as "Not set" when null or blank -- an older account,
  /// or one that hasn't completed Mobile Profile Setup yet, never crashes
  /// or shows a blank line here.
  Widget _buildInfoRow(String label, String? value) {
    final trimmed = value?.trim();
    final display = (trimmed == null || trimmed.isEmpty) ? 'Not set' : trimmed;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 110,
            child: Text(label, style: AppTextStyles.body(size: 11, color: AppColors.textGray)),
          ),
          Expanded(
            child: Text(display, style: AppTextStyles.body(size: 11.5, weight: FontWeight.w600)),
          ),
        ],
      ),
    );
  }

  /// The editable form, using the exact same [UserNameRules] validators and
  /// canonical Position values/labels as `ProfileSetupScreen`.
  Widget _buildEditForm() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildTextField(
          label: 'First Name',
          controller: _firstNameController!,
          hint: 'e.g., Juan',
          fieldKey: const Key('profile.firstName'),
          validator: UserNameRules.validateFirstName,
        ),
        const SizedBox(height: 12),
        _buildTextField(
          label: 'Last Name',
          controller: _lastNameController!,
          hint: 'e.g., Dela Cruz',
          fieldKey: const Key('profile.lastName'),
          validator: UserNameRules.validateLastName,
        ),
        const SizedBox(height: 12),
        _buildTextField(
          label: 'Middle Initial',
          controller: _middleInitialController!,
          hint: 'e.g., D.',
          fieldKey: const Key('profile.middleInitial'),
          validator: UserNameRules.validateMiddleInitial,
        ),
        const SizedBox(height: 12),
        _buildTextField(
          label: 'Display Name',
          controller: _displayNameController!,
          hint: 'e.g., Juan Dela Cruz',
          fieldKey: const Key('profile.displayName'),
          validator: (value) =>
              (value == null || value.trim().isEmpty) ? 'This field is required' : null,
        ),
        const SizedBox(height: 12),
        _buildPositionDropdown(),
      ],
    );
  }

  Widget _buildTextField({
    required String label,
    required TextEditingController controller,
    String? hint,
    String? Function(String?)? validator,
    Key? fieldKey,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: AppTextStyles.body(size: 10.5, weight: FontWeight.w600)),
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
          validator: validator,
        ),
      ],
    );
  }

  Widget _buildPositionDropdown() {
    // Guarantees this account's own currently-selected position (including a
    // custom one) is always a selectable item, even if the loaded/fallback
    // list doesn't otherwise recognize it -- see
    // GuidancePositions.ensureIncludes's own doc comment.
    final positions = GuidancePositions.ensureIncludes(
      AppStateScope.of(context).guidancePositions,
      _guidancePosition,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Position', style: AppTextStyles.body(size: 10.5, weight: FontWeight.w600)),
        const SizedBox(height: 6),
        DropdownButtonFormField<String>(
          key: const Key('profile.position'),
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
