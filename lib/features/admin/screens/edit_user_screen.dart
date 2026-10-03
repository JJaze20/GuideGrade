import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../../../core/constants/app_colors.dart';
import '../../../core/constants/app_text_styles.dart';
import '../../../core/services/firestore_service.dart';
import '../../../core/services/logging_service.dart';
import '../../../core/state/app_state.dart';
import '../../../models/guidance_position.dart';
import '../../../models/user.dart';
import '../../../shared/widgets/form_field_decoration.dart';
import '../../../shared/widgets/form_layout.dart';
import '../../../shared/widgets/primary_button.dart';
import '../../../shared/widgets/status_badge.dart';
import '../widgets/position_management_dialog.dart';

/// Edit User screen for the System Administrator.
///
/// Editable: Display Name, First Name / Middle Initial / Last Name (Guidance
/// Council accounts), Guidance Position, Institution, Active/Inactive
/// status. Email is read-only (changing a Firebase Auth email for another
/// user is an Admin-SDK-only operation, out of scope here). Role is
/// read-only in this first version -- there is currently no "appropriate"
/// role change to expose: the only creation path produces
/// `guidance_council`, and promoting to `system_admin` from this screen is
/// explicitly out of scope for now.
///
/// Self-protection: when the viewed account is the signed-in admin's own
/// account, role editing and the Deactivate action are disabled in the UI
/// AND defensively re-checked in the submit logic, so the currently
/// signed-in admin can never remove their own access from this screen.
class EditUserScreen extends StatefulWidget {
  final UserModel? user;

  /// Only for tests; the app uses the real services.
  final FirestoreService? firestoreService;
  final LoggingService? loggingService;

  const EditUserScreen({
    super.key,
    this.user,
    this.firestoreService,
    this.loggingService,
  });

  @override
  State<EditUserScreen> createState() => _EditUserScreenState();
}

class _EditUserScreenState extends State<EditUserScreen> {
  late final FirestoreService _firestoreService =
      widget.firestoreService ?? FirestoreService();
  late final LoggingService _loggingService =
      widget.loggingService ?? LoggingService();
  final _formKey = GlobalKey<FormState>();

  late final TextEditingController _displayNameController;
  late final TextEditingController _firstNameController;
  late final TextEditingController _middleInitialController;
  late final TextEditingController _lastNameController;
  late final TextEditingController _institutionController;

  String? _guidancePosition;
  bool _isLoading = true;
  bool _isSaving = false;
  bool _isSendingReset = false;

  UserModel? _user;

  @override
  void initState() {
    super.initState();
    _loadUser();
  }

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
    _loadPositions();
  }

  /// Ensures `config/guidancePositions` exists (seeding the three original
  /// positions on the very first call after this feature shipped -- see
  /// [FirestoreService.ensureDefaultGuidancePositionsSeeded]'s own doc
  /// comment), then loads the current list into [AppState] so the Position
  /// dropdown below reflects it, including anything already added. Best
  /// effort and independent of [_loadUser]: both already fall back safely
  /// on their own failure.
  Future<void> _loadPositions() async {
    final appState = AppStateScope.of(context);
    await _firestoreService.ensureDefaultGuidancePositionsSeeded();
    await appState.loadGuidancePositions(_firestoreService);
  }

  /// Opens Position Management (list + add + delete) instead of going
  /// straight to the add-only dialog. Whatever changed while it was open
  /// is picked up by the one [AppState.loadGuidancePositions] refresh
  /// below -- the same refresh this screen already did after the old
  /// add-only dialog closed.
  Future<void> _managePositions() async {
    final appState = AppStateScope.of(context);
    await showPositionManagementDialog(
      context,
      firestoreService: _firestoreService,
      initialPositions: appState.guidancePositions,
    );
    if (!mounted) return;
    await appState.loadGuidancePositions(_firestoreService);
  }

  Future<void> _loadUser() async {
    final args = widget.user ?? ModalRoute.of(context)?.settings.arguments as UserModel?;
    if (args == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Error: No user data provided')),
        );
        Navigator.of(context).pop();
      }
      return;
    }

    // Re-fetch fresh rather than trusting the possibly-stale object passed
    // through navigation arguments, so Save can't silently clobber a
    // concurrent change with data loaded minutes ago.
    final fresh = await _firestoreService.getUserById(args.userId) ?? args;

    if (!mounted) return;
    setState(() {
      _user = fresh;
      _displayNameController = TextEditingController(text: fresh.displayName);
      // Empty for an older account that has no structured name yet.
      _firstNameController = TextEditingController(text: fresh.firstName ?? '');
      _middleInitialController = TextEditingController(text: fresh.middleInitial ?? '');
      _lastNameController = TextEditingController(text: fresh.lastName ?? '');
      _institutionController = TextEditingController(text: fresh.institution);
      _guidancePosition = fresh.guidancePosition;
      _isLoading = false;
    });
  }

  @override
  void dispose() {
    if (!_isLoading) {
      _displayNameController.dispose();
      _firstNameController.dispose();
      _middleInitialController.dispose();
      _lastNameController.dispose();
      _institutionController.dispose();
    }
    super.dispose();
  }

  /// The structured name is checked with the Create User rules once the
  /// account has one, or as soon as any part of it is typed. An older account
  /// with none stays saveable with all three left empty, so unrelated edits
  /// are never blocked by a name it was never given.
  bool get _structuredNameRequired =>
      _user!.isGuidanceCouncil &&
      (_user!.hasStructuredName ||
          _firstNameController.text.trim().isNotEmpty ||
          _middleInitialController.text.trim().isNotEmpty ||
          _lastNameController.text.trim().isNotEmpty);

  bool get _isEditingSelf {
    final appState = AppStateScope.of(context);
    return _user != null && _user!.userId == appState.currentUser?.userId;
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate() || _user == null) return;

    setState(() => _isSaving = true);
    try {
      final saveName = _structuredNameRequired;
      final updated = _user!.copyWith(
        displayName: _displayNameController.text.trim(),
        firstName: saveName ? _firstNameController.text.trim() : null,
        middleInitial: saveName
            ? UserNameRules.normalizeMiddleInitial(_middleInitialController.text)
            : null,
        lastName: saveName ? _lastNameController.text.trim() : null,
        institution: _institutionController.text.trim().isEmpty ? 'NDMU' : _institutionController.text.trim(),
        guidancePosition: _guidancePosition,
      );
      await _firestoreService.updateUser(updated);
      if (!mounted) return;
      setState(() => _user = updated);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('User updated.')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not save changes. Please try again.')),
      );
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  Future<void> _deactivate() async {
    if (_user == null) return;

    // Defensive check -- never trust that the button being disabled in the
    // UI is the only thing preventing this. The currently signed-in admin
    // can never deactivate their own account from here.
    if (_isEditingSelf) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('You cannot deactivate your own account.')),
      );
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Deactivate this account?'),
        content: Text('${_user!.displayName} will no longer be able to sign in until reactivated.'),
        actions: [
          TextButton(onPressed: () => Navigator.of(dialogContext).pop(false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.of(dialogContext).pop(true), child: const Text('Deactivate')),
        ],
      ),
    );
    if (confirmed != true) return;

    await _setActive(false);
  }

  Future<void> _activate() async {
    await _setActive(true);
  }

  Future<void> _setActive(bool isActive) async {
    if (_user == null) return;
    // Defensive re-check, mirroring _deactivate -- activation is always
    // safe, but keeping both paths through the same guard shape avoids a
    // future edit accidentally reordering things and losing the check.
    if (!isActive && _isEditingSelf) return;

    final admin = AppStateScope.of(context).currentUser;

    setState(() => _isSaving = true);
    try {
      if (isActive) {
        await _firestoreService.activateUser(_user!.userId);
      } else {
        await _firestoreService.deactivateUser(_user!.userId);
      }
      // Log only after the Firestore update above has already succeeded --
      // a logging failure here (LoggingService.createLog never throws
      // anyway) must never be mistaken for the activate/deactivate itself
      // having failed.
      if (admin != null) {
        if (isActive) {
          await _loggingService.logUserActivated(admin, targetUserId: _user!.userId, targetUserEmail: _user!.email);
        } else {
          await _loggingService.logUserDeactivated(admin, targetUserId: _user!.userId, targetUserEmail: _user!.email);
        }
      }
      if (!mounted) return;
      setState(() => _user = _user!.copyWith(isActive: isActive));
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(isActive ? 'Account activated.' : 'Account deactivated.')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not update account status. Please try again.')),
      );
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  Future<void> _sendPasswordReset() async {
    if (_user == null) return;
    final admin = AppStateScope.of(context).currentUser;
    setState(() => _isSendingReset = true);
    try {
      // Unprivileged client SDK call -- works for any valid email, doesn't
      // sign anyone in or out, and needs no secondary app instance.
      await FirebaseAuth.instance.sendPasswordResetEmail(email: _user!.email);
      // Log only after the send above has already succeeded.
      if (admin != null) {
        await _loggingService.logPasswordResetSent(admin, targetUserId: _user!.userId, targetUserEmail: _user!.email);
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Password reset email sent to ${_user!.email}.')),
      );
    } on FirebaseAuthException catch (e) {
      if (!mounted) return;
      final message = e.code == 'user-not-found'
          ? 'No Firebase Authentication account exists for this email.'
          : 'Could not send the reset email. Please try again.';
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
    } finally {
      if (mounted) setState(() => _isSendingReset = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading || _user == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    final isSelf = _isEditingSelf;

    return Scaffold(
      backgroundColor: AppColors.lightBg,
      appBar: AppBar(
        backgroundColor: Colors.white,
        foregroundColor: AppColors.textDark,
        elevation: 0,
        shape: const Border(bottom: BorderSide(color: AppColors.border)),
        title: Text('Edit User', style: AppTextStyles.heading(size: 17)),
      ),
      body: SafeArea(
        child: Form(
          key: _formKey,
          child: ListView(
            padding: FormLayout.padding(context),
            children: [
              if (isSelf)
                Container(
                  margin: const EdgeInsets.only(bottom: 16),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: AppColors.warningBg,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    'This is your own account. Role changes and deactivation are disabled here to prevent losing access.',
                    style: AppTextStyles.body(size: 12.5, color: AppColors.warningFg),
                  ),
                ),
              const FormSectionHeader('Account', first: true),
              _buildReadOnlyField('Email', _user!.email),
              const SizedBox(height: 12),
              _buildReadOnlyField('Role', _user!.role == 'system_admin' ? 'System Admin' : 'Guidance Council'),
              const SizedBox(height: 12),
              _buildStatusRow(),
              const SizedBox(height: 16),
              const FormSectionHeader('Profile'),
              if (_user!.isGuidanceCouncil) ...[
                _buildTextField(
                  label: 'First Name',
                  controller: _firstNameController,
                  fieldKey: const Key('editUser.firstName'),
                  validator: (v) => _structuredNameRequired ? UserNameRules.validateFirstName(v) : null,
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
                      fieldKey: const Key('editUser.middleInitial'),
                      validator: (v) => _structuredNameRequired ? UserNameRules.validateMiddleInitial(v) : null,
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                _buildTextField(
                  label: 'Last Name',
                  controller: _lastNameController,
                  fieldKey: const Key('editUser.lastName'),
                  validator: (v) => _structuredNameRequired ? UserNameRules.validateLastName(v) : null,
                ),
                const SizedBox(height: 16),
              ],
              _buildTextField(
                label: 'Display Name',
                controller: _displayNameController,
                fieldKey: const Key('editUser.displayName'),
              ),
              const SizedBox(height: 12),
              if (_user!.role == 'guidance_council') ...[
                _buildGuidancePositionDropdown(),
                const SizedBox(height: 12),
              ],
              _buildTextField(label: 'Institution', controller: _institutionController, required: false),
              const SizedBox(height: 24),
              PrimaryButton(
                label: _isSaving ? 'Saving...' : 'Save Changes',
                onPressed: _isSaving ? null : _save,
              ),
              const SizedBox(height: 12),
              SecondaryButton(
                label: _isSendingReset ? 'Sending...' : 'Send Password Reset Email',
                onPressed: _isSendingReset ? null : _sendPasswordReset,
              ),
              const SizedBox(height: 24),
              const FormSectionHeader('Danger Zone'),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton(
                  onPressed: (_isSaving || isSelf) ? null : (_user!.isActive ? _deactivate : _activate),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: _user!.isActive ? AppColors.dangerFg : AppColors.primaryGreen,
                    side: BorderSide(color: _user!.isActive ? AppColors.dangerFg : AppColors.primaryGreen),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                  ),
                  child: Text(
                    _user!.isActive ? 'Deactivate Account' : 'Activate Account',
                    style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 12.5),
                  ),
                ),
              ),
              const SizedBox(height: 16),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildStatusRow() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const FieldLabel('Status'),
        Align(
          alignment: Alignment.centerLeft,
          child: StatusBadge(
            label: _user!.isActive ? 'Active' : 'Inactive',
            tone: _user!.isActive ? StatusTone.success : StatusTone.neutral,
          ),
        ),
      ],
    );
  }

  Widget _buildReadOnlyField(String label, String value) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        FieldLabel(label),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
          decoration: BoxDecoration(
            color: FormFieldStyle.disabledFill,
            borderRadius: BorderRadius.circular(FormFieldStyle.radius),
            border: Border.all(color: FormFieldStyle.disabledBorder, width: FormFieldStyle.restingWidth),
          ),
          child: Text(value, style: AppTextStyles.body(size: 13, color: AppColors.textMuted)),
        ),
      ],
    );
  }

  Widget _buildTextField({
    required String label,
    required TextEditingController controller,
    bool required = false,
    String? hint,
    Key? fieldKey,
    String? Function(String?)? validator,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        FieldLabel(label, required: required),
        TextFormField(
          key: fieldKey,
          controller: controller,
          decoration: FormFieldStyle.outlined(hint: hint),
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

  /// The Guidance Position dropdown, with a "+" action beside its label so a
  /// System Admin can add a new position without leaving this screen. Reads
  /// the current list from [AppState] (see [AppState.guidancePositions])
  /// rather than a hardcoded map. [GuidancePositions.ensureIncludes] makes
  /// sure this account's own already-saved position is always a selectable
  /// item -- including a custom one the freshly loaded list doesn't (yet, or
  /// ever) recognize -- so it can never be silently dropped from the
  /// dropdown's selection just because of a stale or failed configuration
  /// read.
  Widget _buildGuidancePositionDropdown() {
    final positions = GuidancePositions.ensureIncludes(
      AppStateScope.of(context).guidancePositions,
      _guidancePosition,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const FieldLabel('Guidance Position'),
            InkWell(
              key: const Key('editUser.addPosition'),
              onTap: _managePositions,
              borderRadius: BorderRadius.circular(8),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.tune, size: 16, color: AppColors.primaryGreen),
                    const SizedBox(width: 4),
                    Text(
                      'Manage Positions',
                      style: AppTextStyles.body(size: 12.5, color: AppColors.primaryGreen, weight: FontWeight.w700),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
        DropdownButtonFormField<String>(
          key: const Key('editUser.position'),
          initialValue: _guidancePosition,
          isExpanded: true,
          decoration: FormFieldStyle.outlined(),
          items: positions
              .map((p) => DropdownMenuItem(value: p.value, child: Text(p.label, style: AppTextStyles.body(size: 13))))
              .toList(),
          onChanged: (value) => setState(() => _guidancePosition = value),
        ),
      ],
    );
  }
}
