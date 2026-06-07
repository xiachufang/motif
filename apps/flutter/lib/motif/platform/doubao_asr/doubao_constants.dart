class DoubaoConstants {
  static const registerUrl =
      'https://log.snssdk.com/service/2/device_register/';
  static const settingsUrl = 'https://is.snssdk.com/service/settings/v3/';
  static const websocketUrl =
      'wss://frontier-audio-ime-ws.doubao.com/ocean/api/v1/ws';
  static const aid = 401734;

  static const userAgent =
      'com.bytedance.android.doubaoime/100102018 (Linux; U; Android 16; en_US; Pixel 7 Pro; Build/BP2A.250605.031.A2; Cronet/TTNetVersion:94cf429a 2025-11-17 QuicVersion:1f89f732 2025-05-08)';

  static const appConfig = <String, Object>{
    'aid': aid,
    'app_name': 'oime',
    'version_code': 100102018,
    'version_name': '1.1.2',
    'manifest_version_code': 100102018,
    'update_version_code': 100102018,
    'channel': 'official',
    'package': 'com.bytedance.android.doubaoime',
  };

  static const deviceConfig = <String, Object>{
    'device_platform': 'android',
    'os': 'android',
    'os_api': '34',
    'os_version': '16',
    'device_type': 'Pixel 7 Pro',
    'device_brand': 'google',
    'device_model': 'Pixel 7 Pro',
    'resolution': '1080*2400',
    'dpi': '420',
    'language': 'zh',
    'timezone': 8,
    'access': 'wifi',
    'rom': 'UP1A.231005.007',
    'rom_version': 'UP1A.231005.007',
  };

  static const sampleRate = 16000;
  static const channels = 1;
  static const frameDurationMs = 20;
  static const samplesPerFrame = sampleRate * frameDurationMs ~/ 1000;
  static const bytesPerFrame = samplesPerFrame * 2;
}
