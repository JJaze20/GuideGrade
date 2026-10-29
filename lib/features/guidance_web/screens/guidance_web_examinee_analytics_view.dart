import 'package:flutter/material.dart';

import '../../../core/constants/app_colors.dart';
import '../../../core/constants/app_text_styles.dart';
import '../../../shared/widgets/state_views.dart';
import '../../../shared/widgets/surface_card.dart';
import '../../../models/examinee_record.dart';
import '../services/guidance_web_examinee_records_service.dart';
import '../services/guidance_web_results_service.dart';
import '../widgets/console_style.dart';
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

  // The same soft green panel tint and green-gray hairline as Batch Analytics,
  // so both Analytics tabs read as one family with the green console.
  static const Color _panelTint = Color(0xFFEAF3EE);
  static const Color _hairline = Color(0xFFCADBD0);

  BoxDecoration get _cardDecoration => BoxDecoration(
    color: Colors.white,
    borderRadius: BorderRadius.circular(12),
    border: Border.all(color: _hairline),
  );

  /// One examinee (or one result) as its own light card: the name in bold, the
  /// ID or score beneath it in smaller muted text, and a chevron at the right.
  /// The whole card is the click target, with a soft green hover.
  Widget _entryCard({
    required Key? key,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) => Material(
    key: key,
    color: Colors.white,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(12),
      side: const BorderSide(color: _hairline),
    ),
    clipBehavior: Clip.antiAlias,
    child: InkWell(
      onTap: onTap,
      hoverColor: _panelTint,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: AppTextStyles.body(
                      size: 14.5,
                      weight: FontWeight.w700,
                      color: ConsoleColors.ink,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: AppTextStyles.body(
                      size: 12.5,
                      color: ConsoleColors.muted,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            const Icon(
              Icons.chevron_right,
              size: 20,
              color: ConsoleColors.muted,
            ),
          ],
        ),
      ),
    ),
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

  /// The Examinee / Unlinked Examinee / All filter: three compact chips (the
  /// same kind of filter chips the Results page uses). Each shows its label and,
  /// for the first two, its count in a small pill. They wrap onto a second line
  /// on a narrow window instead of overflowing.
  Widget _modeSwitch(bool narrow) {
    Widget chip(_ListMode mode, String label, {Key? countKey, String? count}) {
      final selected = _mode == mode;
      return ChoiceChip(
        selected: selected,
        onSelected: (_) => setState(() => _mode = mode),
        showCheckmark: false,
        visualDensity: VisualDensity.compact,
        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        backgroundColor: Colors.white,
        selectedColor: const Color(0xFFDCEBE2),
        side: BorderSide(
          color: selected ? ConsoleColors.railSelected : _hairline,
        ),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        label: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppTextStyles.body(
                  size: 13.5,
                  weight: selected ? FontWeight.w700 : FontWeight.w600,
                  color: selected
                      ? ConsoleColors.railSelected
                      : ConsoleColors.ink,
                ),
              ),
            ),
            if (countKey != null) ...[
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1),
                decoration: BoxDecoration(
                  color: selected ? Colors.white : _panelTint,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  count!,
                  key: countKey,
                  style: AppTextStyles.body(
                    size: 12,
                    weight: FontWeight.w700,
                    color: ConsoleColors.railSelected,
                  ),
                ),
              ),
            ],
          ],
        ),
      );
    }

    return Wrap(
      key: const Key('examineeModeSwitch'),
      spacing: 8,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        chip(
          _ListMode.linked,
          'Examinee',
          countKey: const Key('analytics.examineeCount'),
          count: _loading || _error != null ? '—' : '${_filtered.length}',
        ),
        chip(
          _ListMode.unlinked,
          'Unlinked Examinee',
          countKey: const Key('analytics.unlinkedCount'),
          count: _loading || _error != null
              ? '—'
              : '${_filteredUnlinked.length}',
        ),
        chip(_ListMode.all, 'All'),
      ],
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
        SurfaceCard(
          color: _panelTint,
          padding: const EdgeInsets.all(12),
          child: LayoutBuilder(
            builder: (context, constraints) => Wrap(
              spacing: 12,
              runSpacing: 10,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                SizedBox(
                  width: constraints.maxWidth < 360
                      ? constraints.maxWidth
                      : 360,
                  child: TextField(
                    key: const Key('examineeAnalyticsSearch'),
                    controller: _search,
                    style: AppTextStyles.body(size: 14),
                    decoration: InputDecoration(
                      hintText: 'Search name or ID...',
                      hintStyle: AppTextStyles.body(
                        size: 14,
                        color: ConsoleColors.muted,
                      ),
                      suffixIcon: _search.text.isEmpty
                          ? null
                          : IconButton(
                              tooltip: 'Clear search',
                              onPressed: _search.clear,
                              icon: const Icon(Icons.close, size: 18),
                            ),
                      isDense: true,
                      filled: true,
                      fillColor: Colors.white,
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 10,
                      ),
                      prefixIcon: const Icon(Icons.search, size: 18),
                      // Keep the icon slots slim so the field stays ~42 px.
                      prefixIconConstraints: const BoxConstraints(
                        minWidth: 38,
                        minHeight: 36,
                      ),
                      suffixIconConstraints: const BoxConstraints(
                        minWidth: 38,
                        minHeight: 36,
                      ),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                        borderSide: const BorderSide(color: _hairline),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                        borderSide: const BorderSide(color: _hairline),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                        borderSide: const BorderSide(
                          color: ConsoleColors.railSelected,
                          width: 1.5,
                        ),
                      ),
                    ),
                  ),
                ),
                _modeSwitch(constraints.maxWidth < 560),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
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
              // One separate card per examinee, with a gap between cards.
              : ListView(
                  children: [
                    for (final e in linked)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: _linkedRow(e),
                      ),
                    for (final h in unlinked)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: _unlinkedRow(h),
                      ),
                  ],
                ),
        ),
      ],
    );
  }

  Widget _linkedRow(ExamineeRecord e) => _entryCard(
    key: Key('examineeAnalyticsRow_${e.id}'),
    title: e.displayName,
    subtitle: e.temporaryExamineeId,
    onTap: () => _select(e),
  );

  Widget _unlinkedRow(ExamineeHistoryItem item) => _entryCard(
    key: Key('unlinkedAnalyticsRow_${item.scan.id}'),
    title: 'Unlinked Examinee — ${item.examCode} · ${item.batch.batchCode}',
    subtitle: _scoreText(item),
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
              : ListView.separated(
                  itemCount: _history.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 8),
                  itemBuilder: (_, i) => _historyRow(_history[i]),
                ),
        ),
      ],
    );
  }

  Widget _historyRow(ExamineeHistoryItem item) => _entryCard(
    key: null,
    title: '${item.examCode} — ${item.batch.batchCode}',
    subtitle: _scoreText(item),
    onTap: () => setState(() => _viewing = item),
  );
}
