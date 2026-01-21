import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:js/js.dart' as js;
import 'package:js/js_util.dart' as js_util;

// Define JavaScript functions/objects
@js.JS('window')
external dynamic get _window;

// Removed unused external declaration

class ExtractedData {
  final String? address;
  final String? zaehlpunktnummer;
  final String? kwhConsumed;

  ExtractedData({
    this.address,
    this.zaehlpunktnummer,
    this.kwhConsumed,
  });
}

class OCRService {
  /// Extract text from image bytes using Tesseract.js
  static Future<String> extractTextFromImage(Uint8List imageBytes) async {
    try {
      final base64 = base64Encode(imageBytes);
      final dataUrl = 'data:image/png;base64,$base64';
      return await _performTesseractOCR(dataUrl);
    } catch (e) {
      throw Exception('Failed to extract text from image: $e');
    }
  }

  /// Extract text from PDF bytes using Tesseract.js
  /// Converts PDF pages to images first using PDF.js, then performs OCR
  static Future<String> extractTextFromPdf(Uint8List pdfBytes) async {
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

      // Call the JavaScript function directly from window
      if (!js_util.hasProperty(_window, 'extractTextFromPdf')) {
        throw Exception('extractTextFromPdf JavaScript function not found. Make sure PDF.js and Tesseract.js are loaded.');
      }

      // Call the function directly: extractTextFromPdf(dataUrl, callback)
      js_util.callMethod(_window, 'extractTextFromPdf', [dataUrl, jsCallback]);

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
      throw Exception('Failed to extract text from PDF: $e');
    }
  }

  /// Perform OCR using Tesseract.js via JavaScript interop
  static Future<String> _performTesseractOCR(String imageData) async {
    final completer = Completer<String>();

    try {
      // Call Tesseract.js via JavaScript
      final tesseract = js_util.getProperty(_window, 'Tesseract');
      if (tesseract == null) {
        throw Exception('Tesseract.js not loaded. Please check index.html');
      }

      // Tesseract.recognize(imageData, 'deu+eng', { logger: m => console.log(m) })
      final promise = js_util.callMethod(tesseract, 'recognize', [
        imageData,
        'deu+eng', // German + English
        js_util.jsify({
          'logger': js.allowInterop((dynamic m) {
            // print('Tesseract: ${m.toString()}'); // Too verbose for console
          })
        })
      ]);

      // Handle promise
      js_util.callMethod(promise, 'then', [
        js.allowInterop((dynamic result) {
          final data = js_util.getProperty(result, 'data');
          final text = js_util.getProperty(data, 'text') as String? ?? '';
          if (!completer.isCompleted) {
            completer.complete(text);
          }
        })
      ]);

      js_util.callMethod(promise, 'catch', [
        js.allowInterop((error) {
          if (!completer.isCompleted) {
            completer.completeError(Exception('Tesseract OCR error: ${error.toString()}'));
          }
        })
      ]);
    } catch (e) {
      if (!completer.isCompleted) {
        completer.completeError(e);
      }
    }

    return completer.future.timeout(
      const Duration(minutes: 5),
      onTimeout: () {
        if (!completer.isCompleted) {
          completer.completeError(TimeoutException('Tesseract OCR timed out after 5 minutes.'));
        }
        return ''; // Should not be reached
      },
    );
  }

  /// Parse extracted text to find address, Zählpunktnummer, and kWh
  /// Improved parsing for German number formats and specific patterns
  static ExtractedData parseInvoiceData(String extractedText) {
    String? address;
    String? zaehlpunktnummer;
    String? kwhConsumed;

    final lines = extractedText.split('\n').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
    final text = extractedText.toLowerCase();

    // Extract address - generic Austrian address pattern
    // Austrian addresses typically: Name, Street Number, Postal Code City
    // Postal codes in Austria are 4 digits (e.g., 1010, 5020, 8010)
    
    // Pattern 1: Look for Austrian postal code (4 digits) followed by city name
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      // Match Austrian postal code (4 digits) followed by city name
      final postalMatch = RegExp(r'^(\d{4})\s+([A-ZÄÖÜ][a-zäöüß]+(?:[\s-][A-ZÄÖÜ][a-zäöüß]+)*)$').firstMatch(line);
      if (postalMatch != null) {
        final addressParts = <String>[];
        
        // Look backwards for street and house number
        if (i > 0) {
          final prevLine = lines[i - 1];
          // Match street name with house number (e.g., "Hauptstraße 12", "Karl-Roll-Str. 16")
          final streetMatch = RegExp(r'([A-ZÄÖÜ][a-zäöüß-]+(?:\.|Straße|Strasse|Platz|Weg|Gasse|Allee|Ring|Str\.?))\s+(\d+[a-z]?)', caseSensitive: false).firstMatch(prevLine);
          if (streetMatch != null) {
            addressParts.add(prevLine);
            
            // Look one more line back for name
            if (i > 1) {
              final nameLine = lines[i - 2];
              // Match name pattern (Firstname Lastname)
              if (RegExp(r'^[A-ZÄÖÜ][a-zäöüß]+\s+[A-ZÄÖÜ][a-zäöüß]+$').hasMatch(nameLine) &&
                  !nameLine.toLowerCase().contains('straße') &&
                  !nameLine.toLowerCase().contains('strasse')) {
                addressParts.insert(0, nameLine);
              }
            }
          }
        }
        
        // Add postal code and city
        addressParts.add(line);
        
        if (addressParts.length >= 2) {
          address = addressParts.join(', ');
          break;
        }
      }
    }
    
    // Pattern 2: Look for street with number, then postal code + city on next line
    if (address == null) {
      for (var i = 0; i < lines.length - 1; i++) {
        final line = lines[i];
        final nextLine = lines[i + 1];
        
        // Check if current line has street + number
        final streetMatch = RegExp(r'([A-ZÄÖÜ][a-zäöüß-]+(?:\.|Straße|Strasse|Platz|Weg|Gasse|Allee|Ring|Str\.?))\s+(\d+[a-z]?)', caseSensitive: false).firstMatch(line);
        // Check if next line has postal code + city
        final postalMatch = RegExp(r'^(\d{4})\s+([A-ZÄÖÜ][a-zäöüß]+(?:[\s-][A-ZÄÖÜ][a-zäöüß]+)*)$').firstMatch(nextLine);
        
        if (streetMatch != null && postalMatch != null) {
          final addressParts = <String>[];
          
          // Check previous line for name
          if (i > 0) {
            final prevLine = lines[i - 1];
            if (RegExp(r'^[A-ZÄÖÜ][a-zäöüß]+\s+[A-ZÄÖÜ][a-zäöüß]+$').hasMatch(prevLine) &&
                !prevLine.toLowerCase().contains('straße') &&
                !prevLine.toLowerCase().contains('strasse')) {
              addressParts.add(prevLine);
            }
          }
          
          addressParts.add(line);
          addressParts.add(nextLine);
          
          if (addressParts.length >= 2) {
            address = addressParts.join(', ');
            break;
          }
        }
      }
    }
    
    // Pattern 3: Single line address pattern
    if (address == null) {
      final singleLinePattern = RegExp(
        r'([A-ZÄÖÜ][a-zäöüß]+\s+[A-ZÄÖÜ][a-zäöüß]+)?,?\s*([A-ZÄÖÜ][a-zäöüß-]+(?:\.|Straße|Strasse|Platz|Weg|Gasse|Allee|Ring|Str\.?))\s+(\d+[a-z]?),?\s*(\d{4})\s+([A-ZÄÖÜ][a-zäöüß]+(?:[\s-][A-ZÄÖÜ][a-zäöüß]+)*)',
        caseSensitive: false,
      );
      
      for (var line in lines) {
        final match = singleLinePattern.firstMatch(line);
        if (match != null) {
          final parts = <String>[];
          if (match.group(1) != null) parts.add(match.group(1)!);
          parts.add('${match.group(2)} ${match.group(3)}');
          parts.add('${match.group(4)} ${match.group(5)}');
          address = parts.join(', ');
          break;
        }
      }
    }

    // Extract Zählpunktnummer (meter point number)
    // Generic pattern: 33 characters alphanumeric, typically starts with AT
    // Can be continuous or split into groups (e.g., "AT 004000 05020 00000 00000 00101 27094")
    
    // Pattern 1: With label (Zählpunktnummer, ZP-Nr, etc.) - can be split or continuous
    final labeledPatternSplit = RegExp(
      r'(?:zählpunkt|zählpunktnummer|zp-nr|zp\s*nr|zählernummer|metering\s*point)[:\s]*(AT(?:\s+[A-Z0-9]+)+)',
      caseSensitive: false,
    );
    final labeledMatchSplit = labeledPatternSplit.firstMatch(extractedText);
    if (labeledMatchSplit != null && labeledMatchSplit.group(1) != null) {
      final zpWithSpaces = labeledMatchSplit.group(1)!;
      final zp = zpWithSpaces.replaceAll(RegExp(r'\s+'), ''); // Remove all spaces
      if (zp.length == 33) {
        zaehlpunktnummer = zp;
      }
    }
    
    // Pattern 1b: With label - continuous 33-char string
    if (zaehlpunktnummer == null) {
      final labeledPattern = RegExp(
        r'(?:zählpunkt|zählpunktnummer|zp-nr|zp\s*nr|zählernummer|metering\s*point)[:\s]*([A-Z0-9]{33})',
        caseSensitive: false,
      );
      final labeledMatch = labeledPattern.firstMatch(extractedText);
      if (labeledMatch != null && labeledMatch.group(1) != null) {
        final zp = labeledMatch.group(1)!;
        if (zp.length == 33) {
          zaehlpunktnummer = zp.trim();
        }
      }
    }
    
    // Pattern 2: Split format - "AT" followed by space-separated groups
    // Example: "AT 004000 05020 00000 00000 00101 27094"
    if (zaehlpunktnummer == null) {
      // Match "AT" followed by one or more groups of alphanumeric characters separated by spaces
      final splitPattern = RegExp(r'\b(AT(?:\s+[A-Z0-9]+)+)\b', caseSensitive: true);
      final matches = splitPattern.allMatches(extractedText);
      for (var match in matches) {
        final zpWithSpaces = match.group(1);
        if (zpWithSpaces != null) {
          // Remove all spaces and check if total length is 33
          final zp = zpWithSpaces.replaceAll(RegExp(r'\s+'), '');
          if (zp.length == 33) {
            // Filter out common false positives
            // Zählpunktnummer typically has a mix of letters and numbers, not just numbers
            if (RegExp(r'[A-Z]').hasMatch(zp) && RegExp(r'[0-9]').hasMatch(zp)) {
              zaehlpunktnummer = zp;
              break;
            }
          }
        }
      }
    }
    
    // Pattern 3: Standalone continuous 33-character alphanumeric strings starting with AT
    if (zaehlpunktnummer == null) {
      final atPattern = RegExp(r'\b(AT[A-Z0-9]{31})\b', caseSensitive: true);
      final matches = atPattern.allMatches(extractedText);
      for (var match in matches) {
        final zp = match.group(1);
        if (zp != null && zp.length == 33) {
          // Filter out common false positives (dates, IDs that aren't Zählpunktnummer)
          // Zählpunktnummer typically has a mix of letters and numbers, not just numbers
          if (RegExp(r'[A-Z]').hasMatch(zp) && RegExp(r'[0-9]').hasMatch(zp)) {
            zaehlpunktnummer = zp.trim();
            break;
          }
        }
      }
    }
    
    // Pattern 4: Any 33-character alphanumeric string (more permissive)
    if (zaehlpunktnummer == null) {
      final genericPattern = RegExp(r'\b([A-Z0-9]{33})\b', caseSensitive: true);
      final matches = genericPattern.allMatches(extractedText);
      for (var match in matches) {
        final zp = match.group(1);
        if (zp != null && zp.length == 33) {
          // Filter out pure numbers (likely not Zählpunktnummer)
          // Zählpunktnummer should have at least some letters
          if (RegExp(r'[A-Z]').hasMatch(zp)) {
            zaehlpunktnummer = zp.trim();
            break;
          }
        }
      }
    }

    // Extract kWh consumption
    // Handle German number format: 2.573,1 means 2573.1 (dot = thousands separator, comma = decimal separator)
    // Prioritize "aktuell" (current) value over "Vorperiode" (previous period)
    
    // Helper function to normalize and parse kWh value
    double? parseKwhValue(String kwhStr) {
      try {
        String normalized = kwhStr;
        
        // If contains both dot and comma, assume German format: dot=thousands separator, comma=decimal separator
        if (normalized.contains('.') && normalized.contains(',')) {
          normalized = normalized.replaceAll('.', ''); // Remove thousands separator
          normalized = normalized.replaceAll(',', '.'); // Convert decimal separator
        } else if (normalized.contains(',')) {
          // Only comma: check if it's decimal or thousands separator
          if (RegExp(r',\d{1,2}$').hasMatch(normalized)) {
            normalized = normalized.replaceAll('.', '');
            normalized = normalized.replaceAll(',', '.');
          } else {
            normalized = normalized.replaceAll(',', '');
          }
        } else if (normalized.contains('.')) {
          if (RegExp(r'\.\d{1,2}$').hasMatch(normalized)) {
            // Keep as is (decimal point)
          } else {
            normalized = normalized.replaceAll('.', '');
          }
        }
        
        final kwhValue = double.parse(normalized);
        // Filter reasonable values (between 1 and 100000)
        if (kwhValue > 1 && kwhValue < 100000) {
          return kwhValue;
        }
      } catch (e) {
        // Ignore parse errors
      }
      return null;
    }
    
    // Pattern to find kWh values with context (look for "aktuell" or "Vorperiode" nearby)
    final kwhPatterns = [
      // Pattern with context: "aktuell 2.573,1 kWh" or "aktuell: 2.573,1 kWh"
      RegExp(r'(aktuell|current)[:\s]+(\d{1,3}(?:\.\d{3})*,\d+)\s*kwh', caseSensitive: false),
      RegExp(r'(aktuell|current)[:\s]+(\d{1,3}(?:,\d{3})*\.\d+)\s*kwh', caseSensitive: false),
      RegExp(r'(aktuell|current)[:\s]+(\d{1,3}(?:[.,]\d{3})*)\s*kwh', caseSensitive: false),
      // Pattern: "Strom 2.573,1 kWh" or "Verbrauch 2.573,1 kWh"
      RegExp(r'(?:strom|verbrauch|gesamtverbrauch|kwh|kwh-verbrauch|energieverbrauch)[:\s]*(\d{1,3}(?:\.\d{3})*,\d+)\s*kwh', caseSensitive: false),
      // Pattern: "2.573,1 kWh" (German format with thousands separator and decimal comma)
      RegExp(r'(\d{1,3}(?:\.\d{3})*,\d+)\s*kwh', caseSensitive: false),
      // Pattern: "2573.1 kWh" (English format)
      RegExp(r'(\d{1,3}(?:,\d{3})*\.\d+)\s*kwh', caseSensitive: false),
      // Pattern: "2573 kWh" (no decimals)
      RegExp(r'(\d{1,3}(?:[.,]\d{3})*)\s*kwh', caseSensitive: false),
    ];
    
    double? aktuellKwh;
    String? aktuellKwhStr;
    double? maxKwh;
    String? bestKwhStr;
    
    // First pass: Look for "aktuell" values (highest priority)
    for (var pattern in kwhPatterns.take(3)) {
      final matches = pattern.allMatches(extractedText);
      for (var match in matches) {
        if (match.groupCount >= 2) {
          final kwhStr = match.group(2);
          if (kwhStr != null) {
            final kwhValue = parseKwhValue(kwhStr);
            if (kwhValue != null) {
              if (aktuellKwh == null || kwhValue > aktuellKwh) {
                aktuellKwh = kwhValue;
                aktuellKwhStr = kwhValue.toStringAsFixed(1);
              }
            }
          }
        }
      }
    }
    
    // If we found an "aktuell" value, use it
    if (aktuellKwh != null) {
      kwhConsumed = aktuellKwhStr;
    } else {
      // Second pass: Look for all kWh values, but exclude those near "Vorperiode"
      for (var pattern in kwhPatterns.skip(3)) {
        final matches = pattern.allMatches(extractedText);
        for (var match in matches) {
          if (match.groupCount >= 1) {
            final kwhStr = match.group(1) ?? match.group(0);
            if (kwhStr != null) {
              // Check context around the match to see if it's near "Vorperiode"
              final matchStart = match.start;
              final matchEnd = match.end;
              final contextStart = (matchStart - 50).clamp(0, extractedText.length);
              final contextEnd = (matchEnd + 50).clamp(0, extractedText.length);
              final context = extractedText.substring(contextStart, contextEnd).toLowerCase();
              
              // Skip if it's near "Vorperiode" or "previous"
              if (context.contains('vorperiode') || context.contains('previous')) {
                continue;
              }
              
              final kwhValue = parseKwhValue(kwhStr);
              if (kwhValue != null) {
                if (maxKwh == null || kwhValue > maxKwh) {
                  maxKwh = kwhValue;
                  bestKwhStr = kwhValue.toStringAsFixed(1);
                }
              }
            }
          }
        }
      }
      
      kwhConsumed = bestKwhStr;
    }

    return ExtractedData(
      address: address,
      zaehlpunktnummer: zaehlpunktnummer,
      kwhConsumed: kwhConsumed,
    );
  }
}

