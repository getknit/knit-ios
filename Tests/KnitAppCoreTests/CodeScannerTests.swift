import Testing

@testable import KnitAppCore

/// The scanner's camera gate (ADR 2026-10.65xx): a device that cannot scan never asks, the first scan asks, and a
/// refusal points to Settings.
@MainActor
@Suite struct CodeScannerTests {
    @Test func aDeviceThatCannotScanNeverAsks() async {
        let camera = FakeCamera(scans: false)
        let model = CodeScannerModel(camera: camera)
        #expect(model.phase == .checking)
        #expect(model.text == nil)
        await model.prepare()
        #expect(model.phase == .unsupported)
        #expect(model.text == Copy.Scan.unsupported)
        #expect(camera.requests == 0)
    }

    @Test func theFirstScanAsksAndAnAllowStartsTheCamera() async {
        let camera = FakeCamera(onRequest: .allowed)
        let model = CodeScannerModel(camera: camera)
        await model.prepare()
        #expect(model.phase == .scanning)
        #expect(model.text == Copy.Scan.hint)
        #expect(!model.offersSettings)
        #expect(camera.requests == 1)
    }

    @Test func aRefusalPointsToSettings() async {
        let camera = FakeCamera(onRequest: .denied)
        let model = CodeScannerModel(camera: camera)
        await model.prepare()
        #expect(model.phase == .denied)
        #expect(model.text == Copy.Scan.denied)
        #expect(model.offersSettings)
    }

    @Test(arguments: [CameraAuthorization.allowed, .denied])
    func anAnswerAlreadyGivenIsNeverAskedAgain(answer: CameraAuthorization) async {
        let camera = FakeCamera(current: answer)
        let model = CodeScannerModel(camera: camera)
        await model.prepare()
        #expect(model.phase == (answer == .allowed ? .scanning : .denied))
        #expect(camera.requests == 0)
    }

    @Test func comingBackFromSettingsStartsTheCamera() async {
        let camera = FakeCamera(current: .denied)
        let model = CodeScannerModel(camera: camera)
        await model.prepare()
        #expect(model.phase == .denied)
        camera.change(to: .allowed)
        await model.prepare()
        #expect(model.phase == .scanning)
    }

    @Test func aCameraThatFailsSaysSo() async {
        let model = CodeScannerModel(camera: FakeCamera(current: .allowed))
        await model.prepare()
        model.failed()
        #expect(model.phase == .unavailable)
        #expect(model.text == Copy.Scan.unavailable)
        await model.prepare()
        #expect(model.phase == .scanning, "a second try starts it again")
    }

    @Test func everyPhaseHasItsOwnWordsAndIdentifier() async {
        let phases = CodeScannerModel.Phase.allCases
        #expect(Set(phases.map(CodeScannerModel.accessibilityState)).count == phases.count)
        let texts = [Copy.Scan.hint, Copy.Scan.denied, Copy.Scan.unsupported, Copy.Scan.unavailable]
        #expect(Set(texts).count == texts.count)
        let model = CodeScannerModel(camera: FakeCamera(scans: false))
        #expect(model.accessibilityState == .checking)
        await model.prepare()
        #expect(model.accessibilityState == .unsupported)
    }
}
