import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:epub_view/epub_view.dart';
import 'package:file_picker/file_picker.dart';
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_background/just_audio_background.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:audio_session/audio_session.dart';
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

  // State
  bool _isDarkMode = false;
  bool _bookLoaded = false;
  String _currentFilePath = '';
  EpubBook? _epubBook;
  List<EpubChapter> _flatChapters = [];
  int _currentChapterIndex = 0;

  // Rendered blocks
  List<EpubBlockData> _currentChapterBlocks = [];
  bool _isLoadingChapter = false;

  // TTS State
  bool _isLoadingAudio = false;
  bool _isPlaying = false;
  bool _isAutoPlaying = false;
  bool _isPaused = false;
  double _playbackRate = 1.0;

  // Highlighting
  int _currentPlayingBlockIndex = -1;
  int _highlightedWordIndex = -1;
  List<String> _currentWords = [];
  Duration _audioDuration = Duration.zero;

  // Library
  List<Map<String, dynamic>> _recentBooks = [];
  final Map<int, List<int>> _audioCache = {};

  final ScrollController _scrollController = ScrollController();
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();

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
        setState(() => _highlightedWordIndex = -1);
        if (_isAutoPlaying && !_isPaused) {
          if (_currentPlayingBlockIndex < _currentChapterBlocks.length - 1) {
            setState(() => _currentPlayingBlockIndex++);
            _playCurrentBlock();
            _scrollToCurrentPlayingBlock();
            _saveProgress();
          } else if (_currentChapterIndex < _flatChapters.length - 1) {
            // Next chapter
            _loadChapter(_currentChapterIndex + 1).then((_) {
              if (_currentChapterBlocks.isNotEmpty) {
                setState(() => _currentPlayingBlockIndex = 0);
                _playCurrentBlock();
              } else {
                setState(() => _isAutoPlaying = false);
              }
            });
          } else {
            setState(() => _isAutoPlaying = false);
            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Livre terminé !')));
          }
        }
      }
    });

    _audioPlayer.positionStream.listen((position) {
      if (_currentWords.isEmpty || _audioDuration == Duration.zero) return;
      final progress = position.inMilliseconds / _audioDuration.inMilliseconds;
      final wordIndex = (progress * _currentWords.length).floor().clamp(0, _currentWords.length - 1);
      if (wordIndex != _highlightedWordIndex && mounted) {
        setState(() => _highlightedWordIndex = wordIndex);
      }
    });

    _audioPlayer.durationStream.listen((duration) {
      if (duration != null) _audioDuration = duration;
    });
  }

  Future<void> _initAudioSession() async {
    try {
      final session = await AudioSession.instance;
      await session.configure(const AudioSessionConfiguration.speech());
    } catch (_) {}
  }

  // ─── Library ───
  Future<void> _loadRecentBooks() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final String? booksJson = prefs.getString('recent_books');
      if (booksJson != null) {
        setState(() => _recentBooks = List<Map<String, dynamic>>.from(json.decode(booksJson)));
      }
    } catch (_) {}
  }

  Future<void> _saveProgress() async {
    if (_currentFilePath.isEmpty || _epubBook == null) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final existingIndex = _recentBooks.indexWhere((b) => b['path'] == _currentFilePath);
      final bookData = {
        'path': _currentFilePath,
        'title': _epubBook!.Title ?? 'Livre inconnu',
        'chapterIndex': _currentChapterIndex,
        'blockIndex': _currentPlayingBlockIndex >= 0 ? _currentPlayingBlockIndex : 0,
        'timestamp': DateTime.now().millisecondsSinceEpoch,
      };

      if (existingIndex >= 0) _recentBooks.removeAt(existingIndex);
      _recentBooks.insert(0, bookData);
      if (_recentBooks.length > 10) _recentBooks = _recentBooks.sublist(0, 10);
      await prefs.setString('recent_books', json.encode(_recentBooks));
      if (mounted) setState(() {});
    } catch (_) {}
  }

  // ─── EPUB Parsing ───
  Future<void> _pickEpubFile() async {
    FilePickerResult? result = await FilePicker.platform.pickFiles(type: FileType.custom, allowedExtensions: ['epub']);
    if (result != null && result.files.single.path != null) {
      _openEpub(result.files.single.path!);
    }
  }

  Future<void> _openSavedBook(Map<String, dynamic> bookData) async {
    final path = bookData['path'] as String;
    await _openEpub(path, startChapter: bookData['chapterIndex'] as int?, startBlock: bookData['blockIndex'] as int?);
  }

  Future<void> _openEpub(String path, {int? startChapter, int? startBlock}) async {
    if (!File(path).existsSync()) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Fichier introuvable.")));
      return;
    }

    setState(() {
      _bookLoaded = false;
      _isLoadingChapter = true;
      _currentFilePath = path;
    });

    try {
      final file = File(path);
      final bytes = await file.readAsBytes();
      final book = await EpubReader.readBook(bytes);

      setState(() {
        _epubBook = book;
        _flatChapters = book.Chapters ?? [];
        _bookLoaded = true;
      });

      await _loadChapter(startChapter ?? 0);
      if (startBlock != null && startBlock < _currentChapterBlocks.length) {
        setState(() => _currentPlayingBlockIndex = startBlock);
        WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToCurrentPlayingBlock());
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Erreur: $e')));
    } finally {
      if (mounted) setState(() => _isLoadingChapter = false);
    }
  }

  Future<void> _loadChapter(int index) async {
    if (index < 0 || index >= _flatChapters.length) return;
    
    _stopAudio();
    setState(() {
      _isLoadingChapter = true;
      _currentChapterIndex = index;
      _currentChapterBlocks = [];
    });

    try {
      final chapter = _flatChapters[index];
      final rawHtml = chapter.HtmlContent ?? '';
      
      final List<EpubBlockData> blocks = [];
      
      final regex = RegExp(r'<(h[1-6]|p|div|li|blockquote)[^>]*>(.*?)</\1>', caseSensitive: false, dotAll: true);
      for (final match in regex.allMatches(rawHtml)) {
        final tag = match.group(1)?.toLowerCase() ?? 'p';
        String content = match.group(2) ?? '';
        
        content = content
            .replaceAll(RegExp(r'<[^>]*>'), '')
            .replaceAll('&nbsp;', ' ')
            .replaceAll('&amp;', '&')
            .replaceAll('&lt;', '<')
            .replaceAll('&gt;', '>')
            .replaceAll('&quot;', '"')
            .replaceAll('&#39;', "'")
            .replaceAll(RegExp(r'\s+'), ' ')
            .trim();
            
        if (content.length > 2) {
          BlockType type = BlockType.paragraph;
          if (tag == 'h1') type = BlockType.h1;
          if (tag == 'h2') type = BlockType.h2;
          if (tag == 'h3') type = BlockType.h3;
          if (tag == 'h4') type = BlockType.h4;
          if (tag == 'blockquote') type = BlockType.quote;

          blocks.add(EpubBlockData(type: type, content: content));
        }
      }

      if (blocks.isEmpty) {
        blocks.add(EpubBlockData(type: BlockType.paragraph, content: '(Chapitre vide)'));
      }

      setState(() {
        _currentChapterBlocks = blocks;
        _isLoadingChapter = false;
        _currentPlayingBlockIndex = -1;
      });
      _saveProgress();
      _scrollController.jumpTo(0);
    } catch (e) {
      setState(() => _isLoadingChapter = false);
    }
  }

  // ─── TTS Audio ───
  Future<List<int>> _fetchAudioForText(String text) async {
    final prefs = await SharedPreferences.getInstance();
    final provider = prefs.getString('tts_provider') ?? 'mistral';
    final safeText = text.length > 4000 ? text.substring(0, 4000) : text;

    if (provider == 'google') {
      final apiKey = prefs.getString('google_api_key') ?? '';
      final voice = prefs.getString('google_voice') ?? 'Kore';
      return await _googleTtsService.getTtsAudio(safeText, apiKey: apiKey, voiceName: voice);
    } else {
      final voiceId = prefs.getString('mistral_voice_id');
      final apiKey = prefs.getString('mistral_api_key');
      return await _mistralService.getTtsAudio(safeText, voiceId: voiceId ?? '', apiKey: apiKey);
    }
  }

  void _scrollToCurrentPlayingBlock() {
    if (_currentPlayingBlockIndex < 0 || !_scrollController.hasClients) return;
    
    // Rough estimate logic or use indexed list view if needed.
    // For now, we scroll down proportionally as a quick fallback.
    final maxScroll = _scrollController.position.maxScrollExtent;
    final target = (maxScroll / _currentChapterBlocks.length) * _currentPlayingBlockIndex;
    _scrollController.animateTo(
      target.clamp(0.0, maxScroll),
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOut,
    );
  }

  Future<void> _playCurrentBlock() async {
    if (_currentPlayingBlockIndex < 0 || _currentPlayingBlockIndex >= _currentChapterBlocks.length) {
      _stopAudio();
      return;
    }

    final block = _currentChapterBlocks[_currentPlayingBlockIndex];
    
    setState(() {
      // Split into words maintaining simple punctuation
      _currentWords = block.content.split(RegExp(r'\s+'));
      _highlightedWordIndex = 0;
    });

    List<int>? audioBytes = _audioCache[_currentPlayingBlockIndex];

    if (audioBytes == null) {
      setState(() => _isLoadingAudio = true);
      try {
        audioBytes = await _fetchAudioForText(block.content);
        if (!_isAutoPlaying) return; // if user stopped while fetching
        _audioCache[_currentPlayingBlockIndex] = audioBytes;
      } catch (e) {
        if (mounted) {
          setState(() {
            _isLoadingAudio = false;
            _isAutoPlaying = false;
          });
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Erreur: $e')));
        }
        return;
      }
      if (mounted) setState(() => _isLoadingAudio = false);
    }

    try {
      final prefs = await SharedPreferences.getInstance();
      final provider = prefs.getString('tts_provider') ?? 'mistral';
      final contentType = provider == 'google' ? 'audio/wav' : 'audio/mpeg';

      final source = MyCustomSource(
        bytes: audioBytes,
        contentId: 'chap_${_currentChapterIndex}_block_$_currentPlayingBlockIndex',
        title: _epubBook!.Title ?? 'Lecture VoxLibre',
        contentType: contentType,
      );

      await _audioPlayer.setAudioSource(source);
      await _audioPlayer.setSpeed(_playbackRate);
      await _audioPlayer.play();

      _prefetchNext(_currentPlayingBlockIndex + 1);
    } catch (_) {}
  }

  void _prefetchNext(int nextIndex) async {
    if (nextIndex >= _currentChapterBlocks.length || _audioCache.containsKey(nextIndex)) return;
    try {
      final bytes = await _fetchAudioForText(_currentChapterBlocks[nextIndex].content);
      _audioCache[nextIndex] = bytes;
    } catch (_) {}
  }

  void _togglePlayPause() async {
    if (_isPlaying) {
      await _audioPlayer.pause();
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
        if (_currentPlayingBlockIndex < 0) _currentPlayingBlockIndex = 0;
      });
      _playCurrentBlock();
    }
  }

  void _seekRelative(int seconds) async {
    if (!_isPlaying && !_isPaused) return;
    final pos = _audioPlayer.position;
    final newPos = pos + Duration(seconds: seconds);
    await _audioPlayer.seek(newPos < Duration.zero ? Duration.zero : newPos);
  }

  Future<void> _stopAudio() async {
    setState(() {
      _isAutoPlaying = false;
      _isLoadingAudio = false;
      _isPaused = false;
      _highlightedWordIndex = -1;
      _currentWords = [];
    });
    await _audioPlayer.stop();
  }

  @override
  void dispose() {
    _audioPlayer.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  // ─── UI BUILD ───
  @override
  Widget build(BuildContext context) {
    final bgColor = _isDarkMode ? const Color(0xFF161618) : const Color(0xFFF9F7F3); // Couleur papier crème
    final textColor = _isDarkMode ? Colors.white.withOpacity(0.9) : const Color(0xFF2C2C2C);
    final iconColor = !_bookLoaded ? Colors.white : textColor;

    return Scaffold(
      key: _scaffoldKey,
      backgroundColor: !_bookLoaded ? const Color(0xFF1C1C1E) : bgColor,
      extendBodyBehindAppBar: !_bookLoaded,
      drawer: _bookLoaded ? _buildDrawer() : null,
      appBar: AppBar(
        iconTheme: IconThemeData(color: iconColor),
        backgroundColor: !_bookLoaded ? Colors.transparent : bgColor.withOpacity(0.95),
        elevation: 0,
        centerTitle: true,
        title: Text(
          !_bookLoaded ? '' : (_flatChapters.isNotEmpty ? _flatChapters[_currentChapterIndex].Title ?? 'VoxLibre' : 'VoxLibre'),
          style: TextStyle(color: textColor, fontWeight: FontWeight.bold, fontSize: 16, fontFamily: 'Georgia'),
        ),
        actions: [
          IconButton(
            icon: Icon(_isDarkMode ? Icons.light_mode : Icons.dark_mode, color: iconColor),
            onPressed: () => setState(() => _isDarkMode = !_isDarkMode),
          ),
          IconButton(
            icon: Icon(Icons.settings_outlined, color: iconColor),
            onPressed: () {
              Navigator.push(context, MaterialPageRoute(builder: (_) => const SettingsScreen()));
            },
          ),
          IconButton(
            icon: Icon(Icons.library_books_rounded, color: !_bookLoaded ? Colors.white : Colors.orangeAccent.shade700),
            onPressed: _pickEpubFile,
          ),
        ],
      ),
      body: !_bookLoaded ? _buildWelcome() : _buildUnifiedReader(),
      floatingActionButtonLocation: FloatingActionButtonLocation.centerFloat,
      floatingActionButton: _bookLoaded ? _buildAudioControls() : null,
    );
  }

  Widget _buildDrawer() {
    final textColor = _isDarkMode ? Colors.white : Colors.black87;
    final bg = _isDarkMode ? const Color(0xFF1E1E1E) : Colors.white;

    return Drawer(
      backgroundColor: bg,
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.fromLTRB(16, 60, 16, 20),
            color: Colors.orangeAccent.shade700,
            width: double.infinity,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.book, size: 40, color: Colors.white),
                const SizedBox(height: 12),
                Text(
                  _epubBook?.Title ?? 'Livre',
                  style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
                ),
                Text(
                  _epubBook?.Author ?? 'Auteur inconnu',
                  style: TextStyle(color: Colors.white.withOpacity(0.8), fontSize: 14),
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView.builder(
              padding: EdgeInsets.zero,
              itemCount: _flatChapters.length,
              itemBuilder: (context, i) {
                final c = _flatChapters[i];
                final isCurrent = i == _currentChapterIndex;
                return ListTile(
                  title: Text(c.Title ?? 'Chapitre ${i + 1}', style: TextStyle(color: isCurrent ? Colors.orangeAccent.shade700 : textColor, fontWeight: isCurrent ? FontWeight.bold : FontWeight.normal)),
                  onTap: () {
                    Navigator.pop(context);
                    if (i != _currentChapterIndex) _loadChapter(i);
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  // ─── UNIFIED READER (Typography + TTS) ───
  Widget _buildUnifiedReader() {
    if (_isLoadingChapter) {
      return const Center(child: CircularProgressIndicator(color: Colors.orangeAccent));
    }

    return ListView.builder(
      controller: _scrollController,
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 180),
      itemCount: _currentChapterBlocks.length,
      itemBuilder: (context, index) {
        final block = _currentChapterBlocks[index];
        final isPlayingSegment = index == _currentPlayingBlockIndex && (_isPlaying || _isLoadingAudio || _isPaused);

        return GestureDetector(
          onTap: () {
            setState(() {
              _currentPlayingBlockIndex = index;
              _isAutoPlaying = true;
              _isPaused = false;
            });
            _playCurrentBlock();
          },
          child: EpubBlockWidget(
            block: block,
            isDarkMode: _isDarkMode,
            isPlaying: isPlayingSegment,
            words: isPlayingSegment ? _currentWords : null,
            highlightedIndex: isPlayingSegment ? _highlightedWordIndex : -1,
          ),
        );
      },
    );
  }

  Widget _buildWelcome() {
    return Container(
      decoration: const BoxDecoration(
        image: DecorationImage(
          image: NetworkImage('https://images.unsplash.com/photo-1544716278-ca5e3f4abd8c?q=80&w=1000&auto=format&fit=crop'),
          fit: BoxFit.cover,
        ),
      ),
      child: Container(
        color: Colors.black.withOpacity(0.65),
        child: Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                const Text('VoxLibre', style: TextStyle(fontSize: 48, fontWeight: FontWeight.w900, color: Colors.white, letterSpacing: 2)),
                const SizedBox(height: 8),
                const Text('Votre lecteur EPUB IA unifié.', textAlign: TextAlign.center, style: TextStyle(fontSize: 16, height: 1.5, color: Colors.white70)),
                const SizedBox(height: 48),
                ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.orangeAccent.shade700,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(30)),
                  ),
                  icon: const Icon(Icons.auto_stories),
                  label: const Text('Ouvrir un livre (EPUB)', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                  onPressed: _pickEpubFile,
                ),
                const SizedBox(height: 32),
                if (_recentBooks.isNotEmpty) ...[
                  const Align(alignment: Alignment.centerLeft, child: Text('Reprendre', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.white))),
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
                          child: Container(
                            width: 110,
                            margin: const EdgeInsets.only(right: 16),
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(color: Colors.white.withOpacity(0.15), borderRadius: BorderRadius.circular(16)),
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                const Icon(Icons.book, color: Colors.white, size: 36),
                                const SizedBox(height: 8),
                                Text(b['title'] ?? '', style: const TextStyle(color: Colors.white, fontSize: 12), textAlign: TextAlign.center, maxLines: 3, overflow: TextOverflow.ellipsis),
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

  Widget _buildAudioControls() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: _isDarkMode ? const Color(0xFF2C2C2E) : Colors.white,
          borderRadius: BorderRadius.circular(30),
          boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.15), blurRadius: 20, offset: const Offset(0, 10))],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Icon(Icons.speed, size: 18, color: Colors.grey.shade500),
                Expanded(
                  child: Slider(
                    value: _playbackRate, min: 0.5, max: 2.0,
                    activeColor: Colors.orangeAccent.shade700,
                    inactiveColor: Colors.grey.shade300,
                    onChanged: (val) {
                      setState(() => _playbackRate = val);
                      _audioPlayer.setSpeed(val);
                    },
                  ),
                ),
                Text('${_playbackRate.toStringAsFixed(2)}x', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.orangeAccent.shade700, fontSize: 13)),
              ],
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                IconButton(icon: const Icon(Icons.replay_5_rounded, size: 28), onPressed: () => _seekRelative(-5), color: Colors.orangeAccent.shade700),
                if (_isLoadingAudio)
                  const Padding(padding: EdgeInsets.all(12), child: SizedBox(width: 32, height: 32, child: CircularProgressIndicator(color: Colors.orangeAccent, strokeWidth: 3)))
                else
                  GestureDetector(
                    onTap: _togglePlayPause,
                    child: Container(
                      width: 56, height: 56,
                      decoration: BoxDecoration(color: Colors.orangeAccent.shade700, shape: BoxShape.circle, boxShadow: [BoxShadow(color: Colors.orangeAccent.withOpacity(0.4), blurRadius: 10, offset: const Offset(0, 4))]),
                      child: Icon(_isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded, color: Colors.white, size: 32),
                    ),
                  ),
                IconButton(icon: const Icon(Icons.forward_5_rounded, size: 28), onPressed: () => _seekRelative(5), color: Colors.orangeAccent.shade700),
                IconButton(icon: const Icon(Icons.stop_rounded, size: 28), onPressed: _isAutoPlaying ? _stopAudio : null, color: _isAutoPlaying ? Colors.red.shade400 : Colors.grey),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ─── PREMIUM TYPOGRAPHY COMPONENT ───
enum BlockType { h1, h2, h3, h4, paragraph, quote }

class EpubBlockData {
  final BlockType type;
  final String content;
  EpubBlockData({required this.type, required this.content});
}

class EpubBlockWidget extends StatelessWidget {
  final EpubBlockData block;
  final bool isDarkMode;
  final bool isPlaying;
  final List<String>? words;
  final int highlightedIndex;

  const EpubBlockWidget({
    super.key,
    required this.block,
    required this.isDarkMode,
    this.isPlaying = false,
    this.words,
    this.highlightedIndex = -1,
  });

  @override
  Widget build(BuildContext context) {
    final textColor = isDarkMode ? Colors.white.withOpacity(0.9) : const Color(0xFF2C2C2C);
    
    // Beautiful highlight style: Bold + vibrant orange text
    final highlightStyle = TextStyle(
      color: Colors.orangeAccent.shade700,
      fontWeight: FontWeight.w900,
      decoration: TextDecoration.underline,
      decorationColor: Colors.orangeAccent.shade200,
      decorationStyle: TextDecorationStyle.wavy,
    );

    Widget textWidget;
    TextStyle baseStyle;

    switch (block.type) {
      case BlockType.h1:
        baseStyle = TextStyle(fontSize: 28, fontWeight: FontWeight.w900, color: textColor, height: 1.3, fontFamily: 'Georgia');
        break;
      case BlockType.h2:
        baseStyle = TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: textColor, height: 1.3, fontFamily: 'Georgia');
        break;
      case BlockType.h3:
        baseStyle = TextStyle(fontSize: 21, fontWeight: FontWeight.w600, color: textColor, height: 1.4, fontFamily: 'Georgia');
        break;
      case BlockType.h4:
        baseStyle = TextStyle(fontSize: 19, fontWeight: FontWeight.w500, color: textColor, height: 1.4, fontFamily: 'Georgia');
        break;
      case BlockType.quote:
        baseStyle = TextStyle(fontSize: 18, fontStyle: FontStyle.italic, color: textColor.withOpacity(0.7), height: 1.6, fontFamily: 'Georgia');
        break;
      case BlockType.paragraph:
      default:
        baseStyle = TextStyle(fontSize: 18, height: 1.85, color: textColor.withOpacity(0.85), fontFamily: 'Georgia');
        break;
    }

    if (isPlaying && words != null && words!.isNotEmpty) {
      textWidget = RichText(
        textAlign: block.type == BlockType.paragraph ? TextAlign.justify : TextAlign.left,
        text: TextSpan(
          style: baseStyle,
          children: List.generate(words!.length, (i) {
            final word = words![i];
            final isHighlighted = i == highlightedIndex;
            return TextSpan(
              text: i < words!.length - 1 ? '$word ' : word,
              style: isHighlighted ? highlightStyle : null,
            );
          }),
        ),
      );
    } else {
      textWidget = Text(
        block.content,
        style: baseStyle,
        textAlign: block.type == BlockType.paragraph ? TextAlign.justify : TextAlign.left,
      );
    }

    // Wrap headings with decorators
    if (block.type == BlockType.h1 || block.type == BlockType.h2) {
      return Container(
        margin: EdgeInsets.only(top: block.type == BlockType.h1 ? 40 : 32, bottom: 24),
        padding: const EdgeInsets.only(left: 16),
        decoration: BoxDecoration(
          border: Border(left: BorderSide(color: Colors.orangeAccent.shade700, width: 4)),
        ),
        child: textWidget,
      );
    }

    if (block.type == BlockType.quote) {
      return Container(
        margin: const EdgeInsets.symmetric(vertical: 20, horizontal: 8),
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: isDarkMode ? Colors.white.withOpacity(0.05) : Colors.black.withOpacity(0.03),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.format_quote_rounded, color: Colors.orangeAccent.shade700, size: 32),
            const SizedBox(width: 12),
            Expanded(child: textWidget),
          ],
        ),
      );
    }

    // Standard paragraph padding
    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: textWidget,
    );
  }
}
