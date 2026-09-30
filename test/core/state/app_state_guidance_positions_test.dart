import 'package:flutter_test/flutter_test.dart';
import 'package:guidegrade/core/services/batch_repository.dart';
import 'package:guidegrade/core/services/firestore_service.dart';
import 'package:guidegrade/core/state/app_state.dart';
import 'package:guidegrade/models/guidance_position.dart';
import 'package:guidegrade/models/local_batch.dart';

class _FakeBatchRepository implements BatchRepository {
  @override
  Future<List<LocalBatch>> getBatches() async => const [];
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeFirestoreService implements FirestoreService {
  _FakeFirestoreService(this._positions);
  final List<GuidancePosition> _positions;

  @override
  Future<List<GuidancePosition>> loadGuidancePositions() async => _positions;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late AppState appState;

  setUp(() {
    appState = AppState(batchRepository: _FakeBatchRepository());
  });

  tearDown(() {
    try {
      appState.dispose();
    } catch (_) {/* AppState.dispose may touch unused camera handles */}
  });

  test('guidancePositions starts as the safe fallback before any load', () {
    expect(appState.guidancePositions, GuidancePositions.defaults);
  });

  test('loadGuidancePositions replaces guidancePositions with what the service returns', () async {
    final custom = [
      ...GuidancePositions.defaults,
      const GuidancePosition(value: 'auditing', label: 'Auditing'),
    ];
    await appState.loadGuidancePositions(_FakeFirestoreService(custom));
    expect(appState.guidancePositions, custom);
  });

  test('loadGuidancePositions notifies listeners', () async {
    var notified = false;
    appState.addListener(() => notified = true);
    await appState.loadGuidancePositions(_FakeFirestoreService(GuidancePositions.defaults));
    expect(notified, isTrue);
  });
}
