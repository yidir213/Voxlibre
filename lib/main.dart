import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:just_audio_background/just_audio_background.dart';
import 'screens/reader_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    await dotenv.load(fileName: ".env");
  } catch (e) {
    debugPrint("Could not load .env file. Make sure it exists.");
  }
  
  /*
  try {
    await JustAudioBackground.init(
      androidNotificationChannelId: 'com.voxlibre.audio.channel',
      androidNotificationChannelName: 'VoxLibre Audio',
      androidNotificationOngoing: true,
    );
  } catch (e) {
    debugPrint("Background audio init failed: $e");
  }
  */
  
  runApp(const VoxLibreApp());
}

class VoxLibreApp extends StatelessWidget {
  const VoxLibreApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'VoxLibre - EPUB & IA',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
        useMaterial3: true,
      ),
      home: const ReaderScreen(),
    );
  }
}
