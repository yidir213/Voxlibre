import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:epub_view/epub_view.dart';
import 'package:file_picker/file_picker.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import '../services/mistral_service.dart';
import 'settings_screen.dart';

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
  bool _isAutoPlaying = false; // Vrai si le mode lecture en chaîne est actif
  bool _isPaused = false;
  
  double _playbackRate = 1.0;

  String _currentChapterTitle = '';
  List<String> _chapterParagraphs = [];
  List<GlobalKey> _paragraphKeys = [];
  int _readingIndex = -1; // Index du paragraphe en cours de lecture

  // Préchargement audio pour éviter les coupures
  final Map<int, List<int>> _audioCache = {};
  int _currentlyFetchingIndex = -1;

  @override
  void initState() {
    super.initState();
    _audioPlayer.onPlayerStateChanged.listen((state) {
      if (mounted) {
        setState(() {
          _isPlaying = state == PlayerState.playing;
          if (state == PlayerState.paused) {
            _isPaused = true;
          } else if (state == PlayerState.playing) {
            _isPaused = false;
          }
        });
      }
    });

    _audioPlayer.onPlayerComplete.listen((_) {
      if (mounted && _isAutoPlaying && !_isPaused) {
        if (_readingIndex < _chapterParagraphs.length - 1) {
          setState(() {
            _readingIndex++;
          });
          _scrollToCurrent();
          _playCurrentChunk();
        } else {
          setState(() {
            _isAutoPlaying = false;
            _readingIndex = -1;
          });
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Fin du chapitre atteinte.')),
          );
        }
      }
    });
  }

  Future<void> _pickEpubFile() async {
    FilePickerResult? result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['epub'],
    );

    if (result != null && result.files.single.path != null) {
      final file = File(result.files.single.path!);
      final bytes = file.readAsBytesSync();
      
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
        _currentChapterIndex = 0;
      });
      
      _loadChapter(_currentChapterIndex);
    }
  }

  void _loadChapter(int index) {
    if (_flatChapters.isEmpty) return;
    if (index < 0 || index >= _flatChapters.length) return;

    final chap = _flatChapters[index];
    final title = chap.Title ?? 'Chapitre ${index + 1}';
    final htmlContent = chap.HtmlContent ?? '';

    String cleanText = htmlContent.replaceAll(RegExp(r'<[^>]*>'), ' ');
    cleanText = cleanText.replaceAll('&nbsp;', ' ')
                         .replaceAll('&amp;', '&')
                         .replaceAll('&lt;', '<')
                         .replaceAll('&gt;', '>')
                         .replaceAll('&quot;', '"')
                         .replaceAll('&#39;', "'");
                         
    List<String> rawChunks = cleanText.split(RegExp(r'\n\s*\n'));
    List<String> paragraphs = rawChunks
        .map((p) => p.replaceAll(RegExp(r'\s+'), ' ').trim())
        .where((p) => p.isNotEmpty)
        .toList();

    // Suppression experte du titre
    String cleanTitleLow = title.toLowerCase().replaceAll(RegExp(r'[^\w]'), '').trim();
    if (cleanTitleLow.isNotEmpty) {
      while (paragraphs.isNotEmpty) {
        String pLow = paragraphs.first.toLowerCase().replaceAll(RegExp(r'[^\w]'), '').trim();
        if (pLow.isEmpty || pLow == cleanTitleLow || pLow.contains(cleanTitleLow) || cleanTitleLow.contains(pLow)) {
          paragraphs.removeAt(0); // Suppression si texte correspond
        } else {
          break;
        }
      }
    }

    if (paragraphs.isEmpty) {
      paragraphs = ["(Aucun texte lisible dans cette section)"];
    }

    setState(() {
      _currentChapterIndex = index;
      _currentChapterTitle = title;
      _chapterParagraphs = paragraphs;
      _paragraphKeys = List.generate(paragraphs.length, (_) => GlobalKey());
      _readingIndex = -1;
      _audioCache.clear();
      _isPaused = false;
    });

    _stopAudio();
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
      await _audioPlayer.resume();
      await _audioPlayer.setPlaybackRate(_playbackRate); // remet la vitesse après pause
      setState(() {
        _isPaused = false;
        _isAutoPlaying = true;
      });
    } else {
      int startIdx = _readingIndex >= 0 ? _readingIndex : 0;
      _playFromIndex(startIdx);
    }
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
      await _audioPlayer.play(BytesSource(Uint8List.fromList(audioBytes)));
      await _audioPlayer.setPlaybackRate(_playbackRate);

      // Préchargement
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
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 1,
        title: Text(
          _epubBook == null ? 'VoxLibre' : _currentChapterTitle,
          style: const TextStyle(color: Colors.black87, fontWeight: FontWeight.bold, fontSize: 18),
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings, color: Colors.black54),
            onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const SettingsScreen())),
            tooltip: 'Paramètres',
          ),
          IconButton(
            icon: const Icon(Icons.folder_open, color: Colors.deepPurple),
            onPressed: _pickEpubFile,
            tooltip: 'Ouvrir un EPUB',
          ),
        ],
      ),
      body: _epubBook == null ? _buildWelcome() : _buildNativeReader(),
      bottomNavigationBar: _epubBook == null ? null : _buildBottomBar(),
    );
  }

  Widget _buildWelcome() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.auto_stories, size: 80, color: Colors.deepPurple),
          const SizedBox(height: 24),
          const Text('VoxLibre', style: TextStyle(fontSize: 32, fontWeight: FontWeight.bold)),
          const SizedBox(height: 16),
          ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.deepPurple,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
            ),
            onPressed: _pickEpubFile,
            icon: const Icon(Icons.folder_open),
            label: const Text('Sélectionner un livre EPUB'),
          ),
        ],
      ),
    );
  }

  Widget _buildNativeReader() {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 100), // Espace en bas
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: List.generate(_chapterParagraphs.length, (index) {
          final text = _chapterParagraphs[index];
          final isReading = _readingIndex == index && (_isPlaying || _isLoadingAudio || _isPaused);
          return Container(
            key: _paragraphKeys[index],
            child: CodeParagraph(
              text: text,
              isReading: isReading,
              onTap: () {
                _playFromIndex(index);
              },
            ),
          );
        }),
      ),
    );
  }

  Widget _buildBottomBar() {
    return Container(
      color: Colors.grey.shade100,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // SCROLL DE VITESSE (CONTINU, PAS DE VALEURS FIGÉES)
            Row(
              children: [
                const Text('Vitesse:', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.black54)),
                Expanded(
                  child: Slider(
                    value: _playbackRate,
                    min: 0.5,
                    max: 2.0,
                    // "divisions" est VOLONTAIREMENT RETIRÉ pour autoriser 0.8, 1.35, etc.
                    activeColor: Colors.deepPurple,
                    inactiveColor: Colors.deepPurple.shade100,
                    onChanged: (val) {
                      setState(() => _playbackRate = val);
                      _audioPlayer.setPlaybackRate(val);
                    },
                  ),
                ),
                Text('${_playbackRate.toStringAsFixed(2)}x', style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.deepPurple, fontSize: 13)),
              ],
            ),
            
            // CONTRÔLES LECTURE
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                IconButton(
                  icon: const Icon(Icons.arrow_back_ios),
                  onPressed: _currentChapterIndex > 0 ? _prevChapter : null,
                  color: Colors.deepPurple,
                ),
                
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _isLoadingAudio
                      ? const SizedBox(width: 48, height: 48, child: Padding(
                          padding: EdgeInsets.all(12),
                          child: CircularProgressIndicator(color: Colors.deepPurple, strokeWidth: 3),
                        ))
                      : FloatingActionButton(
                          backgroundColor: _isPlaying ? Colors.orange : Colors.deepPurple,
                          foregroundColor: Colors.white,
                          elevation: 2,
                          onPressed: _togglePlayPause,
                          child: Icon(_isPlaying ? Icons.pause : Icons.play_arrow, size: 28),
                        ),
                    const SizedBox(width: 12),
                    // Bouton Stop
                    if (_isPlaying || _isPaused || _isLoadingAudio)
                      IconButton(
                        icon: const Icon(Icons.stop_circle, size: 36, color: Colors.redAccent),
                        onPressed: _stopAudio,
                      ),
                  ],
                ),

                IconButton(
                  icon: const Icon(Icons.arrow_forward_ios),
                  onPressed: _currentChapterIndex < _flatChapters.length - 1 ? _nextChapter : null,
                  color: Colors.deepPurple,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class CodeParagraph extends StatelessWidget {
  final String text;
  final bool isReading;
  final VoidCallback onTap;

  const CodeParagraph({
    super.key,
    required this.text,
    required this.isReading,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        margin: const EdgeInsets.only(bottom: 12),
        decoration: BoxDecoration(
          color: isReading ? Colors.deepPurple.withOpacity(0.15) : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
          border: isReading 
            ? Border.all(color: Colors.deepPurple.withOpacity(0.5), width: 1.5) 
            : Border.all(color: Colors.transparent, width: 1.5),
        ),
        padding: const EdgeInsets.all(12),
        child: Text(
          text,
          style: TextStyle(
            color: Colors.black87,
            fontSize: 19,
            height: 1.6,
            fontFamily: 'Georgia',
            fontWeight: isReading ? FontWeight.w500 : FontWeight.normal,
          ),
        ),
      ),
    );
  }
}
