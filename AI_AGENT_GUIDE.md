# AI Agent Guide for Folder `skripsi`

Tujuan dokumen ini adalah membantu AI agent memahami struktur proyek Flutter ini dengan cepat tanpa harus membaca seluruh tree mentah satu per satu.

## Ringkasan proyek
- Ini adalah proyek Flutter bernama `skripsi`.
- Fokus aplikasi berada di file `lib/main.dart`.
- Proyek ini memiliki target multi-platform standar Flutter: Android, iOS, Linux, macOS, Web, dan Windows.
- Integrasi native Android yang relevan ada di `android/app/src/main/kotlin/com/example/skripsi/MainActivity.kt`.
- Model machine learning disimpan di `assets/model/`.

## Folder yang paling penting untuk AI agent
- `lib/`
  - Sumber utama aplikasi Flutter.
  - File paling penting: `lib/main.dart`.
- `assets/`
  - Menyimpan aset runtime aplikasi.
  - Model TFLite ada di `assets/model/morphology_transformer_final.tflite`.
- `android/`
  - Implementasi native Android.
  - Tempat penting untuk MethodChannel, permission, manifest, dan integrasi platform.
  - File kunci: `android/app/src/main/kotlin/com/example/skripsi/MainActivity.kt`.
- `test/`
  - Tempat test Flutter/Dart.
- `pubspec.yaml`
  - Konfigurasi dependency, asset registration, dan metadata proyek.
- `README.md`
  - Dokumentasi proyek jika tersedia.

## Folder yang biasanya generated atau bukan fokus utama coding
- `.dart_tool/`
  - Cache dan metadata tool Dart/Flutter.
  - Biasanya tidak diedit manual.
- `build/`
  - Artefak hasil build.
  - Biasanya tidak diedit manual.
- `android/.gradle/`, `android/build/`
  - Cache/artefak Gradle dan Android build.
  - Biasanya tidak diedit manual.
- `.idea/`
  - Konfigurasi IDE.
  - Biasanya tidak penting untuk logic aplikasi.
- `ios/Flutter/ephemeral/`, `windows/flutter/`, `linux/flutter/`, `macos/Flutter/ephemeral/`
  - File generated dari tooling Flutter/platform.
  - Hindari edit manual kecuali memang ada kebutuhan platform tertentu yang jelas.

## Jalur kerja yang disarankan untuk AI agent
- Jika tugas terkait UI, state, alur inferensi, evaluasi CSV, atau Bluetooth di sisi Flutter:
  - mulai dari `lib/main.dart`
- Jika tugas terkait pembacaan CPU, MethodChannel, atau perilaku Android native:
  - cek `android/app/src/main/kotlin/com/example/skripsi/MainActivity.kt`
- Jika tugas terkait model atau asset runtime:
  - cek `assets/model/`
- Jika tugas terkait dependency atau asset registration:
  - cek `pubspec.yaml`

## Catatan penting saat membaca tree penuh
- Tree penuh di `DIRECTORY_TREE_FULL.txt` mencantumkan semua file dan folder yang terlihat dari root proyek saat perintah dijalankan.
- Karena ini tree penuh, ada banyak file generated yang tidak perlu disentuh saat melakukan revisi fitur.
- Untuk kebanyakan tugas coding, AI agent cukup fokus pada:
  - `lib/`
  - `assets/`
  - `android/app/src/main/`
  - `pubspec.yaml`
  - `test/`

## Heuristik cepat untuk agent
- Ubah logic aplikasi Flutter: `lib/main.dart`
- Ubah integrasi Android native: `android/app/src/main/.../MainActivity.kt`
- Cek asset model: `assets/model/`
- Abaikan cache/build kecuali debugging build system

## File yang dibuat untuk membantu navigasi
- `DIRECTORY_TREE_FULL.txt`: tree lengkap plain text
- `AI_AGENT_GUIDE.md`: penjelasan struktur proyek ini
