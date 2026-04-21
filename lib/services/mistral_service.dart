import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:flutter_dotenv/flutter_dotenv.dart';

class MistralService {
  static const String _baseUrl = 'https://api.mistral.ai/v1';

  /// Crée une voix sauvegardée sur Mistral à partir d'un clip audio base64.
  /// Retourne le voice_id créé.
  Future<String> createVoice({
    required String name,
    required String audioBase64,
    String audioMimeType = 'audio/mp3',
  }) async {
    final apiKey = dotenv.env['MISTRAL_API_KEY'];
    if (apiKey == null || apiKey.trim().isEmpty) {
      throw Exception('MISTRAL_API_KEY est manquante dans le fichier .env');
    }

    final response = await http.post(
      Uri.parse('$_baseUrl/audio/voices'),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $apiKey',
      },
      body: jsonEncode({
        'name': name,
        'audio': audioBase64,
        'audio_mime_type': audioMimeType,
      }),
    );

    if (response.statusCode == 200 || response.statusCode == 201) {
      final json = jsonDecode(response.body);
      return json['id'] as String;
    } else {
      throw Exception(
          'Erreur création de voix: ${response.statusCode} — ${response.body}');
    }
  }

  /// Appelle l'API Mistral TTS (voxtral-mini-tts-2603).
  /// [voiceId] doit être un ID de voix créé via l'API ou via Mistral Studio.
  /// Retourne les bytes audio MP3 décodés depuis la réponse base64.
  Future<List<int>> getTtsAudio(
    String text, {
    required String voiceId,
    String responseFormat = 'mp3',
  }) async {
    final apiKey = dotenv.env['MISTRAL_API_KEY'];
    if (apiKey == null || apiKey.trim().isEmpty) {
      throw Exception('MISTRAL_API_KEY est manquante dans le fichier .env');
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
