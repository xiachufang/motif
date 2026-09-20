// Based on rhinoc/douvo at d68cf190 (MIT); see DOUVO_LICENSE.txt.
import 'doubao_constants.dart';

Map<String, Object> doubaoSessionConfig(String deviceId) => {
  'audio_info': {
    'channel': DoubaoConstants.channels,
    'format': 'speech_opus',
    'sample_rate': DoubaoConstants.sampleRate,
  },
  'enable_punctuation': true,
  'enable_speech_rejection': false,
  'extra': {
    'app_name': 'com.android.chrome',
    'app_version': DoubaoConstants.appConfig['version_name']!,
    'aid': DoubaoConstants.aid.toString(),
    'cell_compress_rate': 8,
    'did': deviceId,
    'enable_asr_threepass': true,
    'enable_asr_twopass': true,
    'enable_print_chinese': false,
    'disable_user_words': true,
    'enable_text_post_process': true,
    'asr_text_post_process_type': 'last_post_process',
    'input_mode': 'tool',
    'strong_ddc': true,
    'use_twopass_retry': true,
    'update_version_code':
        '${DoubaoConstants.appConfig['update_version_code']}',
    'version_code': '${DoubaoConstants.appConfig['version_code']}',
    'version_name': DoubaoConstants.appConfig['version_name']!,
  },
};
