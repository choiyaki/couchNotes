import XCTest
import PencilKit
@testable import couchNotes

final class HandwritingExporterTests: XCTestCase {
    private func drawing(from start: CGPoint, to end: CGPoint) -> PKDrawing {
        let points = [start, end].enumerated().map { i, p in
            PKStrokePoint(location: p, timeOffset: TimeInterval(i) * 0.1,
                          size: CGSize(width: 4, height: 4), opacity: 1, force: 1,
                          azimuth: 0, altitude: .pi / 2)
        }
        let path = PKStrokePath(controlPoints: points, creationDate: Date())
        return PKDrawing(strokes: [PKStroke(ink: PKInk(.pen, color: .black), path: path)])
    }

    func testEmptyDrawingExportsNothing() {
        XCTAssertNil(HandwritingExporter.export(drawing: PKDrawing(), width: 320, paper: .grid))
    }

    func testExportKeepsWidthAndCropsBelowLowestStroke() throws {
        let d = drawing(from: CGPoint(x: 40, y: 60), to: CGPoint(x: 200, y: 100))
        let output = try XCTUnwrap(HandwritingExporter.export(drawing: d, width: 320, paper: .grid))
        let image = try XCTUnwrap(UIImage(data: output.png))
        let expectedHeight = ceil(d.bounds.maxY + HandwritingExporter.bottomMargin)
        XCTAssertEqual(image.size.width * image.scale, 320 * HandwritingExporter.scale, accuracy: 1)
        XCTAssertEqual(image.size.height * image.scale, expectedHeight * HandwritingExporter.scale, accuracy: 1)
        XCTAssertNotNil(UIImage(data: output.ocrImage))
    }
}
