import 'dart:convert';
import 'package:http/http.dart' as http;

class MistralService {
  static const String _baseUrl = 'https://api.mistral.ai/v1';

  /// Appelle l'API Mistral TTS (voxtral-mini-tts-2603).
  /// Retourne les bytes audio MP3 décodés depuis la réponse base64.
  Future<List<int>> getTtsAudio(
    String text, {
    required String voiceId,
    String? apiKey,
    String responseFormat = 'mp3',
  }) async {
    if (apiKey == null || apiKey.trim().isEmpty) {
      throw Exception('Clé API Mistral manquante. Configurez-la dans les Paramètres.');
    }

    if (voiceId.trim().isEmpty) {
      voiceId = 'fr_marie_neutral';
    }

    final response = await http.post(
      Uri.parse('$_baseUrl/audio/speech'),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $apiKey',
      },
      body: jsonEncode({
        'model': 'voxtral-mini-tts-2603',
        'input': text,
        'voice_id': voiceId,
        'response_format': responseFormat,
      }),
    );

    if (response.statusCode == 200) {
      final jsonResponse = jsonDecode(response.body);
      final audioBase64 = jsonResponse['audio_data'] as String?;
      if (audioBase64 == null || audioBase64.isEmpty) {
        throw Exception('Réponse Mistral vide — pas de données audio.');
      }
      return base64Decode(audioBase64);
    } else {
      throw Exception(
        'Erreur Mistral TTS: ${response.statusCode} — ${response.body}',
      );
    }
  }
}
