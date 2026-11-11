# Book Vocabulary (Flutter Android)

A small multi-book English–Bangla vocabulary reader.

## Features

- Import one JSON file per book.
- Browse Books → Parts → Chapters → Words.
- Displays all Bangla meanings available for each word.
- Mark a word known once; that word is hidden in every chapter of the same book.
- `Show known` reveals known and unknown words in the current chapter.
- Tap a checked word again to mark it unknown.
- Book files and learning progress are stored locally on the Android device.
- Each book has its own known-word list. A word marked known in Book A does not affect Book B.

## JSON structure

The importer is designed for the output created by the earlier Colab workflow. It looks for:

- top-level `parts`
- each Part's `chapters`
- each Chapter's `word_entries`, containing `word` and `bangla_meanings`
- or a Chapter's `bangla_meanings` map / `distinct_words` list as fallback

It also accepts common alternate keys such as `part_title`, `chapter_title`, `word`, `meanings`, and `bn`.

A representative shape:

```json
{
  "book_title": "My Book",
  "parts": [
    {
      "part_title": "Part I",
      "start_page": 1,
      "end_page": 50,
      "chapters": [
        {
          "chapter_title": "Chapter I",
          "start_page": 2,
          "end_page": 12,
          "word_entries": [
            {
              "word": "account",
              "bangla_meanings": ["হিসাব", "বিবরণ", "বর্ণনা"]
            }
          ]
        }
      ]
    }
  ]
}
```

## Setup

1. Install Flutter and Android Studio / Android SDK.
2. Extract this project folder.
3. Open a terminal in this folder.
4. Run:

```bash
flutter create .
flutter pub get
flutter doctor
flutter run
```

If more than one device is connected, run `flutter devices` and then:

```bash
flutter run -d DEVICE_ID
```

## Build APK

```bash
flutter build apk --release
```

APK output:

`build/app/outputs/flutter-apk/app-release.apk`

## GitHub

Create an empty repository on GitHub (do not add README or .gitignore there if you already have them locally). Then run in the project folder:

```bash
git init
git add .
git commit -m "Initial Flutter vocabulary app"
git branch -M main
git remote add origin https://github.com/YOUR_USERNAME/YOUR_REPOSITORY.git
git push -u origin main
```

For later updates:

```bash
git add .
git commit -m "Describe your changes"
git push
```

## Notes

- Data is stored locally on the device, not in Firebase or cloud sync.
- Removing a book removes its local JSON copy and its known-word progress.
- Importing the same JSON again creates a separate book entry.
