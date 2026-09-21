import 'package:flutter/material.dart';

import '../../../core/constants/app_colors.dart';
import '../../../core/constants/app_text_styles.dart';
import '../../../core/omr/cluster_analysis.dart';
import '../../../models/examinee_record.dart';
import '../services/guidance_web_examinee_records_service.dart';
import '../services/guidance_web_results_service.dart';
import 'guidance_web_result_detail_view.dart';

/// Analytics → Examinee Analytics: pick one examinee, then open any of their
/// AT / QTM results to see Examinee Information, Result Summary, the scanned
/// sheet and the Cluster Analysis table. It reuses
/// [GuidanceWebResultDetailView] (in its cluster mode) rather than a second
/// result implementation. TAT results are not listed — TAT has no cluster
/// analysis yet.
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
      if (!mounted) return;
      setState(() {
        _examinees = list;
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
        _history = [
          for (final h in all)
            if (clusterDefsFor(h.examCode) != null) h,
        ];
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

  @override
  Widget build(BuildContext context) {
    final viewing = _viewing;
    if (viewing != null) {
      return GuidanceWebResultDetailView(
        scan: viewing.scan,
        batch: viewing.batch,
        service: _results,
        showClusterAnalysis: true,
        backLabel: 'Back to Examinee',
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

  Widget _buildPicker() {
    final list = _filtered;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.all(16),
          decoration: _cardDecoration,
          child: TextField(
            key: const Key('examineeAnalyticsSearch'),
            controller: _search,
            decoration: InputDecoration(
              hintText: 'Search name or Temporary Examinee ID...',
              isDense: true,
              prefixIcon: const Icon(Icons.search, size: 18),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
            ),
          ),
        ),
        const SizedBox(height: 16),
        Expanded(
          child: _loading
              ? _message('Loading examinees...')
              : _error != null
              ? _message(_error!, isError: true)
              : list.isEmpty
              ? _message('No examinees found.')
              : Container(
                  decoration: _cardDecoration,
                  child: ListView.separated(
                    itemCount: list.length,
                    separatorBuilder: (_, _) =>
                        const Divider(height: 1, color: AppColors.cardBorder),
                    itemBuilder: (_, i) => ListTile(
                      key: Key('examineeAnalyticsRow_${list[i].id}'),
                      dense: true,
                      title: Text(
                        list[i].displayName,
                        style: AppTextStyles.body(
                          size: 12,
                          weight: FontWeight.w700,
                        ),
                      ),
                      subtitle: Text(
                        list[i].temporaryExamineeId,
                        style: AppTextStyles.body(
                          size: 11,
                          color: AppColors.textGray,
                        ),
                      ),
                      trailing: const Icon(Icons.chevron_right, size: 18),
                      onTap: () => _select(list[i]),
                    ),
                  ),
                ),
        ),
      ],
    );
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
              ? _message('No AT or QTM results for this examinee yet.')
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
    final result = item.result;
    final score = result == null
        ? '—'
        : '${result.rawScore} / ${result.totalItems} '
              '(${result.percentage.toStringAsFixed(1)}%)';
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
      trailing: Text(
        'View',
        style: AppTextStyles.body(
          size: 11,
          weight: FontWeight.w700,
          color: AppColors.primaryGreen,
        ),
      ),
      onTap: () => setState(() => _viewing = item),
    );
  }
}
