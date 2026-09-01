import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';

/// Plays a short MP3 cue tied to a driver-initiated action.
///
/// Currently only used for the **Start Trip** and **Finish Trip** buttons.
/// No automatic announcements are produced for any other trip status change.
class TripStatusVoice {
  TripStatusVoice._();

  static final AudioPlayer _player = AudioPlayer();

  static Future<void> playNewOrderSound() =>
      _playAsset('audios/yettiqanot_ringtone.mp3', label: 'New order');

  static Future<void> playStartTripSound() =>
      _playAsset('audios/download (5).mp3', label: 'Start trip');

  static Future<void> playFinishTripSound() =>
      _playAsset('audios/download (6).mp3', label: 'Finish trip');

  static Future<void> _playAsset(String path, {required String label}) async {
    try {
      // Avoid waiting on an explicit stop before every cue; it adds audible tap lag.
      await _player.play(AssetSource(path));
    } catch (e, st) {
      if (kDebugMode) {
        debugPrint('[yetti_driver] $label audio failed: $e\n$st');
      }
    }
  }
}
