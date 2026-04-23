import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui';
import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:flutter_epub_viewer/flutter_epub_viewer.dart';
import 'package:file_picker/file_picker.dart';
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_background/just_audio_background.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:audio_session/audio_session.dart';
import 'package:path_provider/path_provider.dart';
import '../services/mistral_service.dart';
import '../services/google_tts_service.dart';
import 'settings_screen.dart';

// ─── Custom Audio Source for just_audio ───
class MyCustomSource extends StreamAudioSource {
  final List<int> bytes;
  final String contentType;

  MyCustomSource({
    required this.bytes,
    required String contentId,
    required String title,
    this.contentType = 'audio/mpeg',
  }) : super(
          tag: MediaItem(
            id: contentId,
            title: title,
            artist: 'VoxLibre IA',
          ),
        );

  @override
  Future<StreamAudioResponse> request([int? start, int? end]) async {
    start ??= 0;
    end ??= bytes.length;
    return StreamAudioResponse(
      sourceLength: bytes.length,
      contentLength: end - start,
      offset: start,
      stream: Stream.value(bytes.sublist(start, end)),
      contentType: contentType,
    );
  }
}

// ─── Main Reader Screen ───
class ReaderScreen extends StatefulWidget {
  const ReaderScreen({super.key});

  @override
  State<ReaderScreen> createState() => _ReaderScreenState();
}

class _ReaderScreenState extends State<ReaderScreen> {
  final MistralService _mistralService = MistralService();
  final GoogleTtsService _googleTtsService = GoogleTtsService();
  final AudioPlayer _audioPlayer = AudioPlayer();
  final EpubController _epubController = EpubController();

  // State
  bool _isDarkMode = false;
  bool _bookLoaded = false;
  String _currentFilePath = '';
  String _bookTitle = '';

  // TTS State
  bool _isTtsMode = false;
  bool _isLoadingAudio = false;
  bool _isPlaying = false;
  bool _isAutoPlaying = false;
  bool _isPaused = false;
  double _playbackRate = 1.0;

  // TTS Text chunks
  List<String> _ttsChunks = [];
  int _currentChunkIndex = -1;

  // Word-level highlighting
  List<String> _currentWords = [];
  int _highlightedWordIndex = -1;
  Timer? _wordTimer;
  Duration _audioDuration = Duration.zero;

  // Library
  List<Map<String, dynamic>> _recentBooks = [];

  // Audio cache
  final Map<int, List<int>> _audioCache = {};

  @override
  void initState() {
    super.initState();
    _initAudioSession();
    _loadRecentBooks();

    _audioPlayer.playerStateStream.listen((state) {
      if (!mounted) return;
      setState(() {
        _isPlaying = state.playing && state.processingState != ProcessingState.completed;
        _isPaused = !state.playing &&
            (state.processingState == ProcessingState.ready || state.processingState == ProcessingState.buffering);
      });

      if (state.processingState == ProcessingState.completed) {
        _wordTimer?.cancel();
        setState(() => _highlightedWordIndex = -1);
        if (_isAutoPlaying && !_isPaused) {
          if (_currentChunkIndex < _ttsChunks.length - 1) {
            setState(() => _currentChunkIndex++);
            _playCurrentChunk();
            _saveProgress();
          } else {
            setState(() => _isAutoPlaying = false);
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Fin du texte atteinte.')),
            );
          }
        }
      }
    });

    // Position stream for word highlighting
    _audioPlayer.positionStream.listen((position) {
      if (_currentWords.isEmpty || _audioDuration == Duration.zero) return;
      final progress = position.inMilliseconds / _audioDuration.inMilliseconds;
      final wordIndex = (progress * _currentWords.length).floor().clamp(0, _currentWords.length - 1);
      if (wordIndex != _highlightedWordIndex && mounted) {
        setState(() => _highlightedWordIndex = wordIndex);
      }
    });

    // Duration stream
    _audioPlayer.durationStream.listen((duration) {
      if (duration != null) {
        _audioDuration = duration;
      }
    });
  }

  Future<void> _initAudioSession() async {
    try {
      final session = await AudioSession.instance;
      await session.configure(const AudioSessionConfiguration.speech());
    } catch (e) {
      debugPrint("AudioSession init failed: $e");
    }
  }

  // ─── Library ───
  Future<void> _loadRecentBooks() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final String? booksJson = prefs.getString('recent_books');
      if (booksJson != null) {
        setState(() {
          _recentBooks = List<Map<String, dynamic>>.from(json.decode(booksJson));
        });
      }
    } catch (e) {
      debugPrint("Load books failed: $e");
    }
  }

  Future<void> _saveProgress() async {
    if (_currentFilePath.isEmpty) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final existingIndex = _recentBooks.indexWhere((b) => b['path'] == _currentFilePath);
      final bookData = {
        'path': _currentFilePath,
        'title': _bookTitle.isNotEmpty ? _bookTitle : 'Livre',
        'chunkIndex': _currentChunkIndex >= 0 ? _currentChunkIndex : 0,
        'timestamp': DateTime.now().millisecondsSinceEpoch,
      };

      if (existingIndex >= 0) {
        _recentBooks.removeAt(existingIndex);
      }
      _recentBooks.insert(0, bookData);
      if (_recentBooks.length > 10) _recentBooks = _recentBooks.sublist(0, 10);

      await prefs.setString('recent_books', json.encode(_recentBooks));
      if (mounted) setState(() {});
    } catch (e) {
      debugPrint("Save progress failed: $e");
    }
  }

  // ─── File Picking ───
  Future<void> _pickEpubFile() async {
    FilePickerResult? result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['epub'],
    );

    if (result != null && result.files.single.path != null) {
      final path = result.files.single.path!;
      _openEpub(path);
    }
  }

  Future<void> _openEpub(String path) async {
    final file = File(path);
    if (!file.existsSync()) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Fichier introuvable.")),
      );
      return;
    }

    // Copy to app directory for flutter_epub_viewer
    final appDir = await getApplicationDocumentsDirectory();
    final destPath = '${appDir.path}/current_book.epub';
    file.copySync(destPath);

    setState(() {
      _currentFilePath = path;
      _bookTitle = path.split(Platform.pathSeparator).last.replaceAll('.epub', '');
      _bookLoaded = true;
      _isTtsMode = false;
      _ttsChunks = [];
      _currentChunkIndex = -1;
      _audioCache.clear();
    });

    _saveProgress();
  }

  Future<void> _openSavedBook(Map<String, dynamic> bookData) async {
    final path = bookData['path'] as String;
    await _openEpub(path);
  }

  // ─── TTS Logic ───
  Future<void> _enterTtsMode() async {
    // Get visible text from the epub viewer for TTS
    // We'll use the epub controller to get the current chapter text
    setState(() {
      _isTtsMode = true;
      _isLoadingAudio = true;
    });

    try {
      // Extract text by loading the epub file manually
      final file = File(_currentFilePath);
      if (!file.existsSync()) return;

      final bytes = file.readAsBytesSync();
      // Use archive to extract HTML content from EPUB
      final chunks = await _extractTextFromEpub(bytes);

      setState(() {
        _ttsChunks = chunks;
        _isLoadingAudio = false;
        _currentChunkIndex = 0;
      });
    } catch (e) {
      setState(() => _isLoadingAudio = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Erreur extraction texte: $e')),
        );
      }
    }
  }

  Future<List<String>> _extractTextFromEpub(Uint8List epubBytes) async {
    // EPUB = ZIP archive containing XHTML/HTML files
    final archive = ZipDecoder().decodeBytes(epubBytes);

    // Find all HTML/XHTML files from the archive
    final htmlFiles = archive.files.where((f) {
      final name = f.name.toLowerCase();
      return !f.isFile ? false : (name.endsWith('.xhtml') || name.endsWith('.html') || name.endsWith('.htm'));
    }).toList();

    htmlFiles.sort((a, b) => a.name.compareTo(b.name));

    final List<String> paragraphs = [];
    for (final file in htmlFiles) {
      final html = utf8.decode(file.content as List<int>, allowMalformed: true);
      // Extract text from paragraph and heading tags
      final pRegex = RegExp(r'<(?:p|h[1-6]|div|li)[^>]*>(.*?)</(?:p|h[1-6]|div|li)>', caseSensitive: false, dotAll: true);
      for (final match in pRegex.allMatches(html)) {
        String text = match.group(1) ?? '';
        text = text
            .replaceAll(RegExp(r'<[^>]*>'), '')
            .replaceAll('&nbsp;', ' ')
            .replaceAll('&amp;', '&')
            .replaceAll('&lt;', '<')
            .replaceAll('&gt;', '>')
            .replaceAll('&quot;', '"')
            .replaceAll('&#39;', "'")
            .replaceAll(RegExp(r'\s+'), ' ')
            .trim();
        if (text.length > 3) {
          paragraphs.add(text);
        }
      }
    }

    if (paragraphs.isEmpty) {
      paragraphs.add('(Aucun texte lisible trouvé dans cet EPUB)');
    }

    return paragraphs;
  }

  Future<List<int>> _fetchAudioForText(String text) async {
    final prefs = await SharedPreferences.getInstance();
    final provider = prefs.getString('tts_provider') ?? 'mistral';
    final safeText = text.length > 4000 ? text.substring(0, 4000) : text;

    if (provider == 'google') {
      final apiKey = prefs.getString('google_api_key') ?? '';
      final voice = prefs.getString('google_voice') ?? 'Kore';
      return await _googleTtsService.getTtsAudio(safeText, apiKey: apiKey, voiceName: voice);
    } else {
      final apiKey = prefs.getString('mistral_api_key') ?? '';
      final voiceId = prefs.getString('mistral_voice_id') ?? 'fr_marie_neutral';
      return await _mistralService.getTtsAudio(safeText, voiceId: voiceId, apiKey: apiKey);
    }
  }

  Future<void> _playCurrentChunk() async {
    if (_currentChunkIndex < 0 || _currentChunkIndex >= _ttsChunks.length || !_isAutoPlaying) {
      _stopAudio();
      return;
    }

    final text = _ttsChunks[_currentChunkIndex];

    // Set up word list for highlighting
    setState(() {
      _currentWords = text.split(RegExp(r'\s+'));
      _highlightedWordIndex = 0;
    });

    List<int>? audioBytes = _audioCache[_currentChunkIndex];

    if (audioBytes == null) {
      setState(() => _isLoadingAudio = true);
      try {
        audioBytes = await _fetchAudioForText(text);
        _audioCache[_currentChunkIndex] = audioBytes;
      } catch (e) {
        if (mounted) {
          setState(() {
            _isLoadingAudio = false;
            _isAutoPlaying = false;
          });
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Erreur TTS: $e')));
        }
        return;
      }
      if (mounted) setState(() => _isLoadingAudio = false);
    }

    if (!_isAutoPlaying) return;

    try {
      final prefs = await SharedPreferences.getInstance();
      final provider = prefs.getString('tts_provider') ?? 'mistral';
      final contentType = provider == 'google' ? 'audio/wav' : 'audio/mpeg';

      final source = MyCustomSource(
        bytes: audioBytes,
        contentId: 'chunk_$_currentChunkIndex',
        title: 'VoxLibre — Paragraphe ${_currentChunkIndex + 1}',
        contentType: contentType,
      );

      await _audioPlayer.setAudioSource(source);
      await _audioPlayer.setSpeed(_playbackRate);
      await _audioPlayer.play();

      // Prefetch next
      _prefetchNext(_currentChunkIndex + 1);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Erreur Lecture: $e')));
      }
    }
  }

  void _prefetchNext(int nextIndex) async {
    if (nextIndex >= _ttsChunks.length || _audioCache.containsKey(nextIndex)) return;
    try {
      final bytes = await _fetchAudioForText(_ttsChunks[nextIndex]);
      _audioCache[nextIndex] = bytes;
    } catch (_) {}
  }

  void _togglePlayPause() async {
    if (_isPlaying) {
      await _audioPlayer.pause();
      _wordTimer?.cancel();
      setState(() => _isPaused = true);
    } else if (_isPaused) {
      await _audioPlayer.play();
      await _audioPlayer.setSpeed(_playbackRate);
      setState(() {
        _isPaused = false;
        _isAutoPlaying = true;
      });
    } else {
      setState(() {
        _isAutoPlaying = true;
        _isPaused = false;
        if (_currentChunkIndex < 0) _currentChunkIndex = 0;
      });
      _playCurrentChunk();
    }
  }

  void _seekRelative(int seconds) async {
    if (!_isPlaying && !_isPaused) return;
    final pos = _audioPlayer.position;
    final newPos = pos + Duration(seconds: seconds);
    await _audioPlayer.seek(newPos < Duration.zero ? Duration.zero : newPos);
  }

  Future<void> _stopAudio() async {
    _wordTimer?.cancel();
    setState(() {
      _isAutoPlaying = false;
      _isLoadingAudio = false;
      _isPaused = false;
      _highlightedWordIndex = -1;
      _currentWords = [];
    });
    await _audioPlayer.stop();
  }

  void _exitTtsMode() {
    _stopAudio();
    _audioCache.clear();
    setState(() {
      _isTtsMode = false;
      _ttsChunks = [];
      _currentChunkIndex = -1;
    });
  }

  @override
  void dispose() {
    _wordTimer?.cancel();
    _audioPlayer.dispose();
    super.dispose();
  }

  // ─── BUILD ───
  @override
  Widget build(BuildContext context) {
    final bgColor = _isDarkMode ? const Color(0xFF121212) : const Color(0xFFFAF9F6);
    final textColor = _isDarkMode ? Colors.white : Colors.black87;
    final iconColor = !_bookLoaded ? Colors.white : textColor;

    return Scaffold(
      backgroundColor: !_bookLoaded ? const Color(0xFF222222) : bgColor,
      extendBodyBehindAppBar: !_bookLoaded,
      appBar: AppBar(
        iconTheme: IconThemeData(color: iconColor),
        backgroundColor: !_bookLoaded ? Colors.transparent : (_isDarkMode ? const Color(0xFF1A1A1A).withOpacity(0.95) : Colors.white.withOpacity(0.95)),
        elevation: !_bookLoaded ? 0 : 0.5,
        flexibleSpace: _bookLoaded
            ? ClipRect(child: BackdropFilter(filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10), child: Container(color: Colors.transparent)))
            : null,
        title: Text(
          !_bookLoaded ? '' : (_isTtsMode ? 'Lecture IA' : _bookTitle),
          style: TextStyle(color: textColor, fontWeight: FontWeight.bold, fontSize: 18),
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          if (_bookLoaded && !_isTtsMode)
            IconButton(
              icon: Icon(Icons.record_voice_over, color: Colors.orangeAccent.shade700),
              onPressed: _enterTtsMode,
              tooltip: 'Lecture IA (TTS)',
            ),
          if (_bookLoaded && _isTtsMode)
            IconButton(
              icon: Icon(Icons.chrome_reader_mode, color: Colors.orangeAccent.shade700),
              onPressed: _exitTtsMode,
              tooltip: 'Mode lecture',
            ),
          IconButton(
            icon: Icon(_isDarkMode ? Icons.light_mode : Icons.dark_mode, color: iconColor),
            onPressed: () => setState(() => _isDarkMode = !_isDarkMode),
            tooltip: 'Mode Nuit / Jour',
          ),
          IconButton(
            icon: Icon(Icons.settings_outlined, color: iconColor),
            onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const SettingsScreen())),
            tooltip: 'Paramètres',
          ),
          IconButton(
            icon: Icon(Icons.library_books_outlined, color: !_bookLoaded ? Colors.white : Colors.orangeAccent.shade700),
            onPressed: _pickEpubFile,
            tooltip: 'Ouvrir un EPUB',
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: !_bookLoaded ? _buildWelcome() : (_isTtsMode ? _buildTtsReader() : _buildEpubViewer()),
      floatingActionButtonLocation: FloatingActionButtonLocation.centerFloat,
      floatingActionButton: (_bookLoaded && _isTtsMode) ? _buildAudioControls() : null,
    );
  }

  // ─── EPUB Viewer (flutter_epub_viewer) ───
  Widget _buildEpubViewer() {
    return FutureBuilder<String>(
      future: _getLocalEpubPath(),
      builder: (context, snapshot) {
        if (!snapshot.hasData) {
          return const Center(child: CircularProgressIndicator(color: Colors.orangeAccent));
        }
        return EpubViewer(
          epubController: _epubController,
          epubSource: EpubSource.fromFile(File(snapshot.data!)),
          displaySettings: EpubDisplaySettings(
            fontSize: 18,
            spread: EpubSpread.auto,
          ),
          onEpubLoaded: () {
            debugPrint("EPUB chargé avec flutter_epub_viewer");
          },
          onChaptersLoaded: (chapters) {
            if (chapters.isNotEmpty) {
              setState(() => _bookTitle = chapters.first.title ?? _bookTitle);
            }
          },
          onRelocated: (value) {
            debugPrint("Relocated: ${value.progress}%");
          },
        );
      },
    );
  }

  Future<String> _getLocalEpubPath() async {
    final appDir = await getApplicationDocumentsDirectory();
    return '${appDir.path}/current_book.epub';
  }

  // ─── TTS Reader (custom with word highlighting) ───
  Widget _buildTtsReader() {
    if (_isLoadingAudio && _ttsChunks.isEmpty) {
      return const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircularProgressIndicator(color: Colors.orangeAccent),
            SizedBox(height: 16),
            Text('Extraction du texte...', style: TextStyle(color: Colors.grey)),
          ],
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(20, 100, 20, 200),
      itemCount: _ttsChunks.length,
      itemBuilder: (context, index) {
        final text = _ttsChunks[index];
        final isCurrent = index == _currentChunkIndex && (_isPlaying || _isLoadingAudio || _isPaused);

        return GestureDetector(
          onTap: () {
            setState(() {
              _currentChunkIndex = index;
              _isAutoPlaying = true;
              _isPaused = false;
            });
            _playCurrentChunk();
          },
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 300),
            margin: const EdgeInsets.only(bottom: 20),
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: isCurrent
                  ? Colors.orangeAccent.withOpacity(_isDarkMode ? 0.15 : 0.06)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: isCurrent ? Colors.orangeAccent.withOpacity(0.4) : Colors.transparent,
                width: 1.5,
              ),
            ),
            child: isCurrent && _currentWords.isNotEmpty
                ? _buildHighlightedText()
                : Text(
                    text,
                    style: TextStyle(
                      color: (_isDarkMode ? Colors.white : Colors.black87).withOpacity(0.82),
                      fontSize: 18,
                      height: 1.85,
                      fontFamily: 'Georgia',
                    ),
                    textAlign: TextAlign.justify,
                  ),
          ),
        );
      },
    );
  }

  /// Build word-by-word highlighted text using RichText
  Widget _buildHighlightedText() {
    final baseColor = _isDarkMode ? Colors.white : Colors.black87;

    return RichText(
      textAlign: TextAlign.justify,
      text: TextSpan(
        style: TextStyle(
          fontSize: 18,
          height: 1.85,
          fontFamily: 'Georgia',
          color: baseColor.withOpacity(0.82),
        ),
        children: List.generate(_currentWords.length, (i) {
          final isHighlighted = i == _highlightedWordIndex;
          final word = _currentWords[i];
          return TextSpan(
            text: i < _currentWords.length - 1 ? '$word ' : word,
            style: TextStyle(
              color: isHighlighted ? Colors.white : null,
              backgroundColor: isHighlighted ? Colors.orangeAccent.shade700 : null,
              fontWeight: isHighlighted ? FontWeight.w700 : null,
            ),
          );
        }),
      ),
    );
  }

  // ─── Welcome Screen ───
  Widget _buildWelcome() {
    return Container(
      decoration: const BoxDecoration(
        image: DecorationImage(
          image: NetworkImage(
              'https://images.unsplash.com/photo-1544716278-ca5e3f4abd8c?q=80&w=1000&auto=format&fit=crop'),
          fit: BoxFit.cover,
        ),
      ),
      child: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Colors.black.withOpacity(0.2), Colors.black.withOpacity(0.85)],
          ),
        ),
        child: Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.end,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Icon(Icons.headphones_rounded, size: 70, color: Colors.white),
                const SizedBox(height: 16),
                const Text(
                  'VoxLibre',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 48, fontWeight: FontWeight.w900, color: Colors.white, letterSpacing: 2),
                ),
                const SizedBox(height: 8),
                Text(
                  'Redécouvrez le plaisir de lire, ou laissez l\'IA vous raconter vos histoires préférées.',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 16, height: 1.5, color: Colors.white.withOpacity(0.9)),
                ),
                const SizedBox(height: 48),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.orangeAccent.shade700,
                    foregroundColor: Colors.white,
                    elevation: 10,
                    shadowColor: Colors.orangeAccent.withOpacity(0.5),
                    padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(30)),
                  ),
                  onPressed: _pickEpubFile,
                  child: const Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.auto_stories, size: 24),
                      SizedBox(width: 12),
                      Text('Ouvrir un livre (EPUB)', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                    ],
                  ),
                ),
                const SizedBox(height: 32),

                // Recent books library
                if (_recentBooks.isNotEmpty) ...[
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      'Reprendre la lecture',
                      style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.white.withOpacity(0.9)),
                    ),
                  ),
                  const SizedBox(height: 16),
                  SizedBox(
                    height: 120,
                    child: ListView.builder(
                      scrollDirection: Axis.horizontal,
                      itemCount: _recentBooks.length,
                      itemBuilder: (context, i) {
                        final b = _recentBooks[i];
                        return InkWell(
                          onTap: () => _openSavedBook(b),
                          borderRadius: BorderRadius.circular(16),
                          child: Container(
                            width: 110,
                            margin: const EdgeInsets.only(right: 16),
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: Colors.white.withOpacity(0.15),
                              borderRadius: BorderRadius.circular(16),
                              border: Border.all(color: Colors.white.withOpacity(0.2)),
                            ),
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                const Icon(Icons.book_rounded, color: Colors.white, size: 36),
                                const SizedBox(height: 8),
                                Text(
                                  b['title'] ?? 'Livre',
                                  style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600),
                                  textAlign: TextAlign.center,
                                  maxLines: 3,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ],
                const SizedBox(height: 40),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ─── Audio Controls Bar ───
  Widget _buildAudioControls() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: _isDarkMode ? const Color(0xFF1E1E1E).withOpacity(0.95) : Colors.white.withOpacity(0.95),
          borderRadius: BorderRadius.circular(30),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(_isDarkMode ? 0.4 : 0.15),
              blurRadius: 20,
              offset: const Offset(0, 10),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Speed slider
            Row(
              children: [
                Icon(Icons.speed_rounded, size: 18, color: _isDarkMode ? Colors.grey.shade400 : Colors.grey.shade600),
                Expanded(
                  child: SliderTheme(
                    data: SliderThemeData(
                      trackHeight: 4,
                      activeTrackColor: Colors.orangeAccent.shade700,
                      inactiveTrackColor: _isDarkMode ? Colors.grey.shade800 : Colors.grey.shade200,
                      thumbColor: Colors.orangeAccent.shade700,
                      overlayColor: Colors.orangeAccent.withOpacity(0.2),
                      thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                    ),
                    child: Slider(
                      value: _playbackRate,
                      min: 0.5,
                      max: 2.0,
                      onChanged: (val) {
                        setState(() => _playbackRate = val);
                        _audioPlayer.setSpeed(val);
                      },
                    ),
                  ),
                ),
                Text(
                  '${_playbackRate.toStringAsFixed(2)}x',
                  style: TextStyle(fontWeight: FontWeight.bold, color: Colors.orangeAccent.shade700, fontSize: 13),
                ),
              ],
            ),
            const SizedBox(height: 4),
            // Playback controls
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                // -5s
                IconButton(
                  icon: const Icon(Icons.replay_5_rounded, size: 28),
                  onPressed: (_isPlaying || _isPaused) ? () => _seekRelative(-5) : null,
                  color: (_isPlaying || _isPaused) ? Colors.orangeAccent.shade700 : Colors.grey,
                  tooltip: '-5 secondes',
                ),
                // Play/Pause
                if (_isLoadingAudio)
                  const SizedBox(
                    width: 50, height: 50,
                    child: Padding(
                      padding: EdgeInsets.all(12),
                      child: CircularProgressIndicator(color: Colors.orangeAccent, strokeWidth: 3),
                    ),
                  )
                else
                  GestureDetector(
                    onTap: _togglePlayPause,
                    child: Container(
                      width: 56, height: 56,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: Colors.orangeAccent.shade700,
                        boxShadow: [BoxShadow(color: Colors.orangeAccent.withOpacity(0.4), blurRadius: 12, offset: const Offset(0, 4))],
                      ),
                      child: Icon(
                        _isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
                        color: Colors.white,
                        size: 32,
                      ),
                    ),
                  ),
                // +5s
                IconButton(
                  icon: const Icon(Icons.forward_5_rounded, size: 28),
                  onPressed: (_isPlaying || _isPaused) ? () => _seekRelative(5) : null,
                  color: (_isPlaying || _isPaused) ? Colors.orangeAccent.shade700 : Colors.grey,
                  tooltip: '+5 secondes',
                ),
                // Stop
                IconButton(
                  icon: const Icon(Icons.stop_rounded, size: 28),
                  onPressed: _isAutoPlaying ? _stopAudio : null,
                  color: _isAutoPlaying ? Colors.red.shade400 : Colors.grey,
                  tooltip: 'Arrêter',
                ),
              ],
            ),
            // Current chunk info
            if (_currentChunkIndex >= 0 && _ttsChunks.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  '${_currentChunkIndex + 1} / ${_ttsChunks.length}',
                  style: TextStyle(fontSize: 12, color: _isDarkMode ? Colors.grey.shade500 : Colors.grey.shade600),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
