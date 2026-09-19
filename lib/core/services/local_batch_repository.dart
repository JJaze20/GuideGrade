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
///       <scanId>_name_last.enc  - cropped Last Name field, if any
///       <scanId>_name_first.enc - cropped First Name field, if any
///       <scanId>_name_mi.enc    - cropped MI field, if any
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
    File? nameCropLastImage,
    File? nameCropFirstImage,
    File? nameCropMiddleImage,
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

    final nameCropLastRelPath =
        await _writeNameCropIfPresent(batchDirPath, '${scanId}_name_last.enc', nameCropLastImage);
    final nameCropFirstRelPath =
        await _writeNameCropIfPresent(batchDirPath, '${scanId}_name_first.enc', nameCropFirstImage);
    final nameCropMiddleRelPath =
        await _writeNameCropIfPresent(batchDirPath, '${scanId}_name_mi.enc', nameCropMiddleImage);

    final scan = LocalScan(
      id: scanId,
      imageFileName: relPath,
      rectifiedImageFileName: rectifiedRelPath,
      capturedAt: now,
      decoded: decoded,
      result: result,
      examinee: examinee,
      nameCropLastFileName: nameCropLastRelPath,
      nameCropFirstFileName: nameCropFirstRelPath,
      nameCropMiddleFileName: nameCropMiddleRelPath,
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
    File? nameCropLastImage,
    File? nameCropFirstImage,
    File? nameCropMiddleImage,
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

    // Rectified overlay copy and the 3 name crops all follow the same rule:
    // deliberately refreshed-to-null rather than kept when this rescan
    // didn't produce a new one, so a stale image from the *previous*
    // capture is never paired with this rescan's fresh photo (see
    // ScannedImageViewerScreen's _hasOverlay, which falls back to the plain
    // photo when the rectified path is null, and NameCropStrip, which
    // falls back to "no crop available" the same way).
    final rectifiedRelPath = await _replaceOptionalImage(
      batchDirPath,
      '${scanId}_rectified.enc',
      rectifiedImage,
      existing.rectifiedImageFileName,
    );
    final nameCropLastRelPath = await _replaceOptionalImage(
      batchDirPath,
      '${scanId}_name_last.enc',
      nameCropLastImage,
      existing.nameCropLastFileName,
    );
    final nameCropFirstRelPath = await _replaceOptionalImage(
      batchDirPath,
      '${scanId}_name_first.enc',
      nameCropFirstImage,
      existing.nameCropFirstFileName,
    );
    final nameCropMiddleRelPath = await _replaceOptionalImage(
      batchDirPath,
      '${scanId}_name_mi.enc',
      nameCropMiddleImage,
      existing.nameCropMiddleFileName,
    );

    final updatedScan = LocalScan(
      id: existing.id,
      imageFileName: newImageFileName,
      rectifiedImageFileName: rectifiedRelPath,
      capturedAt: DateTime.now(),
      decoded: decoded,
      result: result,
      examinee: examinee ?? existing.examinee, // default: same physical sheet -- keep its tag
      nameCropLastFileName: nameCropLastRelPath,
      nameCropFirstFileName: nameCropFirstRelPath,
      nameCropMiddleFileName: nameCropMiddleRelPath,
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
  Future<Uint8List?> resolveScanRectifiedImage(String batchId, LocalScan scan) =>
      _resolveOptionalImage(batchId, scan.rectifiedImageFileName);

  @override
  Future<Uint8List?> resolveScanNameCropLast(String batchId, LocalScan scan) =>
      _resolveOptionalImage(batchId, scan.nameCropLastFileName);

  @override
  Future<Uint8List?> resolveScanNameCropFirst(String batchId, LocalScan scan) =>
      _resolveOptionalImage(batchId, scan.nameCropFirstFileName);

  @override
  Future<Uint8List?> resolveScanNameCropMiddle(String batchId, LocalScan scan) =>
      _resolveOptionalImage(batchId, scan.nameCropMiddleFileName);

  /// Shared read path for every optional per-scan image (rectified overlay
  /// copy, name crops): null [name] (never stored) and a missing file
  /// (deleted out from under the app) both resolve to null, same as a
  /// genuinely-absent image -- callers already treat all of these as
  /// "nothing to show" rather than an error.
  Future<Uint8List?> _resolveOptionalImage(String batchId, String? name) async {
    if (name == null) return null;
    final root = await _root();
    final file = File('${_batchDir(root, batchId).path}/$name');
    if (!file.existsSync()) return null;
    final bytes = await file.readAsBytes();
    return name.endsWith('.enc') ? _crypto.decrypt(bytes) : bytes;
  }

  // ---------------------------------------------------------------------------
  // Cloud restore -- id-aware upserts sourced FROM the cloud (additive to
  // the existing push-sync design; see CloudRestoreService). Reuse the same
  // _root()/_batchDir()/_readManifest()/_writeManifest() primitives every
  // other method above already uses -- no new storage format.
  // ---------------------------------------------------------------------------

  @override
  Future<LocalBatch> upsertBatchFromCloud(LocalBatch batch) async {
    final root = await _root();
    final existing = await _readManifest(_batchDir(root, batch.id));
    if (existing == null) {
      // New to this device: write it as given, with no scans yet -- scans
      // are reconciled one at a time via upsertScanFromCloud.
      final fresh = LocalBatch(
        id: batch.id,
        batchCode: batch.batchCode,
        examCode: batch.examCode,
        examTitle: batch.examTitle,
        description: batch.description,
        expectedCount: batch.expectedCount,
        status: batch.status,
        createdByUid: batch.createdByUid,
        createdByName: batch.createdByName,
        createdAt: batch.createdAt,
        updatedAt: batch.updatedAt,
        scans: const [],
      );
      await _writeManifest(fresh);
      return fresh;
    }
    if (!batch.updatedAt.isAfter(existing.updatedAt)) {
      // Local is at least as new -- leave it exactly as it is (ties favor
      // the existing local copy).
      return existing;
    }
    // Cloud is strictly newer: merge only the mutable metadata fields.
    // Audit fields and scans are never touched by this merge.
    final merged = existing.copyWith(
      batchCode: batch.batchCode,
      examTitle: batch.examTitle,
      description: batch.description,
      expectedCount: batch.expectedCount,
      status: batch.status,
      updatedAt: batch.updatedAt,
    );
    await _writeManifest(merged);
    return merged;
  }

  @override
  Future<LocalBatch> upsertScanFromCloud({
    required String batchId,
    required LocalScan scan,
  }) async {
    final root = await _root();
    final batch = await _readManifest(_batchDir(root, batchId));
    if (batch == null) {
      throw StateError('Batch $batchId does not exist.');
    }
    final alreadyExists = batch.scans.any((s) => s.id == scan.id);
    if (alreadyExists) {
      // v1 rule: an existing local scan is never overwritten or merged,
      // regardless of which is newer -- left completely untouched.
      return batch;
    }
    final updated = batch.copyWith(scans: [...batch.scans, scan]);
    await _writeManifest(updated);
    return updated;
  }

  @override
  Future<void> writeRestoredScanImage({
    required String batchId,
    required String scanId,
    required Uint8List bytes,
  }) =>
      _writeRestoredImage(batchId, '$scanId.enc', bytes);

  @override
  Future<void> writeRestoredScanRectifiedImage({
    required String batchId,
    required String scanId,
    required Uint8List bytes,
  }) =>
      _writeRestoredImage(batchId, '${scanId}_rectified.enc', bytes);

  /// Shared write path for both cloud-restored image variants: encrypt via
  /// the same [_crypto] every captured photo already goes through, then
  /// write to the batch's `images/` directory under [fileName]. Does not
  /// read or touch the manifest -- image bytes live outside `batch.enc`,
  /// same as a normal capture.
  Future<void> _writeRestoredImage(
    String batchId,
    String fileName,
    Uint8List bytes,
  ) async {
    final root = await _root();
    final batchDirPath = _batchDir(root, batchId).path;
    final imagesDir = Directory('$batchDirPath/$_imagesDirName');
    if (!imagesDir.existsSync()) imagesDir.createSync(recursive: true);
    final encrypted = await _crypto.encrypt(bytes);
    await File('$batchDirPath/$_imagesDirName/$fileName')
        .writeAsBytes(encrypted, flush: true);
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

  /// [addScan]'s write path for one optional per-scan image (a name crop
  /// today; the rectified overlay copy uses this same shape inline since
  /// it has no "existing" file to worry about on a fresh scan): encrypts
  /// and writes [image] under [fileName] when given and present on disk,
  /// returning the relative path to store on the [LocalScan]; returns null
  /// (nothing written) when [image] is null or missing, e.g. cropping
  /// failed for this sheet -- never blocks the scan itself from saving.
  Future<String?> _writeNameCropIfPresent(String batchDirPath, String fileName, File? image) async {
    if (image == null || !image.existsSync()) return null;
    final relPath = '$_imagesDirName/$fileName';
    final encrypted = await _crypto.encrypt(await image.readAsBytes());
    await File('$batchDirPath/$relPath').writeAsBytes(encrypted, flush: true);
    return relPath;
  }

  /// [replaceScan]'s write path for one optional per-scan image (rectified
  /// overlay copy, or a name crop): when [newImage] is given and present on
  /// disk, encrypts and writes it under [fileName], deletes [existingRelPath]
  /// if it names a different file, and returns the new relative path. When
  /// [newImage] is absent, deliberately clears to null instead of keeping
  /// [existingRelPath] (deleting that old file too) -- see the call site's
  /// comment for why a stale image must never survive a rescan that didn't
  /// reproduce it.
  Future<String?> _replaceOptionalImage(
    String batchDirPath,
    String fileName,
    File? newImage,
    String? existingRelPath,
  ) async {
    if (newImage != null && newImage.existsSync()) {
      final relPath = '$_imagesDirName/$fileName';
      final encrypted = await _crypto.encrypt(await newImage.readAsBytes());
      await File('$batchDirPath/$relPath').writeAsBytes(encrypted, flush: true);
      if (existingRelPath != null && existingRelPath != relPath) {
        _deleteIfExists(File('$batchDirPath/$existingRelPath'));
      }
      return relPath;
    }
    if (existingRelPath != null) {
      _deleteIfExists(File('$batchDirPath/$existingRelPath'));
    }
    return null;
  }
}
