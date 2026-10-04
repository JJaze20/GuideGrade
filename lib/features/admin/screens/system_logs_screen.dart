import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

import '../../../core/constants/app_colors.dart';
import '../../../core/constants/app_text_styles.dart';
import '../../../core/constants/app_tokens.dart';
import '../../../core/services/firestore_service.dart';
import '../../../core/services/logging_service.dart';
import '../../../models/log_entry.dart';
import '../../../shared/widgets/form_field_decoration.dart';
import '../../../shared/widgets/state_views.dart';
import '../widgets/log_list_item.dart';

/// System Logs screen for the System Administrator -- a read-only audit
/// trail. There is deliberately no edit, delete, or bulk-delete affordance
/// anywhere on this screen: the deployed Firestore rules make `logs`
/// append-only for every role, including `system_admin`, so no such action
/// could ever succeed even if a control existed for it.
class SystemLogsScreen extends StatefulWidget {
  /// [loggingService] is only for tests; the app uses the real one.
  const SystemLogsScreen({super.key, this.loggingService});

  final LoggingService? loggingService;

  @override
  State<SystemLogsScreen> createState() => _SystemLogsScreenState();
}

class _SystemLogsScreenState extends State<SystemLogsScreen> {
  late final LoggingService _loggingService = widget.loggingService ?? LoggingService();
  final _searchController = TextEditingController();

  String _categoryFilter = 'All';
  String _severityFilter = 'All';

  final List<LogEntry> _logs = [];
  DocumentSnapshot? _lastDocument;
  bool _hasMore = false;
  bool _isLoading = true;
  bool _isLoadingMore = false;
  bool _hasError = false;

  /// The original error behind [_hasError], for message classification via
  /// [FirestoreService.messageFor]. Null whenever [_hasError] is false.
  Object? _errorCause;

  static const int _pageSize = 100;

  @override
  void initState() {
    super.initState();
    _searchController.addListener(() => setState(() {}));
    _loadInitial();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadInitial() async {
    setState(() {
      _isLoading = true;
      _hasError = false;
      _errorCause = null;
    });
    final page = await _loggingService.getRecentLogs(limit: _pageSize);
    if (!mounted) return;
    setState(() {
      _logs
        ..clear()
        ..addAll(page.entries);
      _lastDocument = page.lastDocument;
      _hasMore = page.hasMore;
      _isLoading = false;
      // getRecentLogs never throws (it swallows and returns LogPage.error()),
      // so this is the one signal that distinguishes a genuinely empty
      // result from a failed read -- see LogPage.isError's doc comment.
      _hasError = page.isError;
      _errorCause = page.cause;
    });
  }

  Future<void> _loadMore() async {
    if (_isLoadingMore || !_hasMore) return;
    setState(() => _isLoadingMore = true);
    final page = await _loggingService.getRecentLogs(limit: _pageSize, startAfter: _lastDocument);
    if (!mounted) return;
    if (page.isError) {
      // A pagination failure must not disturb the logs already loaded and
      // showing, or the whole-screen error state -- only the initial load
      // does that. _hasMore is left as-is, so the existing "Load More"
      // button just reappears for the user to retry.
      setState(() => _isLoadingMore = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not load more logs. Please try again.')),
      );
      return;
    }
    setState(() {
      _logs.addAll(page.entries);
      _lastDocument = page.lastDocument;
      _hasMore = page.hasMore;
      _isLoadingMore = false;
    });
  }

  List<LogEntry> get _filteredLogs {
    final term = _searchController.text.trim().toLowerCase();
    return _logs.where((log) {
      if (_categoryFilter != 'All' && log.category != _categoryFilter) return false;
      if (_severityFilter != 'All' && log.severity != _severityFilter) return false;
      if (term.isNotEmpty) {
        return log.actorEmail.toLowerCase().contains(term) || log.description.toLowerCase().contains(term);
      }
      return true;
    }).toList();
  }

  void _showLogDetail(LogEntry log) {
    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(log.action, style: AppTextStyles.heading(size: 16)),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              _buildDetailRow('Description', log.description),
              _buildDetailRow('Category', log.category),
              _buildDetailRow('Severity', log.severity),
              _buildDetailRow('Success', log.success ? 'Yes' : 'No'),
              _buildDetailRow('Actor', '${log.actorEmail} (${log.actorRole})'),
              _buildDetailRow('Actor UID', log.actorUid),
              if (log.targetUserEmail != null) _buildDetailRow('Target', log.targetUserEmail!),
              _buildDetailRow('Timestamp', log.timestamp?.toLocal().toString() ?? 'Pending server confirmation'),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(dialogContext).pop(), child: const Text('Close')),
        ],
      ),
    );
  }

  Widget _buildDetailRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpace.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: AppTextStyles.label()),
          const SizedBox(height: 2),
          Text(value, style: AppTextStyles.text()),
        ],
      ),
    );
  }

  bool get _filtersActive =>
      _searchController.text.isNotEmpty || _categoryFilter != 'All' || _severityFilter != 'All';

  void _clearFilters() {
    setState(() {
      _searchController.clear();
      _categoryFilter = 'All';
      _severityFilter = 'All';
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
        title: Text('System Logs', style: AppTextStyles.heading(size: 17)),
        actions: [
          IconButton(
            tooltip: 'Refresh logs',
            icon: const FaIcon(FontAwesomeIcons.rotateRight, size: 18),
            onPressed: _loadInitial,
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            _buildSearchAndFilterBar(),
            Expanded(
              child: _isLoading
                  ? const LoadingState(message: 'Loading logs…')
                  : _hasError
                      ? _buildErrorState()
                      : _filteredLogs.isEmpty
                          ? _buildEmptyState()
                          : _buildLogList(),
            ),
          ],
        ),
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
                hint: 'Search by actor email or description',
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
            _filterGroup(
              'Category',
              _categoryFilter,
              const [
                'All',
                LogCategory.authentication,
                LogCategory.userManagement,
                LogCategory.authorization,
              ],
              (v) => setState(() => _categoryFilter = v),
            ),
            const SizedBox(height: AppSpace.sm),
            _filterGroup(
              'Severity',
              _severityFilter,
              const ['All', LogSeverity.info, LogSeverity.warning],
              (v) => setState(() => _severityFilter = v),
            ),
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
        SizedBox(width: 72, child: Text(label, style: AppTextStyles.label())),
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

  Widget _buildLogList() {
    final logs = _filteredLogs;
    return _centered(
      ListView.builder(
        padding: const EdgeInsets.all(AppSpace.lg),
        itemCount: logs.length + (_hasMore ? 1 : 0),
        itemBuilder: (context, index) {
          if (index >= logs.length) {
            return Padding(
              padding: const EdgeInsets.only(top: AppSpace.xs, bottom: AppSpace.lg),
              child: Center(
                child: _isLoadingMore
                    ? const CircularProgressIndicator()
                    : OutlinedButton(
                        onPressed: _loadMore,
                        style: OutlinedButton.styleFrom(
                          foregroundColor: AppColors.primaryGreen,
                          side: const BorderSide(color: AppColors.primaryGreen),
                        ),
                        child: const Text('Load More'),
                      ),
              ),
            );
          }
          final log = logs[index];
          return Padding(
            padding: const EdgeInsets.only(bottom: AppSpace.md),
            child: LogListItem(log: log, onTap: () => _showLogDetail(log)),
          );
        },
      ),
    );
  }

  Widget _buildEmptyState() {
    return EmptyState(
      icon: Icons.assignment_outlined,
      title: 'No logs found',
      message: _filtersActive
          ? 'Try adjusting your search or filters'
          : 'System activity will appear here as it happens',
      action: _filtersActive
          ? OutlinedButton(onPressed: _clearFilters, child: const Text('Clear filters'))
          : null,
    );
  }

  Widget _buildErrorState() {
    final cause = _errorCause;
    final message = cause == null
        ? 'Could not load logs'
        : FirestoreService.messageFor(cause, fallback: 'Could not load logs');
    return ErrorState(message: message, onRetry: _loadInitial);
  }
}
