// Adds the shading sample (a "Correct shading" caption and four bubbles, A B C
// D, with D fully shaded) to the checked-in TAT v5 sheet, below the pencil
// instruction. answer_sheets/TAT-portrait-v5.pdf is a vector
// PDF kept by hand, not an output of generate_sheets.dart -- see
// update_tat_v5_header.py.
//
// Run from the repository root: cd tool && dart run add_tat_v5_sample_shading.dart
//
// The change is a PDF *incremental update*: every original byte of the file is
// left exactly as it was and a new revision is appended after it -- one new
// content stream (the sample, in TAT's own bubble size) and a page object that
// lists it after the existing content. Nothing the scanner reads (bubbles,
// marks, name fields) is redrawn or moved, and
// lib/core/omr/omr_template_tat_v5.dart is not touched. The shapes come from
// sample_shading.dart, shared with the AT/QTM generator and the clearance check.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:pdf/pdf.dart';

import 'sample_shading.dart';

/// Page 1's object number and the content stream it currently points at.
const int _pageObject = 4;
const String _oldContents = '/Contents 15 0 R';

/// Page 612 x 936 pt. The pencil instruction is right-aligned to x = 558 with
/// its baseline 146 pt from the top; the sample sits one line below it,
/// right-aligned the same way, clear of the section marks that start 192 pt
/// from the top and of every bubble.
const double _pageHeight = 936;
const double _rightX = 558;
const double _baselineY = 160; // from the top (PDF y = 776)
const String _marker = '%TAT-sample-shading';

String _n(double v) => v.toStringAsFixed(4).replaceFirst(RegExp(r'\.?0+$'), '').replaceFirst(RegExp(r'\.$'), '');

/// PDF operators for [shapes]. The page already defines /F1 (Helvetica) and
/// /F2 (Helvetica-Bold).
String _operators(List<ShadeShape> shapes) {
  const k = 0.5522847498; // Bezier circle constant
  String ellipse(ShadeEllipse e, String paint) {
    final cx = e.cx, cy = _pageHeight - e.cy, rx = e.rx, ry = e.ry;
    return '${_n(cx + rx)} ${_n(cy)} m\n'
        '${_n(cx + rx)} ${_n(cy + ry * k)} ${_n(cx + rx * k)} ${_n(cy + ry)} ${_n(cx)} ${_n(cy + ry)} c\n'
        '${_n(cx - rx * k)} ${_n(cy + ry)} ${_n(cx - rx)} ${_n(cy + ry * k)} ${_n(cx - rx)} ${_n(cy)} c\n'
        '${_n(cx - rx)} ${_n(cy - ry * k)} ${_n(cx - rx * k)} ${_n(cy - ry)} ${_n(cx)} ${_n(cy - ry)} c\n'
        '${_n(cx + rx * k)} ${_n(cy - ry)} ${_n(cx + rx)} ${_n(cy - ry * k)} ${_n(cx + rx)} ${_n(cy)} c\n$paint\n';
  }

  final ops = StringBuffer()
    ..writeln(_marker)
    ..writeln('q');
  for (final s in shapes) {
    switch (s) {
      case ShadeText():
        ops.writeln(s.gray ? '0.45882 0.45882 0.45882 rg' : '0 0 0 rg');
        ops.writeln('BT /${s.bold ? 'F2' : 'F1'} ${_n(s.size)} Tf 1 0 0 1 ${_n(s.x)} ${_n(_pageHeight - s.baselineY)} Tm (${s.text}) Tj ET');
      case ShadeEllipse():
        if (s.filled) {
          ops.writeln('0 0 0 rg');
          ops.write(ellipse(s, 'f'));
        } else {
          ops.writeln('0 0 0 RG ${_n(s.lineWidth)} w');
          ops.write(ellipse(s, 'S'));
        }
    }
  }
  ops.writeln('Q');
  return ops.toString();
}

void main() {
  final path = File('../answer_sheets/TAT-portrait-v5.pdf');
  final original = path.readAsBytesSync();
  final text = latin1.decode(original);

  if (text.contains(_marker)) {
    stdout.writeln('TAT v5 sample shading already added');
    return;
  }

  final startxref = RegExp(r'startxref\s+(\d+)\s+%%EOF\s*$').firstMatch(text);
  final size = RegExp(r'/Size (\d+)').allMatches(text).last;
  if (startxref == null) throw StateError('Unexpected PDF ending');
  final prev = int.parse(startxref.group(1)!);
  final newObject = int.parse(size.group(1)!); // next free object number

  final pageMatch = RegExp('(?<![0-9])$_pageObject 0 obj\\s*(<<.*?>>)\\s*endobj', dotAll: true).firstMatch(text);
  if (pageMatch == null || !pageMatch.group(1)!.contains(_oldContents)) {
    throw StateError('Unexpected TAT page object');
  }
  final pageDict = pageMatch.group(1)!.replaceFirst(_oldContents, '/Contents [ 15 0 R $newObject 0 R ]');

  final doc = PdfDocument();
  final regular = PdfFont.helvetica(doc);
  final bold = PdfFont.helveticaBold(doc);
  double measure(String t, double size, bool isBold) => ((isBold ? bold : regular).stringMetrics(t) * size).advanceWidth;
  const style = SampleShadingStyle.tat;
  final leftX = _rightX - sampleShadingWidth(style, measure);
  final stream = _operators(buildSampleShading(style, leftX, _baselineY, measure));

  final out = BytesBuilder()..add(original);
  void add(String s) => out.add(latin1.encode(s));
  if (!text.endsWith('\n')) add('\n');

  final streamOffset = out.length;
  add('$newObject 0 obj\n<< /Length ${stream.length} >>\nstream\n$stream\nendstream\nendobj\n');
  final pageOffset = out.length;
  add('$_pageObject 0 obj\n$pageDict\nendobj\n');

  String entry(int offset) => '${offset.toString().padLeft(10, '0')} 00000 n \n';
  final xrefOffset = out.length;
  add('xref\n$_pageObject 1\n${entry(pageOffset)}$newObject 1\n${entry(streamOffset)}'
      'trailer\n<< /Size ${newObject + 1} /Root 3 0 R /Info 1 0 R /Prev $prev >>\n'
      'startxref\n$xrefOffset\n%%EOF\n');

  final bytes = out.toBytes();
  // The original bytes must be untouched at the start of the file.
  for (var i = 0; i < original.length; i++) {
    if (bytes[i] != original[i]) throw StateError('Original bytes changed at $i');
  }
  path.writeAsBytesSync(bytes);
  stdout.writeln('Added the shading sample to TAT-portrait-v5.pdf '
      '(${bytes.length - original.length} bytes appended; original ${original.length} bytes unchanged)');
}
