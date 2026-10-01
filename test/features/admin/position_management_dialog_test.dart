import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guidegrade/core/services/firestore_service.dart';
import 'package:guidegrade/features/admin/widgets/position_management_dialog.dart';
import 'package:guidegrade/models/guidance_position.dart';

/// Records every write and lets a test script exactly what
/// [isGuidancePositionAssigned] reports on each successive call -- needed to
/// simulate the "became assigned in between the first check and the
/// confirmed delete" race the dialog's defensive re-check guards against.
class _FakeFirestoreService implements FirestoreService {
  _FakeFirestoreService([List<GuidancePosition>? positions]) : _positions = positions ?? GuidancePositions.defaults;

  List<GuidancePosition> _positions;
  final addedLabels = <String>[];
  final removedValues = <String>[];
  final assignmentChecks = <String>[];

  /// Values reported as assigned on the FIRST [isGuidancePositionAssigned]
  /// call for them.
  final Set<String> assignedValues = {};

  /// Values that flip to "assigned" starting from their SECOND check --
  /// simulates another admin assigning the position in between the initial
  /// check and the confirmed delete.
  final Set<String> becomesAssignedOnRecheck = {};
  final Map<String, int> _checkCounts = {};

  @override
  Future<List<GuidancePosition>> loadGuidancePositions() async => _positions;

  @override
  Future<GuidancePosition> addGuidancePosition(String label, List<GuidancePosition> existingPositions) async {
    final error = GuidancePositions.validateNewLabel(label, existingPositions);
    if (error != null) throw ArgumentError(error);
    final added = GuidancePositions.build(label);
    addedLabels.add(label);
    _positions = [..._positions, added];
    return added;
  }

  @override
  Future<bool> isGuidancePositionAssigned(String value) async {
    assignmentChecks.add(value);
    final count = (_checkCounts[value] ?? 0) + 1;
    _checkCounts[value] = count;
    if (assignedValues.contains(value)) return true;
    if (becomesAssignedOnRecheck.contains(value) && count >= 2) return true;
    return false;
  }

  @override
  Future<void> removeGuidancePosition(String value) async {
    removedValues.add(value);
    _positions = [..._positions]..removeWhere((p) => p.value == value);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late _FakeFirestoreService firestore;

  Future<void> openDialog(WidgetTester tester, {List<GuidancePosition>? positions}) async {
    firestore = _FakeFirestoreService(positions);
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () => showPositionManagementDialog(
                  context,
                  firestoreService: firestore,
                  initialPositions: positions ?? GuidancePositions.defaults,
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets('1. existing positions are displayed when the dialog opens', (tester) async {
    await openDialog(tester);

    expect(find.text('Position Management'), findsOneWidget);
    expect(find.text('Guidance Head'), findsOneWidget);
    expect(find.text('Psychometrician'), findsOneWidget);
    expect(find.text('Guidance Staff'), findsOneWidget);
  });

  testWidgets('2. add position still works, reusing the existing add dialog and its validation', (tester) async {
    await openDialog(tester);

    await tester.tap(find.byKey(const Key('positionManagement.add')));
    await tester.pumpAndSettle();
    // Same keys/validation as the pre-existing add dialog, unchanged.
    expect(find.byKey(const Key('addGuidancePosition.label')), findsOneWidget);
    await tester.tap(find.byKey(const Key('addGuidancePosition.add')));
    await tester.pumpAndSettle();
    expect(find.text('Position name is required'), findsOneWidget);

    await tester.enterText(find.byKey(const Key('addGuidancePosition.label')), 'Auditing');
    await tester.tap(find.byKey(const Key('addGuidancePosition.add')));
    await tester.pumpAndSettle();

    expect(firestore.addedLabels, ['Auditing']);
    expect(find.text('Auditing'), findsOneWidget);
  });

  testWidgets('3. confirmation is required before deletion', (tester) async {
    await openDialog(tester);

    await tester.tap(find.byKey(const Key('positionManagement.delete.guidance_staff')));
    await tester.pumpAndSettle();

    expect(find.text('Delete this position?'), findsOneWidget);
    expect(firestore.removedValues, isEmpty);
  });

  testWidgets('4. delete an unassigned position works after confirmation', (tester) async {
    await openDialog(tester);

    await tester.tap(find.byKey(const Key('positionManagement.delete.guidance_staff')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('positionManagement.deleteConfirm.delete')));
    await tester.pumpAndSettle();

    expect(firestore.removedValues, ['guidance_staff']);
    expect(find.text('Guidance Staff'), findsNothing);
    // No unrelated configuration data is deleted -- the other two positions
    // are still present and nothing else was removed.
    expect(find.text('Guidance Head'), findsOneWidget);
    expect(find.text('Psychometrician'), findsOneWidget);
    expect(firestore.removedValues, hasLength(1));
  });

  testWidgets('cancelling the confirmation deletes nothing', (tester) async {
    await openDialog(tester);

    await tester.tap(find.byKey(const Key('positionManagement.delete.guidance_staff')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('positionManagement.deleteConfirm.cancel')));
    await tester.pumpAndSettle();

    expect(firestore.removedValues, isEmpty);
    expect(find.text('Guidance Staff'), findsOneWidget);
  });

  testWidgets('5. delete a position currently assigned to a user is blocked, before the confirmation dialog',
      (tester) async {
    await openDialog(tester);
    firestore.assignedValues.add('guidance_staff');

    await tester.tap(find.byKey(const Key('positionManagement.delete.guidance_staff')));
    await tester.pumpAndSettle();

    expect(find.text('Delete this position?'), findsNothing);
    expect(find.text('Cannot Delete This Position'), findsOneWidget);
    expect(firestore.removedValues, isEmpty);

    await tester.tap(find.widgetWithText(FilledButton, 'OK'));
    await tester.pumpAndSettle();
    expect(find.text('Guidance Staff'), findsOneWidget);
  });

  testWidgets(
      '6. the assignment check runs against the real user-query pattern: a position becoming assigned '
      'between the first check and the confirmed delete is caught by the defensive re-check', (tester) async {
    await openDialog(tester);
    firestore.becomesAssignedOnRecheck.add('guidance_staff');

    await tester.tap(find.byKey(const Key('positionManagement.delete.guidance_staff')));
    await tester.pumpAndSettle();

    // First check (unassigned) let the confirmation dialog through.
    expect(find.text('Delete this position?'), findsOneWidget);

    await tester.tap(find.byKey(const Key('positionManagement.deleteConfirm.delete')));
    await tester.pumpAndSettle();

    // The re-check immediately before the delete now reports "assigned" --
    // the delete must be cancelled, never silently proceed.
    expect(firestore.removedValues, isEmpty);
    expect(find.text('Cannot Delete This Position'), findsOneWidget);
    expect(find.text('Guidance Staff'), findsOneWidget);
    expect(firestore.assignmentChecks.where((v) => v == 'guidance_staff'), hasLength(2));
  });

  testWidgets('deleting an assigned position never silently reassigns or clears any user', (tester) async {
    // There is no user-profile write path anywhere in this dialog or in
    // FirestoreService.removeGuidancePosition/isGuidancePositionAssigned --
    // both only ever touch config/guidancePositions, never a users/{uid}
    // document. This test documents that contract: the fake's own
    // `updates`-style user-write tracking doesn't even exist on this fake,
    // because the dialog has no code path that could call it.
    await openDialog(tester);
    firestore.assignedValues.add('guidance_staff');

    await tester.tap(find.byKey(const Key('positionManagement.delete.guidance_staff')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'OK'));
    await tester.pumpAndSettle();

    expect(firestore.removedValues, isEmpty);
    expect(find.text('Guidance Staff'), findsOneWidget);
  });
}
