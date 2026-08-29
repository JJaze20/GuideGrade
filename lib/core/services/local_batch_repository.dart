import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../../models/local_batch.dart';
import '../../models/omr_scan_result.dart';
import 'batch_repository.dart';

/// Device-storage implementation of [BatchRepository].
///
/// Every batch is a self-contained folder under the app's private
/// documents directory, so it survives app restarts and upgrades (only a
/// full uninstall clears it) and can be reasoned about / backed up as one
/// unit:
///
/// ```
/// <appDocs>/guidegrade_batches/
///   <batchId>/
///     batch.json        - batch info, exam type, scans, results, metadata
///     images/
///       <scanId>.jpg    - the original captured sheet photo
/// ```
///
/// `batch.json` is the single source of truth; the directory listing is
/// only used to discover which batches exist.
class LocalBatchRepository implements BatchRepository {
  LocalBatchRepository({this.rootOverride});

  /// Test seam: when set, batches are stored under here instead of the
  /// platform documents directory.
  final Directory? rootOverride;
  Directory? _rootCache;

  static const _folderName = 'guidegrade_batches';
  static const _manifestName = 'batch.json';
  static const _imagesDirName = 'images';

  Future<Directory> _root() async {
    if (_rootCache != null) return _rootCache!;
    final base = rootOverride ?? await getApplicationDocumentsDirectory();
    final dir = Directory('${base.path}/$_folderName');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    _rootCache = dir;
    return dir;
  }

  Directory _batchDir(Directory root, String id) => Directory('${root.path}/$id');

  File _manifestFile(Directory root, String id) =>
      File('${_batchDir(root, id).path}/$_manifestName');

  Future<LocalBatch?> _readManifest(File file) async {
    try {
      if (!file.existsSync()) return null;
      final raw = await file.readAsString();
      return LocalBatch.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (e) {
      // A single corrupt manifest must not take down the whole list.
      // ignore: avoid_print
      print('LocalBatchRepository: skipping unreadable batch at ${file.path}: $e');
      return null;
    }
  }

  Future<void> _writeManifest(LocalBatch batch) async {
    final root = await _root();
    final dir = _batchDir(root, batch.id);
    if (!dir.existsSync()) dir.createSync(recursive: true);
    final file = _manifestFile(root, batch.id);
    await file.writeAsString(
      const JsonEncoder.withIndent('  ').convert(batch.toJson()),
      flush: true,
    );
  }

  @override
  Future<List<LocalBatch>> getBatches() async {
    final root = await _root();
    final out = <LocalBatch>[];
    for (final entity in root.listSync()) {
      if (entity is! Directory) continue;
      final manifest = File('${entity.path}/$_manifestName');
      final batch = await _readManifest(manifest);
      if (batch != null) out.add(batch);
    }
    out.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return out;
  }

  @override
  Future<LocalBatch?> getBatchById(String id) async {
    final root = await _root();
    return _readManifest(_manifestFile(root, id));
  }

  @override
  Future<List<LocalBatch>> getBatchesByExamCode(String examCode) async {
    final all = await getBatches();
    return all.where((b) => b.examCode == examCode).toList();
  }

  @override
  Future<LocalBatch> createBatch({
    required String batchCode,
    required String examCode,
    required String examTitle,
    required String description,
    required int expectedCount,
    required String createdByUid,
    required String createdByName,
  }) async {
    final now = DateTime.now();
    final id = 'b_${now.millisecondsSinceEpoch}_${now.microsecond}';
    final batch = LocalBatch(
      id: id,
      batchCode: batchCode,
      examCode: examCode,
      examTitle: examTitle,
      description: description,
      expectedCount: expectedCount,
      status: 'Draft',
      createdByUid: createdByUid,
      createdByName: createdByName,
      createdAt: now,
      updatedAt: now,
      scans: const [],
    );
    await _writeManifest(batch);
    return batch;
  }

  @override
  Future<LocalBatch> updateBatch(LocalBatch batch) async {
    final root = await _root();
    final existing = await _readManifest(_manifestFile(root, batch.id));
    if (existing == null) {
      throw StateError('Batch ${batch.id} does not exist.');
    }
    // Never let an edit drop scans that were captured concurrently: keep
    // whatever is on disk unless the caller explicitly passed a scan list.
    final merged = batch.copyWith(
      scans: batch.scans.isEmpty && existing.scans.isNotEmpty
          ? existing.scans
          : batch.scans,
      updatedAt: DateTime.now(),
    );
    await _writeManifest(merged);
    return merged;
  }

  @override
  Future<void> deleteBatch(String id) async {
    final root = await _root();
    final dir = _batchDir(root, id);
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  }

  @override
  Future<LocalBatch> addScan({
    required String batchId,
    required OmrScanResult decoded,
    required File sourceImage,
    LocalScanResult? result,
  }) async {
    final root = await _root();
    final batch = await _readManifest(_manifestFile(root, batchId));
    if (batch == null) {
      throw StateError('Batch $batchId does not exist.');
    }

    final now = DateTime.now();
    final scanId = 's_${now.millisecondsSinceEpoch}_${batch.scans.length}';
    final imagesDir = Directory('${_batchDir(root, batchId).path}/$_imagesDirName');
    if (!imagesDir.existsSync()) imagesDir.createSync(recursive: true);

    final ext = _extensionOf(sourceImage.path);
    final relPath = '$_imagesDirName/$scanId$ext';
    await sourceImage.copy('${_batchDir(root, batchId).path}/$relPath');

    final scan = LocalScan(
      id: scanId,
      imageFileName: relPath,
      capturedAt: now,
      decoded: decoded,
      result: result,
    );

    final updated = batch.copyWith(
      scans: [...batch.scans, scan],
      // First scan promotes a Draft batch to Active.
      status: batch.status == 'Draft' ? 'Active' : batch.status,
      updatedAt: now,
    );
    await _writeManifest(updated);
    return updated;
  }

  @override
  Future<LocalBatch> attachResult({
    required String batchId,
    required String scanId,
    required LocalScanResult result,
  }) async {
    final root = await _root();
    final batch = await _readManifest(_manifestFile(root, batchId));
    if (batch == null) {
      throw StateError('Batch $batchId does not exist.');
    }
    final scans = batch.scans
        .map((s) => s.id == scanId ? s.copyWith(result: result) : s)
        .toList();
    final updated = batch.copyWith(scans: scans, updatedAt: DateTime.now());
    await _writeManifest(updated);
    return updated;
  }

  @override
  Future<File> resolveScanImage(String batchId, LocalScan scan) async {
    final root = await _root();
    return File('${_batchDir(root, batchId).path}/${scan.imageFileName}');
  }

  String _extensionOf(String path) {
    final dot = path.lastIndexOf('.');
    if (dot == -1 || dot < path.length - 6) return '.jpg';
    return path.substring(dot);
  }
}
