import RemoteAPI
import XCTest

final class OnboardingStateTests: XCTestCase {
  func testOfferedLocalModelsPreselectByMemory() {
    let gibibyte: UInt64 = 1_024 * 1_024 * 1_024
    let qwen2 = "qwen_3.8_27b_i2x.ckpt"
    let qwen4 = "qwen_3.8_27b_i4x.ckpt"
    let deepSeek4 = "deepseek_4_flash_0731_i2x.ckpt"
    let deepSeek41 = "deepseek_4.1_flash_1017_i2x.ckpt"
    // Both DeepSeek variants are always offered; only the preselected first entry changes.
    for memory in [8, 16, 18, 24] {
      XCTAssertEqual(
        OnboardingState.offeredLocalModels(physicalMemory: UInt64(memory) * gibibyte),
        [qwen2, deepSeek41, deepSeek4])
    }
    for memory in [32, 36, 48] {
      XCTAssertEqual(
        OnboardingState.offeredLocalModels(physicalMemory: UInt64(memory) * gibibyte),
        [qwen4, deepSeek41, deepSeek4])
    }
    for memory in [64, 72] {
      XCTAssertEqual(
        OnboardingState.offeredLocalModels(physicalMemory: UInt64(memory) * gibibyte),
        [deepSeek4, deepSeek41, qwen4])
    }
    for memory in [96, 128, 256] {
      XCTAssertEqual(
        OnboardingState.offeredLocalModels(physicalMemory: UInt64(memory) * gibibyte),
        [deepSeek41, deepSeek4, qwen4])
    }
    XCTAssertEqual(
      OnboardingState.offeredLocalModels(physicalMemory: 32 * gibibyte - 1).first, qwen2)
    XCTAssertEqual(
      OnboardingState.offeredLocalModels(physicalMemory: 64 * gibibyte - 1).first, qwen4)
    XCTAssertEqual(
      OnboardingState.offeredLocalModels(physicalMemory: 96 * gibibyte - 1).first, deepSeek4)
  }

  func testSignedInAccountIsOmittedFromProgressAndBothNavigationDirections() {
    for selection in [OnboardingState.Selection.local]
      + RemoteProvider.allCases.map(OnboardingState.Selection.remote)
    {
      var state = OnboardingState(
        step: .model, selection: selection, welcomeCompleted: true, isAccountSignedIn: true,
        isProviderConnected: true, isModelSelected: true)
      XCTAssertEqual(state.steps, [.welcome, .model, .finished])
      state.advance()
      XCTAssertEqual(state.step, .finished)
      state.goBack()
      XCTAssertEqual(state.step, .model)
      state.goBack()
      XCTAssertEqual(state.step, .welcome)
      state.advance()
      XCTAssertEqual(state.step, .model)
    }
  }

  func testSignedInRouterWaitsForProvisioningOnModelStep() {
    var state = OnboardingState(
      step: .model, selection: .remote(.localCode), isAccountSignedIn: true)
    state.advance()
    XCTAssertEqual(state.step, .model)
    state.isProviderConnected = true
    XCTAssertFalse(state.canContinue)
    state.isModelSelected = true
    state.advance()
    XCTAssertEqual(state.step, .finished)
  }

  func testWelcomeCannotAdvanceUntilAnimationAndHoldComplete() {
    var state = OnboardingState()
    state.advance()
    XCTAssertEqual(state.step, .welcome)
    state.welcomeCompleted = true
    state.advance()
    XCTAssertEqual(state.step, .model)
  }

  func testLocalCanSkipAccountWithoutCredentials() {
    var state = OnboardingState(step: .model)
    state.advance()
    XCTAssertEqual(state.step, .account)
    XCTAssertTrue(state.canSkipAccount)
    state.advance()
    XCTAssertEqual(state.step, .finished)
    XCTAssertTrue(state.canContinue)
  }

  func testRouterRequiresSignInAndProvisionedModel() {
    var state = OnboardingState(step: .model, selection: .remote(.localCode))
    state.advance()
    XCTAssertEqual(state.step, .account)
    XCTAssertFalse(state.canSkipAccount)
    state.advance()
    XCTAssertEqual(state.step, .account)
    state.isAccountSignedIn = true
    state.isProviderConnected = true
    XCTAssertFalse(state.canContinue)
    state.isModelSelected = true
    XCTAssertTrue(state.canContinue)
    state.advance()
    XCTAssertEqual(state.step, .finished)
    state.isAccountSignedIn = false
    XCTAssertFalse(state.canContinue)
  }

  func testOtherProvidersRequireConnectionAndModelButNotLocalCodeAccount() {
    for provider in RemoteProvider.allCases where provider != .localCode {
      var state = OnboardingState(step: .model, selection: .remote(provider))
      XCTAssertFalse(state.canContinue)
      XCTAssertFalse(state.canSkipAccount)
      state.isProviderConnected = true
      XCTAssertTrue(state.canSkipAccount)
      XCTAssertFalse(state.canContinue)
      state.isModelSelected = true
      state.advance()
      XCTAssertEqual(state.step, .account)
      XCTAssertTrue(state.canContinue)
      state.advance()
      XCTAssertEqual(state.step, .finished)
      state.isProviderConnected = false
      XCTAssertFalse(state.canContinue)
    }
  }

  func testChangingSelectionRevalidatesAccountAndBackPreservesProgress() {
    var state = OnboardingState(step: .account, welcomeCompleted: true)
    XCTAssertTrue(state.canSkipAccount)
    state.selection = .remote(.localCode)
    XCTAssertFalse(state.canSkipAccount)
    XCTAssertFalse(state.canContinue)
    state.goBack()
    XCTAssertEqual(state.step, .model)
    XCTAssertTrue(state.welcomeCompleted)
    state.goBack()
    state.goBack()
    XCTAssertEqual(state.step, .welcome)
  }
}
