import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

import '../../../core/constants/app_colors.dart';
import '../../../core/constants/app_text_styles.dart';
import '../../../core/routes/app_routes.dart';
import '../../../core/services/firestore_service.dart';
import '../../../models/batch.dart';
import '../widgets/batch_list_item.dart';

/// Batch Management screen for Guidance Council users.
/// Displays all batches with search and create functionality.
class BatchManagementScreen extends StatefulWidget {
  const BatchManagementScreen({super.key});

  @override
  State<BatchManagementScreen> createState() => _BatchManagementScreenState();
}

class _BatchManagementScreenState extends State<BatchManagementScreen> {
  final FirestoreService _firestoreService = FirestoreService();
  
  final TextEditingController _searchController = TextEditingController();
  
  List<BatchModel> _allBatches = [];
  List<BatchModel> _filteredBatches = [];
  String _selectedStatusFilter = 'All'; // All, Draft, Active, Completed, Archived
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadBatches();
    _searchController.addListener(_onSearchChanged);
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadBatches() async {
    setState(() => _isLoading = true);
    
    try {
      final batches = await _firestoreService.getBatches();
      setState(() {
        _allBatches = batches;
        _applyFilters();
        _isLoading = false;
      });
    } catch (e) {
      print('Error loading batches: $e');
      setState(() => _isLoading = false);
    }
  }

  void _onSearchChanged() {
    _applyFilters();
  }

  void _applyFilters() {
    final searchTerm = _searchController.text.toLowerCase();
    
    setState(() {
      _filteredBatches = _allBatches.where((batch) {
        // Apply status filter
        if (_selectedStatusFilter != 'All' && batch.status != _selectedStatusFilter) {
          return false;
        }
        
        // Apply search filter
        if (searchTerm.isNotEmpty) {
          return batch.description.toLowerCase().contains(searchTerm) ||
                 batch.batchCode.toLowerCase().contains(searchTerm) ||
                 batch.examTitle.toLowerCase().contains(searchTerm);
        }
        
        return true;
      }).toList();
    });
  }

  void _navigateToCreateBatch() async {
    final result = await Navigator.of(context).pushNamed(AppRoutes.createBatch);
    if (result == true) {
      _loadBatches(); // Refresh if batch was created
    }
  }

  void _navigateToEditBatch(BatchModel batch) async {
    final result = await Navigator.of(context).pushNamed(
      AppRoutes.editBatch,
      arguments: batch,
    );
    if (result == true) {
      _loadBatches(); // Refresh if batch was edited
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
        title: Text('Batch Management', style: AppTextStyles.heading(size: 13)),
        actions: [
          IconButton(
            icon: const FaIcon(FontAwesomeIcons.rotateRight, size: 18),
            onPressed: _loadBatches,
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
                  : _filteredBatches.isEmpty
                      ? _buildEmptyState()
                      : _buildBatchList(),
            ),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _navigateToCreateBatch,
        backgroundColor: AppColors.primaryGreen,
        icon: const FaIcon(FontAwesomeIcons.folderPlus, size: 16),
        label: Text('Create Batch', style: AppTextStyles.body(size: 11, color: Colors.white)),
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
              hintText: 'Search by description, batch code, or exam...',
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
                _buildFilterChip('Active'),
                const SizedBox(width: 8),
                _buildFilterChip('Completed'),
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

  Widget _buildBatchList() {
    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: _filteredBatches.length,
      itemBuilder: (context, index) {
        final batch = _filteredBatches[index];
        return Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: BatchListItem(
            batch: batch,
            onTap: () => _navigateToEditBatch(batch),
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
          const FaIcon(FontAwesomeIcons.folderOpen, size: 48, color: AppColors.textGray),
          const SizedBox(height: 16),
          Text(
            'No batches found',
            style: AppTextStyles.body(size: 12, weight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          Text(
            _searchController.text.isNotEmpty || _selectedStatusFilter != 'All'
                ? 'Try adjusting your search or filters'
                : 'Create your first batch to get started',
            style: AppTextStyles.body(size: 10, color: AppColors.textGray),
          ),
        ],
      ),
    );
  }
}
