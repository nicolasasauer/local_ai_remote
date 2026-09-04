import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart';
import 'package:uuid/uuid.dart';

import '../models/chat.dart';

const _uuid = Uuid();

/// Anhänge werden in der App aufbereitet: Bilder gehen roh ans Backend, PDFs
/// nicht — kein Inferenz-Server nimmt PDFs an. Der Text wird deshalb hier
/// extrahiert und als Kontext mitgeschickt.
class AttachmentPicker {
  const AttachmentPicker();

  Future<List<Attachment>> pickImages() async {
    // file_picker 12: statische API, liefert direkt die Liste — bei Abbruch
    // ist sie leer statt null.
    final files = await FilePicker.pickFiles(type: FileType.image);

    final out = <Attachment>[];
    for (final file in files) {
      final path = file.path;
      if (path == null) continue;
      out.add(
        Attachment(
          id: _uuid.v4(),
          messageId: '',
          kind: AttachmentKind.image,
          filename: file.name,
          path: path,
          // length() statt des früheren size-Feldes: seit file_picker 12
          // wird die Größe erst beim Zugriff ermittelt.
          bytes: await file.length(),
        ),
      );
    }
    return out;
  }

  Future<List<Attachment>> pickDocuments() async {
    final files = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['pdf', 'txt', 'md'],
    );

    final out = <Attachment>[];
    for (final file in files) {
      final path = file.path;
      if (path == null) continue;

      final isPdf = file.extension?.toLowerCase() == 'pdf';
      final extraction =
          isPdf ? await extractPdfText(path) : await _readPlainText(path);

      out.add(
        Attachment(
          id: _uuid.v4(),
          messageId: '',
          kind: isPdf ? AttachmentKind.pdf : AttachmentKind.text,
          filename: file.name,
          path: path,
          bytes: await file.length(),
          extractedText: extraction.text,
          // Grobe Schätzung; nach der ersten Antwort korrigiert der
          // TokenEstimator den Faktor anhand der gemeldeten Prompt-Tokens.
          estimatedTokens: extraction.text == null
              ? null
              : (extraction.text!.length / 4).round(),
        ),
      );
    }
    return out;
  }

  Future<PdfExtraction> extractPdfText(String path) async {
    try {
      final bytes = await File(path).readAsBytes();
      final document = PdfDocument(inputBytes: bytes);
      final pages = document.pages.count;
      final text = PdfTextExtractor(document).extractText();
      document.dispose();

      final cleaned = text.trim();
      if (cleaned.isEmpty) {
        // Typischer Fall: gescanntes PDF ohne Textebene. Das muss der Nutzer
        // wissen, sonst schickt er eine leere Datei und wundert sich.
        return PdfExtraction(
          pages: pages,
          text: null,
          problem: 'Das PDF enthält keine Textebene — vermutlich ein Scan. '
              'Ohne OCR lässt sich daraus nichts mitschicken.',
        );
      }
      return PdfExtraction(pages: pages, text: cleaned);
    } catch (e) {
      return PdfExtraction(
        pages: null,
        text: null,
        problem: 'PDF konnte nicht gelesen werden: $e',
      );
    }
  }

  Future<PdfExtraction> _readPlainText(String path) async {
    try {
      return PdfExtraction(pages: null, text: await File(path).readAsString());
    } catch (e) {
      return PdfExtraction(
        pages: null,
        text: null,
        problem: 'Datei konnte nicht gelesen werden: $e',
      );
    }
  }
}

class PdfExtraction {
  const PdfExtraction({required this.pages, required this.text, this.problem});

  final int? pages;
  final String? text;
  final String? problem;
}
