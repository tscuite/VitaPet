import AIEngine
import XCTest

final class AIModelSelectionTests: XCTestCase {
    func testExplicitPreviousDefaultIsPreservedAcrossBackendChange() {
        XCTAssertEqual(
            AIModelSelection.resolvedModel("llama3.2", for: .openAICompatible),
            "llama3.2"
        )
    }

    func testExplicitCustomModelIsTrimmedAndPreserved() {
        XCTAssertEqual(
            AIModelSelection.resolvedModel("  custom-tencent/hy3-preview  ", for: .openAICompatible),
            "custom-tencent/hy3-preview"
        )
    }

    func testBlankModelUsesSelectedBackendDefault() {
        XCTAssertEqual(
            AIModelSelection.resolvedModel(" \n\t ", for: .openAICompatible),
            AIBackend.openAICompatible.defaultModel
        )
    }
}
