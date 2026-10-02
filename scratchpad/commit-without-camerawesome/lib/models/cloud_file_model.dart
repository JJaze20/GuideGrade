/// Represents a synced record inside the Cloud Storage Archive screen.
class CloudFileModel {
  final String name;
  final String code;
  final int total;
  final String timestamp;

  const CloudFileModel({
    required this.name,
    required this.code,
    required this.total,
    required this.timestamp,
  });
}
