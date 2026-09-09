import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Encrypts/decrypts the locally saved batch archive's data at rest --
/// batch.json manifests (examinee names/numbers, decoded answers, scores)
/// and scan images (the photographed sheets, which carry their own
/// handwritten ID section) -- so that whoever gets at the raw files
/// directly (a rooted device, a compromised OS, ADB/physical extraction)
/// without *also* compromising this device's hardware-backed key store
/// cannot read any of it.
///
/// Deliberately does **not** protect against someone using the app itself
/// while it's unlocked and already signed in -- that's a different threat
/// (see AppState's session handling / a future re-lock feature), not one
/// encrypting files on disk can address: the app decrypts everything it
/// shows through its own UI regardless.
///
/// Uses AES-256-GCM: authenticated encryption, so a corrupted or tampered
/// file is detected (decrypt throws) rather than silently accepted. The
/// key is generated once per app install and stored via
/// [FlutterSecureStorage], which itself keeps it in the Android Keystore /
/// iOS Keychain -- not in a plain file the same attacker could also just
/// read.
class BatchCryptoService {
  BatchCryptoService({FlutterSecureStorage? secureStorage})
      : _secureStorage = secureStorage ?? const FlutterSecureStorage();

  static const _keyStorageKey = 'guidegrade_batch_encryption_key_v1';

  final FlutterSecureStorage _secureStorage;
  final AesGcm _algorithm = AesGcm.with256bits();

  /// Cached after first use so every encrypt/decrypt call doesn't pay for
  /// a fresh Keystore/Keychain round-trip -- those have a small but real
  /// fixed cost, wasteful to repeat for every scan/manifest touched in a
  /// session.
  SecretKey? _cachedKey;

  Future<SecretKey> _getKey() async {
    final cached = _cachedKey;
    if (cached != null) return cached;

    final existing = await _secureStorage.read(key: _keyStorageKey);
    if (existing != null) {
      final key = SecretKey(base64Decode(existing));
      _cachedKey = key;
      return key;
    }

    // First run on this device (or secure storage was cleared) -- mint a
    // new key and persist it. Anything encrypted under a since-lost key
    // (e.g. secure storage cleared independently of app data, which can
    // happen on some OEM skins) is unrecoverable by design -- that's the
    // same trade-off any at-rest encryption makes.
    final newKey = await _algorithm.newSecretKey();
    final bytes = await newKey.extractBytes();
    await _secureStorage.write(key: _keyStorageKey, value: base64Encode(bytes));
    _cachedKey = newKey;
    return newKey;
  }

  /// Encrypts [plaintext], packing a fresh random nonce + ciphertext + MAC
  /// into one blob suitable for writing straight to a file.
  Future<Uint8List> encrypt(Uint8List plaintext) async {
    final key = await _getKey();
    final box = await _algorithm.encrypt(plaintext, secretKey: key);
    return Uint8List.fromList(box.concatenation());
  }

  /// Reverses [encrypt]. Throws if [packed] isn't a valid box for this
  /// key -- wrong/lost key, or a corrupted/tampered file. Callers decide
  /// how to handle that (e.g. [LocalBatchRepository] treats an unreadable
  /// manifest the same as any other corrupt-file case: skip it, don't
  /// crash the whole batch list).
  Future<Uint8List> decrypt(Uint8List packed) async {
    final key = await _getKey();
    final box = SecretBox.fromConcatenation(
      packed,
      nonceLength: _algorithm.nonceLength,
      macLength: _algorithm.macAlgorithm.macLength,
    );
    final plain = await _algorithm.decrypt(box, secretKey: key);
    return Uint8List.fromList(plain);
  }
}
