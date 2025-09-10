import 'dart:io';
import 'package:archive/archive_io.dart';

class AndroidDownloadsService {
  /// Zips [sourceDir] contents into [fileName] and saves under
  /// Downloads/BudgetBuddy on Android. Returns saved File or null on failure.
  static Future<File?> zipToDownloads({
    required Directory sourceDir,
    required String fileName,
  }) async {
    try {
      // Best-effort Android public Downloads directory path
      // Note: On some devices/versions this may vary. Adjust if needed.
      final downloadsPath = '/storage/emulated/0/Download';
      final targetDir = Directory('$downloadsPath/BudgetBuddy');
      await targetDir.create(recursive: true);
      final outFile = File('${targetDir.path}/$fileName');

      // Build zip from directory
      final encoder = ZipFileEncoder();
      encoder.create(outFile.path);
      encoder.addDirectory(sourceDir, includeDirName: false);
      encoder.close();
      return outFile;
    } catch (_) {
      return null;
    }
  }
}
