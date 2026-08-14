class BlePeerIdentityRegistry {
  BlePeerIdentityRegistry();

  static final BlePeerIdentityRegistry instance = BlePeerIdentityRegistry();

  final Map<String, String> _nodeIdBySource = <String, String>{};

  String? nodeIdForSource(String sourceKey) =>
      _nodeIdBySource[_normalizeSourceKey(sourceKey)];

  void bind({required String sourceKey, required String nodeId}) {
    final normalizedNodeId = nodeId.toLowerCase();
    if (!RegExp(r'^[0-9a-f]{16}$').hasMatch(normalizedNodeId)) return;
    final normalizedSource = _normalizeSourceKey(sourceKey);
    if (normalizedSource.isEmpty) return;
    _nodeIdBySource[normalizedSource] = normalizedNodeId;
  }

  void unbindSource(String sourceKey) {
    _nodeIdBySource.remove(_normalizeSourceKey(sourceKey));
  }

  void clear() => _nodeIdBySource.clear();

  static String _normalizeSourceKey(String value) => value.trim().toUpperCase();
}
