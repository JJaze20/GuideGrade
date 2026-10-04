import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../../../core/omr/cluster_analysis.dart';
import 'guidance_web_certificate.dart';
import 'guidance_web_export_models.dart';

/// Builds the Guidance Council export PDF from [ExportDocument]: a Batch
/// Analytics page (optional) followed by one Examinee Analytics page per
/// examinee, on US Letter paper matching the council's export template.
///
/// Uses only the built-in Helvetica font and vector drawing (no font or
/// network downloads), so it works identically in the browser preview and in
/// the saved file.
Future<Uint8List> buildExportPdf(
  ExportDocument document, {
  required Uint8List leftLogo,
  required Uint8List rightLogo,
}) async {
  final pdf = pw.Document(
    title: 'Guidance Council Export',
    author: 'Guidance Council of NDMU',
  );
  final left = pw.MemoryImage(leftLogo);
  final right = pw.MemoryImage(rightLogo);

  const format = PdfPageFormat.letter;
  const margin = pw.EdgeInsets.fromLTRB(72, 24, 72, 36);

  final batch = document.batch;
  if (batch != null) {
    pdf.addPage(
      pw.Page(
        pageFormat: format,
        margin: margin,
        build: (_) => _batchPage(batch, left, right),
      ),
    );
  }
  for (final e in document.examinees) {
    pdf.addPage(
      pw.Page(
        pageFormat: format,
        margin: margin,
        build: (_) => _examineePage(e, left, right),
      ),
    );
    final cert = e.certificate;
    if (cert != null) {
      pdf.addPage(
        pw.Page(
          pageFormat: format.landscape,
          margin: const pw.EdgeInsets.fromLTRB(72, 30, 72, 30),
          build: (_) => _certificatePage(cert, left, right),
        ),
      );
    }
  }
  return pdf.save();
}

// --- shared pieces ---------------------------------------------------------

const _ink = PdfColors.black;
const _muted = PdfColor.fromInt(0xFF555555);
const _rule = PdfColor.fromInt(0xFFA6A6A6);
const _bar = PdfColor.fromInt(0xFF2E7D32);
const _track = PdfColor.fromInt(0xFFE6E6E6);

/// The built-in Helvetica covers Latin-1 only: map the typographic dashes and
/// quotes to plain ASCII so they never print as empty boxes.
String _clean(String t) => t
    .replaceAll('\u2013', '-')
    .replaceAll('\u2014', '-')
    .replaceAll('\u2018', "'")
    .replaceAll('\u2019', "'")
    .replaceAll('\u201C', '"')
    .replaceAll('\u201D', '"');

pw.TextStyle _s(double size, {bool bold = false, PdfColor color = _ink}) =>
    pw.TextStyle(
      font: bold ? pw.Font.helveticaBold() : pw.Font.helvetica(),
      fontSize: size,
      color: color,
    );

pw.Widget _header(pw.ImageProvider left, pw.ImageProvider right) {
  pw.Widget line(String t) =>
      pw.Text(t, style: _s(9), textAlign: pw.TextAlign.center);
  return pw.Column(
    children: [
      pw.Row(
        crossAxisAlignment: pw.CrossAxisAlignment.center,
        children: [
          pw.SizedBox(width: 50, height: 58, child: pw.Image(left)),
          pw.Expanded(
            child: pw.Column(
              children: [
                line('JMJ Marist Brothers'),
                line('Notre Dame of Marbel University'),
                line('Guidance Council of NDMU'),
                line('City of Koronadal, Province of South Cotabato'),
              ],
            ),
          ),
          pw.SizedBox(width: 58, height: 58, child: pw.Image(right)),
        ],
      ),
      pw.SizedBox(height: 14),
      pw.Container(height: 2, color: _rule),
    ],
  );
}

pw.Widget _hr() => pw.Padding(
  padding: const pw.EdgeInsets.symmetric(vertical: 10),
  child: pw.Container(height: 1.5, color: _rule),
);

pw.Widget _h1(String t) => pw.Text(t, style: _s(15, bold: true));

pw.Widget _labelValue(String label, String value) => pw.RichText(
  text: pw.TextSpan(
    children: [
      pw.TextSpan(text: '$label: ', style: _s(10, bold: true)),
      pw.TextSpan(text: _clean(value), style: _s(10)),
    ],
  ),
);

pw.Widget _pairRow(String l1, String v1, String? l2, String? v2) => pw.Padding(
  padding: const pw.EdgeInsets.symmetric(vertical: 4),
  child: pw.Row(
    children: [
      pw.Expanded(child: _field(l1, v1)),
      pw.Expanded(child: l2 == null ? pw.SizedBox() : _field(l2, v2 ?? '—')),
    ],
  ),
);

pw.Widget _field(String label, String value) => pw.RichText(
  text: pw.TextSpan(
    children: [
      pw.TextSpan(text: '$label: ', style: _s(10.5)),
      pw.TextSpan(text: _clean(value), style: _s(10.5, bold: true)),
    ],
  ),
);

pw.Widget _bars(List<ExportBar> bars) {
  if (bars.isEmpty) {
    return pw.Text('No data available.', style: _s(9.5, color: _muted));
  }
  final max = bars.map((b) => b.count).fold<int>(0, (a, b) => a > b ? a : b);
  return pw.Column(
    children: [
      for (final b in bars)
        pw.Padding(
          padding: const pw.EdgeInsets.symmetric(vertical: 3),
          child: pw.Row(
            children: [
              pw.SizedBox(
                width: 150,
                child: pw.Text(_clean(b.label), style: _s(9.5)),
              ),
              pw.Expanded(
                child: pw.Row(
                  children: [
                    if (b.count > 0)
                      pw.Expanded(
                        flex: b.count,
                        child: pw.Container(height: 9, color: _bar),
                      ),
                    if (max - b.count > 0)
                      pw.Expanded(
                        flex: max - b.count,
                        child: pw.Container(height: 9, color: _track),
                      ),
                    if (max == 0)
                      pw.Expanded(
                        child: pw.Container(height: 9, color: _track),
                      ),
                  ],
                ),
              ),
              pw.SizedBox(
                width: 30,
                child: pw.Text(
                  '${b.count}',
                  style: _s(9.5, bold: true),
                  textAlign: pw.TextAlign.right,
                ),
              ),
            ],
          ),
        ),
    ],
  );
}

// --- page 1: Batch Analytics -----------------------------------------------

pw.Widget _batchPage(
  ExportBatchSection s,
  pw.ImageProvider left,
  pw.ImageProvider right,
) {
  final stats = {for (final e in s.stats) e.$1: e.$2};
  String v(String k) => stats[k] ?? '—';
  return pw.Column(
    crossAxisAlignment: pw.CrossAxisAlignment.start,
    children: [
      _header(left, right),
      pw.SizedBox(height: 16),
      _h1('Batch Analytics'),
      pw.SizedBox(height: 12),
      pw.Row(
        children: [
          pw.Expanded(child: _labelValue('Exam Type', s.examLabel)),
          pw.Expanded(child: _labelValue('Batch', s.batchLabel)),
        ],
      ),
      pw.SizedBox(height: 6),
      _labelValue('Batch Date', s.batchDate),
      pw.SizedBox(height: 16),
      pw.Text('Overall Statistics', style: _s(11, bold: true)),
      pw.SizedBox(height: 6),
      _pairRow('Total', v('Total'), 'Graded', v('Graded')),
      _pairRow('Ungraded', v('Ungraded'), 'Average', v('Average')),
      _pairRow('Highest', v('Highest'), 'Lowest', v('Lowest')),
      _pairRow('Median', v('Median'), null, null),
      if (s.unavailableNote != null) ...[
        pw.SizedBox(height: 4),
        pw.Text(_clean(s.unavailableNote!), style: _s(9, color: _muted)),
      ],
      _hr(),
      _h1('Score Distribution:'),
      pw.SizedBox(height: 8),
      _bars(s.scoreBars),
      _hr(),
      _h1('Category Distribution:'),
      pw.SizedBox(height: 8),
      _bars(s.categoryBars),
    ],
  );
}

// --- per-examinee page: Examinee Analytics ---------------------------------

pw.Widget _check(PdfColor color) => pw.SizedBox(
  width: 11,
  height: 11,
  child: pw.CustomPaint(
    size: const PdfPoint(11, 11),
    painter: (canvas, size) {
      canvas
        ..setStrokeColor(color)
        ..setLineWidth(1.6)
        ..moveTo(1.5, 5.5)
        ..lineTo(4.5, 2)
        ..lineTo(10, 9.5)
        ..strokePath();
    },
  ),
);

pw.Widget _cell(pw.Widget child, {pw.Alignment align = pw.Alignment.center}) =>
    pw.Container(
      alignment: align,
      padding: const pw.EdgeInsets.symmetric(vertical: 4, horizontal: 3),
      child: child,
    );

String _fmt(double v) =>
    v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(1);

pw.Widget _clusterTable(List<ClusterRow> rows) {
  pw.Widget head(String t, {pw.Alignment a = pw.Alignment.center}) => _cell(
    pw.Text(t, style: _s(8.5, bold: true, color: _muted)),
    align: a,
  );
  const red = PdfColor.fromInt(0xFFD32F2F);
  return pw.Table(
    columnWidths: const {
      0: pw.FlexColumnWidth(4),
      1: pw.FlexColumnWidth(1.8),
      2: pw.FlexColumnWidth(1.1),
      3: pw.FlexColumnWidth(1.4),
      4: pw.FlexColumnWidth(1.4),
      5: pw.FlexColumnWidth(1.4),
    },
    border: const pw.TableBorder(
      horizontalInside: pw.BorderSide(color: _rule, width: 0.5),
      bottom: pw.BorderSide(color: _rule, width: 0.5),
    ),
    children: [
      pw.TableRow(
        decoration: const pw.BoxDecoration(
          border: pw.Border(bottom: pw.BorderSide(color: _rule, width: 0.8)),
        ),
        children: [
          head('CLUSTER', a: pw.Alignment.centerLeft),
          head('TOTAL ITEMS'),
          head('RIGHT'),
          head('BELOW AVG'),
          head('AVERAGE'),
          head('ABOVE AVG'),
        ],
      ),
      for (final r in rows)
        pw.TableRow(
          decoration: r.def.isGroup
              ? const pw.BoxDecoration(color: PdfColor.fromInt(0xFFEFEFEF))
              : null,
          children: [
            _cell(
              pw.Padding(
                padding: pw.EdgeInsets.only(left: r.def.isGroup ? 0 : 12),
                child: pw.Text(
                  _clean('${r.def.label} (${r.def.fromItem}-${r.def.toItem})'),
                  style: _s(9, bold: r.def.isGroup),
                ),
              ),
              align: pw.Alignment.centerLeft,
            ),
            _cell(pw.Text('${r.total}', style: _s(9))),
            _cell(
              pw.Text(r.right?.toString() ?? '-', style: _s(9, bold: true)),
            ),
            _cell(
              r.band == ClusterBand.below
                  ? _check(red)
                  : pw.Text('-', style: _s(9, color: _muted)),
            ),
            _cell(
              pw.Text(
                r.average == null
                    ? '-'
                    : '${r.right?.toString() ?? '-'}/${_fmt(r.average!)}',
                style: _s(9, bold: r.band == ClusterBand.average),
              ),
            ),
            _cell(
              r.band == ClusterBand.above
                  ? _check(_bar)
                  : pw.Text('-', style: _s(9, color: _muted)),
            ),
          ],
        ),
    ],
  );
}

pw.Widget _categoryList(ExportExamineeSection s) {
  return pw.Column(
    crossAxisAlignment: pw.CrossAxisAlignment.start,
    children: [
      for (final b in s.categoryBands)
        pw.Container(
          margin: const pw.EdgeInsets.symmetric(vertical: 3),
          padding: const pw.EdgeInsets.symmetric(horizontal: 8, vertical: 5),
          decoration: b.letter == s.categoryLetter
              ? pw.BoxDecoration(
                  color: const PdfColor.fromInt(0xFFE8F5E9),
                  border: pw.Border.all(color: _bar, width: 1.4),
                  borderRadius: pw.BorderRadius.circular(4),
                )
              : null,
          child: pw.Row(
            children: [
              pw.SizedBox(
                width: 34,
                child: pw.Text(
                  '${b.letter}.',
                  style: _s(16, bold: b.letter == s.categoryLetter),
                ),
              ),
              pw.SizedBox(
                width: 90,
                child: pw.Text(_clean(b.range), style: _s(10.5, bold: true)),
              ),
              pw.Expanded(
                child: pw.Text(
                  _clean(b.percentLabel ?? ''),
                  style: _s(10, color: _muted),
                ),
              ),
              if (b.letter == s.categoryLetter)
                pw.Text(
                  'Examinee category',
                  style: _s(9, bold: true, color: _bar),
                ),
            ],
          ),
        ),
    ],
  );
}

pw.Widget _examineePage(
  ExportExamineeSection s,
  pw.ImageProvider left,
  pw.ImageProvider right,
) {
  return pw.Column(
    crossAxisAlignment: pw.CrossAxisAlignment.start,
    children: [
      _header(left, right),
      pw.SizedBox(height: 16),
      _h1('Examinee Analytics'),
      pw.SizedBox(height: 12),
      pw.Row(
        children: [
          pw.Expanded(child: _labelValue('Exam Type', s.examLabel)),
          pw.Expanded(child: _labelValue('Batch', s.batchLabel)),
        ],
      ),
      pw.SizedBox(height: 16),
      pw.Row(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.Expanded(
            child: pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                pw.Text('Examinee Information', style: _s(11, bold: true)),
                pw.SizedBox(height: 6),
                for (final f in [
                  ('Examinee Id', s.examineeId),
                  ('First Name', s.firstName),
                  ('Middle Name', s.middleName),
                  ('Last Name', s.lastName),
                  ('Scan Date', s.scanDate),
                ])
                  pw.Padding(
                    padding: const pw.EdgeInsets.symmetric(vertical: 2.5),
                    child: _field(f.$1, f.$2),
                  ),
              ],
            ),
          ),
          pw.Expanded(
            child: pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                pw.Text('Result Summary', style: _s(11, bold: true)),
                pw.SizedBox(height: 6),
                pw.Padding(
                  padding: const pw.EdgeInsets.symmetric(vertical: 2.5),
                  child: _field('Score', s.score),
                ),
                pw.Padding(
                  padding: const pw.EdgeInsets.symmetric(vertical: 2.5),
                  child: _field('Percentage', s.percentage),
                ),
              ],
            ),
          ),
        ],
      ),
      if (s.clusterRows != null) ...[
        _hr(),
        _h1('Cluster Analysis:'),
        pw.SizedBox(height: 8),
        _clusterTable(s.clusterRows!),
        if (s.clusterNote != null) ...[
          pw.SizedBox(height: 6),
          pw.Text(_clean(s.clusterNote!), style: _s(8, color: _muted)),
        ],
      ],
      _hr(),
      _h1('Category:'),
      pw.SizedBox(height: 6),
      _categoryList(s),
    ],
  );
}

// --- category certificate ---------------------------------------------------

PdfColor _certColor(String letter) => switch (letter) {
  'D' => const PdfColor.fromInt(0xFF00B0F0),
  'C' => const PdfColor.fromInt(0xFF1F497D),
  'B' => const PdfColor.fromInt(0xFFFFC000),
  _ => const PdfColor.fromInt(0xFFEE0000),
};

pw.Widget _certHeader(pw.ImageProvider crest, pw.ImageProvider seal) {
  const grey = PdfColor.fromInt(0xFF7F7F7F);
  pw.Widget line(String t, double size) => pw.Text(
    t,
    style: _s(size, color: grey),
    textAlign: pw.TextAlign.center,
  );
  return pw.Row(
    crossAxisAlignment: pw.CrossAxisAlignment.center,
    children: [
      pw.SizedBox(width: 49, height: 57, child: pw.Image(crest)),
      pw.Expanded(
        child: pw.Column(
          children: [
            line('JMJ Marist Brothers', 10),
            line('Notre Dame of Marbel University', 10),
            line('Guidance Council of NDMU', 10),
            line('City of Koronadal, Province of South Cotabato', 10),
            line('Guidance and Testing Center', 18),
          ],
        ),
      ),
      pw.SizedBox(width: 58, height: 57, child: pw.Image(seal)),
    ],
  );
}

pw.Widget _certColumn(List<CertEntry> col) => pw.Column(
  crossAxisAlignment: pw.CrossAxisAlignment.start,
  children: [
    for (final e in col)
      pw.Padding(
        // The template sets the course lists in Calibri Bold, which is
        // narrower than the built-in Helvetica Bold, hence the smaller size.
        padding: pw.EdgeInsets.only(top: e.isHeading ? 6 : 0, bottom: 1.5),
        child: pw.Text(_clean(e.text), style: _s(11.5, bold: true)),
      ),
  ],
);

pw.Widget _certificatePage(
  ExportCertificate c,
  pw.ImageProvider crest,
  pw.ImageProvider seal,
) {
  final color = _certColor(c.letter);
  final cols = c.columns;
  final body = pw.Column(
    crossAxisAlignment: pw.CrossAxisAlignment.stretch,
    children: [
      pw.Center(child: pw.Text('CONGRATULATIONS!', style: _s(36, bold: true))),
      pw.SizedBox(height: 2),
      pw.Center(
        child: pw.Text(
          _clean(c.intro),
          style: _s(14, bold: true),
          textAlign: pw.TextAlign.center,
        ),
      ),
      pw.SizedBox(height: 4),
      pw.Center(
        child: pw.RichText(
          text: pw.TextSpan(
            children: [
              pw.TextSpan(text: 'TEST RESULT: ', style: _s(18, bold: true)),
              pw.TextSpan(
                text: 'CATEGORY ${c.letter} ',
                style: _s(18, bold: true, color: color),
              ),
              pw.TextSpan(
                text: _clean(c.rangeLabel),
                style: _s(18, bold: true),
              ),
            ],
          ),
        ),
      ),
      pw.SizedBox(height: 14),
      if (c.name.isEmpty)
        // No name on record: leave a line to write it on.
        pw.Center(
          child: pw.Container(
            width: 340,
            height: 30,
            decoration: pw.BoxDecoration(
              border: pw.Border(
                bottom: pw.BorderSide(color: color, width: 1.2),
              ),
            ),
          ),
        )
      else
        pw.Center(
          child: pw.Text(
            _clean(c.name),
            style: _s(24, bold: true, color: color),
            textAlign: pw.TextAlign.center,
          ),
        ),
      pw.SizedBox(height: 8),
      pw.Container(height: 1, color: _rule),
      pw.SizedBox(height: 10),
      pw.Center(
        child: pw.RichText(
          text: pw.TextSpan(
            children: [
              pw.TextSpan(
                text: 'Based on your result, you are qualified to ${c.verb} ',
                style: _s(14),
              ),
              pw.TextSpan(
                text: 'ANY',
                style: pw.TextStyle(
                  font: pw.Font.helveticaBold(),
                  fontSize: 14,
                  decoration: pw.TextDecoration.underline,
                ),
              ),
              pw.TextSpan(text: ' of the following courses:', style: _s(14)),
            ],
          ),
        ),
      ),
      pw.SizedBox(height: 10),
      pw.Row(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          for (final col in cols)
            pw.Expanded(
              child: pw.Padding(
                padding: const pw.EdgeInsets.only(right: 8),
                child: _certColumn(col),
              ),
            ),
        ],
      ),
    ],
  );
  return pw.Column(
    crossAxisAlignment: pw.CrossAxisAlignment.stretch,
    children: [
      _certHeader(crest, seal),
      pw.SizedBox(height: 6),
      // Scales down (never overflows) if a long course list needs the room.
      pw.Expanded(
        child: pw.FittedBox(
          fit: pw.BoxFit.scaleDown,
          alignment: pw.Alignment.topCenter,
          child: pw.SizedBox(width: 648, child: body),
        ),
      ),
    ],
  );
}
