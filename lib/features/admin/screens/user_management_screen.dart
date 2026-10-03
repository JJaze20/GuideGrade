import 'package:flutter/material.dart';

import '../../../core/constants/app_colors.dart';
import '../../../core/constants/app_text_styles.dart';
import '../../../core/constants/app_tokens.dart';
import '../../../core/routes/app_routes.dart';
import '../../../core/services/firestore_service.dart';
import '../../../models/user.dart';
import '../../../shared/widgets/form_field_decoration.dart';
import '../../../shared/widgets/state_views.dart';
import '../widgets/user_list_item.dart';

/// User Management screen for the System Administrator.
/// Lists authorized accounts (System Admin and Guidance Council) with
/// search and filtering. Shows only account/administrative fields --
/// nothing examination-related, since [UserModel] has no such fields.
class UserManagementScreen extends StatefulWidget {
  /// [firestoreService] is only for tests; the app uses the real one.
  const UserManagementScreen({super.key, this.firestoreService});

  final FirestoreService? firestoreService;

  @override
  State<UserManagementScreen> createState() => _UserManagementScreenState();
}

class _UserManagementScreenState extends State<UserManagementScreen> {
  late final FirestoreService _firestoreService =
      widget.firestoreService ?? FirestoreService();

  // A single, stable Stream for this screen's whole lifetime. Search text
  // and the role/status filter chips are handled entirely client-side (see
  // _applyFilters) via plain setState -- they never need a new Firestore
  // query. Calling _firestoreService.usersStream() fresh inside build()
  // (as this used to) hands StreamBuilder a new Stream object on every one
  // of those setState calls; StreamBuilder treats that as an entirely
  // different stream, cancels the live Firestore subscription, resets to
  // ConnectionState.waiting, and the whole screen -- including the search
  // TextField itself -- is briefly unmounted and replaced by a spinner.
  // That's what made typing feel like the screen kept "refreshing" and
  // losing focus: the fix is simply to never call usersStream() more than
  // once.
  late final Stream<List<UserModel>> _usersStream = _firestoreService.usersStream();

  final TextEditingController _searchController = TextEditingController();

  String _roleFilter = 'All'; // All, System Admin, Guidance Council
  String _statusFilter = 'All'; // All, Active, Inactive

  @override
  void initState() {
    super.initState();
    _searchController.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  List<UserModel> _applyFilters(List<UserModel> users) {
    final term = _searchController.text.trim().toLowerCase();
    return users.where((user) {
      if (_roleFilter == 'System Admin' && user.role != 'system_admin') return false;
      if (_roleFilter == 'Guidance Council' && user.role != 'guidance_council') return false;
      if (_statusFilter == 'Active' && !user.isActive) return false;
      if (_statusFilter == 'Inactive' && user.isActive) return false;

      if (term.isNotEmpty) {
        return user.displayName.toLowerCase().contains(term) || user.email.toLowerCase().contains(term);
      }
      return true;
    }).toList();
  }

  void _navigateToCreateUser() {
    Navigator.of(context).pushNamed(AppRoutes.createUser);
  }

  void _navigateToEditUser(UserModel user) {
    Navigator.of(context).pushNamed(AppRoutes.editUser, arguments: user);
  }

  bool get _filtersActive =>
      _searchController.text.isNotEmpty || _roleFilter != 'All' || _statusFilter != 'All';

  void _clearFilters() {
    setState(() {
      _searchController.clear();
      _roleFilter = 'All';
      _statusFilter = 'All';
    });
  }

  /// Keeps the toolbar and list readable on wide desktop windows.
  Widget _centered(Widget child) => Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 960), child: child),
      );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.lightBg,
      appBar: AppBar(
        backgroundColor: Colors.white,
        foregroundColor: AppColors.textDark,
        elevation: 0,
        shape: const Border(bottom: BorderSide(color: AppColors.border)),
        title: Text('User Management', style: AppTextStyles.heading(size: 17)),
      ),
      body: SafeArea(
        child: StreamBuilder<List<UserModel>>(
          // Live updates (a created/edited/deactivated user is reflected
          // immediately) rather than manual pull-to-refresh. Reuses the
          // one stable _usersStream (see its own doc comment) -- never
          // calls usersStream() here directly.
          stream: _usersStream,
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return const LoadingState(message: 'Loading users…');
            }
            if (snapshot.hasError) {
              return _buildErrorState(snapshot.error);
            }

            final users = _applyFilters(snapshot.data ?? []);

            return Column(
              children: [
                _buildSearchAndFilterBar(),
                Expanded(
                  child: users.isEmpty ? _buildEmptyState() : _buildUserList(users),
                ),
              ],
            );
          },
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _navigateToCreateUser,
        backgroundColor: AppColors.primaryGreen,
        foregroundColor: Colors.white,
        icon: const Icon(Icons.person_add_alt_1_rounded, size: 20),
        label: Text('Create User', style: AppTextStyles.body(size: 13, weight: FontWeight.w700, color: Colors.white)),
      ),
    );
  }

  Widget _buildSearchAndFilterBar() {
    return Container(
      width: double.infinity,
      decoration: const BoxDecoration(
        color: AppColors.surface,
        border: Border(bottom: BorderSide(color: AppColors.border)),
      ),
      padding: const EdgeInsets.all(AppSpace.lg),
      child: _centered(
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _searchController,
              decoration: FormFieldStyle.outlined(
                hint: 'Search by name or email',
                prefixIcon: const Icon(Icons.search, size: 20),
                suffixIcon: _searchController.text.isNotEmpty
                    ? IconButton(
                        tooltip: 'Clear search',
                        icon: const Icon(Icons.clear, size: 20),
                        onPressed: _searchController.clear,
                      )
                    : null,
              ),
            ),
            const SizedBox(height: AppSpace.md),
            _filterGroup('Role', _roleFilter, const ['All', 'System Admin', 'Guidance Council'],
                (v) => setState(() => _roleFilter = v)),
            const SizedBox(height: AppSpace.sm),
            _filterGroup('Status', _statusFilter, const ['All', 'Active', 'Inactive'],
                (v) => setState(() => _statusFilter = v)),
          ],
        ),
      ),
    );
  }

  /// A labelled group of filter chips that WRAPS on narrow screens instead of
  /// forcing a sideways scroll.
  Widget _filterGroup(
    String label,
    String current,
    List<String> options,
    void Function(String) onSelect,
  ) {
    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: AppSpace.sm,
      runSpacing: AppSpace.xs,
      children: [
        SizedBox(width: 52, child: Text(label, style: AppTextStyles.label())),
        for (final option in options) _buildFilterChip(current, option, onSelect),
      ],
    );
  }

  Widget _buildFilterChip(String currentValue, String label, void Function(String) onSelect) {
    final isSelected = currentValue == label;
    return FilterChip(
      label: Text(label),
      selected: isSelected,
      onSelected: (_) => onSelect(label),
      showCheckmark: false,
      selectedColor: AppColors.successBg,
      backgroundColor: AppColors.surface,
      side: BorderSide(color: isSelected ? AppColors.successBorder : AppColors.borderStrong),
      labelStyle: AppTextStyles.body(
        size: 12.5,
        weight: isSelected ? FontWeight.w800 : FontWeight.w600,
        color: isSelected ? AppColors.primaryGreen : AppColors.textDark,
      ),
    );
  }

  Widget _buildUserList(List<UserModel> users) {
    return _centered(
      ListView.separated(
        padding: const EdgeInsets.all(AppSpace.lg),
        // Leaves room so the last card is never hidden behind the FAB.
        itemCount: users.length,
        separatorBuilder: (_, _) => const SizedBox(height: AppSpace.md),
        itemBuilder: (context, index) {
          final user = users[index];
          return UserListItem(user: user, onTap: () => _navigateToEditUser(user));
        },
      ),
    );
  }

  Widget _buildEmptyState() {
    return EmptyState(
      icon: Icons.group_outlined,
      title: 'No users found',
      message: _filtersActive ? 'Try adjusting your search or filters' : 'Create a user to get started',
      action: _filtersActive
          ? OutlinedButton(onPressed: _clearFilters, child: const Text('Clear filters'))
          : null,
    );
  }

  Widget _buildErrorState(Object? error) {
    final message = error == null
        ? 'Could not load users'
        : FirestoreService.messageFor(error, fallback: 'Could not load users');
    return ErrorState(message: message);
  }
}
