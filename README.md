# Rechnung Datenauslesung

A Flutter app to extract information from utility invoices (power utility invoices).

## Features

- **PDF Upload**: Upload PDF invoices with magic bytes validation
- **Camera Capture**: Take photos of invoices using the device camera
- **Document Display**: View uploaded documents/images when recognition is started

## Setup

1. Make sure you have Flutter installed on your system
2. Install dependencies:
   ```bash
   flutter pub get
   ```

## Running the App

```bash
flutter run
```

## Dependencies

- `file_picker`: For selecting PDF files
- `image_picker`: For camera/photo capture
- `pdfx`: For displaying PDF documents

## Platform Support

- iOS (requires camera permissions)
- Android (requires camera and storage permissions)

Make sure to grant necessary permissions when running on a device.


