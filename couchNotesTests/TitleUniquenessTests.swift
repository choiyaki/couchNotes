import XCTest
@testable import couchNotes

final class TitleUniquenessTests: XCTestCase {
    func testTitleKeyIgnoresFolderExtensionCaseAndUnicodeForm() {
        let composed = "個人/が旅行計画.MD"
        let decomposed = "仕事/か\u{3099}旅行計画.md"
        XCTAssertEqual(NoteNaming.titleKey(fromPath: composed),
                       NoteNaming.titleKey(fromPath: decomposed))
    }

    func testImportAllowsOverwriteOfSamePath() {
        let existing = [NoteItem(id: "work/plan.md", path: "Work/Plan.md")]
        XCTAssertNil(NoteNaming.titleConflict(
            incomingPaths: ["work/PLAN.md"], existing: existing
        ))
    }

    func testImportRejectsSameTitleInDifferentFolders() {
        let existing = [NoteItem(id: "work/plan.md", path: "Work/Plan.md")]
        XCTAssertNotNil(NoteNaming.titleConflict(
            incomingPaths: ["Private/Plan.md"], existing: existing
        ))
    }

    func testImportRejectsDuplicatesWithinIncomingFiles() {
        XCTAssertNotNil(NoteNaming.titleConflict(
            incomingPaths: ["Work/Plan.md", "Private/plan.md"], existing: []
        ))
    }
}
