import AVFoundation
import Flutter
import Foundation
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate, UIDocumentPickerDelegate {
  private var pendingFileResult: FlutterResult?
  private var activePicker: UIDocumentPickerViewController?
  private let fallbackSynth = SimpleScoreSynth()
  private let fluidSynth = FluidScoreSynth()
  private let engineQueue = DispatchQueue(label: "com.musereader.musescore-engine")
  private var nativeEngineAvailable = false
  private var nativeEngineReady = false
  private let importDirectoryName = "muse_reader/imports"

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    let messenger = engineBridge.applicationRegistrar.messenger()
    nativeEngineAvailable = muse_reader_is_available() != 0
    nativeEngineReady = nativeEngineAvailable && muse_reader_initialize() != 0

    let fileChannel = FlutterMethodChannel(
      name: "com.musereader/files",
      binaryMessenger: messenger
    )
    fileChannel.setMethodCallHandler { [weak self] call, result in
      guard let self else { return }
      switch call.method {
      case "pickScoreFile":
        self.presentScorePicker(result: result)
      case "listImportedScoreFiles":
        result(self.listImportedScoreFiles())
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    let engineChannel = FlutterMethodChannel(
      name: "com.musereader/musescore_engine",
      binaryMessenger: messenger
    )
    engineChannel.setMethodCallHandler { [weak self] call, result in
      guard let self else { return }
      switch call.method {
      case "open":
        let arguments = call.arguments as? [String: Any] ?? [:]
        guard let path = arguments["path"] as? String, !path.isEmpty else {
          result([
            "available": self.nativeEngineAvailable,
            "error": "The score path is empty.",
          ])
          return
        }
        guard self.nativeEngineReady else {
          result([
            "available": self.nativeEngineAvailable,
            "error": self.nativeErrorMessage(
              fallback: "MuseScore native initialization failed."
            ),
          ])
          return
        }
        self.engineQueue.async {
          let document = self.nativeDocument(path: path)
          let response: [String: Any]
          if let document {
            response = ["available": true, "document": document]
          } else {
            response = [
              "available": self.nativeEngineAvailable,
              "error": self.nativeErrorMessage(
                fallback: "MuseScore native rendering failed."
              ),
            ]
          }
          DispatchQueue.main.async {
            result(response)
          }
        }
      case "startAudio":
        let arguments = call.arguments as? [String: Any] ?? [:]
        let events = arguments["events"] as? [[String: Any]] ?? []
        let positionUs = (arguments["positionUs"] as? NSNumber)?.int64Value ?? 0
        let speed = (arguments["speed"] as? NSNumber)?.doubleValue ?? 1.0
        self.fallbackSynth.stop()
        if !self.fluidSynth.start(events: events, positionUs: positionUs, speed: speed) {
          self.fallbackSynth.start(events: events, positionUs: positionUs, speed: speed)
        }
        result(nil)
      case "stopAudio":
        self.fluidSynth.stop()
        self.fallbackSynth.stop()
        result(nil)
      case "audioPositionUs":
        result(self.fluidSynth.positionUs() ?? self.fallbackSynth.positionUs())
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private func presentScorePicker(result: @escaping FlutterResult) {
    guard pendingFileResult == nil else {
      result(FlutterError(code: "picker_busy", message: "A file picker is already open.", details: nil))
      return
    }
    guard let presenter = topViewController() else {
      result(FlutterError(code: "no_view", message: "The reader window is unavailable.", details: nil))
      return
    }
    pendingFileResult = result
    let picker = UIDocumentPickerViewController(
      documentTypes: ["public.data", "public.zip-archive", "public.xml"],
      in: .import
    )
    picker.delegate = self
    picker.allowsMultipleSelection = false
    activePicker = picker
    presenter.present(picker, animated: true)
  }

  func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
    finishPicker(controller: controller, url: urls.first)
  }

  func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
    finishPicker(controller: controller, url: nil)
  }

  private func finishPicker(controller: UIDocumentPickerViewController, url: URL?) {
    let result = pendingFileResult
    pendingFileResult = nil
    activePicker = nil
    guard let result else { return }
    guard let url else {
      result(nil)
      return
    }
    let accessed = url.startAccessingSecurityScopedResource()
    defer {
      if accessed { url.stopAccessingSecurityScopedResource() }
    }
    do {
      let directory = persistentImportsDirectory()
      let extensionName = url.pathExtension.isEmpty ? "mscx" : url.pathExtension
      let target = uniqueImportTarget(
        directory: directory,
        baseName: url.deletingPathExtension().lastPathComponent,
        extensionName: extensionName
      )
      try FileManager.default.copyItem(at: url, to: target)
      result(target.path)
    } catch {
      result(FlutterError(code: "copy_failed", message: error.localizedDescription, details: nil))
    }
  }

  private func uniqueImportTarget(
    directory: URL,
    baseName: String,
    extensionName: String
  ) -> URL {
    let timestamp = Int(Date().timeIntervalSince1970 * 1000)
    var target = directory.appendingPathComponent(
      "\(timestamp)_\(baseName).\(extensionName)"
    )
    var suffix = 1
    let fileManager = FileManager.default
    while fileManager.fileExists(atPath: target.path) {
      target = directory.appendingPathComponent(
        "\(timestamp)_\(suffix)_\(baseName).\(extensionName)"
      )
      suffix += 1
    }
    return target
  }

  /// Imported scores live in Application Support so they survive process
  /// restarts and iOS temporary-directory cleanup. Older builds copied files
  /// to the temporary directory; migrate those files when the library first
  /// asks for its persisted imports.
  private func listImportedScoreFiles() -> [String] {
    migrateLegacyImports()
    let fileManager = FileManager.default
    guard let files = try? fileManager.contentsOfDirectory(
      at: persistentImportsDirectory(),
      includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
      options: [.skipsHiddenFiles]
    ) else {
      return []
    }
    return files
      .filter {
        guard isSupportedScoreFile($0.lastPathComponent) else { return false }
        return (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
      }
      .sorted { lhs, rhs in
        let leftDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
          ?? .distantPast
        let rightDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
          ?? .distantPast
        if leftDate != rightDate { return leftDate > rightDate }
        return lhs.lastPathComponent > rhs.lastPathComponent
      }
      .map(\.path)
  }

  private func persistentImportsDirectory() -> URL {
    let fileManager = FileManager.default
    let applicationSupport = fileManager.urls(
      for: .applicationSupportDirectory,
      in: .userDomainMask
    )[0]
    let directory = applicationSupport.appendingPathComponent(importDirectoryName, isDirectory: true)
    try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }

  private func migrateLegacyImports() {
    let fileManager = FileManager.default
    let legacyDirectory = fileManager.temporaryDirectory
      .appendingPathComponent(importDirectoryName, isDirectory: true)
    guard let files = try? fileManager.contentsOfDirectory(
      at: legacyDirectory,
      includingPropertiesForKeys: [.isRegularFileKey],
      options: [.skipsHiddenFiles]
    ) else {
      return
    }
    let destination = persistentImportsDirectory()
    for source in files where isSupportedScoreFile(source.lastPathComponent) {
      guard (try? source.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
        continue
      }
      let target = destination.appendingPathComponent(source.lastPathComponent)
      if fileManager.fileExists(atPath: target.path) { continue }
      do {
        try fileManager.moveItem(at: source, to: target)
      } catch {
        // A cross-volume move may fail; retain a copy fallback and leave the
        // legacy file untouched if copying also fails.
        do {
          try fileManager.copyItem(at: source, to: target)
        } catch {
          try? fileManager.removeItem(at: target)
        }
      }
    }
  }

  private func isSupportedScoreFile(_ name: String) -> Bool {
    let extensionName = (name as NSString).pathExtension.lowercased()
    return extensionName == "mscx" || extensionName == "mscz"
  }

  private func nativeDocument(path: String) -> [String: Any]? {
    let jsonPointer = path.withCString { muse_reader_open_json($0) }
    guard let jsonPointer else { return nil }
    defer { muse_reader_free_json(jsonPointer) }
    let data = Data(bytes: jsonPointer, count: strlen(jsonPointer))
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
  }

  private func nativeErrorMessage(fallback: String) -> String {
    guard let error = muse_reader_last_error() else { return fallback }
    let message = String(cString: error)
    return message.isEmpty ? fallback : message
  }

  private func topViewController() -> UIViewController? {
    let windows = UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .flatMap(\.windows)
    guard var controller = windows.first(where: { $0.isKeyWindow })?.rootViewController else {
      return nil
    }
    while let presented = controller.presentedViewController {
      controller = presented
    }
    return controller
  }

  deinit {
    fluidSynth.stop()
    fallbackSynth.stop()
  }
}
