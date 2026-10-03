import 'package:flutter/material.dart';

import '../../../core/constants/app_colors.dart';
import '../../../core/constants/app_text_styles.dart';
import '../../../core/services/firestore_service.dart';
import '../../../core/services/user_provisioning_service.dart';
import '../../../core/state/app_state.dart';
import '../../../models/user.dart';
import '../../../shared/widgets/form_field_decoration.dart';
import '../../../shared/widgets/form_layout.dart';
import '../../../shared/widgets/primary_button.dart';
import '../../../models/guidance_position.dart';
import '../widgets/position_management_dialog.dart';

/// Create User screen for the System Administrator.
///
/// Creates ONLY Guidance Council accounts -- role is fixed, not a choice on
/// this form. System Administrator accounts remain an external/manual
/// provisioning step for now (per the approved architecture), so
/// `system_admin` is deliberately not offered here.
///
/// The admin never sees or sets a password: [UserProvisioningService]
/// creates the Firebase Authentication account with a single-use random
/// password the admin never has access to, then emails the new user a
/// password-setup link.
///
/// The account holder's own personal profile (First Name / Last Name /
/// Middle Initial / Display Name / Position) is OPTIONAL here -- the admin
/// only authorizes the account (email, role, active status); the new user
/// completes their own profile on Mobile Profile Setup at first sign-in
/// (see `AppRoutes`/`ProfileSetupScreen`). Leaving these blank is the
/// normal case, not an error. Providing any part of the structured name
/// still requires the whole name to be valid -- same "required once any
/// part is filled in" rule [UserNameRules] already enforces on
/// `EditUserScreen`, so a half-typed name can never be silently saved here
/// either.
class CreateUserScreen extends StatefulWidget {
  /// [provisioningService]/[firestoreService] are only for tests; the app
  /// uses the real ones.
  const CreateUserScreen({super.key, this.provisioningService, this.firestoreService});

  final UserProvisioningService? provisioningService;
  final FirestoreService? firestoreService;

  @override
  State<CreateUserScreen> createState() => _CreateUserScreenState();
}

class _CreateUserScreenState extends State<CreateUserScreen> {
  late final UserProvisioningService _provisioningService =
      widget.provisioningService ?? UserProvisioningService();
  late final FirestoreService _firestoreService =
      widget.firestoreService ?? FirestoreService();

  final _formKey = GlobalKey<FormState>();

  final _emailController = TextEditingController();
  final _firstNameController = TextEditingController();
  final _middleInitialController = TextEditingController();
  final _lastNameController = TextEditingController();
  final _displayNameController = TextEditingController();
  final _institutionController = TextEditingController(text: 'NDMU');

  String? _guidancePosition;
  bool _isSaving = false;

  static const _emailPattern = r'^[^@\s]+@[^@\s]+\.[^@\s]+$';

  /// Same "required once any part is filled in, optional when all three are
  /// left untouched" rule [EditUserScreen] already uses (see its own
  /// `_structuredNameRequired`) -- an admin who leaves the whole name blank
  /// is deferring it to Mobile Profile Setup, not making a mistake.
  bool get _structuredNameProvided =>
      _firstNameController.text.trim().isNotEmpty ||
      _middleInitialController.text.trim().isNotEmpty ||
      _lastNameController.text.trim().isNotEmpty;

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
  /// positions if this is the very first time it's been opened after this
  /// feature shipped -- see
  /// [FirestoreService.ensureDefaultGuidancePositionsSeeded]'s own doc
  /// comment), then loads the current list into [AppState] so the Position
  /// dropdown below reflects it -- including anything a System Admin has
  /// already added. Best effort: both calls already fall back safely on
  /// their own failure, so this never blocks or breaks the form.
  Future<void> _loadPositions() async {
    final appState = AppStateScope.of(context);
    await _firestoreService.ensureDefaultGuidancePositionsSeeded();
    await appState.loadGuidancePositions(_firestoreService);
  }

  /// Opens Position Management (list + add + delete) instead of going
  /// straight to the add-only dialog. Whatever changed while it was open
  /// (a position added and/or deleted) is picked up by the one
  /// [AppState.loadGuidancePositions] refresh below -- the same refresh
  /// this screen already did after the old add-only dialog closed.
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

  @override
  void dispose() {
    _emailController.dispose();
    _firstNameController.dispose();
    _middleInitialController.dispose();
    _lastNameController.dispose();
    _displayNameController.dispose();
    _institutionController.dispose();
    super.dispose();
  }

  Future<void> _createUser() async {
    if (!_formKey.currentState!.validate()) {
      return;
    }

    final appState = AppStateScope.of(context);
    final admin = appState.currentUser;
    if (admin == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Unable to verify your admin session. Please sign in again.')),
      );
      return;
    }

    setState(() => _isSaving = true);

    try {
      await _provisioningService.createGuidanceCouncilUser(
        email: _emailController.text,
        // Independent of the structured name below -- never derived from it.
        displayName: _displayNameController.text,
        firstName: _firstNameController.text,
        middleInitial: _middleInitialController.text,
        lastName: _lastNameController.text,
        actor: admin,
        guidancePosition: _guidancePosition,
        institution: _institutionController.text.trim().isEmpty ? 'NDMU' : _institutionController.text.trim(),
      );

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Account created. The new user will receive an email to set their password.')),
      );
      Navigator.of(context).pop(true);
    } on EmailAlreadyExistsException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    } on UserProvisioningException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not create the account. Please try again.')),
      );
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.lightBg,
      appBar: AppBar(
        backgroundColor: Colors.white,
        foregroundColor: AppColors.textDark,
        elevation: 0,
        shape: const Border(bottom: BorderSide(color: AppColors.border)),
        title: Text('Create User', style: AppTextStyles.heading(size: 17)),
      ),
      body: SafeArea(
        child: Form(
          key: _formKey,
          child: ListView(
            padding: FormLayout.padding(context),
            children: [
              const FormSectionHeader('Name', first: true),
              Text(
                'Optional -- the account holder can complete this themselves in the app.',
                style: AppTextStyles.caption(),
              ),
              const SizedBox(height: 8),
              _buildTextField(
                label: 'First Name',
                controller: _firstNameController,
                hint: 'e.g., Juan',
                fieldKey: const Key('createUser.firstName'),
                validator: (v) => _structuredNameProvided ? UserNameRules.validateFirstName(v) : null,
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
                    fieldKey: const Key('createUser.middleInitial'),
                    validator: (v) => _structuredNameProvided ? UserNameRules.validateMiddleInitial(v) : null,
                  ),
                ),
              ),
              const SizedBox(height: 12),
              _buildTextField(
                label: 'Last Name',
                controller: _lastNameController,
                hint: 'e.g., Dela Cruz',
                fieldKey: const Key('createUser.lastName'),
                validator: (v) => _structuredNameProvided ? UserNameRules.validateLastName(v) : null,
              ),
              const SizedBox(height: 16),
              const FormSectionHeader('Account'),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppColors.successBg,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  'This creates a Guidance Council account. System Administrator accounts are provisioned separately.',
                  style: AppTextStyles.body(size: 12.5, color: AppColors.successFg),
                ),
              ),
              const SizedBox(height: 16),
              _buildTextField(
                label: 'Email',
                controller: _emailController,
                hint: 'e.g., staff@ndmu.edu.ph',
                required: true,
                fieldKey: const Key('createUser.email'),
                keyboardType: TextInputType.emailAddress,
                validator: (value) {
                  if (value == null || value.trim().isEmpty) return 'Email is required';
                  if (!RegExp(_emailPattern).hasMatch(value.trim())) return 'Enter a valid email address';
                  return null;
                },
              ),
              const SizedBox(height: 12),
              _buildTextField(
                label: 'Display Name',
                controller: _displayNameController,
                hint: 'e.g., Juan Dela Cruz',
                fieldKey: const Key('createUser.displayName'),
              ),
              const SizedBox(height: 16),
              const FormSectionHeader('Guidance Details'),
              _buildGuidancePositionField(),
              const SizedBox(height: 12),
              _buildTextField(
                label: 'Institution',
                controller: _institutionController,
                hint: 'e.g., NDMU',
                required: false,
              ),
              const SizedBox(height: 24),
              PrimaryButton(
                label: _isSaving ? 'Creating...' : 'Create User',
                onPressed: _isSaving ? null : _createUser,
              ),
              const SizedBox(height: 16),
            ],
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
    TextInputType? keyboardType,
    String? Function(String?)? validator,
    Key? fieldKey,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        FieldLabel(label, required: required),
        TextFormField(
          key: fieldKey,
          controller: controller,
          keyboardType: keyboardType,
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
  /// the current position list from [AppState] (see
  /// [AppState.guidancePositions]) rather than a hardcoded map, so a
  /// position added here -- or on Edit User -- is immediately reflected.
  Widget _buildGuidancePositionField() {
    // ensureIncludes: if the position currently picked in this (unsaved)
    // form was deleted via Position Management while this screen was open,
    // it must still appear as a selectable item -- otherwise
    // DropdownButtonFormField asserts because its own value no longer
    // matches any item. Mirrors EditUserScreen's existing safeguard for the
    // same dropdown.
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
              key: const Key('createUser.addPosition'),
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
          key: const Key('createUser.position'),
          initialValue: _guidancePosition,
          isExpanded: true,
          hint: Text(
            'Not set (the account holder can choose this later)',
            style: AppTextStyles.body(size: 13, color: AppColors.textMuted),
          ),
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
