import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

import '../../../core/constants/app_colors.dart';
import '../../../core/constants/app_text_styles.dart';
import '../../../core/routes/app_routes.dart';
import '../../../core/services/firestore_service.dart';
import '../../../models/user.dart';
import '../widgets/user_list_item.dart';

/// User Management screen for the System Administrator.
/// Lists authorized accounts (System Admin and Guidance Council) with
/// search and filtering. Shows only account/administrative fields --
/// nothing examination-related, since [UserModel] has no such fields.
class UserManagementScreen extends StatefulWidget {
  const UserManagementScreen({super.key});

  @override
  State<UserManagementScreen> createState() => _UserManagementScreenState();
}

class _UserManagementScreenState extends State<UserManagementScreen> {
  final FirestoreService _firestoreService = FirestoreService();
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.lightBg,
      appBar: AppBar(
        backgroundColor: Colors.white,
        foregroundColor: AppColors.textDark,
        elevation: 0.5,
        title: Text('User Management', style: AppTextStyles.heading(size: 13)),
      ),
      body: SafeArea(
        child: StreamBuilder<List<UserModel>>(
          // Live updates (a created/edited/deactivated user is reflected
          // immediately) rather than manual pull-to-refresh.
          stream: _firestoreService.usersStream(),
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return const Center(child: CircularProgressIndicator());
            }
            if (snapshot.hasError) {
              return _buildErrorState();
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
        icon: const FaIcon(FontAwesomeIcons.userPlus, size: 16),
        label: Text('Create User', style: AppTextStyles.body(size: 11, color: Colors.white)),
      ),
    );
  }

  Widget _buildSearchAndFilterBar() {
    return Container(
      padding: const EdgeInsets.all(16),
      color: Colors.white,
      child: Column(
        children: [
          TextField(
            controller: _searchController,
            decoration: InputDecoration(
              hintText: 'Search by name or email...',
              prefixIcon: const Icon(Icons.search, size: 20),
              suffixIcon: _searchController.text.isNotEmpty
                  ? IconButton(
                      icon: const Icon(Icons.clear, size: 20),
                      onPressed: _searchController.clear,
                    )
                  : null,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(color: AppColors.cardBorder),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(color: AppColors.cardBorder),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(color: AppColors.primaryGreen),
              ),
              contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            ),
          ),
          const SizedBox(height: 12),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                Text('Role: ', style: AppTextStyles.body(size: 10, color: AppColors.textGray)),
                const SizedBox(width: 4),
                _buildFilterChip(_roleFilter, 'All', (v) => setState(() => _roleFilter = v)),
                const SizedBox(width: 8),
                _buildFilterChip(_roleFilter, 'System Admin', (v) => setState(() => _roleFilter = v)),
                const SizedBox(width: 8),
                _buildFilterChip(_roleFilter, 'Guidance Council', (v) => setState(() => _roleFilter = v)),
              ],
            ),
          ),
          const SizedBox(height: 8),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                Text('Status: ', style: AppTextStyles.body(size: 10, color: AppColors.textGray)),
                const SizedBox(width: 4),
                _buildFilterChip(_statusFilter, 'All', (v) => setState(() => _statusFilter = v)),
                const SizedBox(width: 8),
                _buildFilterChip(_statusFilter, 'Active', (v) => setState(() => _statusFilter = v)),
                const SizedBox(width: 8),
                _buildFilterChip(_statusFilter, 'Inactive', (v) => setState(() => _statusFilter = v)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFilterChip(String currentValue, String label, void Function(String) onSelect) {
    final isSelected = currentValue == label;
    return FilterChip(
      label: Text(label, style: AppTextStyles.body(size: 10.5)),
      selected: isSelected,
      onSelected: (_) => onSelect(label),
      selectedColor: AppColors.primaryGreen.withOpacity(0.1),
      checkmarkColor: AppColors.primaryGreen,
      backgroundColor: AppColors.lightBg,
      labelStyle: AppTextStyles.body(
        size: 10.5,
        color: isSelected ? AppColors.primaryGreen : AppColors.textDark,
      ),
    );
  }

  Widget _buildUserList(List<UserModel> users) {
    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: users.length,
      itemBuilder: (context, index) {
        final user = users[index];
        return Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: UserListItem(
            user: user,
            onTap: () => _navigateToEditUser(user),
          ),
        );
      },
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const FaIcon(FontAwesomeIcons.userGroup, size: 48, color: AppColors.textGray),
          const SizedBox(height: 16),
          Text('No users found', style: AppTextStyles.body(size: 12, weight: FontWeight.w600)),
          const SizedBox(height: 8),
          Text(
            _searchController.text.isNotEmpty || _roleFilter != 'All' || _statusFilter != 'All'
                ? 'Try adjusting your search or filters'
                : 'Create a user to get started',
            style: AppTextStyles.body(size: 10, color: AppColors.textGray),
          ),
        ],
      ),
    );
  }

  Widget _buildErrorState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const FaIcon(FontAwesomeIcons.triangleExclamation, size: 40, color: AppColors.warmRedOrange),
          const SizedBox(height: 12),
          Text('Could not load users', style: AppTextStyles.body(size: 12, weight: FontWeight.w600)),
        ],
      ),
    );
  }
}
