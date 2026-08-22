import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

import '../../models/user.dart';
import '../../models/exam.dart';
import '../../models/answer_key.dart';
import '../../models/answer_key_model.dart';
import '../../models/batch.dart';
import '../../models/examinee.dart';
import '../../models/result.dart';
import '../omr/answer_key_adapter.dart';

/// Firestore service for all database operations.
/// This service handles Firestore interactions for the GuideGrade application.
class FirestoreService {
  FirestoreService({
    FirebaseFirestore? firestore,
    FirebaseAuth? firebaseAuth,
  })  : _firestore = firestore ?? FirebaseFirestore.instance,
        _auth = firebaseAuth ?? FirebaseAuth.instance;

  final FirebaseFirestore _firestore;
  final FirebaseAuth _auth;

  // Collection references
  CollectionReference get _usersCollection => _firestore.collection('users');
  CollectionReference get _examsCollection => _firestore.collection('exams');
  CollectionReference get _answerKeysCollection => _firestore.collection('answer_keys');
  CollectionReference get _batchesCollection => _firestore.collection('batches');
  CollectionReference get _examineesCollection => _firestore.collection('examinees');
  CollectionReference get _resultsCollection => _firestore.collection('results');

  // ============================================
  // USER OPERATIONS
  // ============================================

  /// Get current user document
  Future<UserModel?> getCurrentUser() async {
    final user = _auth.currentUser;
    if (user == null) return null;

    try {
      final doc = await _usersCollection.doc(user.uid).get();
      if (!doc.exists) return null;
      
      return UserModel.fromFirestore(doc.data() as Map<String, dynamic>, doc.id);
    } catch (e) {
      print('Error getting current user: $e');
      return null;
    }
  }

  /// Get user by ID
  Future<UserModel?> getUserById(String userId) async {
    try {
      final doc = await _usersCollection.doc(userId).get();
      if (!doc.exists) return null;
      
      return UserModel.fromFirestore(doc.data() as Map<String, dynamic>, doc.id);
    } catch (e) {
      print('Error getting user by ID: $e');
      return null;
    }
  }

  /// Get user by email
  Future<UserModel?> getUserByEmail(String email) async {
    try {
      final query = await _usersCollection.where('email', isEqualTo: email).limit(1).get();
      if (query.docs.isEmpty) return null;
      
      final doc = query.docs.first;
      return UserModel.fromFirestore(doc.data() as Map<String, dynamic>, doc.id);
    } catch (e) {
      print('Error getting user by email: $e');
      return null;
    }
  }

  /// Get all users (admin only)
  Future<List<UserModel>> getAllUsers() async {
    try {
      final query = await _usersCollection.get();
      return query.docs.map((doc) => 
        UserModel.fromFirestore(doc.data() as Map<String, dynamic>, doc.id)
      ).toList();
    } catch (e) {
      print('Error getting all users: $e');
      return [];
    }
  }

  /// Get users by role
  Future<List<UserModel>> getUsersByRole(String role) async {
    try {
      final query = await _usersCollection.where('role', isEqualTo: role).get();
      return query.docs.map((doc) => 
        UserModel.fromFirestore(doc.data() as Map<String, dynamic>, doc.id)
      ).toList();
    } catch (e) {
      print('Error getting users by role: $e');
      return [];
    }
  }

  /// Get active users only
  Future<List<UserModel>> getActiveUsers() async {
    try {
      final query = await _usersCollection.where('isActive', isEqualTo: true).get();
      return query.docs.map((doc) => 
        UserModel.fromFirestore(doc.data() as Map<String, dynamic>, doc.id)
      ).toList();
    } catch (e) {
      print('Error getting active users: $e');
      return [];
    }
  }

  /// Check if user document exists
  Future<bool> userExists(String userId) async {
    try {
      final doc = await _usersCollection.doc(userId).get();
      return doc.exists;
    } catch (e) {
      print('Error checking user existence: $e');
      return false;
    }
  }

  /// Create a new user document with specific ID (admin only)
  /// Uses Firebase Auth UID as the document ID
  Future<void> createUserWithId(UserModel user) async {
    try {
      await _usersCollection.doc(user.userId).set(user.toFirestore());
      print('User created with ID: ${user.userId}');
    } catch (e) {
      print('Error creating user with ID: $e');
      rethrow;
    }
  }

  /// Create a new user document (deprecated - use createUserWithId)
  /// Kept for backward compatibility but should not be used
  @Deprecated('Use createUserWithId instead to use Firebase Auth UID')
  Future<String> createUser(UserModel user) async {
    try {
      final docRef = await _usersCollection.add(user.toFirestore());
      print('User created with auto-generated ID: ${docRef.id}');
      return docRef.id;
    } catch (e) {
      print('Error creating user: $e');
      rethrow;
    }
  }

  /// Update user document
  Future<void> updateUser(UserModel user) async {
    try {
      await _usersCollection.doc(user.userId).update(user.toFirestore());
      print('User updated: ${user.userId}');
    } catch (e) {
      print('Error updating user: $e');
      rethrow;
    }
  }

  /// Deactivate user account (admin only)
  Future<void> deactivateUser(String userId) async {
    try {
      await _usersCollection.doc(userId).update({'isActive': false});
      print('User deactivated: $userId');
    } catch (e) {
      print('Error deactivating user: $e');
      rethrow;
    }
  }

  /// Activate user account (admin only)
  Future<void> activateUser(String userId) async {
    try {
      await _usersCollection.doc(userId).update({'isActive': true});
      print('User activated: $userId');
    } catch (e) {
      print('Error activating user: $e');
      rethrow;
    }
  }

  /// Update user's last login timestamp
  Future<void> updateLastLogin(String userId) async {
    try {
      await _usersCollection.doc(userId).update({
        'lastLoginAt': DateTime.now().toIso8601String()
      });
    } catch (e) {
      print('Error updating last login: $e');
    }
  }

  /// Request password reset for user (admin only)
  Future<void> requestPasswordReset(String userId) async {
    try {
      await _usersCollection.doc(userId).update({
        'passwordResetRequired': true
      });
      print('Password reset requested for: $userId');
    } catch (e) {
      print('Error requesting password reset: $e');
      rethrow;
    }
  }

  /// Stream of users for real-time updates
  Stream<List<UserModel>> usersStream() {
    return _usersCollection.snapshots().map((snapshot) => 
      snapshot.docs.map((doc) => 
        UserModel.fromFirestore(doc.data() as Map<String, dynamic>, doc.id)
      ).toList()
    );
  }

  /// Stream of current user for real-time updates
  Stream<UserModel?> currentUserStream() {
    final user = _auth.currentUser;
    if (user == null) return Stream.value(null);
    
    return _usersCollection.doc(user.uid).snapshots().map((doc) {
      if (!doc.exists) return null;
      return UserModel.fromFirestore(doc.data() as Map<String, dynamic>, doc.id);
    });
  }

  // ============================================
  // EXAM OPERATIONS
  // ============================================

  /// Get all exams
  Future<List<ExamModel>> getExams() async {
    try {
      final query = await _examsCollection.get();
      return query.docs.map((doc) => 
        ExamModel.fromFirestore(doc.data() as Map<String, dynamic>, doc.id)
      ).toList();
    } catch (e) {
      print('Error getting all exams: $e');
      return [];
    }
  }

  /// Get exam by ID
  Future<ExamModel?> getExamById(String examId) async {
    try {
      final doc = await _examsCollection.doc(examId).get();
      if (!doc.exists) return null;
      
      return ExamModel.fromFirestore(doc.data() as Map<String, dynamic>, doc.id);
    } catch (e) {
      print('Error getting exam by ID: $e');
      return null;
    }
  }

  /// Get exam by exam code (for uniqueness validation)
  Future<ExamModel?> getExamByCode(String examCode) async {
    try {
      final query = await _examsCollection.where('examCode', isEqualTo: examCode).limit(1).get();
      if (query.docs.isEmpty) return null;
      
      final doc = query.docs.first;
      return ExamModel.fromFirestore(doc.data() as Map<String, dynamic>, doc.id);
    } catch (e) {
      print('Error getting exam by code: $e');
      return null;
    }
  }

  /// Create a new exam
  Future<void> createExam(ExamModel exam) async {
    try {
      final docRef = await _examsCollection.add(exam.toFirestore());
      print('Exam created with ID: ${docRef.id}');
    } catch (e) {
      print('Error creating exam: $e');
      rethrow;
    }
  }

  /// Update an existing exam
  Future<void> updateExam(ExamModel exam) async {
    try {
      await _examsCollection.doc(exam.examId).update(exam.toFirestore());
      print('Exam updated: ${exam.examId}');
    } catch (e) {
      print('Error updating exam: $e');
      rethrow;
    }
  }

  /// Archive an exam (change status to Archived)
  Future<void> archiveExam(String examId) async {
    try {
      await _examsCollection.doc(examId).update({'status': 'Archived'});
      print('Exam archived: $examId');
    } catch (e) {
      print('Error archiving exam: $e');
      rethrow;
    }
  }

  /// Activate an exam (change status to Ready)
  Future<void> activateExam(String examId) async {
    try {
      await _examsCollection.doc(examId).update({'status': 'Ready'});
      print('Exam activated: $examId');
    } catch (e) {
      print('Error activating exam: $e');
      rethrow;
    }
  }

  /// Stream of exams for real-time updates
  Stream<List<ExamModel>> examsStream() {
    return _examsCollection.snapshots().map((snapshot) => 
      snapshot.docs.map((doc) => 
        ExamModel.fromFirestore(doc.data() as Map<String, dynamic>, doc.id)
      ).toList()
    );
  }

  // ============================================
  // ANSWER KEY OPERATIONS
  // ============================================

  /// Get answer key by exam ID
  Future<AnswerKeyModel?> getAnswerKeyByExamId(String examId) async {
    try {
      final query = await _answerKeysCollection.where('examId', isEqualTo: examId).limit(1).get();
      if (query.docs.isEmpty) return null;
      
      final doc = query.docs.first;
      return AnswerKeyModel.fromFirestore(doc.data() as Map<String, dynamic>, doc.id);
    } catch (e) {
      print('Error getting answer key by exam ID: $e');
      return null;
    }
  }

  /// Check if answer key exists for exam
  Future<bool> checkAnswerKeyExists(String examId) async {
    try {
      final query = await _answerKeysCollection.where('examId', isEqualTo: examId).limit(1).get();
      return query.docs.isNotEmpty;
    } catch (e) {
      print('Error checking answer key existence: $e');
      return false;
    }
  }

  /// Create a new answer key
  Future<String> createAnswerKey(AnswerKeyModel answerKey) async {
    try {
      final docRef = await _answerKeysCollection.add(answerKey.toFirestore());
      print('Answer key created with ID: ${docRef.id}');
      return docRef.id;
    } catch (e) {
      print('Error creating answer key: $e');
      rethrow;
    }
  }

  /// Update an existing answer key (preserves audit fields)
  Future<void> updateAnswerKey(AnswerKeyModel answerKey) async {
    try {
      await _answerKeysCollection.doc(answerKey.answerKeyId).update(answerKey.toFirestore());
      print('Answer key updated: ${answerKey.answerKeyId}');
    } catch (e) {
      print('Error updating answer key: $e');
      rethrow;
    }
  }

  /// Get the single current-schema Final answer key for an exam, or null if
  /// none exists. This is the only entry point the official scan/scoring
  /// path should use -- a legacy (pre-section-support) Final document is
  /// still returned (so the caller can build a clear "needs re-entry"
  /// message via answer_key_adapter.dart) but is never treated as usable.
  ///
  /// Throws [MultipleFinalAnswerKeysException] if more than one
  /// current-schema Final key exists for the same exam, rather than
  /// silently picking one -- this should be prevented by the finalize-time
  /// guard in the answer key editor (see [hasOtherFinalAnswerKey]), so
  /// seeing it here means that guard was bypassed (e.g. a race between two
  /// concurrent sessions) and needs Guidance Council attention.
  Future<AnswerKeyModel?> getFinalAnswerKeyByExamId(String examId) async {
    try {
      final query = await _answerKeysCollection
          .where('examId', isEqualTo: examId)
          .where('status', isEqualTo: 'Final')
          .get();
      if (query.docs.isEmpty) return null;

      final keys = query.docs
          .map((doc) => AnswerKeyModel.fromFirestore(doc.data() as Map<String, dynamic>, doc.id))
          .toList();
      final currentSchemaKeys = keys.where((k) => !k.isLegacy).toList();

      if (currentSchemaKeys.length > 1) {
        throw MultipleFinalAnswerKeysException(examId);
      }
      if (currentSchemaKeys.isNotEmpty) return currentSchemaKeys.first;
      // No current-schema Final key, but a legacy Final one exists -- return
      // it so the caller can explain why it can't be used, rather than
      // reporting "no key at all".
      return keys.first;
    } catch (e) {
      if (e is MultipleFinalAnswerKeysException) rethrow;
      print('Error getting Final answer key by exam ID: $e');
      return null;
    }
  }

  /// True if a Final answer key other than [excludingAnswerKeyId] already
  /// exists for [examId]. Used by the answer key editor immediately before
  /// finalizing, so two concurrent Guidance Council sessions can't both end
  /// up with a Final key active for the same exam.
  Future<bool> hasOtherFinalAnswerKey(String examId, String excludingAnswerKeyId) async {
    try {
      final query = await _answerKeysCollection
          .where('examId', isEqualTo: examId)
          .where('status', isEqualTo: 'Final')
          .get();
      return query.docs.any((doc) => doc.id != excludingAnswerKeyId);
    } catch (e) {
      print('Error checking for other Final answer keys: $e');
      // Fail closed: if this check can't be performed, don't let
      // finalization proceed as if it were safe.
      return true;
    }
  }

  // ============================================
  // BATCH OPERATIONS
  // ============================================

  /// Get all batches
  Future<List<BatchModel>> getBatches() async {
    try {
      final query = await _batchesCollection.get();
      return query.docs.map((doc) => 
        BatchModel.fromFirestore(doc.data() as Map<String, dynamic>, doc.id)
      ).toList();
    } catch (e) {
      print('Error getting all batches: $e');
      return [];
    }
  }

  /// Get batch by ID
  Future<BatchModel?> getBatchById(String batchId) async {
    try {
      final doc = await _batchesCollection.doc(batchId).get();
      if (!doc.exists) return null;
      
      return BatchModel.fromFirestore(doc.data() as Map<String, dynamic>, doc.id);
    } catch (e) {
      print('Error getting batch by ID: $e');
      return null;
    }
  }

  /// Get batch by batch code (for uniqueness validation)
  Future<BatchModel?> getBatchByCode(String batchCode) async {
    try {
      final query = await _batchesCollection.where('batchCode', isEqualTo: batchCode).limit(1).get();
      if (query.docs.isEmpty) return null;
      
      final doc = query.docs.first;
      return BatchModel.fromFirestore(doc.data() as Map<String, dynamic>, doc.id);
    } catch (e) {
      print('Error getting batch by code: $e');
      return null;
    }
  }

  /// Get batches by exam ID
  Future<List<BatchModel>> getBatchesByExamId(String examId) async {
    try {
      final query = await _batchesCollection.where('examId', isEqualTo: examId).get();
      return query.docs.map((doc) => 
        BatchModel.fromFirestore(doc.data() as Map<String, dynamic>, doc.id)
      ).toList();
    } catch (e) {
      print('Error getting batches by exam ID: $e');
      return [];
    }
  }

  /// Create a new batch
  Future<String> createBatch(BatchModel batch) async {
    try {
      final docRef = await _batchesCollection.add(batch.toFirestore());
      print('Batch created with ID: ${docRef.id}');
      return docRef.id;
    } catch (e) {
      print('Error creating batch: $e');
      rethrow;
    }
  }

  /// Update an existing batch (preserves audit fields)
  Future<void> updateBatch(BatchModel batch) async {
    try {
      await _batchesCollection.doc(batch.batchId).update(batch.toFirestore());
      print('Batch updated: ${batch.batchId}');
    } catch (e) {
      print('Error updating batch: $e');
      rethrow;
    }
  }

  /// Archive a batch (change status to Archived)
  Future<void> archiveBatch(String batchId) async {
    try {
      await _batchesCollection.doc(batchId).update({'status': 'Archived'});
      print('Batch archived: $batchId');
    } catch (e) {
      print('Error archiving batch: $e');
      rethrow;
    }
  }

  /// Activate a batch (change status to Active)
  Future<void> activateBatch(String batchId) async {
    try {
      await _batchesCollection.doc(batchId).update({'status': 'Active'});
      print('Batch activated: $batchId');
    } catch (e) {
      print('Error activating batch: $e');
      rethrow;
    }
  }

  /// Complete a batch (change status to Completed)
  Future<void> completeBatch(String batchId) async {
    try {
      await _batchesCollection.doc(batchId).update({'status': 'Completed'});
      print('Batch completed: $batchId');
    } catch (e) {
      print('Error completing batch: $e');
      rethrow;
    }
  }

  /// Stream of batches for real-time updates
  Stream<List<BatchModel>> batchesStream() {
    return _batchesCollection.snapshots().map((snapshot) => 
      snapshot.docs.map((doc) => 
        BatchModel.fromFirestore(doc.data() as Map<String, dynamic>, doc.id)
      ).toList()
    );
  }

  // ============================================
  // EXAMINEE OPERATIONS
  // ============================================

  /// Get all examinees
  Future<List<ExamineeModel>> getExaminees() async {
    try {
      final query = await _examineesCollection.get();
      return query.docs.map((doc) => 
        ExamineeModel.fromFirestore(doc.data() as Map<String, dynamic>, doc.id)
      ).toList();
    } catch (e) {
      print('Error getting all examinees: $e');
      return [];
    }
  }

  /// Get examinee by ID
  Future<ExamineeModel?> getExamineeById(String examineeId) async {
    try {
      final doc = await _examineesCollection.doc(examineeId).get();
      if (!doc.exists) return null;
      
      return ExamineeModel.fromFirestore(doc.data() as Map<String, dynamic>, doc.id);
    } catch (e) {
      print('Error getting examinee by ID: $e');
      return null;
    }
  }

  /// Get examinees by batch ID
  Future<List<ExamineeModel>> getExamineesByBatchId(String batchId) async {
    try {
      final query = await _examineesCollection.where('batchId', isEqualTo: batchId).get();
      return query.docs.map((doc) => 
        ExamineeModel.fromFirestore(doc.data() as Map<String, dynamic>, doc.id)
      ).toList();
    } catch (e) {
      print('Error getting examinees by batch ID: $e');
      return [];
    }
  }

  /// Get examinee by student number
  Future<ExamineeModel?> getExamineeByStudentNumber(String studentNumber) async {
    try {
      final query = await _examineesCollection.where('studentNumber', isEqualTo: studentNumber).limit(1).get();
      if (query.docs.isEmpty) return null;
      
      final doc = query.docs.first;
      return ExamineeModel.fromFirestore(doc.data() as Map<String, dynamic>, doc.id);
    } catch (e) {
      print('Error getting examinee by student number: $e');
      return null;
    }
  }

  /// Create a new examinee
  Future<String> createExaminee(ExamineeModel examinee) async {
    try {
      final docRef = await _examineesCollection.add(examinee.toFirestore());
      print('Examinee created with ID: ${docRef.id}');
      return docRef.id;
    } catch (e) {
      print('Error creating examinee: $e');
      rethrow;
    }
  }

  /// Update an existing examinee (preserves audit fields)
  Future<void> updateExaminee(ExamineeModel examinee) async {
    try {
      await _examineesCollection.doc(examinee.examineeId).update(examinee.toFirestore());
      print('Examinee updated: ${examinee.examineeId}');
    } catch (e) {
      print('Error updating examinee: $e');
      rethrow;
    }
  }

  /// Delete an examinee
  Future<void> deleteExaminee(String examineeId) async {
    try {
      await _examineesCollection.doc(examineeId).delete();
      print('Examinee deleted: $examineeId');
    } catch (e) {
      print('Error deleting examinee: $e');
      rethrow;
    }
  }

  /// Stream of examinees for real-time updates
  Stream<List<ExamineeModel>> examineesStream() {
    return _examineesCollection.snapshots().map((snapshot) => 
      snapshot.docs.map((doc) => 
        ExamineeModel.fromFirestore(doc.data() as Map<String, dynamic>, doc.id)
      ).toList()
    );
  }

  /// Stream of examinees by batch ID for real-time updates
  Stream<List<ExamineeModel>> examineesByBatchStream(String batchId) {
    return _examineesCollection.where('batchId', isEqualTo: batchId).snapshots().map((snapshot) =>
      snapshot.docs.map((doc) =>
        ExamineeModel.fromFirestore(doc.data() as Map<String, dynamic>, doc.id)
      ).toList()
    );
  }

  // ============================================
  // RESULT OPERATIONS
  // ============================================

  /// Get a result by its (deterministic) ID.
  Future<ResultModel?> getResultById(String resultId) async {
    try {
      final doc = await _resultsCollection.doc(resultId).get();
      if (!doc.exists) return null;
      return ResultModel.fromFirestore(doc.data() as Map<String, dynamic>, doc.id);
    } catch (e) {
      print('Error getting result by ID: $e');
      return null;
    }
  }

  /// Get all results for a batch.
  Future<List<ResultModel>> getResultsByBatchId(String batchId) async {
    try {
      final query = await _resultsCollection.where('batchId', isEqualTo: batchId).get();
      return query.docs.map((doc) =>
        ResultModel.fromFirestore(doc.data() as Map<String, dynamic>, doc.id)
      ).toList();
    } catch (e) {
      print('Error getting results by batch ID: $e');
      return [];
    }
  }

  /// Creates or updates [result] at its deterministic ID
  /// (ResultModel.buildId), and increments the owning batch's actualCount
  /// exactly once -- only the first time a result is created for a given
  /// exam+batch+examinee, never on a correction/re-scan of an existing one.
  ///
  /// Both the result write and the count increment happen inside one
  /// Firestore transaction: either both land or neither does, so
  /// actualCount can never drift out of sync with the number of result
  /// documents that actually exist. Throws (without writing anything) if
  /// the batch referenced by [result.batchId] doesn't exist.
  Future<ResultPersistOutcome> persistResult(ResultModel result) async {
    final docRef = _resultsCollection.doc(result.resultId);
    final batchRef = _batchesCollection.doc(result.batchId);

    return _firestore.runTransaction<ResultPersistOutcome>((transaction) async {
      // All reads must happen before any writes in a Firestore transaction.
      final existingSnap = await transaction.get(docRef);
      final batchSnap = await transaction.get(batchRef);

      if (!batchSnap.exists) {
        throw StateError('Batch ${result.batchId} does not exist.');
      }

      final isNew = !existingSnap.exists;
      transaction.set(docRef, result.toFirestore());

      if (isNew) {
        final batchData = batchSnap.data() as Map<String, dynamic>;
        final currentCount = batchData['actualCount'] as int? ?? 0;
        transaction.update(batchRef, {
          'actualCount': currentCount + 1,
          'updatedAt': DateTime.now().toIso8601String(),
        });
      }

      return isNew ? ResultPersistOutcome.created : ResultPersistOutcome.updated;
    });
  }

  /// Stream of results for a batch, for real-time updates.
  Stream<List<ResultModel>> resultsByBatchStream(String batchId) {
    return _resultsCollection.where('batchId', isEqualTo: batchId).snapshots().map((snapshot) =>
      snapshot.docs.map((doc) =>
        ResultModel.fromFirestore(doc.data() as Map<String, dynamic>, doc.id)
      ).toList()
    );
  }
}
