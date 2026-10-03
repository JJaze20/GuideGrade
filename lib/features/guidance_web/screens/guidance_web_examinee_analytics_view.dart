import 'package:flutter/material.dart';

import '../../../core/constants/app_colors.dart';
import '../../../core/constants/app_text_styles.dart';
import '../../../shared/widgets/state_views.dart';
import '../../../models/examinee_record.dart';
import '../services/guidance_web_examinee_records_service.dart';
import '../services/guidance_web_results_service.dart';
import 'guidance_web_result_detail_view.dart';

/// Analytics → Examinee Analytics: pick one examinee, then open any of their
/// AT / QTM results to see Examinee Information, Result Summary, the scanned
/// sheet and the Cluster Analysis table. It reuses
/// [GuidanceWebResultDetailView] (in its cluster mode) rather than a second
/// result implementation. AT, QTM and TAT show cluster analysis and category.
///
/// An Examinee / Unlinked Examinee / All switch chooses what the list shows: examinee
/// records (linked), or scans not yet linked to any examinee (unlinked).
class GuidanceWebExamineeAnalyticsView extends StatefulWidget {
  const GuidanceWebExamineeAnalyticsView({
    super.key,
    GuidanceWebExamineeRecordsService? recordsService,
    GuidanceWebResultsService? resultsService,
  }) : _recordsService = recordsService,
       _resultsService = resultsService;

  final GuidanceWebExamineeRecordsService? _recordsService;
  final GuidanceWebResultsService? _resultsService;

  @override
  State<GuidanceWebExamineeAnalyticsView> createState() =>
      _GuidanceWebExamineeAnalyticsViewState();
}

enum _ListMode { linked, unlinked, all }

class _GuidanceWebExamineeAnalyticsViewState
    extends State<GuidanceWebExamineeAnalyticsView> {
  late final GuidanceWebExamineeRecordsService _records =
      widget._recordsService ?? GuidanceWebExamineeRecordsService();
  late final GuidanceWebResultsService _results =
      widget._resultsService ?? GuidanceWebResultsService();
  final TextEditingController _search = TextEditingController();

  bool _loading = true;
  String? _error;
  List<ExamineeRecord> _examinees = [];

  /// Unresolved scans from the same Analytics snapshot as the linked people.
  List<ExamineeHistoryItem> _unlinked = [];

  _ListMode _mode = _ListMode.linked;

  ExamineeRecord? _selected;
  bool _loadingHistory = false;
  String? _historyError;
  List<ExamineeHistoryItem> _history = [];
  ExamineeHistoryItem? _viewing;

  @override
  void initState() {
    super.initState();
    _search.addListener(() => setState(() {}));
    _loadExaminees();
  }

  @override
  void reassemble() {
    super.reassemble();
    // Hot reload preserves existing State objects, including objects created
    // before the linked/unlinked fields and mode values were introduced.
    // Reinitialize this read-only snapshot before any length/count is read.
    _examinees = [];
    _unlinked = [];
    _mode = _ListMode.linked;
    _selected = null;
    _history = [];
    _viewing = null;
    _loadingHistory = false;
    _historyError = null;
    _loadExaminees();
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _loadExaminees() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final population = await _records.loadAnalyticsPopulation();
      if (!mounted) return;
      setState(() {
        _examinees = population.examinees;
        _unlinked = population.unlinked;
        _loading = false;
      });
    } on GuidanceWebExamineeRecordsException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error = 'Could not load examinees. Please try again.';
        _loading = false;
      });
    }
  }

  Future<void> _select(ExamineeRecord examinee) async {
    setState(() {
      _selected = examinee;
      _loadingHistory = true;
      _historyError = null;
      _history = [];
      _viewing = null;
    });
    try {
      final all = await _records.loadHistoryFor(examinee);
      if (!mounted) return;
      setState(() {
        _history = all.where((item) => !item.isArchivedAttempt).toList();
        _loadingHistory = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _historyError =
            "Could not load this examinee's results. Please try again.";
        _loadingHistory = false;
      });
    }
  }

  List<ExamineeRecord> get _filtered {
    final term = _search.text.trim().toLowerCase();
    if (term.isEmpty) return _examinees;
    return _examinees
        .where(
          (e) =>
              e.displayName.toLowerCase().contains(term) ||
              e.temporaryExamineeId.toLowerCase().contains(term),
        )
        .toList();
  }

  List<ExamineeHistoryItem> get _filteredUnlinked {
    final term = _search.text.trim().toLowerCase();
    if (term.isEmpty) return _unlinked;
    return _unlinked
        .where(
          (h) =>
              h.batch.batchCode.toLowerCase().contains(term) ||
              h.examCode.toLowerCase().contains(term) ||
              'unlinked examinee'.contains(term),
        )
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    final viewing = _viewing;
    if (viewing != null) {
      return GuidanceWebResultDetailView(
        scan: viewing.scan,
        batch: viewing.batch,
        service: _results,
        linkedExaminee: _selected,
        showClusterAnalysis: true,
        backLabel: _selected != null ? 'Back to Examinee' : 'Back to List',
        onBack: () => setState(() => _viewing = null),
      );
    }
    final selected = _selected;
    return selected == null ? _buildPicker() : _buildExamineeResults(selected);
  }

  BoxDecoration get _cardDecoration => BoxDecoration(
    color: Colors.white,
    borderRadius: BorderRadius.circular(12),
    border: Border.all(color: AppColors.cardBorder),
  );

  Widget _message(String text, {bool isError = false}) {
    if (isError)
      return ErrorState(
        message: text,
        onRetry: _selected == null ? _loadExaminees : () => _select(_selected!),
      );
    if (text.startsWith('Loading')) return LoadingState(message: text);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Text(
          text,
          textAlign: TextAlign.center,
          style: AppTextStyles.body(size: 13, color: AppColors.textGray),
        ),
      ),
    );
  }

  Widget _modeSwitch(bool narrow) {
    return SegmentedButton<_ListMode>(
      key: const Key('examineeModeSwitch'),
      showSelectedIcon: false,
      style: ButtonStyle(
        minimumSize: const WidgetStatePropertyAll(Size(44, 44)),
        textStyle: WidgetStatePropertyAll(
          AppTextStyles.body(size: 14, weight: FontWeight.w700),
        ),
        backgroundColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? AppColors.emerald100
              : Colors.white,
        ),
        foregroundColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? AppColors.primaryGreen
              : AppColors.textDark,
        ),
      ),
      direction: narrow ? Axis.vertical : Axis.horizontal,
      segments: [
        ButtonSegment(
          value: _ListMode.linked,
          label: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('Examinee'),
              Text(
                _loading || _error != null ? '—' : '${_filtered.length}',
                key: const Key('analytics.examineeCount'),
              ),
            ],
          ),
        ),
        ButtonSegment(
          value: _ListMode.unlinked,
          label: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('Unlinked Examinee'),
              Text(
                _loading || _error != null
                    ? '—'
                    : '${_filteredUnlinked.length}',
                key: const Key('analytics.unlinkedCount'),
              ),
            ],
          ),
        ),
        const ButtonSegment(value: _ListMode.all, label: Text('All')),
      ],
      selected: {_mode},
      onSelectionChanged: (v) => setState(() => _mode = v.first),
    );
  }

  Widget _buildPicker() {
    final showExaminee = _mode != _ListMode.unlinked;
    final showUnlinked = _mode != _ListMode.linked;
    final linked = showExaminee ? _filtered : const <ExamineeRecord>[];
    final unlinked = showUnlinked
        ? _filteredUnlinked
        : const <ExamineeHistoryItem>[];
    final count = linked.length + unlinked.length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.all(16),
          decoration: _cardDecoration,
          child: LayoutBuilder(
            builder: (context, constraints) => Wrap(
              spacing: 16,
              runSpacing: 12,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                SizedBox(
                  width: constraints.maxWidth < 380
                      ? constraints.maxWidth
                      : 380,
                  child: TextField(
                    key: const Key('examineeAnalyticsSearch'),
                    controller: _search,
                    decoration: InputDecoration(
                      hintText: 'Search name or ID...',
                      suffixIcon: _search.text.isEmpty
                          ? null
                          : IconButton(
                              tooltip: 'Clear search',
                              onPressed: _search.clear,
                              icon: const Icon(Icons.close, size: 18),
                            ),
                      isDense: true,
                      prefixIcon: const Icon(Icons.search, size: 18),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                  ),
                ),
                _modeSwitch(constraints.maxWidth < 500),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        Expanded(
          child: _loading
              ? _message('Loading examinees...')
              : _error != null
              ? _message(_error!, isError: true)
              : count == 0
              ? _message(
                  _mode == _ListMode.unlinked
                      ? 'No unlinked examinees.'
                      : 'No examinees found.',
                )
              : Container(
                  decoration: _cardDecoration,
                  child: Material(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(12),
                    clipBehavior: Clip.antiAlias,
                    child: ListView(
                      children: [
                        for (final e in linked) ...[
                          _linkedRow(e),
                          const Divider(height: 1, color: AppColors.cardBorder),
                        ],
                        for (final h in unlinked) ...[
                          _unlinkedRow(h),
                          const Divider(height: 1, color: AppColors.cardBorder),
                        ],
                      ],
                    ),
                  ),
                ),
        ),
      ],
    );
  }

  Widget _linkedRow(ExamineeRecord e) => ListTile(
    key: Key('examineeAnalyticsRow_${e.id}'),
    dense: false,
    title: Text(
      e.displayName,
      style: AppTextStyles.body(size: 14, weight: FontWeight.w700),
    ),
    subtitle: Text(
      e.temporaryExamineeId,
      style: AppTextStyles.body(size: 13, color: AppColors.textGray),
    ),
    trailing: const Icon(Icons.chevron_right, size: 18),
    onTap: () => _select(e),
  );

  Widget _unlinkedRow(ExamineeHistoryItem item) => ListTile(
    key: Key('unlinkedAnalyticsRow_${item.scan.id}'),
    dense: false,
    title: Text(
      'Unlinked Examinee — ${item.examCode} · ${item.batch.batchCode}',
      style: AppTextStyles.body(size: 14, weight: FontWeight.w700),
    ),
    subtitle: Text(
      _scoreText(item),
      style: AppTextStyles.body(size: 13, color: AppColors.textGray),
    ),
    trailing: const Icon(Icons.chevron_right, size: 18),
    onTap: () => setState(() {
      _selected = null;
      _viewing = item;
    }),
  );

  String _scoreText(ExamineeHistoryItem item) {
    final result = item.result;
    if (result == null) return '—';
    final denominator = item.examCode == 'TAT' ? 160 : result.totalItems;
    return '${result.rawScore} / $denominator '
        '(${result.percentage.toStringAsFixed(1)}%)';
  }

  Widget _buildExamineeResults(ExamineeRecord examinee) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: () => setState(() => _selected = null),
            icon: const Icon(Icons.arrow_back, size: 16),
            label: const Text('Back to Examinees'),
          ),
        ),
        const SizedBox(height: 8),
        Container(
          padding: const EdgeInsets.all(16),
          decoration: _cardDecoration,
          child: Wrap(
            spacing: 16,
            runSpacing: 8,
            children: [
              Text(
                examinee.displayName,
                style: AppTextStyles.heading(size: 15),
              ),
              Text(
                examinee.temporaryExamineeId,
                style: AppTextStyles.body(size: 13, color: AppColors.textGray),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        Expanded(
          child: _loadingHistory
              ? _message('Loading results...')
              : _historyError != null
              ? _message(_historyError!, isError: true)
              : _history.isEmpty
              ? _message('No results for this examinee yet.')
              : Material(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(12),
                  clipBehavior: Clip.antiAlias,
                  child: ListView.separated(
                    itemCount: _history.length,
                    separatorBuilder: (_, _) =>
                        const Divider(height: 1, color: AppColors.cardBorder),
                    itemBuilder: (_, i) => _historyRow(_history[i]),
                  ),
                ),
        ),
      ],
    );
  }

  Widget _historyRow(ExamineeHistoryItem item) {
    final score = _scoreText(item);
    return ListTile(
      dense: false,
      title: Text(
        '${item.examCode} — ${item.batch.batchCode}',
        style: AppTextStyles.body(size: 14, weight: FontWeight.w700),
      ),
      subtitle: Text(
        score,
        style: AppTextStyles.body(size: 13, color: AppColors.textGray),
      ),
      onTap: () => setState(() => _viewing = item),
    );
  }
}
