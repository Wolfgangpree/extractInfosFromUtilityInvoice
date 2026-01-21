import 'dart:html' as html;
import 'dart:typed_data';
import 'dart:ui_web' as ui_web;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'ocr_service.dart';
import 'vision_ai_service.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Rechnung Datenauslesung',
      theme: ThemeData(
        primarySwatch: Colors.blue,
        useMaterial3: true,
      ),
      home: const InvoiceExtractionPage(),
    );
  }
}

class InvoiceExtractionPage extends StatefulWidget {
  const InvoiceExtractionPage({super.key});

  @override
  State<InvoiceExtractionPage> createState() => _InvoiceExtractionPageState();
}

class _InvoiceExtractionPageState extends State<InvoiceExtractionPage> {
  Uint8List? _fileBytes;
  String? _fileName;
  String? _fileType; // 'pdf' or 'image'
  bool _showDocument = false;
  String? _pdfBlobUrl;
  bool _isProcessing = false;
  ExtractedData? _extractedData;
  String _selectedMethod = 'ocr'; // 'ocr' or 'vision_ai'
  final TextEditingController _apiKeyController = TextEditingController();
  bool _useGemini = false;
  final TextEditingController _geminiKeyController = TextEditingController();
  final List<String> _errorLogs = [];
  bool _isLoadingGeminiModels = false;
  List<String> _geminiModels = [];
  String? _selectedGeminiModel;

  @override
  void initState() {
    super.initState();
    // Load saved API key from localStorage (web only)
    if (kIsWeb) {
      try {
        final savedApiKey = html.window.localStorage['vision_ai_api_key'];
        if (savedApiKey != null) {
          _apiKeyController.text = savedApiKey;
          VisionAIService.setApiKey(savedApiKey);
        }
        final savedGeminiKey = html.window.localStorage['gemini_api_key'];
        if (savedGeminiKey != null) {
          _geminiKeyController.text = savedGeminiKey;
        }
      } catch (e) {
        // Ignore errors
      }
    }
  }

  @override
  void dispose() {
    _apiKeyController.dispose();
    _geminiKeyController.dispose();
    if (kIsWeb && _pdfBlobUrl != null) {
      html.Url.revokeObjectUrl(_pdfBlobUrl!);
    }
    super.dispose();
  }

  Future<void> _pickPdf() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['pdf'],
        withData: true, // Important for web
      );

      if (result != null && result.files.single.bytes != null) {
        final bytes = result.files.single.bytes!;
        final fileName = result.files.single.name;

        // Validate PDF magic bytes
        if (bytes.length < 4 || 
            bytes[0] != 0x25 || // %
            bytes[1] != 0x50 || // P
            bytes[2] != 0x44 || // D
            bytes[3] != 0x46) { // F
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Ungültige PDF-Datei')),
            );
          }
          return;
        }

        // Create blob URL for PDF display on web immediately
        String? pdfBlobUrl;
        if (kIsWeb) {
          if (_pdfBlobUrl != null) {
            html.Url.revokeObjectUrl(_pdfBlobUrl!);
          }
          final blob = html.Blob([bytes], 'application/pdf');
          pdfBlobUrl = html.Url.createObjectUrlFromBlob(blob);
        }

        setState(() {
          _fileBytes = bytes;
          _fileName = fileName;
          _fileType = 'pdf';
          _showDocument = true; // Show document immediately
          _extractedData = null;
          _pdfBlobUrl = pdfBlobUrl;
        });
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Fehler beim Hochladen: $e')),
        );
      }
    }
  }

  Future<void> _takePicture() async {
    try {
      final ImagePicker picker = ImagePicker();
      final XFile? image = await picker.pickImage(source: ImageSource.camera);

      if (image != null) {
        final bytes = await image.readAsBytes();
        setState(() {
          _fileBytes = bytes;
          _fileName = image.name;
          _fileType = 'image';
          _showDocument = true; // Show document immediately
          _extractedData = null;
        });
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Fehler beim Aufnehmen des Fotos: $e')),
        );
      }
    }
  }

  Future<void> _startRecognition() async {
    if (_fileBytes == null) {
      _addErrorLog('Bitte laden Sie zuerst ein Dokument hoch.');
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Bitte laden Sie zuerst ein Dokument hoch')),
      );
      return;
    }

    // Check if Vision AI is selected and API key is set
    if (_selectedMethod == 'vision_ai') {
      if (_apiKeyController.text.isEmpty) {
        _addErrorLog('Google Cloud Vision API-Schlüssel fehlt.');
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Bitte geben Sie einen Google Cloud Vision API-Schlüssel ein'),
            backgroundColor: Colors.orange,
          ),
        );
        return;
      }
      if (_useGemini && _geminiKeyController.text.isEmpty) {
        _addErrorLog('Gemini API-Schlüssel fehlt.');
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Bitte geben Sie einen Gemini API-Schlüssel ein'),
            backgroundColor: Colors.orange,
          ),
        );
        return;
      }
      VisionAIService.setApiKey(_apiKeyController.text);
      // Save API key to localStorage (web only)
      if (kIsWeb) {
        try {
          html.window.localStorage['vision_ai_api_key'] = _apiKeyController.text;
          if (_useGemini) {
            html.window.localStorage['gemini_api_key'] = _geminiKeyController.text;
          }
        } catch (e) {
          // Ignore errors
        }
      }
    }

    setState(() {
      _isProcessing = true;
      _extractedData = null;
    });

    try {
      String extractedText;
      ExtractedData data;
      
      if (_selectedMethod == 'vision_ai') {
        // Use Vision AI service
        if (_fileType == 'pdf') {
          extractedText = await VisionAIService.extractTextFromPdf(_fileBytes!);
        } else {
          extractedText = await VisionAIService.extractTextFromImage(_fileBytes!);
        }
        if (_useGemini) {
          data = await VisionAIService.extractDataWithGemini(
            extractedText: extractedText,
            apiKey: _geminiKeyController.text,
            modelName: _selectedGeminiModel,
          );
        } else {
          data = VisionAIService.parseInvoiceData(extractedText);
        }
      } else {
        // Use OCR service
        if (_fileType == 'pdf') {
          extractedText = await OCRService.extractTextFromPdf(_fileBytes!);
        } else {
          extractedText = await OCRService.extractTextFromImage(_fileBytes!);
        }
        data = OCRService.parseInvoiceData(extractedText);
      }
      
      setState(() {
        _extractedData = data;
        _isProcessing = false;
      });
    } catch (e) {
      setState(() {
        _isProcessing = false;
      });
      _addErrorLog('Texterkennung fehlgeschlagen: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Fehler bei der Texterkennung: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Rechnung Datenauslesung'),
        backgroundColor: Colors.blue.shade700,
        foregroundColor: Colors.white,
      ),
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Colors.purple.shade400, Colors.blue.shade600],
          ),
        ),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Section 1: Rechnung hochladen
              _buildUploadSection(),
              const SizedBox(height: 30),
              
              // Section 2: Daten auslesen
              _buildRecognitionSection(),
              const SizedBox(height: 30),
              
              // Section 2b: Fehlerprotokoll
              _buildErrorLogSection(),
              const SizedBox(height: 30),
              
              // Section 3: Document Display (show immediately after upload)
              if (_fileBytes != null) _buildDocumentSection(),
              if (_fileBytes != null) const SizedBox(height: 30),
              
              // Section 4: Extracted Information (only after recognition)
              if (_extractedData != null || _isProcessing) _buildExtractedInfoSection(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildUploadSection() {
    return Card(
      elevation: 4,
      child: Padding(
        padding: const EdgeInsets.all(20.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Text(
                  'Rechnung hochladen:',
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                if (_fileBytes != null) ...[
                  const SizedBox(width: 10),
                  const Icon(Icons.check_circle, color: Colors.green, size: 24),
                ],
              ],
            ),
            const SizedBox(height: 20),
            Row(
              children: [
                Expanded(
                  child: _buildUploadBox(
                    icon: Icons.picture_as_pdf,
                    label: 'PDF',
                    onTap: _pickPdf,
                    isSelected: _fileType == 'pdf',
                  ),
                ),
                const SizedBox(width: 20),
                Expanded(
                  child: _buildUploadBox(
                    icon: Icons.camera_alt,
                    label: 'Foto aufnehmen',
                    onTap: _takePicture,
                    isSelected: _fileType == 'image',
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildUploadBox({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    required bool isSelected,
  }) {
    return InkWell(
      onTap: onTap,
      child: Container(
        height: 120,
        decoration: BoxDecoration(
          color: isSelected ? Colors.blue.shade50 : Colors.white,
          border: Border.all(
            color: isSelected ? Colors.blue : Colors.grey.shade300,
            width: isSelected ? 2 : 1,
          ),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 48, color: Colors.blue.shade700),
            const SizedBox(height: 8),
            Text(
              label,
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w500,
                color: Colors.blue.shade700,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildRecognitionSection() {
    return Card(
      elevation: 4,
      child: Padding(
        padding: const EdgeInsets.all(20.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  'Daten auslesen:',
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                ElevatedButton.icon(
                  onPressed: _isProcessing ? null : _startRecognition,
                  icon: _isProcessing
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.search),
                  label: Text(_isProcessing ? 'Läuft...' : 'Erkennung starten'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.blue.shade700,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),
            const Text(
              'Erkennungsmethode:',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: RadioListTile<String>(
                    title: const Text('OCR (Tesseract)'),
                    subtitle: const Text('Kostenlos, funktioniert offline'),
                    value: 'ocr',
                    groupValue: _selectedMethod,
                    onChanged: (value) {
                      setState(() {
                        _selectedMethod = value!;
                      });
                    },
                    contentPadding: EdgeInsets.zero,
                  ),
                ),
                Expanded(
                  child: RadioListTile<String>(
                    title: const Text('Vision AI (Google)'),
                    subtitle: const Text('Höhere Genauigkeit, benötigt API-Schlüssel'),
                    value: 'vision_ai',
                    groupValue: _selectedMethod,
                    onChanged: (value) {
                      setState(() {
                        _selectedMethod = value!;
                      });
                    },
                    contentPadding: EdgeInsets.zero,
                  ),
                ),
              ],
            ),
            if (_selectedMethod == 'vision_ai') ...[
              const SizedBox(height: 15),
              TextField(
                controller: _apiKeyController,
                decoration: InputDecoration(
                  labelText: 'Google Cloud Vision API-Schlüssel',
                  hintText: 'Geben Sie Ihren API-Schlüssel ein',
                  border: const OutlineInputBorder(),
                  suffixIcon: IconButton(
                    icon: const Icon(Icons.help_outline),
                    onPressed: () {
                      showDialog(
                        context: context,
                        builder: (context) => AlertDialog(
                          title: const Text('API-Schlüssel erhalten'),
                          content: const Text(
                            'Um einen Google Cloud Vision API-Schlüssel zu erhalten:\n\n'
                            '1. Gehen Sie zu https://console.cloud.google.com/\n'
                            '2. Erstellen Sie ein Projekt oder wählen Sie ein vorhandenes aus\n'
                            '3. Aktivieren Sie die Cloud Vision API\n'
                            '4. Erstellen Sie einen API-Schlüssel in den Anmeldedaten\n'
                            '5. Kopieren Sie den Schlüssel hier hinein\n\n'
                            'Die ersten 1.000 Anfragen pro Monat sind kostenlos.',
                          ),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.of(context).pop(),
                              child: const Text('OK'),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                ),
                obscureText: true,
              ),
              const SizedBox(height: 10),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Gemini-Prompting für Extraktion'),
                subtitle: const Text('Nutze LLM zur präziseren Feldextraktion'),
                value: _useGemini,
                onChanged: (value) {
                  setState(() {
                    _useGemini = value ?? false;
                  });
                },
              ),
              if (_useGemini) ...[
                const SizedBox(height: 8),
                TextField(
                  controller: _geminiKeyController,
                  decoration: InputDecoration(
                    labelText: 'Gemini API-Schlüssel',
                    hintText: 'Geben Sie Ihren Gemini API-Schlüssel ein',
                    border: const OutlineInputBorder(),
                  ),
                  obscureText: true,
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    ElevatedButton.icon(
                      onPressed: _isLoadingGeminiModels
                          ? null
                          : () async {
                              if (_geminiKeyController.text.isEmpty) {
                                _addErrorLog('Gemini API-Schlüssel fehlt.');
                                return;
                              }
                              setState(() {
                                _isLoadingGeminiModels = true;
                              });
                              try {
                                final models = await VisionAIService.listGeminiModels(
                                  apiKey: _geminiKeyController.text,
                                );
                                setState(() {
                                  _geminiModels = models;
                                  if (_geminiModels.isNotEmpty) {
                                    if (_selectedGeminiModel == null ||
                                        !_geminiModels.contains(_selectedGeminiModel)) {
                                      _selectedGeminiModel = _geminiModels.first;
                                    }
                                  } else {
                                    _selectedGeminiModel = null;
                                  }
                                  _isLoadingGeminiModels = false;
                                });
                              } catch (e) {
                                setState(() {
                                  _isLoadingGeminiModels = false;
                                });
                                _addErrorLog('Gemini Modelle laden fehlgeschlagen: $e');
                              }
                            },
                      icon: _isLoadingGeminiModels
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.list),
                      label: const Text('Modelle laden'),
                    ),
                    const SizedBox(width: 12),
                    if (_geminiModels.isNotEmpty)
                      Text('${_geminiModels.length} Modelle gefunden'),
                  ],
                ),
                if (_geminiModels.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  DropdownButtonFormField<String>(
                    value: _selectedGeminiModel,
                    decoration: const InputDecoration(
                      labelText: 'Gemini Modell',
                      border: OutlineInputBorder(),
                    ),
                    items: _geminiModels
                        .map(
                          (model) => DropdownMenuItem<String>(
                            value: model,
                            child: Text(model),
                          ),
                        )
                        .toList(),
                    onChanged: (value) {
                      setState(() {
                        _selectedGeminiModel = value;
                      });
                    },
                  ),
                  const SizedBox(height: 8),
                  Container(
                    width: double.infinity,
                    height: 120,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      border: Border.all(color: Colors.grey.shade300, width: 2),
                      borderRadius: BorderRadius.circular(8),
                      color: Colors.grey.shade50,
                    ),
                    child: SingleChildScrollView(
                      child: Text(_geminiModels.join('\n')),
                    ),
                  ),
                ],
              ],
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildExtractedInfoSection() {
    return Card(
      elevation: 4,
      child: Padding(
        padding: const EdgeInsets.all(20.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Extrahierte Informationen:',
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 15),
            Container(
              width: double.infinity,
              height: 200, // Fixed height
              padding: const EdgeInsets.all(15),
              decoration: BoxDecoration(
                border: Border.all(color: Colors.grey.shade300, width: 2),
                borderRadius: BorderRadius.circular(8),
                color: Colors.grey.shade50,
              ),
              child: _isProcessing
                  ? const Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          CircularProgressIndicator(),
                          SizedBox(height: 15),
                          Text('Texterkennung läuft...'),
                        ],
                      ),
                    )
                  : _extractedData != null
                      ? SingleChildScrollView(
                          child: _buildExtractedInfoContent(),
                        )
                      : const Center(
                          child: Text(
                            'Keine Daten gefunden.',
                            style: TextStyle(color: Colors.grey),
                          ),
                        ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildErrorLogSection() {
    return Card(
      elevation: 4,
      child: Padding(
        padding: const EdgeInsets.all(20.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  'Fehlerprotokoll:',
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                TextButton.icon(
                  onPressed: _errorLogs.isEmpty
                      ? null
                      : () {
                          setState(() {
                            _errorLogs.clear();
                          });
                        },
                  icon: const Icon(Icons.delete_outline),
                  label: const Text('Leeren'),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Container(
              width: double.infinity,
              height: 140,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                border: Border.all(color: Colors.grey.shade300, width: 2),
                borderRadius: BorderRadius.circular(8),
                color: Colors.grey.shade50,
              ),
              child: _errorLogs.isEmpty
                  ? const Text('Keine Fehler vorhanden.')
                  : SingleChildScrollView(
                      child: Text(_errorLogs.reversed.join('\n\n')),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  void _addErrorLog(String message) {
    final timestamp = DateTime.now().toIso8601String();
    setState(() {
      _errorLogs.add('[$timestamp] $message');
    });
  }

  Widget _buildExtractedInfoContent() {
    if (_extractedData == null) {
      return const SizedBox.shrink();
    }

    final infoLines = <String>[];
    
    if (_extractedData!.address != null) {
      infoLines.add('Adresse: ${_extractedData!.address}');
    }
    if (_extractedData!.zaehlpunktnummer != null) {
      infoLines.add('Zählpunktnummer: ${_extractedData!.zaehlpunktnummer}');
    }
    if (_extractedData!.kwhConsumed != null) {
      infoLines.add('kWh: ${_extractedData!.kwhConsumed} kWh');
    }

    if (infoLines.isEmpty) {
      return const Text(
        'Keine Daten gefunden. Bitte überprüfen Sie das Dokument.',
        style: TextStyle(color: Colors.orange),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: infoLines.map((line) {
        return Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Text(
            line,
            style: const TextStyle(
              fontSize: 16,
              color: Colors.black87,
            ),
          ),
        );
      }).toList(),
    );
  }

  Widget _buildDocumentSection() {
    return Card(
      elevation: 4,
      child: Padding(
        padding: const EdgeInsets.all(20.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Dokument:',
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 15),
            _buildDocumentDisplay(),
          ],
        ),
      ),
    );
  }

  Widget _buildDocumentDisplay() {
    if (_fileType == 'pdf') {
      if (kIsWeb && _pdfBlobUrl != null) {
        // Display PDF in iframe on web
        return Column(
          children: [
            Container(
              height: 500,
              decoration: BoxDecoration(
                border: Border.all(color: Colors.grey.shade300),
                borderRadius: BorderRadius.circular(8),
              ),
              child: _buildPdfIframe(),
            ),
            const SizedBox(height: 15),
            _buildFileInfo(),
          ],
        );
      } else {
        // Fallback for non-web or when blob URL is not available
        return Column(
          children: [
            Container(
              height: 500,
              decoration: BoxDecoration(
                color: Colors.grey.shade200,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(Icons.picture_as_pdf, size: 64, color: Colors.grey),
                    const SizedBox(height: 16),
                    const Text(
                      'PDF geladen',
                      style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'PDF-Datei erfolgreich hochgeladen',
                      style: TextStyle(color: Colors.grey.shade600),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 15),
            _buildFileInfo(),
          ],
        );
      }
    } else if (_fileType == 'image' && _fileBytes != null) {
      return Column(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Image.memory(
              _fileBytes!,
              fit: BoxFit.contain,
              height: 500,
            ),
          ),
          const SizedBox(height: 15),
          _buildFileInfo(),
        ],
      );
    }
    return const SizedBox.shrink();
  }

  Widget _buildPdfIframe() {
    if (!kIsWeb || _pdfBlobUrl == null) {
      return const SizedBox.shrink();
    }
    
    // Create a unique view ID each time to avoid registration conflicts
    final String viewId = 'pdf-iframe-${DateTime.now().millisecondsSinceEpoch}';
    
    // Register the iframe element using platform view registry
    ui_web.platformViewRegistry.registerViewFactory(viewId, (int viewId) {
      final iframe = html.IFrameElement()
        ..src = _pdfBlobUrl!
        ..style.border = 'none'
        ..style.width = '100%'
        ..style.height = '100%';
      return iframe;
    });
    
    return HtmlElementView(viewType: viewId);
  }

  Widget _buildFileInfo() {
    if (_fileBytes == null || _fileName == null) return const SizedBox.shrink();
    
    final fileSize = _fileBytes!.length / 1024;
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Colors.teal.shade50,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Datei: $_fileName'),
          Text('Größe: ${fileSize.toStringAsFixed(2)} KB'),
          Text('Typ: ${_fileType == 'pdf' ? 'PDF (validiert)' : 'Bild'}'),
        ],
      ),
    );
  }
}

