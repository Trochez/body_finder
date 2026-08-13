import '../orchestration/portability_policy.dart';
import '../../domain/capability/sensor_capability.dart';

class ParticipantProfile {
  const ParticipantProfile({
    required this.id,
    required this.platform,
    required this.platformVersion,
    required this.operatingProfile,
    required this.lastSeenMicros,
  });

  final String id;
  final String platform;
  final String platformVersion;
  final OperatingProfile operatingProfile;
  final int lastSeenMicros;
}

class ParticipantProfileRegistry {
  final Map<String, ParticipantProfile> _participants = {};

  List<ParticipantProfile> get participants =>
      _participants.values.toList(growable: false);

  int get count => _participants.length;

  void register({
    required String id,
    required NodeCapabilities capabilities,
    required int nowMicros,
  }) {
    _participants[id] = ParticipantProfile(
      id: id,
      platform: capabilities.platform,
      platformVersion: capabilities.platformVersion,
      operatingProfile: selectOperatingProfile(capabilities),
      lastSeenMicros: nowMicros,
    );
  }

  void remove(String id) => _participants.remove(id);
}
