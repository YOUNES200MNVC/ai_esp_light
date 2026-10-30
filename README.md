name: Build APK
on:
  push:
  workflow_dispatch:
permissions:
  contents: write
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-java@v4
        with:
          distribution: temurin
          java-version: 17
      - uses: android-actions/setup-android@v4
      - name: Setup Gradle 8.5
        uses: gradle/actions/setup-gradle@v3
        with:
          gradle-version: 8.5
      - name: Generate project
        run: bash ffpanel.sh
      - name: Build APK (Debug)
        run: |
          cd FFPanel
          gradle assembleDebug --stacktrace
      - name: Rename APK
        run: |
          mv FFPanel/app/build/outputs/apk/debug/app-debug.apk FFPanel/app/build/outputs/apk/debug/app-release.apk
      - name: Create Release
        uses: softprops/action-gh-release@v2
        with:
          tag_name: v1.0.${{ github.run_number }}
          name: AI ESP Light
          files: FFPanel/app/build/outputs/apk/debug/app-release.apk
          make_latest: true# ai_esp_light
