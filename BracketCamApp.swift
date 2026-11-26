
name: BracketCam

options:
  bundleIdPrefix: it.bracketcam
  deploymentTarget:
    iOS: "16.0"

settings:
  base:
    GENERATE_INFOPLIST_FILE: YES

targets:
  BracketCam:
    type: application
    platform: iOS
    sources:
      - BracketCamApp.swift
      - ContentView.swift
      - CameraModel.swift
      - Fusion.swift
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: it.bracketcam.personal
        PRODUCT_NAME: BracketCam
        SWIFT_VERSION: "5.0"
        GENERATE_INFOPLIST_FILE: YES
        INFOPLIST_KEY_NSCameraUsageDescription: "Serve per scattare le foto"
        INFOPLIST_KEY_NSPhotoLibraryAddUsageDescription: "Serve per salvare le foto"
        TARGETED_DEVICE_FAMILY: "1"
