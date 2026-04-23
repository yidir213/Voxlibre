import 'package:flutter/material.dart';
import 'package:just_audio_background/just_audio_background.dart';
import 'screens/reader_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await JustAudioBackground.init(
    androidNotificationChannelId: 'com.voxlibre.audio.channel',
    androidNotificationChannelName: 'VoxLibre Audio',
    androidNotificationOngoing: true,
    androidNotificationIcon: 'mipmap/ic_launcher',
  );

  runApp(const VoxLibreApp());
}

class VoxLibreApp extends StatelessWidget {
  const VoxLibreApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'VoxLibre',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.orange),
        useMaterial3: true,
      ),
      home: const ReaderScreen(),
    );
  }
}
