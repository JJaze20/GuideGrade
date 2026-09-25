import 'package:flutter/material.dart';

import '../../../core/constants/app_colors.dart';
import '../../../core/constants/app_text_styles.dart';
import '../../../core/services/user_provisioning_service.dart';
import '../../../core/state/app_state.dart';
import '../../../models/user.dart';
import '../../../shared/widgets/primary_button.dart';

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
class CreateUserScreen extends StatefulWidget {
  /// [provisioningService] is only for tests; the app uses the real one.
  const CreateUserScreen({super.key, this.provisioningService});

  final UserProvisioningService? provisioningService;

  @override
  State<CreateUserScreen> createState() => _CreateUserScreenState();
}

class _CreateUserScreenState extends State<CreateUserScreen> {
  late final UserProvisioningService _provisioningService =
      widget.provisioningService ?? UserProvisioningService();

  final _formKey = GlobalKey<FormState>();

  final _emailController = TextEditingController();
  final _firstNameController = TextEditingController();
  final _middleInitialController = TextEditingController();
  final _lastNameController = TextEditingController();
  final _displayNameController = TextEditingController();
  final _institutionController = TextEditingController(text: 'NDMU');

  String _guidancePosition = 'guidance_staff';
  bool _isSaving = false;

  static const _emailPattern = r'^[^@\s]+@[^@\s]+\.[^@\s]+$';

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
        elevation: 0.5,
        title: Text('Create User', style: AppTextStyles.heading(size: 13)),
      ),
      body: SafeArea(
        child: Form(
          key: _formKey,
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              _buildSection('Name'),
              const SizedBox(height: 16),
              _buildTextField(
                label: 'First Name',
                controller: _firstNameController,
                hint: 'e.g., Juan',
                required: true,
                fieldKey: const Key('createUser.firstName'),
                validator: UserNameRules.validateFirstName,
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
                    fieldKey: const Key('createUser.middleInitial'),
                    validator: UserNameRules.validateMiddleInitial,
                  ),
                ),
              ),
              const SizedBox(height: 12),
              _buildTextField(
                label: 'Last Name',
                controller: _lastNameController,
                hint: 'e.g., Dela Cruz',
                required: true,
                fieldKey: const Key('createUser.lastName'),
                validator: UserNameRules.validateLastName,
              ),
              const SizedBox(height: 16),
              _buildSection('Account'),
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppColors.emerald100,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  'This creates a Guidance Council account. System Administrator accounts are provisioned separately.',
                  style: AppTextStyles.body(size: 10, color: const Color(0xFF065F46)),
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
                required: true,
                fieldKey: const Key('createUser.displayName'),
              ),
              const SizedBox(height: 16),
              _buildSection('Guidance Details'),
              const SizedBox(height: 16),
              _buildDropdown(
                label: 'Guidance Position',
                value: _guidancePosition,
                items: const {
                  'guidance_head': 'Guidance Head',
                  'psychometrician': 'Psychometrician',
                  'guidance_staff': 'Guidance Staff',
                },
                onChanged: (value) {
                  if (value != null) setState(() => _guidancePosition = value);
                },
              ),
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

  Widget _buildSection(String title) {
    return Text(
      title,
      style: AppTextStyles.body(size: 11, weight: FontWeight.w700, color: AppColors.primaryGreen),
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
          keyboardType: keyboardType,
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

  Widget _buildDropdown({
    required String label,
    required String value,
    required Map<String, String> items,
    required void Function(String?) onChanged,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: AppTextStyles.body(size: 10.5, weight: FontWeight.w600)),
        const SizedBox(height: 6),
        DropdownButtonFormField<String>(
          value: value,
          decoration: InputDecoration(
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
          items: items.entries
              .map((e) => DropdownMenuItem(value: e.key, child: Text(e.value, style: AppTextStyles.body(size: 11))))
              .toList(),
          onChanged: onChanged,
        ),
      ],
    );
  }
}
