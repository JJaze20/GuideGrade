import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

import '../../../core/constants/app_colors.dart';
import '../../../core/constants/app_text_styles.dart';
import '../../../core/routes/app_routes.dart';
import '../../../core/services/firestore_service.dart';
import '../../../models/batch.dart';
import '../../../models/examinee.dart';
import '../widgets/examinee_list_item.dart';

/// Examinee Management screen for Guidance Council users.
/// Displays all examinees with search and filtering, optionally filtered by batch.
class ExamineeManagementScreen extends StatefulWidget {
  const ExamineeManagementScreen({super.key});

  @override
  State<ExamineeManagementScreen> createState() => _ExamineeManagementScreenState();
}

class _ExamineeManagementScreenState extends State<ExamineeManagementScreen> {
  final FirestoreService _firestoreService = FirestoreService();
  
  final TextEditingController _searchController = TextEditingController();
  
  List<ExamineeModel> _allExaminees = [];
  List<ExamineeModel> _filteredExaminees = [];
  String _selectedSexFilter = 'All'; // All, Male, Female
  bool _isLoading = true;
  
  BatchModel? _filterBatch; // Optional batch filter

  @override
  void initState() {
    super.initState();
    _loadExaminees();
    _searchController.addListener(_onSearchChanged);
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadExaminees() async {
    setState(() => _isLoading = true);
    
    try {
      final args = ModalRoute.of(context)?.settings.arguments as BatchModel?;
      if (args != null) {
        setState(() => _filterBatch = args);
      }
      
      List<ExamineeModel> examinees;
      if (_filterBatch != null) {
        examinees = await _firestoreService.getExamineesByBatchId(_filterBatch!.batchId);
      } else {
        examinees = await _firestoreService.getExaminees();
      }
      
      setState(() {
        _allExaminees = examinees;
        _applyFilters();
        _isLoading = false;
      });
    } catch (e) {
      print('Error loading examinees: $e');
      setState(() => _isLoading = false);
    }
  }

  void _onSearchChanged() {
    _applyFilters();
  }

  void _applyFilters() {
    final searchTerm = _searchController.text.toLowerCase();
    
    setState(() {
      _filteredExaminees = _allExaminees.where((examinee) {
        // Apply sex filter
        if (_selectedSexFilter != 'All') {
          if (_selectedSexFilter == 'Male' && !examinee.isMale) return false;
          if (_selectedSexFilter == 'Female' && !examinee.isFemale) return false;
        }
        
        // Apply search filter
        if (searchTerm.isNotEmpty) {
          return examinee.fullName.toLowerCase().contains(searchTerm) ||
                 examinee.studentNumber.toLowerCase().contains(searchTerm) ||
                 examinee.course.toLowerCase().contains(searchTerm);
        }
        
        return true;
      }).toList();
    });
  }

  void _navigateToCreateExaminee() async {
    final result = await Navigator.of(context).pushNamed(
      AppRoutes.createExaminee,
      arguments: _filterBatch,
    );
    if (result == true) {
      _loadExaminees(); // Refresh if examinee was created
    }
  }

  void _navigateToEditExaminee(ExamineeModel examinee) async {
    final result = await Navigator.of(context).pushNamed(
      AppRoutes.editExaminee,
      arguments: examinee,
    );
    if (result == true) {
      _loadExaminees(); // Refresh if examinee was edited
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
        title: Text(
          _filterBatch != null ? 'Examinees - ${_filterBatch!.batchCode}' : 'Examinee Management',
          style: AppTextStyles.heading(size: 13),
        ),
        actions: [
          IconButton(
            icon: const FaIcon(FontAwesomeIcons.rotateRight, size: 18),
            onPressed: _loadExaminees,
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            _buildSearchAndFilterBar(),
            Expanded(
              child: _isLoading
                  ? const Center(child: CircularProgressIndicator())
                  : _filteredExaminees.isEmpty
                      ? _buildEmptyState()
                      : _buildExamineeList(),
            ),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _navigateToCreateExaminee,
        backgroundColor: AppColors.primaryGreen,
        icon: const FaIcon(FontAwesomeIcons.userPlus, size: 16),
        label: Text('Add Examinee', style: AppTextStyles.body(size: 11, color: Colors.white)),
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
              hintText: 'Search by name, student number, or course...',
              prefixIcon: const Icon(Icons.search, size: 20),
              suffixIcon: _searchController.text.isNotEmpty
                  ? IconButton(
                      icon: const Icon(Icons.clear, size: 20),
                      onPressed: () {
                        _searchController.clear();
                      },
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
                _buildFilterChip('All'),
                const SizedBox(width: 8),
                _buildFilterChip('Male'),
                const SizedBox(width: 8),
                _buildFilterChip('Female'),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFilterChip(String sex) {
    final isSelected = _selectedSexFilter == sex;
    
    return FilterChip(
      label: Text(sex, style: AppTextStyles.body(size: 10.5)),
      selected: isSelected,
      onSelected: (selected) {
        setState(() {
          _selectedSexFilter = sex;
          _applyFilters();
        });
      },
      selectedColor: AppColors.primaryGreen.withOpacity(0.1),
      checkmarkColor: AppColors.primaryGreen,
      backgroundColor: AppColors.lightBg,
      labelStyle: AppTextStyles.body(
        size: 10.5,
        color: isSelected ? AppColors.primaryGreen : AppColors.textDark,
      ),
    );
  }

  Widget _buildExamineeList() {
    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: _filteredExaminees.length,
      itemBuilder: (context, index) {
        final examinee = _filteredExaminees[index];
        return Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: ExamineeListItem(
            examinee: examinee,
            onTap: () => _navigateToEditExaminee(examinee),
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
          const FaIcon(FontAwesomeIcons.users, size: 48, color: AppColors.textGray),
          const SizedBox(height: 16),
          Text(
            'No examinees found',
            style: AppTextStyles.body(size: 12, weight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          Text(
            _searchController.text.isNotEmpty || _selectedSexFilter != 'All'
                ? 'Try adjusting your search or filters'
                : 'Add examinees to get started',
            style: AppTextStyles.body(size: 10, color: AppColors.textGray),
          ),
        ],
      ),
    );
  }
}
