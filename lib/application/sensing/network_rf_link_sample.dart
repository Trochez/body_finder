class NetworkRfLinkSample {
  const NetworkRfLinkSample({
    required this.fromNodeId,
    required this.toNodeId,
    required this.rssiDbm,
    required this.observedAt,
  });

  final String fromNodeId;
  final String toNodeId;
  final double rssiDbm;
  final DateTime observedAt;

  String get linkId => '$fromNodeId->$toNodeId';

  String get undirectedLinkId {
    final ends = [fromNodeId, toNodeId]..sort();
    return '${ends[0]}<->${ends[1]}';
  }

  bool get isValid =>
      _nodeIdPattern.hasMatch(fromNodeId) &&
      _nodeIdPattern.hasMatch(toNodeId) &&
      fromNodeId != toNodeId &&
      rssiDbm.isFinite &&
      rssiDbm >= -127 &&
      rssiDbm <= 20;

  static final RegExp _nodeIdPattern = RegExp(r'^[0-9a-fA-F]{16}$');
}
