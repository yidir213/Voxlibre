import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';

/// Écran de paramètres pour saisir le Voice ID Mistral.
/// Le voice_id est stocké dans le .env en mémoire (à persister si besoin).
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late TextEditingController _apiKeyController;

  String _selectedLanguage = 'fr';
  String _selectedVoice = 'marie';
  String _selectedEmotion = 'neutral';

  final Map<String, List<String>> _voiceToEmotions = {
    'marie': ['neutral', 'happy', 'sad', 'excited', 'curious', 'angry'],
    'jane': ['neutral', 'sarcasm', 'confused', 'shameful', 'sad', 'jealousy', 'frustrated', 'curious', 'confident'],
    'paul': ['neutral', 'sad', 'happy', 'frustrated', 'excited', 'confident', 'cheerful', 'angry'],
    'oliver': ['neutral', 'sad', 'excited', 'curious', 'confident', 'cheerful', 'angry'],
  };

  final Map<String, String> _voiceToLang = {
    'marie': 'fr',
    'jane': 'gb',
    'oliver': 'gb',
    'paul': 'en',
  };

  List<String> _getVoicesForLang(String lang) {
    return _voiceToLang.entries.where((e) => e.value == lang).map((e) => e.key).toList();
  }

  @override
  void initState() {
    super.initState();
    _apiKeyController = TextEditingController(text: dotenv.env['MISTRAL_API_KEY'] ?? '');
    
    String currentVoiceId = dotenv.env['MISTRAL_VOICE_ID'] ?? '';
    if (currentVoiceId.isEmpty) currentVoiceId = 'fr_marie_neutral';
    
    var parts = currentVoiceId.split('_');
    if (parts.length == 3) {
      if (['fr', 'gb', 'en'].contains(parts[0])) _selectedLanguage = parts[0];
      if (_voiceToLang.containsKey(parts[1])) _selectedVoice = parts[1];
      
      // Valider l'émotion par rapport à la voix
      if (_voiceToEmotions[_selectedVoice]?.contains(parts[2]) == true) {
        _selectedEmotion = parts[2];
      }

      // Auto-corriger si la voix ne correspond pas à la langue
      if (_voiceToLang[_selectedVoice] != _selectedLanguage) {
        _selectedLanguage = _voiceToLang[_selectedVoice]!;
      }
    }
  }

  @override
  void dispose() {
    _apiKeyController.dispose();
    super.dispose();
  }

  String get _finalVoiceId => '${_selectedLanguage}_${_selectedVoice}_${_selectedEmotion}';

  void _save() {
    dotenv.env['MISTRAL_API_KEY'] = _apiKeyController.text.trim();
    dotenv.env['MISTRAL_VOICE_ID'] = _finalVoiceId;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Paramètres sauvegardés (session en cours)')),
    );
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.grey.shade50,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 1,
        title: const Text('Paramètres', style: TextStyle(color: Colors.black87, fontWeight: FontWeight.bold)),
        iconTheme: const IconThemeData(color: Colors.black87),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Clé API Mistral',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15, color: Colors.deepPurple),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _apiKeyController,
              obscureText: true,
              decoration: InputDecoration(
                filled: true,
                fillColor: Colors.white,
                hintText: 'sk-...',
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              ),
            ),
            const SizedBox(height: 32),
            
            const Text(
              'Configuration de la Voix (TTS)',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18, color: Colors.deepPurple),
            ),
            const SizedBox(height: 16),

            // SÉLECTEUR LANGUE
            _buildDropdown(
              label: 'Langue / Accent',
              value: _selectedLanguage,
              items: ['fr', 'gb', 'en'],
              onChanged: (val) {
                if (val != null) {
                  setState(() {
                    _selectedLanguage = val;
                    // Reset voice to the first available in this language
                    _selectedVoice = _getVoicesForLang(val).first;
                    
                    // Si la nouvelle voix (auto-sélectionnée) ne supporte pas l'émotion actuelle, on remet par défaut
                    if (!(_voiceToEmotions[_selectedVoice]?.contains(_selectedEmotion) ?? false)) {
                      _selectedEmotion = 'neutral';
                    }
                  });
                }
              },
            ),
            
            // SÉLECTEUR VOIX
            _buildDropdown(
              label: 'Interprète (Voix)',
              value: _selectedVoice,
              items: _getVoicesForLang(_selectedLanguage),
              onChanged: (val) {
                if (val != null) {
                  setState(() {
                    _selectedVoice = val;
                    _selectedLanguage = _voiceToLang[val]!;
                    
                    // Si la nouvelle voix ne supporte pas l'émotion actuelle, on remet par défaut
                    if (!(_voiceToEmotions[_selectedVoice]?.contains(_selectedEmotion) ?? false)) {
                      _selectedEmotion = 'neutral';
                    }
                  });
                }
              },
            ),

            // SÉLECTEUR ÉMOTION
            _buildDropdown(
              label: 'Émotion',
              value: _selectedEmotion,
              items: _voiceToEmotions[_selectedVoice] ?? ['neutral'],
              onChanged: (val) {
                if (val != null) setState(() => _selectedEmotion = val);
              },
            ),

            const SizedBox(height: 16),
            // APERÇU ID FINAL
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.deepPurple.shade50,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.deepPurple.shade200),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('ID :', style: TextStyle(fontSize: 12, color: Colors.deepPurple)),
                  const SizedBox(height: 4),
                  Text(
                    _finalVoiceId,
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.deepPurple, letterSpacing: 1),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 40),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.deepPurple,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 16),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
              onPressed: _save,
              child: const Text('Enregistrer les paramètres', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDropdown({
    required String label,
    required String value,
    required List<String> items,
    required ValueChanged<String?> onChanged,
  }) {
    // Rend les labels plus jolis (ex: "fr" -> "FR", "marie" -> "Marie")
    String displayString(String s) {
      if (s == 'fr') return 'Français (FR)';
      if (s == 'gb') return 'Anglais (GB)';
      if (s == 'en') return 'Anglais (US)';
      return s[0].toUpperCase() + s.substring(1);
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14, color: Colors.black87)),
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.grey.shade300),
            ),
            child: DropdownButtonHideUnderline(
              child: DropdownButton<String>(
                value: value,
                isExpanded: true,
                icon: const Icon(Icons.keyboard_arrow_down, color: Colors.deepPurple),
                items: items.map((i) => DropdownMenuItem(value: i, child: Text(displayString(i)))).toList(),
                onChanged: onChanged,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
