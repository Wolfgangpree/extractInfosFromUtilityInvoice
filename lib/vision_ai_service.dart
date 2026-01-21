import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:http/http.dart' as http;
import 'package:js/js.dart' as js;
import 'package:js/js_util.dart' as js_util;
import 'ocr_service.dart';

// Define JavaScript functions/objects
@js.JS('window')
external dynamic get _window;

class VisionAIService {
  // Google Cloud Vision API endpoint
  static const String _visionApiUrl = 'https://vision.googleapis.com/v1/images:annotate';
  static const String _geminiApiBaseUrl =
      'https://generativelanguage.googleapis.com/v1beta';
  static const String _geminiListModelsUrl =
      'https://generativelanguage.googleapis.com/v1beta/models';
  
  /// Extract text from image using Google Cloud Vision API
  /// Requires API key to be set via setApiKey()
  static String? _apiKey;
  
  static void setApiKey(String? apiKey) {
    _apiKey = apiKey;
  }
  
  static String? getApiKey() => _apiKey;
  
  /// Extract text from image bytes using Vision API
  static Future<String> extractTextFromImage(Uint8List imageBytes) async {
    if (_apiKey == null || _apiKey!.isEmpty) {
      throw Exception('Google Cloud Vision API key not set. Please configure it in the settings.');
    }
    
    try {
      final base64Image = base64Encode(imageBytes);
      
      final requestBody = {
        'requests': [
          {
            'image': {
              'content': base64Image,
            },
            'features': [
              {
                'type': 'TEXT_DETECTION',
                'maxResults': 10,
              }
            ],
          }
        ]
      };
      
      final response = await http.post(
        Uri.parse('$_visionApiUrl?key=$_apiKey'),
        headers: {
          'Content-Type': 'application/json',
        },
        body: jsonEncode(requestBody),
      );
      
      if (response.statusCode != 200) {
        final errorBody = jsonDecode(response.body);
        throw Exception('Vision API error: ${errorBody['error']?['message'] ?? response.statusCode}');
      }
      
      final responseBody = jsonDecode(response.body);
      final textAnnotations = responseBody['responses']?[0]?['textAnnotations'];
      
      if (textAnnotations == null || textAnnotations.isEmpty) {
        return '';
      }
      
      // The first annotation contains the full text
      final fullText = textAnnotations[0]['description'] as String? ?? '';
      return fullText;
    } catch (e) {
      throw Exception('Failed to extract text from image using Vision AI: $e');
    }
  }
  
  /// Extract text from PDF bytes using Vision API
  /// Converts PDF pages to images first using PDF.js, then sends to Vision API
  static Future<String> extractTextFromPdf(Uint8List pdfBytes) async {
    if (!kIsWeb) {
      throw Exception('Vision AI PDF extraction is only supported on web.');
    }
    
    if (_apiKey == null || _apiKey!.isEmpty) {
      throw Exception('Google Cloud Vision API key not set. Please configure it in the settings.');
    }
    
    try {
      // Convert PDF to base64
      final base64 = base64Encode(pdfBytes);
      final dataUrl = 'data:application/pdf;base64,$base64';

      // Use JavaScript helper function from index.html
      final completer = Completer<String>();

      final jsCallback = js.allowInterop((dynamic error, dynamic text) {
        if (error != null) {
          if (!completer.isCompleted) {
            completer.completeError(Exception('PDF extraction error: $error'));
          }
        } else {
          if (!completer.isCompleted) {
            completer.complete(text as String? ?? '');
          }
        }
      });

      final extractFunction = js_util.getProperty(_window, 'extractTextFromPdfWithVisionAI');
      if (extractFunction == null) {
        throw Exception('extractTextFromPdfWithVisionAI JavaScript function not found. Make sure PDF.js is loaded.');
      }

      // Call the function: extractTextFromPdfWithVisionAI(dataUrl, apiKey, callback)
      js_util.callMethod(_window, 'extractTextFromPdfWithVisionAI', [dataUrl, _apiKey, jsCallback]);

      return await completer.future.timeout(
        const Duration(minutes: 5),
        onTimeout: () {
          if (!completer.isCompleted) {
            completer.completeError(TimeoutException('PDF OCR timed out after 5 minutes.'));
          }
          return ''; // Should not be reached
        },
      );
    } catch (e) {
      throw Exception('Failed to extract text from PDF using Vision AI: $e');
    }
  }
  
  /// Parse invoice data from extracted text (reuses OCR service parsing logic)
  static ExtractedData parseInvoiceData(String extractedText) {
    return OCRService.parseInvoiceData(extractedText);
  }

  /// List available Gemini models for the given API key.
  /// Filters to models supporting generateContent.
  static Future<List<String>> listGeminiModels({required String apiKey}) async {
    if (apiKey.isEmpty) {
      throw Exception('Gemini API key not set. Please configure it in the settings.');
    }

    final response = await http.get(
      Uri.parse('$_geminiListModelsUrl?key=$apiKey'),
      headers: {'Content-Type': 'application/json'},
    );

    if (response.statusCode != 200) {
      final errorBody = jsonDecode(response.body);
      throw Exception('Gemini API error: ${errorBody['error']?['message'] ?? response.statusCode}');
    }

    final responseBody = jsonDecode(response.body);
    final models = responseBody['models'] as List<dynamic>? ?? [];
    final filtered = <String>[];
    for (final model in models) {
      final name = model['name'] as String?;
      final methods = model['supportedGenerationMethods'] as List<dynamic>? ?? [];
      final supportsGenerate = methods.any((m) => m == 'generateContent');
      if (name != null && name.isNotEmpty && supportsGenerate) {
        filtered.add(name);
      }
    }
    return filtered;
  }

  static String _buildGeminiGenerateContentUrl(String modelName, String apiKey) {
    final normalized = modelName.startsWith('models/')
        ? modelName
        : 'models/$modelName';
    return '$_geminiApiBaseUrl/$normalized:generateContent?key=$apiKey';
  }

  /// Use Gemini to extract structured invoice data from OCR text.
  static Future<ExtractedData> extractDataWithGemini({
    required String extractedText,
    required String apiKey,
    String? modelName,
  }) async {
    if (apiKey.isEmpty) {
      throw Exception('Gemini API key not set. Please configure it in the settings.');
    }

    final prompt = '''
Du erhältst OCR-Text einer österreichischen Stromrechnung.
Extrahiere exakt folgende Felder und gib NUR valides JSON zurück:
{
  "address": "Vollständige Adresse inkl. Name, Straße, PLZ, Ort oder null",
  "zaehlpunktnummer": "33-stellige alphanumerische Zählpunktnummer (z.B. beginnt mit AT...) oder null",
  "kwh_aktuell": "aktueller Verbrauch in kWh als Zahl/Dezimalstring (z.B. 2573.1) oder null"
}

Wichtige Regeln:
- Wenn mehrere kWh-Werte vorkommen, nimm den nach 'aktuell' (oder 'current') beschriebenen Wert.
- Akzeptiere deutsche Zahlenformate (z.B. 2.573,1 -> 2573.1).
- Wenn ein Feld fehlt, setze es auf null.

OCR-Text:
${extractedText.trim()}
''';

    final requestBody = {
      'contents': [
        {
          'role': 'user',
          'parts': [
            {'text': prompt}
          ],
        }
      ],
      'generationConfig': {
        'temperature': 0.0,
        'topP': 0.1,
        'topK': 1,
        'maxOutputTokens': 512,
      },
    };

    final model = modelName?.isNotEmpty == true
        ? modelName!
        : 'models/gemini-1.5-flash-latest';

    final response = await http.post(
      Uri.parse(_buildGeminiGenerateContentUrl(model, apiKey)),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode(requestBody),
    );

    if (response.statusCode != 200) {
      final errorBody = jsonDecode(response.body);
      throw Exception('Gemini API error: ${errorBody['error']?['message'] ?? response.statusCode}');
    }

    final responseBody = jsonDecode(response.body);
    final candidates = responseBody['candidates'] as List<dynamic>? ?? [];
    if (candidates.isEmpty) {
      return OCRService.parseInvoiceData(extractedText);
    }

    final content = candidates[0]?['content'];
    final parts = content?['parts'] as List<dynamic>? ?? [];
    final text = parts.isNotEmpty ? (parts[0]?['text'] as String?) : null;
    if (text == null || text.trim().isEmpty) {
      return OCRService.parseInvoiceData(extractedText);
    }

    final jsonString = _extractJson(text);
    if (jsonString == null) {
      return OCRService.parseInvoiceData(extractedText);
    }

    final parsed = jsonDecode(jsonString) as Map<String, dynamic>;
    final address = parsed['address'] as String?;
    final zaehlpunktnummer = parsed['zaehlpunktnummer'] as String?;
    final kwhAktuell = parsed['kwh_aktuell'];

    String? kwhString;
    if (kwhAktuell is num) {
      kwhString = kwhAktuell.toString();
    } else if (kwhAktuell is String) {
      kwhString = kwhAktuell.trim();
    }

    return ExtractedData(
      address: address,
      zaehlpunktnummer: zaehlpunktnummer,
      kwhConsumed: kwhString,
    );
  }

  static String? _extractJson(String text) {
    final start = text.indexOf('{');
    final end = text.lastIndexOf('}');
    if (start == -1 || end == -1 || end <= start) {
      return null;
    }
    return text.substring(start, end + 1);
  }
}
