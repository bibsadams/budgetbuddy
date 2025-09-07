import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:pdf/widgets.dart' as pw;

class ReportExportService {
  // Returns the saved file path
  static Future<String> exportCsv({
    required String filename,
    required List<List<String>> rows,
  }) async {
    final content = rows.map((r) => r.map(_escapeCsv).join(',')).join('\n');
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/$filename.csv');
    await file.writeAsString(content, flush: true);
    await Share.shareXFiles([XFile(file.path)], text: 'BudgetBuddy report');
    return file.path;
  }

  static String _escapeCsv(String v) {
    if (v.contains(',') || v.contains('"') || v.contains('\n')) {
      final escaped = v.replaceAll('"', '""');
      return '"$escaped"';
    }
    return v;
  }

  static Future<String> exportPdf({
    required String filename,
    required String title,
    required Map<String, double> byCategory,
    required Map<String, double> bySubcategory,
  }) async {
    final doc = pw.Document();

    pw.Widget tableFromMap(String heading, Map<String, double> data) {
      final entries = data.entries.toList()
        ..sort((a, b) => b.value.compareTo(a.value));
      return pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.Text(
            heading,
            style: pw.TextStyle(fontSize: 16, fontWeight: pw.FontWeight.bold),
          ),
          pw.SizedBox(height: 6),
          pw.Table(
            border: pw.TableBorder.all(width: 0.5),
            columnWidths: {0: pw.FlexColumnWidth(2), 1: pw.FlexColumnWidth(1)},
            children: [
              pw.TableRow(
                children: [
                  pw.Padding(
                    padding: const pw.EdgeInsets.all(4),
                    child: pw.Text(
                      'Name',
                      style: pw.TextStyle(fontWeight: pw.FontWeight.bold),
                    ),
                  ),
                  pw.Padding(
                    padding: const pw.EdgeInsets.all(4),
                    child: pw.Text(
                      'Amount',
                      style: pw.TextStyle(fontWeight: pw.FontWeight.bold),
                    ),
                  ),
                ],
              ),
              ...entries.map(
                (e) => pw.TableRow(
                  children: [
                    pw.Padding(
                      padding: const pw.EdgeInsets.all(4),
                      child: pw.Text(e.key),
                    ),
                    pw.Padding(
                      padding: const pw.EdgeInsets.all(4),
                      child: pw.Text('₱${e.value.toStringAsFixed(2)}'),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ],
      );
    }

    doc.addPage(
      pw.MultiPage(
        build: (context) => [
          pw.Text(
            title,
            style: pw.TextStyle(fontSize: 20, fontWeight: pw.FontWeight.bold),
          ),
          pw.SizedBox(height: 12),
          tableFromMap('By Category', byCategory),
          pw.SizedBox(height: 12),
          tableFromMap('By Subcategory', bySubcategory),
        ],
      ),
    );

    final bytes = await doc.save();
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/$filename.pdf');
    await file.writeAsBytes(bytes, flush: true);
    await Share.shareXFiles([XFile(file.path)], text: 'BudgetBuddy report');
    return file.path;
  }
}
