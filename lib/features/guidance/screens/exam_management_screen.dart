import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

import '../../../core/constants/app_colors.dart';
import '../../../core/constants/app_text_styles.dart';
import '../../../core/routes/app_routes.dart';
import '../../../core/services/firestore_service.dart';
import '../../../models/exam.dart';
import '../widgets/exam_list_item.dart';

/// Exam Management screen for Guidance Council users.
/// Displays all exams with search and create functionality.
class ExamManagementScreen extends StatefulWidget {
  const ExamManagementScreen({super.key});

  @override
  State<ExamManagementScreen> createState() => _ExamManagementScreenState();
}

class _ExamManagementScreenState extends State<ExamManagementScreen> {
  final FirestoreService _firestoreService = FirestoreService();
  
  final TextEditingController _searchController = TextEditingController();
  
  List<ExamModel> _allExams = [];
  List<ExamModel> _filteredExams = [];
  String _selectedStatusFilter = 'All'; // All, Draft, Ready, Archived
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadExams();
    _searchController.addListener(_onSearchChanged);
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadExams() async {
    setState(() => _isLoading = true);
    
    try {
      final exams = await _firestoreService.getExams();
      setState(() {
        _allExams = exams;
        _applyFilters();
        _isLoading = false;
      });
    } catch (e) {
      print('Error loading exams: $e');
      setState(() => _isLoading = false);
    }
  }

  void _onSearchChanged() {
    _applyFilters();
  }

  void _applyFilters() {
    final searchTerm = _searchController.text.toLowerCase();
    
    setState(() {
      _filteredExams = _allExams.where((exam) {
        // Apply status filter
        if (_selectedStatusFilter != 'All' && exam.status != _selectedStatusFilter) {
          return false;
        }
        
        // Apply search filter
        if (searchTerm.isNotEmpty) {
          return exam.title.toLowerCase().contains(searchTerm) ||
                 exam.examCode.toLowerCase().contains(searchTerm);
        }
        
        return true;
      }).toList();
    });
  }

  void _navigateToCreateExam() async {
    final result = await Navigator.of(context).pushNamed(AppRoutes.createExam);
    if (result == true) {
      _loadExams(); // Refresh if exam was created
    }
  }

  void _navigateToEditExam(ExamModel exam) async {
    final result = await Navigator.of(context).pushNamed(
      AppRoutes.editExam,
      arguments: exam,
    );
    if (result == true) {
      _loadExams(); // Refresh if exam was edited
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
        title: Text('Exam Management', style: AppTextStyles.heading(size: 13)),
        actions: [
          IconButton(
            icon: const FaIcon(FontAwesomeIcons.rotateRight, size: 18),
            onPressed: _loadExams,
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
                  : _filteredExams.isEmpty
                      ? _buildEmptyState()
                      : _buildExamList(),
            ),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _navigateToCreateExam,
        backgroundColor: AppColors.primaryGreen,
        icon: const FaIcon(FontAwesomeIcons.plus, size: 16),
        label: Text('Create Exam', style: AppTextStyles.body(size: 11, color: Colors.white)),
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
              hintText: 'Search by title or exam code...',
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
                _buildFilterChip('Draft'),
                const SizedBox(width: 8),
                _buildFilterChip('Ready'),
                const SizedBox(width: 8),
                _buildFilterChip('Archived'),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFilterChip(String status) {
    final isSelected = _selectedStatusFilter == status;
    
    return FilterChip(
      label: Text(status, style: AppTextStyles.body(size: 10.5)),
      selected: isSelected,
      onSelected: (selected) {
        setState(() {
          _selectedStatusFilter = status;
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

  Widget _buildExamList() {
    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: _filteredExams.length,
      itemBuilder: (context, index) {
        final exam = _filteredExams[index];
        return Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: ExamListItem(
            exam: exam,
            onTap: () => _navigateToEditExam(exam),
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
          const FaIcon(FontAwesomeIcons.fileLines, size: 48, color: AppColors.textGray),
          const SizedBox(height: 16),
          Text(
            'No exams found',
            style: AppTextStyles.body(size: 12, weight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          Text(
            _searchController.text.isNotEmpty || _selectedStatusFilter != 'All'
                ? 'Try adjusting your search or filters'
                : 'Create your first exam to get started',
            style: AppTextStyles.body(size: 10, color: AppColors.textGray),
          ),
        ],
      ),
    );
  }
}
