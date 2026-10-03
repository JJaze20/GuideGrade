import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

import '../../models/answer_correction.dart';
import '../../models/local_batch.dart';
import '../../models/omr_scan_result.dart';
import '../batch/batch_lifecycle.dart';
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

  /// One in-flight read-modify-write per batch. Every mutation below reads
  /// the manifest, changes it in memory and writes it back, so two of them
  /// overlapping (a correction tap while a tag saves, or a double tap) would
  /// silently lose one. Chaining them per batch id makes each see the
  /// previous one's result.
  final Map<String, Future<void>> _batchLocks = {};

  Future<T> _serialized<T>(String batchId, Future<T> Function() body) {
    final previous = _batchLocks[batchId] ?? Future<void>.value();
    final run = previous.catchError((_) {}).then((_) => body());
    final tail = run.then<void>((_) {}, onError: (_) {});
    _batchLocks[batchId] = tail;
    // Drop the entry once nothing newer queued behind it.
    tail.whenComplete(() {
      if (identical(_batchLocks[batchId], tail)) _batchLocks.remove(batchId);
    });
    return run;
  }

  /// Applies the derived status and a strictly-increasing revision to a
  /// batch that is about to be saved: a local save always lands on Draft
  /// (required fields have problems) or Active (complete). Archived is only
  /// ever set by [confirmBatchArchived], after the cloud confirms this exact
  /// revision — so any save, including one on an Archived batch, moves it
  /// off Archived until the NEW revision syncs. See [BatchLifecycle].
  LocalBatch _finalize(LocalBatch batch, LocalBatch? previous) {
    final problems = BatchLifecycle.problems(
      batchCode: batch.batchCode,
      examCode: batch.examCode,
      expectedCount: batch.expectedCount,
    );
    final floor = previous?.updatedAt ?? batch.updatedAt;
    return batch.copyWith(
      status: BatchLifecycle.statusAfterSave(problems),
      updatedAt: BatchLifecycle.nextRevision(floor, DateTime.now()),
    );
  }

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
    // Written beside the manifest and moved into place, so a crash or a
    // full disk mid-write leaves the previous manifest intact instead of a
    // truncated one (this file is the only copy of every answer, tag and
    // correction in the batch).
    final target = File('${dir.path}/$_manifestName');
    final temp = File('${dir.path}/$_manifestName.tmp');
    await temp.writeAsBytes(encrypted, flush: true);
    try {
      await temp.rename(target.path);
    } catch (_) {
      // Never delete the live manifest to retry a failed rename: interruption
      // between delete and rename would lose the only committed record.
      _deleteIfExists(temp);
      rethrow;
    }

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
    final draft = LocalBatch(
      id: id,
      batchCode: batchCode,
      examCode: examCode,
      examTitle: examTitle,
      description: description,
      expectedCount: expectedCount,
      status: BatchLifecycle.draft,
      createdByUid: createdByUid,
      createdByName: createdByName,
      createdAt: now,
      updatedAt: now,
      scans: const [],
    );
    // Draft only if a required field is missing/invalid; a complete batch is
    // Active as soon as it is saved.
    final batch = _finalize(draft, null);
    await _writeManifest(batch);
    return batch;
  }

  @override
  Future<LocalBatch> updateBatch(LocalBatch batch) => _serialized(batch.id, () async {
        final root = await _root();
        final existing = await _readManifest(_batchDir(root, batch.id));
        if (existing == null) {
          throw StateError('Batch ${batch.id} does not exist.');
        }
        // Never let an edit drop scans that were captured concurrently: keep
        // whatever is on disk unless the caller explicitly passed a scan list.
        // The caller's `status` is ignored: status is derived (see
        // BatchLifecycle), so an edit can neither pick nor keep Archived.
        final merged = _finalize(
          batch.copyWith(
            scans: batch.scans.isEmpty && existing.scans.isNotEmpty
                ? existing.scans
                : batch.scans,
          ),
          existing,
        );
        await _writeManifest(merged);
        return merged;
      });

  @override
  Future<bool> confirmBatchArchived(
    String batchId,
    DateTime confirmedUpdatedAt,
  ) =>
      _serialized(batchId, () async {
        final root = await _root();
        final batch = await _readManifest(_batchDir(root, batchId));
        if (batch == null) return false;
        if (batch.isArchived) return false; // already recorded
        // Compare-and-set on the revision the cloud actually acknowledged:
        // if anything was saved since, the confirmation is for an OLDER
        // revision and must not archive the newer, unsynced one.
        if (batch.updatedAt != confirmedUpdatedAt) return false;
        final problems = BatchLifecycle.problems(
          batchCode: batch.batchCode,
          examCode: batch.examCode,
          expectedCount: batch.expectedCount,
        );
        if (problems.isNotEmpty) return false; // an incomplete batch is Draft
        // Deliberately NOT bumping updatedAt: this is a derived marker of an
        // already-saved revision, not a new edit — bumping it would make the
        // revision the cloud just confirmed look unsynced again.
        await _writeManifest(batch.copyWith(status: BatchLifecycle.archived));
        return true;
      });

  @override
  Future<LocalBatch> updateScanCorrections({
    required String batchId,
    required String scanId,
    required List<AnswerCorrection> corrections,
    LocalScanResult? result,
  }) =>
      _serialized(batchId, () async {
        final root = await _root();
        final batch = await _readManifest(_batchDir(root, batchId));
        if (batch == null) {
          throw StateError('Batch $batchId does not exist.');
        }
        final index = batch.scans.indexWhere((s) => s.id == scanId);
        if (index == -1) {
          throw StateError('Scan $scanId does not exist in batch $batchId.');
        }
        final scan = batch.scans[index];
        final knownIds = {for (final c in scan.corrections) c.id};
        for (final c in corrections) {
          if (knownIds.contains(c.id)) continue;
          // A new entry must be about THIS capture. If the sheet was
          // rescanned while the editor was open, refuse rather than record a
          // correction against a photo the counselor never looked at.
          if (c.captureRevision != scan.captureRevision) {
            throw StateError(
              'This sheet was rescanned after the editor opened. Reopen the scan and review it again.',
            );
          }
          if (c.scanId != scanId) {
            throw StateError('Correction ${c.id} belongs to a different scan.');
          }
        }
        // History is append-only: a write may add entries but never drop or
        // rewrite one that is already stored.
        final merged = CorrectionRules.merge(scan.corrections, corrections);
        final sameHistory = merged.length == scan.corrections.length;
        final sameResult = result == null ||
            jsonEncode(result.toJson()) == jsonEncode(scan.result?.toJson());
        if (sameHistory && sameResult) {
          return batch; // a repeated request: nothing to record, no new revision
        }
        final scans = [...batch.scans];
        scans[index] = scan.copyWith(corrections: merged, result: result);
        final updated = _finalize(batch.copyWith(scans: scans), batch);
        await _writeManifest(updated);
        return updated;
      });

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
  }) => _serialized(batchId, () async {
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

    // Status is derived on every save (see BatchLifecycle): scanning no
    // longer "promotes" a Draft, because a complete batch is already Active
    // and an incomplete one stays Draft until its required fields are fixed.
    final updated = _finalize(batch.copyWith(scans: [...batch.scans, scan]), batch);
    await _writeManifest(updated);
    return updated;
  });

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
    LocalScan? expectedOriginal,
  }) => _serialized(batchId, () async {
    final root = await _root();
    final batch = await _readManifest(_batchDir(root, batchId));
    if (batch == null) {
      throw StateError('Batch $batchId does not exist.');
    }
    final existingIndex = batch.scans.indexWhere((s) => s.id == scanId);
    if (existingIndex == -1) {
      if (expectedOriginal != null) throw RescanOriginalChangedException(deleted: true);
      throw StateError('Scan $scanId does not exist in batch $batchId.');
    }
    final existing = batch.scans[existingIndex];
    if (expectedOriginal != null && !existing.sameStoredStateAs(expectedOriginal)) {
      throw RescanOriginalChangedException(deleted: false);
    }
    final batchDirPath = _batchDir(root, batchId).path;
    final imagesDir = Directory('$batchDirPath/$_imagesDirName');
    if (!imagesDir.existsSync()) imagesDir.createSync(recursive: true);

    // Copy-on-write: write complete encrypted files at unique final paths
    // BEFORE publishing them in the manifest. Old paths remain untouched
    // throughout preparation. A killed process can leave orphan encrypted
    // files, but the committed manifest still points to a complete capture.
    // Randomness also avoids reusing an orphan's path after a restart/retry.
    final random = Random.secure();
    final version = List.generate(16, (_) => random.nextInt(256)
        .toRadixString(16).padLeft(2, '0')).join();
    final prefix = '${scanId}_r${existing.captureRevision + 1}_$version';
    final staged = <File>[];
    Future<String?> stage(String fileName, File? image, {bool required = false}) async {
      if (image == null || !image.existsSync()) {
        if (required) throw FileSystemException('Replacement photo is missing', image?.path);
        return null;
      }
      final rel = '$_imagesDirName/$fileName';
      final target = File('$batchDirPath/$rel');
      final encrypted = await _crypto.encrypt(await image.readAsBytes());
      // Register before writing so even a partial write is cleaned on failure.
      staged.add(target);
      await target.writeAsBytes(encrypted, flush: true);
      return rel;
    }

    // Always an encrypted filename, regardless of what the previous file
    // was named -- a plaintext-era `.jpg` silently upgrades to
    // `.enc` on this rescan, same as a manifest upgrades on its next write.
    // The rectified overlay copy and the 3 name crops are deliberately
    // refreshed-to-null rather than kept when this rescan didn't produce a
    // new one, so a stale image from the *previous* capture is never paired
    // with this rescan's fresh photo (see ScannedImageViewerScreen's
    // _hasOverlay and NameCropStrip, which both fall back cleanly).
    final LocalBatch updated;
    final LocalScan updatedScan;
    try {
      final newImageRel = (await stage('$prefix.enc', sourceImage, required: true))!;
      final rectifiedRelPath = await stage('${prefix}_rectified.enc', rectifiedImage);
      final nameCropLastRelPath = await stage('${prefix}_name_last.enc', nameCropLastImage);
      final nameCropFirstRelPath = await stage('${prefix}_name_first.enc', nameCropFirstImage);
      final nameCropMiddleRelPath = await stage('${prefix}_name_mi.enc', nameCropMiddleImage);

      updatedScan = LocalScan(
        id: existing.id,
        imageFileName: newImageRel,
        rectifiedImageFileName: rectifiedRelPath,
        // The sheet's own date is never moved by a rescan; when the
        // replacement happened is recorded separately.
        capturedAt: existing.capturedAt,
        rescannedAt: DateTime.now(),
        decoded: decoded,
        result: result,
        examinee: examinee ?? existing.examinee, // default: same physical sheet -- keep its tag
        nameCropLastFileName: nameCropLastRelPath,
        nameCropFirstFileName: nameCropFirstRelPath,
        nameCropMiddleFileName: nameCropMiddleRelPath,
        // A rescan is a NEW capture of the same slot: corrections made on the
        // old capture stay in the history (never dropped) but stop applying —
        // see AnswerCorrection.captureRevision / LocalScan.correctionsNeedingReview.
        captureRevision: existing.captureRevision + 1,
        corrections: existing.corrections,
      );

      final scans = [...batch.scans];
      scans[existingIndex] = updatedScan;
      updated = _finalize(batch.copyWith(scans: scans), batch);
      await _writeManifest(updated); // commit point
    } catch (_) {
      for (final s in staged) {
        _deleteIfExists(s);
      }
      rethrow;
    }

    // All referenced images already exist. Only obsolete files are removed
    // after commit; failed cleanup cannot invalidate the new record.
    final newRefs = <String?>{
      updatedScan.imageFileName,
      updatedScan.rectifiedImageFileName,
      updatedScan.nameCropLastFileName,
      updatedScan.nameCropFirstFileName,
      updatedScan.nameCropMiddleFileName,
    };
    for (final old in <String?>[
      existing.imageFileName,
      existing.rectifiedImageFileName,
      existing.nameCropLastFileName,
      existing.nameCropFirstFileName,
      existing.nameCropMiddleFileName,
    ]) {
      if (old != null && !newRefs.contains(old)) _deleteIfExists(File('$batchDirPath/$old'));
    }
    return updated;
  });

  @override
  Future<LocalBatch> attachResult({
    required String batchId,
    required String scanId,
    required LocalScanResult result,
  }) => _serialized(batchId, () async {
    final root = await _root();
    final batch = await _readManifest(_batchDir(root, batchId));
    if (batch == null) {
      throw StateError('Batch $batchId does not exist.');
    }
    final scans = batch.scans
        .map((s) => s.id == scanId ? s.copyWith(result: result) : s)
        .toList();
    final updated = _finalize(batch.copyWith(scans: scans), batch);
    await _writeManifest(updated);
    return updated;
  });

  @override
  Future<LocalBatch> deleteScan({
    required String batchId,
    required String scanId,
    // Cloud-sync-only metadata (see BatchRepository.deleteScan's doc
    // comment) -- a bare LocalBatchRepository has no cloud operation to
    // attach them to, so they are accepted only to satisfy the shared
    // interface and are otherwise unused here.
    String? deletedByUid,
    String? deletedByName,
    String? reason,
  }) =>
      _serialized(batchId, () async {
        final root = await _root();
        final batch = await _readManifest(_batchDir(root, batchId));
        if (batch == null) {
          throw StateError('Batch $batchId does not exist.');
        }
        final index = batch.scans.indexWhere((s) => s.id == scanId);
        if (index == -1) {
          throw StateError('Scan $scanId does not exist in batch $batchId.');
        }
        final removed = batch.scans[index];
        final scans = [...batch.scans]..removeAt(index);
        var updated = _finalize(batch.copyWith(scans: scans), batch);
        // Removing a sheet corrects the record; it doesn't reopen it. A save
        // normally drops Archived until the cloud re-confirms the new
        // revision (see _finalize), but here the batch stays Archived.
        if (batch.isArchived && updated.status != BatchLifecycle.draft) {
          updated = updated.copyWith(status: BatchLifecycle.archived);
        }
        // Manifest first: if this write fails nothing has been deleted and the
        // batch is exactly as it was. Files go after — a failure there only
        // leaves an unreferenced encrypted file behind, never a broken scan.
        await _writeManifest(updated);
        final batchDirPath = _batchDir(root, batchId).path;
        for (final name in [
          removed.imageFileName,
          removed.rectifiedImageFileName,
          removed.nameCropLastFileName,
          removed.nameCropFirstFileName,
          removed.nameCropMiddleFileName,
        ]) {
          if (name != null) _deleteIfExists(File('$batchDirPath/$name'));
        }
        return updated;
      });

  @override
  Future<LocalBatch> setScanExaminee({
    required String batchId,
    required String scanId,
    ExamineeInfo? examinee,
  }) => _serialized(batchId, () async {
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
    final updated = _finalize(batch.copyWith(scans: scans), batch);
    await _writeManifest(updated);
    return updated;
  });

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

}
