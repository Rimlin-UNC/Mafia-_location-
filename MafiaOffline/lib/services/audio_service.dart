import 'package:audioplayers/audioplayers.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Звук в игре.
///
/// Два независимых канала:
///  * [_sfx] — короткие события (убийство, лечение, смена фазы);
///  * [_ambient] — зацикленный фон текущей фазы.
///
/// Синхронность между устройствами обеспечивает не этот класс, а протокол:
/// ведущий рассылает команду `sound` с меткой времени, и все клиенты
/// проигрывают её одновременно (см. SyncedAudio в player_controller).
class AudioService {
  static final AudioService instance = AudioService._();
  AudioService._();

  final AudioPlayer _sfx = AudioPlayer(playerId: 'mafia_sfx');
  final AudioPlayer _ambient = AudioPlayer(playerId: 'mafia_ambient');

  bool soundEnabled = true;
  bool musicEnabled = true;
  String? _currentAmbient;
  bool _ready = false;

  Future<void> init() async {
    if (_ready) return;
    _ready = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      soundEnabled = prefs.getBool('sound_enabled') ?? true;
      musicEnabled = prefs.getBool('music_enabled') ?? true;
      // Фон звучит тише событий и не должен глушить голоса за столом.
      await _ambient.setVolume(0.34);
      await _ambient.setReleaseMode(ReleaseMode.loop);
      await _sfx.setVolume(0.9);
      // Игра идёт вживую — звук не должен ставить на паузу чужую музыку
      // насовсем и обязан звучать даже в беззвучном режиме iOS.
      await _sfx.setAudioContext(_context());
      await _ambient.setAudioContext(_context());
    } catch (_) {
      // Аудио не критично для хода партии: молча продолжаем без него.
    }
  }

  AudioContext _context() => AudioContext(
        iOS: AudioContextIOS(
          category: AVAudioSessionCategory.playback,
          options: const {AVAudioSessionOptions.mixWithOthers},
        ),
        android: const AudioContextAndroid(
          isSpeakerphoneOn: false,
          stayAwake: false,
          contentType: AndroidContentType.music,
          usageType: AndroidUsageType.game,
          audioFocus: AndroidAudioFocus.none,
        ),
      );

  Future<void> setSound(bool value) async {
    soundEnabled = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('sound_enabled', value);
  }

  Future<void> setMusic(bool value) async {
    musicEnabled = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('music_enabled', value);
    if (!value) {
      await stopAmbient();
    } else if (_currentAmbient != null) {
      final asset = _currentAmbient!;
      _currentAmbient = null;
      await playAmbient(asset);
    }
  }

  /// Короткий звук события.
  Future<void> play(String asset, {double volume = 1.0}) async {
    if (!soundEnabled) return;
    try {
      await _sfx.stop();
      await _sfx.setVolume(volume.clamp(0.0, 1.0));
      await _sfx.play(AssetSource(asset));
    } catch (_) {}
  }

  /// Зацикленный фон фазы. Повторный вызов с тем же файлом ничего не делает,
  /// поэтому при каждом тике таймера луп не начинается заново.
  Future<void> playAmbient(String asset) async {
    if (!musicEnabled) {
      _currentAmbient = asset;
      return;
    }
    if (_currentAmbient == asset) return;
    _currentAmbient = asset;
    try {
      await _ambient.stop();
      await _ambient.setReleaseMode(ReleaseMode.loop);
      await _ambient.play(AssetSource(asset));
    } catch (_) {}
  }

  Future<void> stopAmbient() async {
    _currentAmbient = null;
    try {
      await _ambient.stop();
    } catch (_) {}
  }

  Future<void> dispose() async {
    try {
      await _sfx.dispose();
      await _ambient.dispose();
    } catch (_) {}
  }
}
