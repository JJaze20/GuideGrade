import 'package:flutter/material.dart';

import '../../../core/constants/app_colors.dart';
import '../../../core/constants/app_text_styles.dart';
import '../../../models/examinee_record.dart';
import '../services/guidance_web_examinee_records_service.dart';
import '../services/guidance_web_results_service.dart';
import 'guidance_web_result_detail_view.dart';

/// Analytics → Examinee Analytics: pick one examinee, then open any of their
/// AT / QTM results to see Examinee Information, Result Summary, the scanned
/// sheet and the Cluster Analysis table. It reuses
/// [GuidanceWebResultDetailView] (in its cluster mode) rather than a second
/// result implementation. AT and QTM show the cluster analysis and category;
/// TAT shows the category only.
///
/// A Tagged / Untagged / All switch chooses what the list shows: examinee
/// records (tagged), or scans not yet linked to any examinee (untagged).
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

enum _ListMode { tagged, untagged, all }

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

  /// Scans with no examinee link ("untagged"). Loaded alongside the
  /// examinees; a failure here only affects the Untagged / All views.
  List<ExamineeHistoryItem> _untagged = [];
  String? _untaggedError;

  _ListMode _mode = _ListMode.tagged;

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
      final list = await _records.loadExaminees();
      List<ExamineeHistoryItem> untagged = const [];
      String? untaggedError;
      try {
        untagged = await _records.loadUnlinkedScans();
      } on GuidanceWebExamineeRecordsException catch (e) {
        untaggedError = e.message;
      } catch (_) {
        untaggedError = 'Could not load untagged scans. Please try again.';
      }
      if (!mounted) return;
      setState(() {
        _examinees = list;
        _untagged = untagged;
        _untaggedError = untaggedError;
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
        _history = all;
        _loadingHistory = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _historyError = "Could not load this examinee's results. Please try again.";
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

  List<ExamineeHistoryItem> get _filteredUntagged {
    final term = _search.text.trim().toLowerCase();
    if (term.isEmpty) return _untagged;
    return _untagged
        .where(
          (h) =>
              h.batch.batchCode.toLowerCase().contains(term) ||
              h.examCode.toLowerCase().contains(term) ||
              'untagged'.contains(term),
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

  Widget _message(String text, {bool isError = false}) => Center(
    child: Text(
      text,
      style: AppTextStyles.body(
        size: 11.5,
        color: isError ? AppColors.warmRedOrange : AppColors.textGray,
      ),
    ),
  );

  Widget _modeSwitch() {
    return SegmentedButton<_ListMode>(
      key: const Key('examineeModeSwitch'),
      showSelectedIcon: false,
      style: ButtonStyle(
        visualDensity: VisualDensity.compact,
        textStyle: WidgetStatePropertyAll(
          AppTextStyles.body(size: 12, weight: FontWeight.w700),
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
      segments: const [
        ButtonSegment(value: _ListMode.tagged, label: Text('Tagged')),
        ButtonSegment(value: _ListMode.untagged, label: Text('Untagged')),
        ButtonSegment(value: _ListMode.all, label: Text('All')),
      ],
      selected: {_mode},
      onSelectionChanged: (v) => setState(() => _mode = v.first),
    );
  }

  Widget _buildPicker() {
    final showTagged = _mode != _ListMode.untagged;
    final showUntagged = _mode != _ListMode.tagged;
    final tagged = showTagged ? _filtered : const <ExamineeRecord>[];
    final untagged = showUntagged
        ? _filteredUntagged
        : const <ExamineeHistoryItem>[];
    final count = tagged.length + untagged.length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.all(16),
          decoration: _cardDecoration,
          child: Row(
            children: [
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 380),
                child: SizedBox(
                  width: 380,
                  child: TextField(
                    key: const Key('examineeAnalyticsSearch'),
                    controller: _search,
                    decoration: InputDecoration(
                      hintText: 'Search name or ID...',
                      isDense: true,
                      prefixIcon: const Icon(Icons.search, size: 18),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 16),
              _modeSwitch(),
            ],
          ),
        ),
        const SizedBox(height: 16),
        Expanded(
          child: _loading
              ? _message('Loading examinees...')
              : _error != null
              ? _message(_error!, isError: true)
              : (showUntagged && !showTagged && _untaggedError != null)
              ? _message(_untaggedError!, isError: true)
              : count == 0
              ? _message(
                  _mode == _ListMode.untagged
                      ? 'No untagged scans.'
                      : 'No examinees found.',
                )
              : Container(
                  decoration: _cardDecoration,
                  child: ListView(
                    children: [
                      for (final e in tagged) ...[
                        _taggedRow(e),
                        const Divider(height: 1, color: AppColors.cardBorder),
                      ],
                      for (final h in untagged) ...[
                        _untaggedRow(h),
                        const Divider(height: 1, color: AppColors.cardBorder),
                      ],
                    ],
                  ),
                ),
        ),
      ],
    );
  }

  Widget _taggedRow(ExamineeRecord e) => ListTile(
    key: Key('examineeAnalyticsRow_${e.id}'),
    dense: true,
    title: Text(
      e.displayName,
      style: AppTextStyles.body(size: 12, weight: FontWeight.w700),
    ),
    subtitle: Text(
      e.temporaryExamineeId,
      style: AppTextStyles.body(size: 11, color: AppColors.textGray),
    ),
    trailing: const Icon(Icons.chevron_right, size: 18),
    onTap: () => _select(e),
  );

  Widget _untaggedRow(ExamineeHistoryItem item) => ListTile(
    key: Key('untaggedAnalyticsRow_${item.scan.id}'),
    dense: true,
    title: Text(
      'Untagged — ${item.examCode} · ${item.batch.batchCode}',
      style: AppTextStyles.body(size: 12, weight: FontWeight.w700),
    ),
    subtitle: Text(
      _scoreText(item),
      style: AppTextStyles.body(size: 11, color: AppColors.textGray),
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
          child: Row(
            children: [
              Expanded(
                child: Text(
                  examinee.displayName,
                  style: AppTextStyles.heading(size: 15),
                ),
              ),
              Text(
                examinee.temporaryExamineeId,
                style: AppTextStyles.body(size: 11, color: AppColors.textGray),
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
              : Container(
                  decoration: _cardDecoration,
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
      dense: true,
      title: Text(
        '${item.examCode} — ${item.batch.batchCode}',
        style: AppTextStyles.body(size: 12, weight: FontWeight.w700),
      ),
      subtitle: Text(
        score,
        style: AppTextStyles.body(size: 11, color: AppColors.textGray),
      ),
      onTap: () => setState(() => _viewing = item),
    );
  }
}
