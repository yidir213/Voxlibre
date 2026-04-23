import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import '../services/google_tts_service.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late TextEditingController _mistralApiKeyController;
  late TextEditingController _googleApiKeyController;

  String _ttsProvider = 'mistral'; // 'mistral' or 'google'

  // Mistral config
  String _selectedLanguage = 'fr';
  String _selectedVoice = 'marie';
  String _selectedEmotion = 'neutral';

  // Google config
  String _selectedGoogleVoice = 'Kore';

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
    _mistralApiKeyController = TextEditingController();
    _googleApiKeyController = TextEditingController();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _ttsProvider = prefs.getString('tts_provider') ?? 'mistral';
      _mistralApiKeyController.text = prefs.getString('mistral_api_key') ?? dotenv.env['MISTRAL_API_KEY'] ?? '';
      _googleApiKeyController.text = prefs.getString('google_api_key') ?? '';
      _selectedGoogleVoice = prefs.getString('google_voice') ?? 'Kore';

      String voiceId = prefs.getString('mistral_voice_id') ?? dotenv.env['MISTRAL_VOICE_ID'] ?? 'fr_marie_neutral';
      var parts = voiceId.split('_');
      if (parts.length == 3) {
        if (['fr', 'gb', 'en'].contains(parts[0])) _selectedLanguage = parts[0];
        if (_voiceToLang.containsKey(parts[1])) _selectedVoice = parts[1];
        if (_voiceToEmotions[_selectedVoice]?.contains(parts[2]) == true) {
          _selectedEmotion = parts[2];
        }
        if (_voiceToLang[_selectedVoice] != _selectedLanguage) {
          _selectedLanguage = _voiceToLang[_selectedVoice]!;
        }
      }
    });
  }

  @override
  void dispose() {
    _mistralApiKeyController.dispose();
    _googleApiKeyController.dispose();
    super.dispose();
  }

  String get _finalMistralVoiceId => '${_selectedLanguage}_${_selectedVoice}_${_selectedEmotion}';

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('tts_provider', _ttsProvider);
    await prefs.setString('mistral_api_key', _mistralApiKeyController.text.trim());
    await prefs.setString('mistral_voice_id', _finalMistralVoiceId);
    await prefs.setString('google_api_key', _googleApiKeyController.text.trim());
    await prefs.setString('google_voice', _selectedGoogleVoice);

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('✅ Paramètres sauvegardés !')),
      );
      Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    final accentColor = Colors.orangeAccent.shade700;
    return Scaffold(
      backgroundColor: Colors.grey.shade50,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 1,
        title: Text('Paramètres', style: TextStyle(color: Colors.black87, fontWeight: FontWeight.bold)),
        iconTheme: const IconThemeData(color: Colors.black87),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // ─── TTS PROVIDER SELECTOR ───
            Text('Moteur TTS', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18, color: accentColor)),
            const SizedBox(height: 12),
            Container(
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(16),
                boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.05), blurRadius: 10, offset: const Offset(0, 4))],
              ),
              child: Column(
                children: [
                  _buildProviderTile(
                    title: 'Mistral AI',
                    subtitle: 'Voxtral Mini TTS — voix expressives',
                    icon: Icons.auto_awesome,
                    value: 'mistral',
                  ),
                  Divider(height: 1, indent: 16, endIndent: 16, color: Colors.grey.shade200),
                  _buildProviderTile(
                    title: 'Google Gemini',
                    subtitle: 'Gemini 3.1 Flash TTS — multilingue',
                    icon: Icons.diamond_outlined,
                    value: 'google',
                  ),
                ],
              ),
            ),
            const SizedBox(height: 32),

            // ─── MISTRAL CONFIG ───
            if (_ttsProvider == 'mistral') ...[
              Text('Clé API Mistral', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15, color: accentColor)),
              const SizedBox(height: 8),
              TextField(
                controller: _mistralApiKeyController,
                obscureText: true,
                decoration: InputDecoration(
                  filled: true,
                  fillColor: Colors.white,
                  hintText: 'sk-...',
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                ),
              ),
              const SizedBox(height: 24),
              Text('Configuration de la Voix', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15, color: accentColor)),
              const SizedBox(height: 12),
              _buildDropdown(
                label: 'Langue / Accent',
                value: _selectedLanguage,
                items: ['fr', 'gb', 'en'],
                onChanged: (val) {
                  if (val != null) {
                    setState(() {
                      _selectedLanguage = val;
                      _selectedVoice = _getVoicesForLang(val).first;
                      if (!(_voiceToEmotions[_selectedVoice]?.contains(_selectedEmotion) ?? false)) {
                        _selectedEmotion = 'neutral';
                      }
                    });
                  }
                },
              ),
              _buildDropdown(
                label: 'Interprète (Voix)',
                value: _selectedVoice,
                items: _getVoicesForLang(_selectedLanguage),
                onChanged: (val) {
                  if (val != null) {
                    setState(() {
                      _selectedVoice = val;
                      _selectedLanguage = _voiceToLang[val]!;
                      if (!(_voiceToEmotions[_selectedVoice]?.contains(_selectedEmotion) ?? false)) {
                        _selectedEmotion = 'neutral';
                      }
                    });
                  }
                },
              ),
              _buildDropdown(
                label: 'Émotion',
                value: _selectedEmotion,
                items: _voiceToEmotions[_selectedVoice] ?? ['neutral'],
                onChanged: (val) {
                  if (val != null) setState(() => _selectedEmotion = val);
                },
              ),
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.orange.shade50,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.orange.shade200),
                ),
                child: Row(
                  children: [
                    Icon(Icons.record_voice_over, color: accentColor, size: 20),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        _finalMistralVoiceId,
                        style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: accentColor, letterSpacing: 1),
                      ),
                    ),
                  ],
                ),
              ),
            ],

            // ─── GOOGLE CONFIG ───
            if (_ttsProvider == 'google') ...[
              Text('Clé API Google (Gemini)', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15, color: accentColor)),
              const SizedBox(height: 8),
              TextField(
                controller: _googleApiKeyController,
                obscureText: true,
                decoration: InputDecoration(
                  filled: true,
                  fillColor: Colors.white,
                  hintText: 'AIza...',
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                ),
              ),
              const SizedBox(height: 24),
              Text('Voix Google', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15, color: accentColor)),
              const SizedBox(height: 12),
              _buildDropdown(
                label: 'Voix',
                value: _selectedGoogleVoice,
                items: GoogleTtsService.availableVoices,
                onChanged: (val) {
                  if (val != null) setState(() => _selectedGoogleVoice = val);
                },
              ),
            ],

            const SizedBox(height: 40),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: accentColor,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 16),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                elevation: 6,
                shadowColor: Colors.orangeAccent.withOpacity(0.3),
              ),
              onPressed: _save,
              child: const Text('Enregistrer les paramètres', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildProviderTile({
    required String title,
    required String subtitle,
    required IconData icon,
    required String value,
  }) {
    final isSelected = _ttsProvider == value;
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      leading: Icon(icon, color: isSelected ? Colors.orangeAccent.shade700 : Colors.grey, size: 28),
      title: Text(title, style: TextStyle(fontWeight: FontWeight.bold, color: isSelected ? Colors.black87 : Colors.grey.shade600)),
      subtitle: Text(subtitle, style: TextStyle(fontSize: 12, color: Colors.grey.shade500)),
      trailing: Radio<String>(
        value: value,
        groupValue: _ttsProvider,
        activeColor: Colors.orangeAccent.shade700,
        onChanged: (v) => setState(() => _ttsProvider = v!),
      ),
      onTap: () => setState(() => _ttsProvider = value),
    );
  }

  Widget _buildDropdown({
    required String label,
    required String value,
    required List<String> items,
    required ValueChanged<String?> onChanged,
  }) {
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
                icon: Icon(Icons.keyboard_arrow_down, color: Colors.orangeAccent.shade700),
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
