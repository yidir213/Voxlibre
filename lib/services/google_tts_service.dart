import 'dart:convert';
import 'dart:typed_data';
import 'package:http/http.dart' as http;

class GoogleTtsService {
  static const String _baseUrl =
      'https://generativelanguage.googleapis.com/v1beta/models/gemini-3.1-flash-tts-preview:generateContent';

  /// Available Google TTS voices
  static const List<String> availableVoices = [
    'Kore', 'Charon', 'Fenrir', 'Aoede', 'Puck', 'Leda', 'Orus', 'Zephyr',
  ];

  /// Calls Gemini TTS API and returns audio bytes (WAV format).
  /// The API returns raw PCM (s16le, 24kHz, mono) which we wrap in a WAV header.
  Future<List<int>> getTtsAudio(
    String text, {
    required String apiKey,
    String voiceName = 'Kore',
  }) async {
    if (apiKey.trim().isEmpty) {
      throw Exception('Clé API Google manquante. Configurez-la dans les Paramètres.');
    }

    final response = await http.post(
      Uri.parse('$_baseUrl?key=$apiKey'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'contents': [
          {
            'parts': [
              {'text': text}
            ]
          }
        ],
        'generationConfig': {
          'responseModalities': ['AUDIO'],
          'speechConfig': {
            'voiceConfig': {
              'prebuiltVoiceConfig': {
                'voiceName': voiceName,
              }
            }
          }
        },
      }),
    );

    if (response.statusCode == 200) {
      final jsonResponse = jsonDecode(response.body);
      final candidates = jsonResponse['candidates'] as List?;
      if (candidates == null || candidates.isEmpty) {
        throw Exception('Réponse Google TTS vide — pas de candidats.');
      }

      final parts = candidates[0]['content']['parts'] as List?;
      if (parts == null || parts.isEmpty) {
        throw Exception('Réponse Google TTS vide — pas de parties.');
      }

      final inlineData = parts[0]['inlineData'];
      if (inlineData == null) {
        throw Exception('Réponse Google TTS vide — pas de données audio.');
      }

      final audioBase64 = inlineData['data'] as String;
      final pcmBytes = base64Decode(audioBase64);

      // Wrap raw PCM in WAV header for just_audio compatibility
      return _wrapPcmInWav(pcmBytes, sampleRate: 24000, channels: 1, bitsPerSample: 16);
    } else {
      throw Exception(
        'Erreur Google TTS: ${response.statusCode} — ${response.body}',
      );
    }
  }

  /// Creates a WAV file from raw PCM data (s16le).
  List<int> _wrapPcmInWav(
    List<int> pcmData, {
    required int sampleRate,
    required int channels,
    required int bitsPerSample,
  }) {
    final byteRate = sampleRate * channels * (bitsPerSample ~/ 8);
    final blockAlign = channels * (bitsPerSample ~/ 8);
    final dataSize = pcmData.length;
    final fileSize = 36 + dataSize;

    final header = ByteData(44);
    // RIFF header
    header.setUint8(0, 0x52); // R
    header.setUint8(1, 0x49); // I
    header.setUint8(2, 0x46); // F
    header.setUint8(3, 0x46); // F
    header.setUint32(4, fileSize, Endian.little);
    header.setUint8(8, 0x57);  // W
    header.setUint8(9, 0x41);  // A
    header.setUint8(10, 0x56); // V
    header.setUint8(11, 0x45); // E

    // fmt sub-chunk
    header.setUint8(12, 0x66); // f
    header.setUint8(13, 0x6D); // m
    header.setUint8(14, 0x74); // t
    header.setUint8(15, 0x20); // (space)
    header.setUint32(16, 16, Endian.little); // Sub-chunk size
    header.setUint16(20, 1, Endian.little);  // PCM format
    header.setUint16(22, channels, Endian.little);
    header.setUint32(24, sampleRate, Endian.little);
    header.setUint32(28, byteRate, Endian.little);
    header.setUint16(32, blockAlign, Endian.little);
    header.setUint16(34, bitsPerSample, Endian.little);

    // data sub-chunk
    header.setUint8(36, 0x64); // d
    header.setUint8(37, 0x61); // a
    header.setUint8(38, 0x74); // t
    header.setUint8(39, 0x61); // a
    header.setUint32(40, dataSize, Endian.little);

    return [...header.buffer.asUint8List(), ...pcmData];
  }
}
