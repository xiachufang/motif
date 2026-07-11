import 'services.dart';
import 'secret_store.dart';

/// Web platform services: no Tailscale/push. Voice input is disabled here
/// because Motif's Doubao ASR path needs native mic PCM + custom WebSocket
/// headers; do not fall back to browser/system speech recognition.
PlatformServices makePlatformServices() => PlatformServices(
  tailscale: NoopTailscaleService(),
  speech: NoopSpeechService(),
  push: NoopPushService(),
  secrets: FlutterSecureSecretStore(),
);
