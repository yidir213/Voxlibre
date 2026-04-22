import 'dart:io';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:epub_view/epub_view.dart';
import 'package:file_picker/file_picker.dart';
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_background/just_audio_background.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:audio_session/audio_session.dart';
import '../services/mistral_service.dart';
import 'settings_screen.dart';

class MyCustomSource extends StreamAudioSource {
  final List<int> bytes;
  final String contentId;
  final String title;

  MyCustomSource({required this.bytes, required this.contentId, required this.title}) 
  : super(tag: MediaItem(
      id: contentId,
      title: title,
      artist: 'VoxLibre IA',
      artUri: Uri.parse('https://images.unsplash.com/photo-1544716278-ca5e3f4abd8c?q=80&w=1000&auto=format&fit=crop'), // Belle couverture pour l'écran de verrouillage
    ));

  @override
  Future<StreamAudioResponse> request([int? start, int? end]) async {
    start ??= 0;
    end ??= bytes.length;
    return StreamAudioResponse(
      sourceLength: bytes.length,
      contentLength: end - start,
      offset: start,
      stream: Stream.value(bytes.sublist(start, end)),
      contentType: 'audio/mpeg',
    );
  }
}

class ReaderScreen extends StatefulWidget {
  const ReaderScreen({super.key});

  @override
  State<ReaderScreen> createState() => _ReaderScreenState();
}

class _ReaderScreenState extends State<ReaderScreen> {
  final MistralService _mistralService = MistralService();
  final AudioPlayer _audioPlayer = AudioPlayer();

  EpubBook? _epubBook;
  List<EpubChapter> _flatChapters = [];
  int _currentChapterIndex = 0;

  bool _isLoadingAudio = false;
  bool _isPlaying = false;
  bool _isAutoPlaying = false; 
  bool _isPaused = false;
  bool _isDarkMode = false;
  
  double _playbackRate = 1.0;

  String _currentChapterTitle = '';
  List<Map<String, String>> _chapterBlocks = []; // {type: 'h1'|'h2'|'h3'|'h4'|'p', text: '...'}
  List<String> _chapterParagraphs = []; // texte simple pour TTS
  List<GlobalKey> _paragraphKeys = [];
  int _readingIndex = -1; 

  final Map<int, List<int>> _audioCache = {};
  int _currentlyFetchingIndex = -1;

  // LIBRARY & PROGRESS
  List<Map<String, dynamic>> _recentBooks = [];
  String _currentFilePath = '';

  @override
  void initState() {
    super.initState();
    _initAudioSession();
    _loadRecentBooks();

    _audioPlayer.playerStateStream.listen((state) {
      if (!mounted) return;
      setState(() {
        _isPlaying = state.playing && state.processingState != ProcessingState.completed;
        _isPaused = !state.playing && (state.processingState == ProcessingState.ready || state.processingState == ProcessingState.buffering);
      });

      if (state.processingState == ProcessingState.completed) {
        if (_isAutoPlaying && !_isPaused) {
          if (_readingIndex < _chapterParagraphs.length - 1) {
            setState(() {
              _readingIndex++;
            });
            _scrollToCurrent();
            _playCurrentChunk();
            _saveProgress();
          } else {
            setState(() {
              _isAutoPlaying = false;
            });
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Fin du chapitre atteinte.', style: TextStyle(fontWeight: FontWeight.bold))),
            );
          }
        }
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
    if (_currentFilePath.isEmpty || _epubBook == null) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      
      final existingIndex = _recentBooks.indexWhere((b) => b['path'] == _currentFilePath);
      
      final bookData = {
        'path': _currentFilePath,
        'title': _epubBook?.Title ?? 'Livre',
        'chapterIndex': _currentChapterIndex,
        'readingIndex': _readingIndex >= 0 ? _readingIndex : 0,
        'timestamp': DateTime.now().millisecondsSinceEpoch,
      };
      
      if (existingIndex >= 0) {
        _recentBooks.removeAt(existingIndex);
      }
      _recentBooks.insert(0, bookData);
      
      // Keep only last 10 books
      if (_recentBooks.length > 10) {
        _recentBooks = _recentBooks.sublist(0, 10);
      }
      
      await prefs.setString('recent_books', json.encode(_recentBooks));
      if (mounted) setState(() {});
    } catch (e) {
      debugPrint("Save progress failed: $e");
    }
  }

  Future<void> _openSavedBook(Map<String, dynamic> bookData) async {
    final path = bookData['path'] as String;
    final file = File(path);
    if (!file.existsSync()) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Le fichier introuvable. Peut-être supprimé ?")),
      );
      return;
    }
    
    try {
      final bytes = file.readAsBytesSync();
      await _openEpubBytes(bytes, path, targetChapter: bookData['chapterIndex'] as int, targetParagraph: bookData['readingIndex'] as int);
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Erreur d'ouverture : $e")));
    }
  }

  Future<void> _pickEpubFile() async {
    FilePickerResult? result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['epub'],
    );

    if (result != null && result.files.single.path != null) {
      final path = result.files.single.path!;
      final file = File(path);
      final bytes = file.readAsBytesSync();
      await _openEpubBytes(bytes, path);
    }
  }

  Future<void> _openEpubBytes(Uint8List bytes, String path, {int targetChapter = 0, int targetParagraph = -1}) async {
    final book = await EpubReader.readBook(bytes);
    final flat = <EpubChapter>[];
    void extractChapters(List<EpubChapter> chapters) {
      for (var c in chapters) {
        flat.add(c);
        if (c.SubChapters != null && c.SubChapters!.isNotEmpty) {
          extractChapters(c.SubChapters!);
        }
      }
    }
    extractChapters(book.Chapters ?? []);

    setState(() {
      _epubBook = book;
      _flatChapters = flat;
      _currentChapterIndex = targetChapter;
      _currentFilePath = path;
    });
    
    _loadChapter(_currentChapterIndex, targetReadingIndex: targetParagraph);
    _saveProgress();
  }

  String _cleanHtmlEntity(String text) {
    return text
      .replaceAll('&nbsp;', ' ')
      .replaceAll('&amp;', '&')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'")
      .replaceAll(RegExp(r'<[^>]*>'), '') // Strip any remaining nested tags
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  }

  void _loadChapter(int index, {int targetReadingIndex = -1}) {
    if (_flatChapters.isEmpty) return;
    if (index < 0 || index >= _flatChapters.length) return;

    final chap = _flatChapters[index];
    final title = chap.Title ?? 'Chapitre ${index + 1}';
    final htmlContent = chap.HtmlContent ?? '';

    // Parse HTML into structured blocks (headings + paragraphs)
    final List<Map<String, String>> blocks = [];
    
    // Match heading tags (h1-h6) and paragraph/div/li tags
    final tagPattern = RegExp(
      r'<(h[1-6]|p|div|li|blockquote)[^>]*>(.*?)</\1>',
      caseSensitive: false,
      dotAll: true,
    );
    
    final matches = tagPattern.allMatches(htmlContent);
    
    if (matches.isNotEmpty) {
      for (final match in matches) {
        final tag = match.group(1)!.toLowerCase();
        final rawContent = match.group(2) ?? '';
        final cleanContent = _cleanHtmlEntity(rawContent);
        
        if (cleanContent.isEmpty) continue;
        
        String blockType;
        if (tag == 'h1') {
          blockType = 'h1';
        } else if (tag == 'h2') {
          blockType = 'h2';
        } else if (tag == 'h3') {
          blockType = 'h3';
        } else if (tag.startsWith('h')) {
          blockType = 'h4'; // h4, h5, h6 all treated as h4
        } else {
          blockType = 'p';
        }
        
        blocks.add({'type': blockType, 'text': cleanContent});
      }
    }
    
    // Fallback: if no structured tags found, split by newlines
    if (blocks.isEmpty) {
      String cleanText = htmlContent.replaceAll(RegExp(r'<[^>]*>'), ' ');
      cleanText = _cleanHtmlEntity(cleanText);
      final rawChunks = cleanText.split(RegExp(r'\n\s*\n'));
      for (final chunk in rawChunks) {
        final trimmed = chunk.replaceAll(RegExp(r'\s+'), ' ').trim();
        if (trimmed.isNotEmpty) {
          blocks.add({'type': 'p', 'text': trimmed});
        }
      }
    }
    
    if (blocks.isEmpty) {
      blocks.add({'type': 'p', 'text': '(Aucun texte lisible dans cette section)'});
    }

    // Extract plain text array for TTS (all blocks are speakable)
    final paragraphs = blocks.map((b) => b['text']!).toList();

    setState(() {
      _currentChapterIndex = index;
      _currentChapterTitle = title;
      _chapterBlocks = blocks;
      _chapterParagraphs = paragraphs;
      _paragraphKeys = List.generate(paragraphs.length, (_) => GlobalKey());
      _readingIndex = targetReadingIndex;
      _audioCache.clear();
      _isPaused = false;
    });

    _stopAudio();
    _saveProgress();

    if (_readingIndex >= 0) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _scrollToCurrent();
      });
    }
  }

  void _nextChapter() {
    if (_currentChapterIndex < _flatChapters.length - 1) {
      _loadChapter(_currentChapterIndex + 1);
    }
  }

  void _prevChapter() {
    if (_currentChapterIndex > 0) {
      _loadChapter(_currentChapterIndex - 1);
    }
  }

  void _scrollToCurrent() {
    if (_readingIndex >= 0 && _readingIndex < _paragraphKeys.length) {
      final keyContext = _paragraphKeys[_readingIndex].currentContext;
      if (keyContext != null) {
        Scrollable.ensureVisible(
          keyContext,
          duration: const Duration(milliseconds: 600),
          curve: Curves.easeInOut,
          alignment: 0.25,
        );
      }
    }
  }

  void _togglePlayPause() async {
    if (_isPlaying) {
      await _audioPlayer.pause();
      setState(() => _isPaused = true);
    } else if (_isPaused) {
      await _audioPlayer.play(); // just_audio resume() is basically play() because speed is kept.
      await _audioPlayer.setSpeed(_playbackRate); 
      setState(() {
        _isPaused = false;
        _isAutoPlaying = true;
      });
    } else {
      int startIdx = _readingIndex >= 0 ? _readingIndex : 0;
      _playFromIndex(startIdx);
    }
  }

  void _seekRelative(int seconds) async {
    if (!_isPlaying && !_isPaused) return;
    final pos = _audioPlayer.position;
    final newPos = pos + Duration(seconds: seconds);
    await _audioPlayer.seek(newPos < Duration.zero ? Duration.zero : newPos);
  }

  Future<void> _playFromIndex(int index) async {
    await _stopAudio(); 
    if (!mounted) return;
    setState(() {
      _readingIndex = index;
      _isAutoPlaying = true;
      _isPaused = false;
    });
    _scrollToCurrent();
    _saveProgress();
    _playCurrentChunk();
  }

  Future<List<int>> _fetchAudioForIndex(int index) async {
    final textToRead = _chapterParagraphs[index];
    final safeText = textToRead.length > 4000 
        ? textToRead.substring(0, 4000) 
        : textToRead;

    return await _mistralService.getTtsAudio(
      safeText,
      voiceId: dotenv.env['MISTRAL_VOICE_ID'] ?? '',
    );
  }

  void _prefetchNextChunk(int nextIndex) async {
    if (nextIndex >= _chapterParagraphs.length) return;
    if (_audioCache.containsKey(nextIndex)) return;
    if (_currentlyFetchingIndex == nextIndex) return;

    _currentlyFetchingIndex = nextIndex;
    try {
      final bytes = await _fetchAudioForIndex(nextIndex);
      _audioCache[nextIndex] = bytes;
    } catch (e) {
      // Échec silencieux
    } finally {
      if (_currentlyFetchingIndex == nextIndex) {
        _currentlyFetchingIndex = -1;
      }
    }
  }

  Future<void> _playCurrentChunk() async {
    if (_readingIndex < 0 || _readingIndex >= _chapterParagraphs.length || !_isAutoPlaying) {
      _stopAudio();
      return;
    }

    final textToRead = _chapterParagraphs[_readingIndex];
    if (textToRead.startsWith("(")) {
      setState(() { _isAutoPlaying = false; });
      return;
    }

    List<int>? audioBytes = _audioCache[_readingIndex];

    if (audioBytes == null) {
      setState(() => _isLoadingAudio = true);
      try {
        audioBytes = await _fetchAudioForIndex(_readingIndex);
        _audioCache[_readingIndex] = audioBytes;
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
      final source = MyCustomSource(
        bytes: audioBytes,
        contentId: 'chap_${_currentChapterIndex}_para_$_readingIndex',
        title: 'Chapitre ${_currentChapterIndex + 1} - Paragraphe ${_readingIndex + 1}',
      );
      
      await _audioPlayer.setAudioSource(source);
      await _audioPlayer.setSpeed(_playbackRate);
      await _audioPlayer.play();

      _prefetchNextChunk(_readingIndex + 1);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Erreur Lecture: $e')));
      }
    }
  }

  Future<void> _stopAudio() async {
    setState(() {
      _isAutoPlaying = false;
      _isLoadingAudio = false;
      _isPaused = false;
      _audioCache.clear();
    });
    await _audioPlayer.stop();
  }

  @override
  void dispose() {
    _audioPlayer.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bgColor = _isDarkMode ? const Color(0xFF121212) : const Color(0xFFFAF9F6);
    final appBarColor = _isDarkMode ? const Color(0xFF1A1A1A).withOpacity(0.95) : Colors.white.withOpacity(0.95);
    final textColor = _isDarkMode ? Colors.white : Colors.black87;
    final iconColor = _epubBook == null ? Colors.white : textColor;

    return Scaffold(
      backgroundColor: _epubBook == null ? const Color(0xFF222222) : bgColor,
      extendBodyBehindAppBar: _epubBook == null,
      drawer: _epubBook != null ? _buildDrawer() : null,
      appBar: AppBar(
        iconTheme: IconThemeData(color: iconColor),
        backgroundColor: _epubBook == null ? Colors.transparent : appBarColor,
        elevation: _epubBook == null ? 0 : 0.5,
        flexibleSpace: _epubBook != null ? ClipRect(
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
            child: Container(color: Colors.transparent),
          ),
        ) : null,
        title: Text(
          _epubBook == null ? '' : _currentChapterTitle,
          style: TextStyle(color: textColor, fontWeight: FontWeight.bold, fontSize: 18),
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          IconButton(
            icon: Icon(_isDarkMode ? Icons.light_mode : Icons.dark_mode, color: iconColor),
            onPressed: () {
              setState(() => _isDarkMode = !_isDarkMode);
            },
            tooltip: 'Mode Nuit / Jour',
          ),
          IconButton(
            icon: Icon(Icons.settings_outlined, color: iconColor),
            onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const SettingsScreen())),
            tooltip: 'Paramètres',
          ),
          IconButton(
            icon: Icon(Icons.library_books_outlined, color: _epubBook == null ? Colors.white : Colors.orangeAccent.shade700),
            onPressed: _pickEpubFile,
            tooltip: 'Ouvrir un EPUB',
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: _epubBook == null ? _buildWelcome() : _buildNativeReader(),
      floatingActionButtonLocation: FloatingActionButtonLocation.centerFloat,
      floatingActionButton: _epubBook == null ? null : _buildModernBottomBar(),
    );
  }

  Widget _buildDrawer() {
    return Drawer(
      backgroundColor: _isDarkMode ? const Color(0xFF1E1E1E) : Colors.white,
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.all(20.0),
              child: Text(
                'Table des Matières',
                style: TextStyle(
                  fontSize: 22, 
                  fontWeight: FontWeight.bold,
                  color: _isDarkMode ? Colors.white : Colors.black87,
                ),
              ),
            ),
            Divider(color: _isDarkMode ? Colors.white24 : Colors.black12, height: 1),
            Expanded(
              child: ListView.builder(
                itemCount: _flatChapters.length,
                itemBuilder: (context, index) {
                  final chap = _flatChapters[index];
                  final isCurrent = index == _currentChapterIndex;
                  return ListTile(
                    contentPadding: const EdgeInsets.symmetric(horizontal: 24),
                    title: Text(
                      chap.Title ?? 'Chapitre ${index + 1}',
                      style: TextStyle(
                        fontWeight: isCurrent ? FontWeight.bold : FontWeight.w500,
                        fontSize: 16,
                        color: isCurrent 
                          ? Colors.orangeAccent.shade700 
                          : (_isDarkMode ? Colors.white70 : Colors.black87),
                      ),
                    ),
                    tileColor: isCurrent ? Colors.orangeAccent.withOpacity(0.1) : null,
                    onTap: () {
                      Navigator.pop(context);
                      _loadChapter(index);
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildWelcome() {
    return Container(
      decoration: const BoxDecoration(
        image: DecorationImage(
          image: NetworkImage('https://images.unsplash.com/photo-1544716278-ca5e3f4abd8c?q=80&w=1000&auto=format&fit=crop'), // Image de gens heureux lisant dehors
          fit: BoxFit.cover,
        ),
      ),
      child: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              Colors.black.withOpacity(0.2),
              Colors.black.withOpacity(0.85),
            ],
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
                  style: TextStyle(
                    fontSize: 48,
                    fontWeight: FontWeight.w900,
                    color: Colors.white,
                    letterSpacing: 2,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Redécouvrez le plaisir de lire, ou laissez l\'IA vous raconter vos histoires préférées.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 16,
                    height: 1.5,
                    color: Colors.white.withOpacity(0.9),
                  ),
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
                
                // ZONE BIBLIOTHÈQUE RÉCENTE
                if (_recentBooks.isNotEmpty) ...[
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      'Reprendre la lecture',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: Colors.white.withOpacity(0.9),
                      ),
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

  Widget _buildNativeReader() {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 100, 20, 200),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_currentChapterTitle.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 40, top: 16),
              child: Text(
                _currentChapterTitle,
                style: TextStyle(
                  fontSize: 32,
                  fontWeight: FontWeight.w900,
                  color: _isDarkMode ? Colors.white : Colors.black87,
                  fontFamily: 'Georgia',
                  height: 1.3,
                  letterSpacing: 0.5,
                ),
                textAlign: TextAlign.center,
              ),
            ),
          ...List.generate(_chapterBlocks.length, (index) {
            final block = _chapterBlocks[index];
            final text = block['text']!;
            final type = block['type']!;
            final isReading = _readingIndex == index && (_isPlaying || _isLoadingAudio || _isPaused);
            return Container(
              key: _paragraphKeys[index],
              child: EpubBlock(
                text: text,
                blockType: type,
                isReading: isReading,
                isDarkMode: _isDarkMode,
                onTap: () {
                  _playFromIndex(index);
                },
              ),
            );
          }),
        ],
      ),
    );
  }

  Widget _buildModernBottomBar() {
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
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                // BOUTON PREV CHAPTER
                IconButton(
                  icon: const Icon(Icons.skip_previous_rounded, size: 28),
                  onPressed: _currentChapterIndex > 0 ? _prevChapter : null,
                  color: _isDarkMode ? Colors.grey.shade300 : Colors.grey.shade800,
                  tooltip: 'Chapitre précédent',
                ),

                // BOUTON -5s
                IconButton(
                  icon: const Icon(Icons.replay_5_rounded, size: 28),
                  onPressed: (_isPlaying || _isPaused) ? () => _seekRelative(-5) : null,
                  color: (_isPlaying || _isPaused) ? Colors.orangeAccent.shade700 : (_isDarkMode ? Colors.grey.shade700 : Colors.grey.shade400),
                  tooltip: '-5 secondes',
                ),
                
                // BOUTON PLAY/PAUSE
                if (_isLoadingAudio)
                  const SizedBox(
                    width: 50, height: 50,
                    child: Padding(
                      padding: EdgeInsets.all(12),
                      child: CircularProgressIndicator(color: Colors.orangeAccent, strokeWidth: 3),
                    ),
                  )
                else
                  Container(
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: Colors.orangeAccent.shade700,
                      boxShadow: [
                        BoxShadow(
                          color: Colors.orangeAccent.withOpacity(0.4),
                          blurRadius: 10,
                          offset: const Offset(0, 4),
                        ),
                      ],
                    ),
                    child: IconButton(
                      icon: Icon(_isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded, size: 30),
                      color: Colors.white,
                      onPressed: _togglePlayPause,
                    ),
                  ),

                // BOUTON +5s
                IconButton(
                  icon: const Icon(Icons.forward_5_rounded, size: 28),
                  onPressed: (_isPlaying || _isPaused) ? () => _seekRelative(5) : null,
                  color: (_isPlaying || _isPaused) ? Colors.orangeAccent.shade700 : (_isDarkMode ? Colors.grey.shade700 : Colors.grey.shade400),
                  tooltip: '+5 secondes',
                ),

                // BOUTON NEXT CHAPTER
                IconButton(
                  icon: const Icon(Icons.skip_next_rounded, size: 28),
                  onPressed: _currentChapterIndex < _flatChapters.length - 1 ? _nextChapter : null,
                  color: _isDarkMode ? Colors.grey.shade300 : Colors.grey.shade800,
                  tooltip: 'Chapitre suivant',
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class EpubBlock extends StatelessWidget {
  final String text;
  final String blockType; // 'h1', 'h2', 'h3', 'h4', 'p'
  final bool isReading;
  final bool isDarkMode;
  final VoidCallback onTap;

  const EpubBlock({
    super.key,
    required this.text,
    required this.blockType,
    required this.isReading,
    required this.isDarkMode,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final baseTextColor = isDarkMode ? Colors.white : Colors.black87;
    final accentColor = Colors.orangeAccent;
    
    // Typography settings based on block type
    double fontSize;
    FontWeight fontWeight;
    double lineHeight;
    double bottomMargin;
    double topMargin;
    TextAlign textAlign;
    double letterSpacing;
    
    switch (blockType) {
      case 'h1':
        fontSize = 28;
        fontWeight = FontWeight.w900;
        lineHeight = 1.3;
        bottomMargin = 20;
        topMargin = 40;
        textAlign = TextAlign.left;
        letterSpacing = 0.5;
        break;
      case 'h2':
        fontSize = 24;
        fontWeight = FontWeight.w800;
        lineHeight = 1.35;
        bottomMargin = 16;
        topMargin = 36;
        textAlign = TextAlign.left;
        letterSpacing = 0.3;
        break;
      case 'h3':
        fontSize = 21;
        fontWeight = FontWeight.w700;
        lineHeight = 1.4;
        bottomMargin = 14;
        topMargin = 28;
        textAlign = TextAlign.left;
        letterSpacing = 0.2;
        break;
      case 'h4':
        fontSize = 19;
        fontWeight = FontWeight.w600;
        lineHeight = 1.45;
        bottomMargin = 12;
        topMargin = 24;
        textAlign = TextAlign.left;
        letterSpacing = 0.1;
        break;
      default: // 'p'
        fontSize = 18;
        fontWeight = FontWeight.w400;
        lineHeight = 1.85;
        bottomMargin = 20;
        topMargin = 0;
        textAlign = TextAlign.justify;
        letterSpacing = 0.0;
        break;
    }
    
    final bool isHeading = blockType.startsWith('h');
    
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(isHeading ? 8 : 12),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 300),
        margin: EdgeInsets.only(bottom: bottomMargin, top: topMargin),
        decoration: BoxDecoration(
          color: isReading 
            ? accentColor.withOpacity(isDarkMode ? 0.2 : 0.08) 
            : Colors.transparent,
          borderRadius: BorderRadius.circular(isHeading ? 8 : 12),
          border: Border.all(
            color: isReading 
              ? accentColor.withOpacity(0.4) 
              : Colors.transparent, 
            width: 1.5,
          ),
          // Subtle left border accent for headings
        ),
        padding: EdgeInsets.symmetric(
          horizontal: isHeading ? 12 : 16, 
          vertical: isHeading ? 10 : 14,
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Decorative left bar for headings
            if (isHeading && !isReading)
              Container(
                width: 4,
                height: fontSize * 1.2,
                margin: const EdgeInsets.only(right: 12),
                decoration: BoxDecoration(
                  color: accentColor.shade700.withOpacity(0.7),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            Expanded(
              child: Text(
                text,
                style: TextStyle(
                  color: isHeading 
                    ? baseTextColor 
                    : baseTextColor.withOpacity(isReading ? 1.0 : 0.82),
                  fontSize: fontSize,
                  fontWeight: fontWeight,
                  height: lineHeight,
                  fontFamily: 'Georgia',
                  letterSpacing: letterSpacing,
                ),
                textAlign: textAlign,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
