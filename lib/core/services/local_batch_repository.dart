import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

import '../../models/local_batch.dart';
import '../../models/omr_scan_result.dart';
import 'batch_crypto_service.dart';
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
///     batch.enc         - encrypted batch info, exam type, scans, results, metadata
///     images/
///       <scanId>.enc    - the original captured sheet photo, encrypted
///       <scanId>_rectified.enc  - the perspective-corrected copy, if any
/// ```
///
/// `batch.enc` is the single source of truth; the directory listing is
/// only used to discover which batches exist. Everything is encrypted at
/// rest via [BatchCryptoService] (AES-256-GCM, key in the platform
/// Keystore/Keychain) -- see that class's doc comment for exactly what
/// threat this does and doesn't address. A batch written before this
/// encryption existed may still have a plaintext `batch.json` and/or
/// `images/<scanId>.jpg` sitting alongside/instead of the `.enc` files;
/// those are read transparently (see [_readManifest]/[resolveScanImage])
/// and migrated to encrypted form the next time anything writes to that
/// batch or replaces that image -- there's no separate migration step.
class LocalBatchRepository implements BatchRepository {
  LocalBatchRepository({this.rootOverride, BatchCryptoService? crypto})
      : _crypto = crypto ?? BatchCryptoService();

  /// Test seam: when set, batches are stored under here instead of the
  /// platform documents directory.
  final Directory? rootOverride;
  final BatchCryptoService _crypto;
  Directory? _rootCache;

  static const _folderName = 'guidegrade_batches';
  static const _manifestName = 'batch.enc';
  static const _legacyManifestName = 'batch.json';
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

  /// Reads [batchDir]'s manifest, preferring the encrypted `batch.enc` and
  /// falling back to a legacy plaintext `batch.json` if that's all this
  /// batch has (predates encryption, never written to since). Returns null
  /// if neither exists, or either is unreadable (corrupt file, wrong/lost
  /// key, tampering) -- a single bad batch must never take down the whole
  /// list.
  Future<LocalBatch?> _readManifest(Directory batchDir) async {
    final encFile = File('${batchDir.path}/$_manifestName');
    try {
      if (encFile.existsSync()) {
        final decrypted = await _crypto.decrypt(await encFile.readAsBytes());
        return LocalBatch.fromJson(jsonDecode(utf8.decode(decrypted)) as Map<String, dynamic>);
      }
      final legacyFile = File('${batchDir.path}/$_legacyManifestName');
      if (legacyFile.existsSync()) {
        final raw = await legacyFile.readAsString();
        return LocalBatch.fromJson(jsonDecode(raw) as Map<String, dynamic>);
      }
      return null;
    } catch (e) {
      // ignore: avoid_print
      print('LocalBatchRepository: skipping unreadable batch at ${batchDir.path}: $e');
      return null;
    }
  }

  /// Always writes the encrypted `batch.enc`, then deletes a legacy
  /// plaintext `batch.json` if one exists -- once the encrypted copy is
  /// durably written, a readable plaintext copy must not keep sitting next
  /// to it. This is the only migration step: any write naturally upgrades
  /// that batch to encrypted form.
  Future<void> _writeManifest(LocalBatch batch) async {
    final root = await _root();
    final dir = _batchDir(root, batch.id);
    if (!dir.existsSync()) dir.createSync(recursive: true);

    final jsonBytes = Uint8List.fromList(utf8.encode(jsonEncode(batch.toJson())));
    final encrypted = await _crypto.encrypt(jsonBytes);
    await File('${dir.path}/$_manifestName').writeAsBytes(encrypted, flush: true);

    final legacy = File('${dir.path}/$_legacyManifestName');
    if (legacy.existsSync()) {
      try {
        legacy.deleteSync();
      } catch (_) {
        // Best-effort cleanup only -- the encrypted copy is already the
        // source of truth either way, so a failure here isn't fatal.
      }
    }
  }

  @override
  Future<List<LocalBatch>> getBatches() async {
    final root = await _root();
    final out = <LocalBatch>[];
    for (final entity in root.listSync()) {
      if (entity is! Directory) continue;
      final batch = await _readManifest(entity);
      if (batch != null) out.add(batch);
    }
    out.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return out;
  }

  @override
  Future<LocalBatch?> getBatchById(String id) async {
    final root = await _root();
    return _readManifest(_batchDir(root, id));
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
    final existing = await _readManifest(_batchDir(root, batch.id));
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
    File? rectifiedImage,
    LocalScanResult? result,
    ExamineeInfo? examinee,
    String? ocrLastNameGuess,
    String? ocrFirstNameGuess,
    String? ocrMiddleNameGuess,
  }) async {
    final root = await _root();
    final batch = await _readManifest(_batchDir(root, batchId));
    if (batch == null) {
      throw StateError('Batch $batchId does not exist.');
    }
    // Checked before any file I/O below, so a rejected scan leaves nothing
    // behind (no orphaned image, no partial state) — a failed/blocked scan
    // must never consume a slot. This is the real cap; any check elsewhere
    // (AppState.scanLimitBlockMessage, a disabled button) is only a
    // friendlier warning layered on top of it.
    if (batch.isFull) {
      throw BatchScanLimitExceededException(batch.expectedCount);
    }

    final now = DateTime.now();
    final scanId = 's_${now.millisecondsSinceEpoch}_${batch.scans.length}';
    final batchDirPath = _batchDir(root, batchId).path;
    final imagesDir = Directory('$batchDirPath/$_imagesDirName');
    if (!imagesDir.existsSync()) imagesDir.createSync(recursive: true);

    // Always written encrypted, regardless of the source photo's own
    // format -- see BatchCryptoService's doc comment for what this
    // protects against.
    final relPath = '$_imagesDirName/$scanId.enc';
    final encryptedSource = await _crypto.encrypt(await sourceImage.readAsBytes());
    await File('$batchDirPath/$relPath').writeAsBytes(encryptedSource, flush: true);

    String? rectifiedRelPath;
    if (rectifiedImage != null && rectifiedImage.existsSync()) {
      rectifiedRelPath = '$_imagesDirName/${scanId}_rectified.enc';
      final encryptedRectified = await _crypto.encrypt(await rectifiedImage.readAsBytes());
      await File('$batchDirPath/$rectifiedRelPath').writeAsBytes(encryptedRectified, flush: true);
    }

    final scan = LocalScan(
      id: scanId,
      imageFileName: relPath,
      rectifiedImageFileName: rectifiedRelPath,
      capturedAt: now,
      decoded: decoded,
      result: result,
      examinee: examinee,
      ocrLastNameGuess: ocrLastNameGuess,
      ocrFirstNameGuess: ocrFirstNameGuess,
      ocrMiddleNameGuess: ocrMiddleNameGuess,
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
  Future<LocalBatch> replaceScan({
    required String batchId,
    required String scanId,
    required OmrScanResult decoded,
    required File sourceImage,
    File? rectifiedImage,
    LocalScanResult? result,
    ExamineeInfo? examinee,
    String? ocrLastNameGuess,
    String? ocrFirstNameGuess,
    String? ocrMiddleNameGuess,
  }) async {
    final root = await _root();
    final batch = await _readManifest(_batchDir(root, batchId));
    if (batch == null) {
      throw StateError('Batch $batchId does not exist.');
    }
    final existingIndex = batch.scans.indexWhere((s) => s.id == scanId);
    if (existingIndex == -1) {
      throw StateError('Scan $scanId does not exist in batch $batchId.');
    }
    final existing = batch.scans[existingIndex];
    final batchDirPath = _batchDir(root, batchId).path;

    // Always (re)written to the canonical encrypted filename, regardless
    // of what the previous file was named -- a plaintext-era `.jpg`
    // silently upgrades to `.enc` here, on this rescan, same as a
    // manifest upgrades on its next write.
    final newImageFileName = '$_imagesDirName/$scanId.enc';
    final encryptedSource = await _crypto.encrypt(await sourceImage.readAsBytes());
    await File('$batchDirPath/$newImageFileName').writeAsBytes(encryptedSource, flush: true);
    if (existing.imageFileName != newImageFileName) {
      _deleteIfExists(File('$batchDirPath/${existing.imageFileName}'));
    }

    String? rectifiedRelPath;
    if (rectifiedImage != null && rectifiedImage.existsSync()) {
      final newRectifiedFileName = '$_imagesDirName/${scanId}_rectified.enc';
      final encryptedRectified = await _crypto.encrypt(await rectifiedImage.readAsBytes());
      await File('$batchDirPath/$newRectifiedFileName').writeAsBytes(encryptedRectified, flush: true);
      final oldRectified = existing.rectifiedImageFileName;
      if (oldRectified != null && oldRectified != newRectifiedFileName) {
        _deleteIfExists(File('$batchDirPath/$oldRectified'));
      }
      rectifiedRelPath = newRectifiedFileName;
    } else {
      // No rectified image this time -- deliberately left null rather than
      // kept, so a stale rectified photo from the *previous* capture is
      // never paired with this rescan's fresh marks (see
      // ScannedImageViewerScreen's _hasOverlay, which just falls back to
      // the plain photo when this is null). Clean up the old file too, if
      // there was one.
      final oldRectified = existing.rectifiedImageFileName;
      if (oldRectified != null) {
        _deleteIfExists(File('$batchDirPath/$oldRectified'));
      }
      rectifiedRelPath = null;
    }

    final updatedScan = LocalScan(
      id: existing.id,
      imageFileName: newImageFileName,
      rectifiedImageFileName: rectifiedRelPath,
      capturedAt: DateTime.now(),
      decoded: decoded,
      result: result,
      examinee: examinee ?? existing.examinee, // default: same physical sheet -- keep its tag
      ocrLastNameGuess: ocrLastNameGuess ?? existing.ocrLastNameGuess,
      ocrFirstNameGuess: ocrFirstNameGuess ?? existing.ocrFirstNameGuess,
      ocrMiddleNameGuess: ocrMiddleNameGuess ?? existing.ocrMiddleNameGuess,
    );

    final scans = [...batch.scans];
    scans[existingIndex] = updatedScan;
    final updated = batch.copyWith(scans: scans, updatedAt: DateTime.now());
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
    final batch = await _readManifest(_batchDir(root, batchId));
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
  Future<LocalBatch> setScanExaminee({
    required String batchId,
    required String scanId,
    ExamineeInfo? examinee,
  }) async {
    final root = await _root();
    final batch = await _readManifest(_batchDir(root, batchId));
    if (batch == null) {
      throw StateError('Batch $batchId does not exist.');
    }
    final clear = examinee == null || examinee.isEmpty;
    final scans = batch.scans
        .map((s) => s.id == scanId
            ? s.copyWith(examinee: examinee, clearExaminee: clear)
            : s)
        .toList();
    final updated = batch.copyWith(scans: scans, updatedAt: DateTime.now());
    await _writeManifest(updated);
    return updated;
  }

  @override
  Future<Uint8List?> resolveScanImage(String batchId, LocalScan scan) async {
    final root = await _root();
    final file = File('${_batchDir(root, batchId).path}/${scan.imageFileName}');
    if (!file.existsSync()) return null;
    final bytes = await file.readAsBytes();
    // A legacy plaintext `.jpg` (predates encryption, never rescanned
    // since) is returned as-is; anything else is our encrypted format.
    return scan.imageFileName.endsWith('.enc') ? _crypto.decrypt(bytes) : bytes;
  }

  @override
  Future<Uint8List?> resolveScanRectifiedImage(String batchId, LocalScan scan) async {
    final name = scan.rectifiedImageFileName;
    if (name == null) return null;
    final root = await _root();
    final file = File('${_batchDir(root, batchId).path}/$name');
    if (!file.existsSync()) return null;
    final bytes = await file.readAsBytes();
    return name.endsWith('.enc') ? _crypto.decrypt(bytes) : bytes;
  }

  void _deleteIfExists(File file) {
    if (file.existsSync()) {
      try {
        file.deleteSync();
      } catch (_) {
        // Best-effort cleanup of a superseded file; not fatal if it fails.
      }
    }
  }
}
