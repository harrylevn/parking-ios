import SwiftUI
import UIKit
import XCTest

/// Snapshot testing without a dependency: `ImageRenderer` draws the view at a fixed scale, and
/// the result is compared pixel by pixel with a committed reference in `__Snapshots__/`.
///
/// The usual library (swift-snapshot-testing) would be the project's first third-party
/// dependency, for about eighty lines of code. References are recorded on the iOS 26.3
/// simulator that `make test` uses; after a runtime or deliberate visual change, re-record with
/// `make snapshots-record` and review the images in the diff before committing them.
@MainActor
extension XCTestCase {
    func assertSnapshot<V: View>(
        _ view: V,
        named name: String,
        width: CGFloat = 393,
        height: CGFloat? = nil,
        inWindow: Bool = false,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let framed = view.frame(width: width, height: height)
        let size = CGSize(width: width, height: height ?? 900)
        let rendered = inWindow ? Self.renderInWindow(framed, size: size) : Self.render(framed)
        guard let actual = rendered, let png = actual.pngData() else {
            return XCTFail("could not render \(name)", file: file, line: line)
        }

        let folder = URL(fileURLWithPath: "\(file)").deletingLastPathComponent()
            .appendingPathComponent("__Snapshots__", isDirectory: true)
        let reference = folder.appendingPathComponent("\(name).png")
        let recording = ProcessInfo.processInfo.environment["SNAPSHOT_RECORD"] == "1"

        guard !recording, let expected = UIImage(contentsOfFile: reference.path) else {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try? png.write(to: reference)
            if !recording {
                // A missing reference is a failure, not a silent pass: the image must be looked
                // at and committed.
                XCTFail(
                    "no reference for \(name); recorded \(reference.lastPathComponent): review and commit it",
                    file: file, line: line
                )
            }
            return
        }

        if let difference = Self.difference(between: actual, and: expected) {
            let attachment = XCTAttachment(image: actual)
            attachment.name = "\(name)-actual"
            attachment.lifetime = .keepAlways
            add(attachment)
            XCTFail("\(name) differs from its reference: \(difference)", file: file, line: line)
        }
    }

    static func render<V: View>(_ view: V) -> UIImage? {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        return renderer.uiImage
    }

    /// For views that scroll. `ImageRenderer` cannot draw a `ScrollView`, and the first
    /// largest-text references it produced were blank: a snapshot that would have passed for
    /// ever while checking nothing. This hosts the view in a real window and draws the
    /// view hierarchy instead.
    static func renderInWindow<V: View>(_ view: V, size: CGSize) -> UIImage? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let scene = scenes.first else { return nil }
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: size)
        let controller = UIHostingController(rootView: view)
        window.rootViewController = controller
        window.isHidden = false
        controller.view.frame = window.bounds
        controller.view.layoutIfNeeded()
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            _ = controller.view.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        window.isHidden = true
        return image
    }

    /// Nil when the images match. A pixel counts as different if any channel moves by more
    /// than 8 of 255, which absorbs anti-aliasing; the view fails if more than 0.1% differ.
    nonisolated static func difference(between actual: UIImage, and expected: UIImage) -> String? {
        guard let first = actual.cgImage, let second = expected.cgImage else { return "unreadable image" }
        guard first.width == second.width, first.height == second.height else {
            return "size \(first.width)×\(first.height) against \(second.width)×\(second.height)"
        }
        let pixelsA = rgba(first), pixelsB = rgba(second)
        var different = 0
        for index in stride(from: 0, to: pixelsA.count, by: 4) {
            for channel in 0..<4
            where abs(Int(pixelsA[index + channel]) - Int(pixelsB[index + channel])) > 8 {
                different += 1
                break
            }
        }
        let share = Double(different) / Double(first.width * first.height)
        return share > 0.001 ? String(format: "%.2f%% of pixels", share * 100) : nil
    }

    nonisolated private static func rgba(_ image: CGImage) -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        pixels.withUnsafeMutableBytes { buffer in
            let context = CGContext(
                data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
            context?.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return pixels
    }
}
