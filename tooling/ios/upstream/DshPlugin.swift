import Flutter
import PDFKit
import Photos
import QuickLook
import UIKit
import UserNotifications

// Cove-Go remote-only registration. Runtime, phone control, share intake,
// launchers and DSH notification ownership are deliberately not registered.
final class CovePlatformChannels: NSObject, FlutterPlugin {
  private let keep: [AnyObject]

  static func register(with registrar: any FlutterPluginRegistrar) {
    let plugin = CovePlatformChannels(messenger: registrar.messenger())
    registrar.publish(plugin)
  }

  private init(messenger: any FlutterBinaryMessenger) {
    keep = [
      AppChannel(messenger: messenger),
      FilesChannel(messenger: messenger),
      MediaChannel(messenger: messenger),
      VoiceChannel(messenger: messenger),
      IOSSpeechChannel(messenger: messenger),
      NativeFilesChannel(messenger: messenger),
      NativeMediaChannel(messenger: messenger),
    ]
    super.init()
  }
}

func arguments(_ call: FlutterMethodCall) -> [String: Any] {
  call.arguments as? [String: Any] ?? [:]
}

func onMain(_ work: @escaping () -> Void) {
  DispatchQueue.main.async(execute: work)
}

// MARK: - dsh/app

private final class AppChannel {
  private let channel: FlutterMethodChannel

  init(messenger: any FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "dsh/app", binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "getTimeZoneId": result(TimeZone.current.identifier)
      // iOS doesn't let an app bring itself forward.
      case "bringToFront": result(nil)
      default: result(FlutterMethodNotImplemented)
      }
    }
  }
}

// MARK: - dsh/files

/// Only the engine's committed, private migration record authorizes old-root aliases.
/// No history text is rewritten, and callers still validate the resolved file.
private enum RelocatedGuestPaths {
  private struct Marker: Decodable {
    let version: Int
    let currentRoot: String
    let previousRoots: [String]
  }

  private static func validRoot(_ path: String) -> Bool {
    guard path.hasPrefix("/"), path != "/", !path.contains("\0") else { return false }
    return path.dropFirst().split(separator: "/", omittingEmptySubsequences: false)
      .allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
  }

  static func map(_ path: String, root: String) -> String {
    guard validRoot(root), path.hasPrefix("/"), !path.contains("\0") else { return path }
    if path == root || path.hasPrefix(root + "/") { return path }
    let home = root + "/root/.dsh"
    guard let resolved = realpath(home, nil) else { return path }
    let privateHome = String(cString: resolved)
    free(resolved)
    guard privateHome == home else { return path }
    let fd = open(home + "/ios-container-paths.json", O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    guard fd >= 0 else { return path }
    defer { close(fd) }
    var info = stat()
    let limit = 64 * 1024
    guard fstat(fd, &info) == 0, (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
      info.st_size > 0, info.st_size <= limit
    else { return path }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while true {
      let count = read(fd, &buffer, min(buffer.count, limit + 1 - data.count))
      if count < 0 && errno == EINTR { continue }
      guard count >= 0 else { return path }
      if count == 0 { break }
      data.append(contentsOf: buffer.prefix(count))
      guard data.count <= limit else { return path }
    }
    guard let marker = try? JSONDecoder().decode(Marker.self, from: data), marker.version == 1,
      validRoot(marker.currentRoot), marker.previousRoots.allSatisfy(validRoot)
    else { return path }
    // A second move can occur before JS updates currentRoot. Both it and the
    // older roots therefore map to the native root of this launch.
    let aliases = ([marker.currentRoot] + marker.previousRoots).sorted { $0.count > $1.count }
    for old in aliases where path == old || path.hasPrefix(old + "/") {
      return root + path.dropFirst(old.count)
    }
    return path
  }
}

/// iOS tool paths are already absolute sandbox paths, not Android guest paths.
/// This is a point-in-time lookup; the Dart caller opens the returned path later.
private struct LocalEngineFiles {
  let guestRoot: URL

  private func canonical(_ path: String) -> String? {
    guard path.hasPrefix("/"), !path.contains("\0"), let resolved = realpath(path, nil) else { return nil }
    defer { free(resolved) }
    return String(cString: resolved)
  }

  func resolve(_ path: String) -> String? {
    guard
      let root = canonical(guestRoot.path),
      let file = canonical(RelocatedGuestPaths.map(path, root: root)),
      file.hasPrefix(root + "/"),
      let values = try? FileManager.default.attributesOfItem(atPath: file),
      values[.type] as? FileAttributeType == .typeRegular,
      FileManager.default.isReadableFile(atPath: file)
    else { return nil }
    return file
  }

  /// Same directory advertised by EngineChannel's managed AGENTS.md. Results
  /// carry engine-visible absolute paths and epoch milliseconds, as Dart expects.
  func outputs(depth: Int) -> [[String: Any]] {
    guard let root = canonical(guestRoot.path) else { return [] }
    let expected = root + "/root/workspace/DSH-Go"
    guard canonical(expected) == expected else { return [] }
    let manager = FileManager.default
    let maxDepth = min(max(depth, 1), 8)
    var rows: [[String: Any]] = []
    var visited = 0
    func walk(_ folder: URL, level: Int) {
      guard let entries = try? manager.contentsOfDirectory(
        at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
      else { return }
      for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
        // Bound both returned files and work in a directory-heavy tree.
        guard rows.count < 500, visited < 5000 else { return }
        visited += 1
        guard let values = try? manager.attributesOfItem(atPath: entry.path) else { continue }
        let type = values[.type] as? FileAttributeType
        // Never recurse into or publish a symlink from the output scan.
        if type == .typeDirectory {
          if level < maxDepth { walk(entry, level: level + 1) }
        } else if type == .typeRegular, let path = resolve(entry.path),
          path.hasPrefix(expected + "/"),
          let size = values[.size] as? NSNumber, let modified = values[.modificationDate] as? Date
        {
          rows.append(["path": path, "bytes": size.int64Value, "modified": Int64(modified.timeIntervalSince1970 * 1000)])
        }
      }
    }
    walk(URL(fileURLWithPath: expected, isDirectory: true), level: 1)
    return rows
  }
}

/// Opening, saving and previewing the files a turn produced.
private final class FilesChannel: NSObject, QLPreviewControllerDataSource {
  private let channel: FlutterMethodChannel
  private let pdfQueue = DispatchQueue(label: "dsh.pdf")
  private var pdf: (path: String, document: PDFDocument)?
  private var previewing: URL?

  init(messenger: any FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "dsh/files", binaryMessenger: messenger)
    super.init()
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else { return result(FlutterMethodNotImplemented) }
      let args = arguments(call)
      let path = args["path"] as? String ?? ""
      switch call.method {
      case "resolveGuest":
        self.pdfQueue.async {
          let path = self.localFiles.resolve(path)
          onMain { result(path) }
        }
      case "listOutputs":
        let depth = args["depth"] as? Int ?? 3
        self.pdfQueue.async {
          let rows = self.localFiles.outputs(depth: depth)
          onMain { result(rows) }
        }
      case "open":
        self.open(path: path, name: args["name"] as? String, chooser: args["chooser"] as? Bool ?? false, result: result)
      case "saveToDownloads": self.save(path: path, name: args["name"] as? String, result: result)
      case "pdfInfo": self.pdfInfo(path: path, result: result)
      case "pdfPage":
        self.pdfPage(path: path, page: args["page"] as? Int ?? 0, width: args["width"] as? Int ?? 0, result: result)
      case "pdfClose":
        self.pdfQueue.async {
          self.pdf = nil
          onMain { result(nil) }
        }
      default: result(FlutterMethodNotImplemented)
      }
    }
  }

  /// Match EngineChannel's application-support root and fallback exactly. Resolve
  /// aliases only when reading, after the engine has prepared its root.
  private var localFiles: LocalEngineFiles {
    let base =
      (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
      ?? URL(fileURLWithPath: NSTemporaryDirectory())
    return LocalEngineFiles(guestRoot: base.appendingPathComponent("runtime/rootfs", isDirectory: true))
  }

  // Open

  private func open(path: String, name: String?, chooser: Bool, result: FlutterResult) {
    guard FileManager.default.isReadableFile(atPath: path), let top = topViewController() else {
      return result(FlutterError(code: "missing", message: "no such file", details: nil))
    }
    let url: URL
    do {
      url = try named(URL(fileURLWithPath: path), as: name)
    } catch {
      return result(FlutterError(code: "failed", message: error.localizedDescription, details: nil))
    }
    if !chooser && QLPreviewController.canPreview(url as NSURL) {
      previewing = url
      let preview = QLPreviewController()
      preview.dataSource = self
      top.present(preview, animated: true)
    } else {
      let share = UIActivityViewController(activityItems: [url], applicationActivities: nil)
      if let popover = share.popoverPresentationController {
        popover.sourceView = top.view
        popover.sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.midY, width: 0, height: 0)
        popover.permittedArrowDirections = []
      }
      top.present(share, animated: true)
    }
    result(nil)
  }

  /// The preview and other apps go by the file's extension, and the cache may not
  /// have it under the name the file should show.
  private func named(_ url: URL, as name: String?) throws -> URL {
    guard let name, !name.isEmpty, name != url.lastPathComponent else { return url }
    let manager = FileManager.default
    let folder = manager.temporaryDirectory.appendingPathComponent("open/\(UUID().uuidString)", isDirectory: true)
    try manager.createDirectory(at: folder, withIntermediateDirectories: true)
    let copy = folder.appendingPathComponent((name as NSString).lastPathComponent)
    try manager.copyItem(at: url, to: copy)
    return copy
  }

  func numberOfPreviewItems(in controller: QLPreviewController) -> Int {
    previewing == nil ? 0 : 1
  }

  func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> any QLPreviewItem {
    (previewing ?? URL(fileURLWithPath: "/")) as NSURL
  }

  // Save

  /// Into the app's Documents, which the Files app shows under the app's name
  /// (UIFileSharingEnabled, LSSupportsOpeningDocumentsInPlace). No dialog, like the
  /// save on Android; returns where it landed.
  private func save(path: String, name: String?, result: @escaping FlutterResult) {
    DispatchQueue.global(qos: .userInitiated).async {
      let manager = FileManager.default
      guard manager.isReadableFile(atPath: path) else {
        return onMain { result(FlutterError(code: "missing", message: "no such file", details: nil)) }
      }
      do {
        let documents = try manager.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let wanted = name?.isEmpty == false ? name! : URL(fileURLWithPath: path).lastPathComponent
        let target = Self.free(in: documents, name: (wanted as NSString).lastPathComponent)
        try manager.copyItem(at: URL(fileURLWithPath: path), to: target)
        onMain { result("Cove-Go/\(target.lastPathComponent)") }
      } catch {
        onMain { result(FlutterError(code: "failed", message: error.localizedDescription, details: nil)) }
      }
    }
  }

  /// `report.pdf`, then `report (1).pdf`, the first name not taken.
  private static func free(in folder: URL, name: String) -> URL {
    let manager = FileManager.default
    let plain = folder.appendingPathComponent(name)
    if !manager.fileExists(atPath: plain.path) { return plain }
    let stem = (name as NSString).deletingPathExtension
    let ext = (name as NSString).pathExtension
    var number = 1
    while true {
      let candidate = folder.appendingPathComponent(ext.isEmpty ? "\(stem) (\(number))" : "\(stem) (\(number)).\(ext)")
      if !manager.fileExists(atPath: candidate.path) { return candidate }
      number += 1
    }
  }

  // PDF preview

  private func document(_ path: String) -> PDFDocument? {
    if let pdf, pdf.path == path { return pdf.document }
    guard let document = PDFDocument(url: URL(fileURLWithPath: path)) else { return nil }
    pdf = (path, document)
    return document
  }

  /// A page's size as it is shown: rotated pages swap width and height.
  private static func size(of page: PDFPage) -> CGSize {
    let box = page.bounds(for: .mediaBox).size
    return page.rotation % 180 == 0 ? box : CGSize(width: box.height, height: box.width)
  }

  private func pdfInfo(path: String, result: @escaping FlutterResult) {
    pdfQueue.async {
      guard let document = self.document(path) else {
        return onMain { result(FlutterError(code: "missing", message: "no such PDF", details: nil)) }
      }
      let pages: [[String: Int]] = (0..<document.pageCount).compactMap { index in
        guard let page = document.page(at: index) else { return nil }
        let size = Self.size(of: page)
        return ["width": Int(size.width.rounded()), "height": Int(size.height.rounded())]
      }
      onMain { result(pages) }
    }
  }

  private func pdfPage(path: String, page index: Int, width: Int, result: @escaping FlutterResult) {
    pdfQueue.async {
      guard width > 0, let page = self.document(path)?.page(at: index) else {
        return onMain { result(FlutterError(code: "missing", message: "no such page", details: nil)) }
      }
      let size = Self.size(of: page)
      guard size.width > 0, size.height > 0 else {
        return onMain { result(FlutterError(code: "failed", message: "empty page", details: nil)) }
      }
      let scale = CGFloat(width) / size.width
      let target = CGSize(width: CGFloat(width), height: (size.height * scale).rounded())
      let format = UIGraphicsImageRendererFormat()
      format.scale = 1
      format.opaque = true
      let png = UIGraphicsImageRenderer(size: target, format: format).pngData { context in
        UIColor.white.setFill()
        context.fill(CGRect(origin: .zero, size: target))
        context.cgContext.translateBy(x: 0, y: target.height)
        context.cgContext.scaleBy(x: scale, y: -scale)
        page.draw(with: .mediaBox, to: context.cgContext)
      }
      onMain { result(FlutterStandardTypedData(bytes: png)) }
    }
  }
}

func topViewController() -> UIViewController? {
  let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
  let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
  var top = scene?.windows.first { $0.isKeyWindow }?.rootViewController
  while let presented = top?.presentedViewController { top = presented }
  return top
}

func openAppSettings(_ address: String, result: @escaping FlutterResult) {
  guard let url = URL(string: address) else { return result(false) }
  UIApplication.shared.open(url) { result($0) }
}

// MARK: - dsh/media

private final class MediaChannel {
  private let channel: FlutterMethodChannel

  init(messenger: any FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "dsh/media", binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "saveImage":
        let args = arguments(call)
        guard let bytes = args["bytes"] as? FlutterStandardTypedData, let name = args["name"] as? String else {
          return result(FlutterError(code: "invalid", message: "no image", details: nil))
        }
        Self.save(bytes.data, name: name, result: result)
      case "saveVideoFile":
        let args = arguments(call)
        guard let path = args["path"] as? String, let name = args["name"] as? String,
          let file = Self.videoFile(path, name: name) else {
          return result(FlutterError(code: "invalid", message: "invalid local video", details: nil))
        }
        Self.saveVideo(file, name: name, result: result)
      case "openSettings": openAppSettings(UIApplication.openSettingsURLString, result: result)
      default: result(FlutterMethodNotImplemented)
      }
    }
  }

  private static func videoFile(_ path: String, name: String) -> URL? {
    guard path.hasPrefix("/"), !name.isEmpty, name.utf8.count <= 255,
      name == (name as NSString).lastPathComponent,
      ["mp4", "mov", "m4v"].contains((name as NSString).pathExtension.lowercased()) else { return nil }
    let root = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
      .resolvingSymlinksInPath().standardizedFileURL.path
    let file = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
    guard file.path.hasPrefix(root + "/"),
      ["mp4", "mov", "m4v"].contains(file.pathExtension.lowercased()),
      (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { return nil }
    return file
  }

  private static func saveVideo(_ file: URL, name: String, result: @escaping FlutterResult) {
    PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
      guard status == .authorized || status == .limited else {
        return onMain { result(FlutterError(code: "permission", message: "photos refused", details: nil)) }
      }
      PHPhotoLibrary.shared().performChanges({
        let options = PHAssetResourceCreationOptions()
        options.originalFilename = name
        options.shouldMoveFile = false
        PHAssetCreationRequest.forAsset().addResource(with: .video, fileURL: file, options: options)
      }) { saved, error in
        onMain {
          if saved { result("Photos/\(name)") }
          else { result(FlutterError(code: "failed", message: error?.localizedDescription, details: nil)) }
        }
      }
    }
  }

  /// Add-only access: saving doesn't need to read the rest of the library.
  private static func save(_ data: Data, name: String, result: @escaping FlutterResult) {
    PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
      guard status == .authorized || status == .limited else {
        return onMain { result(FlutterError(code: "permission", message: "photos refused", details: nil)) }
      }
      PHPhotoLibrary.shared().performChanges({
        let options = PHAssetResourceCreationOptions()
        options.originalFilename = name
        PHAssetCreationRequest.forAsset().addResource(with: .photo, data: data, options: options)
      }) { saved, error in
        onMain {
          if saved {
            result("Photos/\(name)")
          } else {
            result(FlutterError(code: "failed", message: error?.localizedDescription, details: nil))
          }
        }
      }
    }
  }
}

