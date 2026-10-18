import XCTest

/// Captures every main screen for visual review. Uses isolated public fixtures
/// only, and never captures a revealed recovery phrase. Set BITTOOL_SIGNER_SHOT_DIR
/// (via the TEST_RUNNER_ prefix) to also save PNGs on the host.
final class ScreenshotTour: XCTestCase {
    private let publicRecoveryPhrase = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"
    private let fixturePassword = "Public-Test-Password1!"
    private let publicSigningRequest = "UR:ETH-SIGN-REQUEST/OSADTPDAGDMYCNHYNLVAVSFZFYONCAGYWPFMSOFWPFAOHDECFWINJYGUINIOJTIHJPCXJOKPIDJZINIACXGOGACXIYINKSJYKPJPIHDMCXGLJLCXIYKPJTIEJKCXJLJPCXJOIHJPJNINJKJKINJLJTJKDMAXAXAAADAHTAADDYOEADLECSDWYKCSFNYKAEYKAEWKAEWKAOCYJKSKTNBKAMGHMKHDWSZCCNDNFZEOVEKIMHAEFSFPWPEEWPPLTNMWATJKGDKPIDJZINIACXJYIHJKJYCXIYINKSJYKPJPIHFWHGMKCH"
    /// Unlimited USDT approval to Permit2: the one request in the tour that
    /// shows the known-contract notice.
    private let approveKnownSpenderRequest = "UR:ETH-SIGN-REQUEST/OLADTPDAGDNDCAWMGTFRKIGRPMNDUTDNBTKGFSSBJNAOHDJOAOYAJNADATLRFRNYSGAELPAAPDCHSPAELFWDHNMWTNSELBMDLGDMVWCNOECXIDAMNLFEMSSEFSLSCKSTLAROFYASHYOSQDAEAEAEAEAEAEAEAEAEAEAEAEAEAEAEAEAECPTYJKAXBSBYJNUEWLYNQZFTSTLUOTZMZMZMZMZMZMZMZMZMZMZMZMZMZMZMZMZMZMZMZMZMZMZMZMZMZMZMZMZMZMZMZMRTAXAAAAADAHTAADDYOEADLECSDWYKCSFNYKAEYKAEWKAEWKAOCYJKSKTNBKAMGHMKHDWSZCCNDNFZEOVEKIMHAEFSFPWPEEWPPLTNMWDIFDNSZE"
    private var prefix = "light"

    override func setUpWithError() throws { continueAfterFailure = true }

    @MainActor func testTourLight() throws { try tour(dark: false) }
    @MainActor func testTourDark() throws { try tour(dark: true) }

    @MainActor private func tour(dark: Bool) throws {
        prefix = dark ? "dark" : "light"
        setupScreens(dark: dark)
        let run = walletScreens(dark: dark)
        lockScreens(dark: dark, run: run)
    }

    // MARK: Welcome, onboarding, import and create

    @MainActor private func setupScreens(dark: Bool) {
        let app = launch(fixtures: 0, dark: dark)
        shot(app, "01-welcome")
        app.buttons["welcome.import"].tap()
        if app.buttons["onboarding.next"].waitForExistence(timeout: 3) {
            // Wait for each page before tapping, so a tap never lands mid-animation.
            for (page, name) in [(1, "02-onboarding-1"), (2, "03-onboarding-2"), (3, "04-onboarding-3")] {
                let indicator = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Page \(page) of 3")).firstMatch
                _ = indicator.waitForExistence(timeout: 5); sleep(1)
                shot(app, name)
                app.buttons["onboarding.next"].tap()
            }
        }
        let input = app.textViews["recovery.input.visible"]
        guard input.waitForExistence(timeout: 5) else { return }
        input.tap(); input.typeText(String(publicRecoveryPhrase.dropLast(3)))
        sleep(1); shot(app, "05-import-phrase")
        input.typeText("out")
        tap(app, app.buttons["setup.import"])
        let password = app.secureTextFields["Wallet password"]
        guard password.waitForExistence(timeout: 20) else { return }
        // Move between fields with Return, as people do; the focused field must
        // scroll into view above the keyboard on small screens.
        password.tap(); password.typeText(fixturePassword + "\n")
        sleep(1); shot(app, "06-password-confirm-focus")
        app.typeText(fixturePassword)
        sleep(1); shot(app, "06-password")
        tap(app, app.buttons["setup.finish"])
        guard app.buttons["setup.done"].waitForExistence(timeout: 60) else { return }
        sleep(1); shot(app, "07-imported")
        app.buttons["setup.done"].tap()
        sleep(2); shot(app, "08-wallets-first")

        app.buttons["wallets.add"].tap()
        let create = app.buttons["Create New Wallet"]
        if create.waitForExistence(timeout: 3) {
            create.tap()
            if app.buttons["setup.create"].waitForExistence(timeout: 5) {
                sleep(1); shot(app, "09-create")
                app.buttons["12 words"].tap()
                app.buttons["setup.create"].tap()
                if app.buttons["recovery.reveal"].waitForExistence(timeout: 10) {
                    sleep(1); shot(app, "09b-backup-concealed")
                    app.segmentedControls["backup.format"].buttons["QR Code"].tap()
                    sleep(1); shot(app, "09c-backup-qr-tab")
                    // A revealed QR code or card holds real (throwaway) words: disk only, never attached.
                    tap(app, app.buttons["backup.qr.reveal"])
                    if app.descendants(matching: .any)["backup.qr"].firstMatch.waitForExistence(timeout: 5) {
                        sleep(1); shot(app, "09d-backup-qr-revealed", sensitive: true)
                        tap(app, app.buttons["backup.qr.hide"])
                    }
                    app.segmentedControls["backup.format"].buttons["Words"].tap()
                    tap(app, app.buttons["backup.cards"])
                    if app.buttons["cards.reveal"].waitForExistence(timeout: 5) {
                        sleep(1); shot(app, "09e-recovery-cards")
                        tap(app, app.buttons["cards.reveal"])
                        sleep(1); shot(app, "09e-recovery-cards-revealed", sensitive: true)
                        app.navigationBars["Recovery Cards"].buttons["Done"].tap(); sleep(1)
                    }
                    tap(app, app.buttons["backup.tips"])
                    if app.navigationBars["Security Tips"].waitForExistence(timeout: 3) {
                        sleep(1); shot(app, "09f-security-tips")
                        app.navigationBars["Security Tips"].buttons["Done"].tap(); sleep(1)
                    }
                    tap(app, app.buttons["recovery.reveal"])
                    tap(app, app.buttons["recovery.hide"])
                    tap(app, app.buttons["backup.continue"])
                    if app.buttons["verification.continue"].waitForExistence(timeout: 5) {
                        let first = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "verification.chip.")).firstMatch
                        if first.exists { first.tap() }
                        sleep(1); shot(app, "09g-verify-board", sensitive: true)
                    }
                }
                app.navigationBars.buttons["Cancel"].firstMatch.tap()
                if app.buttons["Discard"].waitForExistence(timeout: 3) { app.buttons["Discard"].tap() }
            }
        }
        // Another language: a public Spanish test phrase typed without accents.
        sleep(2)
        app.buttons["wallets.add"].tap()
        let importItem = app.buttons["Import Recovery Phrase"]
        if importItem.waitForExistence(timeout: 3) {
            importItem.tap()
            let spanish = app.textViews["recovery.input.visible"]
            if spanish.waitForExistence(timeout: 5) {
                spanish.tap(); spanish.typeText("obra diadema gorila farmacia colgar gorra pausa talar cocina duda dragon optar")
                sleep(1); shot(app, "05b-import-spanish")
                app.navigationBars.buttons["Cancel"].firstMatch.tap()
                if app.buttons["Discard"].waitForExistence(timeout: 3) { app.buttons["Discard"].tap() }
            }
        }
        app.terminate()
    }

    // MARK: Wallets, signing, activity and settings

    @MainActor private func walletScreens(dark: Bool) -> String {
        let app = launch(fixtures: 2, dark: dark)
        let run = app.launchEnvironment["BITTOOL_SIGNER_UI_TEST_RUN"]!
        shot(app, "10-wallets")
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "wallet.card.")).firstMatch.tap()
        sleep(1); shot(app, "11-wallet-detail")
        app.swipeUp(); sleep(1); shot(app, "12-wallet-detail-bottom")
        for (id, name, cancel) in [("detail.changePassword", "19a-change-password", "Change Password"),
                                   ("detail.recoveryPhrase", "19b-recovery-password", "Recovery Phrase"),
                                   ("detail.delete", "19c-delete", "Delete Wallet")] {
            tap(app, app.buttons[id])
            if app.navigationBars[cancel].waitForExistence(timeout: 5) {
                sleep(1); shot(app, name)
                app.navigationBars[cancel].buttons["Cancel"].tap(); sleep(1)
            }
        }
        goBack(app); sleep(1)
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "wallet.connect.")).firstMatch.tap()
        sleep(3); shot(app, "15c-connect-wallet-level")
        app.swipeUp(); sleep(1); shot(app, "15d-connect-wallet-level-verify")
        app.swipeDown(); app.swipeDown(); sleep(1)
        if app.segmentedControls["connect.level"].waitForExistence(timeout: 3) {
            app.segmentedControls["connect.level"].buttons["Coin Level"].tap(); sleep(2)
        }
        shot(app, "13-connect-btc")
        app.swipeUp(); sleep(1); shot(app, "14-connect-btc-bottom")
        app.swipeDown(); sleep(1)
        for chain in ["evm", "tron", "solana"] {
            let button = app.buttons["chain." + chain]
            if button.waitForExistence(timeout: 3) { button.tap(); sleep(2); shot(app, "15-connect-" + chain) }
            if chain == "tron", app.steppers["connect.tronIndex"].waitForExistence(timeout: 3) {
                let increment = app.steppers["connect.tronIndex"].buttons["Increment"]
                if increment.exists { increment.tap(); increment.tap(); sleep(2); shot(app, "15b-connect-tron-index") }
            }
        }
        goBack(app); sleep(1)
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "wallet.addresses.")).firstMatch.tap()
        sleep(2); shot(app, "16-addresses-btc")
        app.buttons["chain.evm"].tap(); sleep(2); shot(app, "17-addresses-evm")
        app.buttons["chain.tron"].tap(); sleep(2); shot(app, "17c-addresses-tron")
        app.buttons["chain.solana"].tap(); sleep(2); shot(app, "17b-addresses-solana")
        app.buttons["chain.evm"].tap(); sleep(2)
        if app.buttons["address.row.1"].waitForExistence(timeout: 5) {
            app.buttons["address.row.1"].tap(); sleep(2); shot(app, "18-address-detail")
            if app.buttons["Done"].exists { app.buttons["Done"].tap(); sleep(1) }
        }

        openTab(app, "Scan"); sleep(1); shot(app, "20-scan")
        app.buttons["signing.paste"].tap()
        let payload = app.textViews["signing.payload"]
        if payload.waitForExistence(timeout: 3) {
            payload.tap(); payload.typeText(publicSigningRequest); shot(app, "21-paste")
            app.buttons["signing.decode"].tap()
        }
        let sign = app.buttons["signing.authorize"]
        if sign.waitForExistence(timeout: 20) {
            sleep(2); shot(app, "22-review")
            app.swipeUp(); sleep(1); shot(app, "23-review-middle")
            app.swipeUp(); sleep(1); shot(app, "24-review-bottom")
            let risk = app.buttons["signing.risk"]
            if risk.exists { risk.tap(); sleep(1); shot(app, "24b-review-acknowledged") }
            sign.tap()
            let password = app.secureTextFields["Wallet password"]
            if password.waitForExistence(timeout: 5) {
                sleep(1); shot(app, "25-authorize")
                password.tap(); password.typeText(fixturePassword)
                app.buttons["authorize.sign"].tap()
            }
            if app.staticTexts["signature.title"].waitForExistence(timeout: 30) {
                sleep(2); shot(app, "26-signature")
                app.swipeUp(); sleep(1); shot(app, "27-signature-bottom")
                tap(app, app.buttons["signature.done"])
            }
        }
        // A dApp approval: the summary names the spender from the bundled library.
        openTab(app, "Scan"); sleep(1)
        if app.buttons["signing.paste"].waitForExistence(timeout: 5) {
            app.buttons["signing.paste"].tap()
            if payload.waitForExistence(timeout: 3) {
                payload.tap(); payload.typeText(approveKnownSpenderRequest)
                app.buttons["signing.decode"].tap()
            }
            if app.buttons["signing.authorize"].waitForExistence(timeout: 20) {
                sleep(2); shot(app, "28-review-known-contract")
                app.swipeUp(); sleep(1); shot(app, "29-review-known-contract-warnings")
                tap(app, app.buttons["signing.reject"]); sleep(1)
            }
        }

        openTab(app, "Activity"); sleep(1); shot(app, "30-activity")
        let row = app.buttons["activity.row"].firstMatch
        if row.exists {
            row.tap(); sleep(2); shot(app, "31-activity-detail")
            app.swipeUp(); sleep(2); shot(app, "31b-activity-input-output")
            if app.buttons["activity.decoded"].exists {
                tap(app, app.buttons["activity.decoded"]); sleep(2); shot(app, "31c-activity-signed-request")
                goBack(app); sleep(1); app.swipeUp(); sleep(1)
            }
            if app.buttons["activity.showQR"].exists {
                tap(app, app.buttons["activity.showQR"]); sleep(2); shot(app, "31d-activity-signature-qr")
                if app.buttons["Done"].firstMatch.exists { app.buttons["Done"].firstMatch.tap(); sleep(1) }
            }
            goBack(app); sleep(1)
        }

        openTab(app, "Settings"); sleep(1); shot(app, "40-settings")
        app.swipeUp(); sleep(1); shot(app, "41-settings-bottom")
        app.swipeDown(); sleep(1)
        tap(app, app.buttons["Networks, Tokens & Contracts"]); sleep(2); shot(app, "42-networks")
        tap(app, app.buttons["network.ethereum"]); sleep(2); shot(app, "43-tokens-ethereum")
        goBack(app); sleep(1)
        tap(app, app.buttons["network.solana"]); sleep(2); shot(app, "44-tokens-solana")
        goBack(app); sleep(1)
        tap(app, app.buttons["network.tron"]); sleep(2); shot(app, "44b-tokens-tron")
        goBack(app); sleep(1)
        // The same page browses the known-contract library.
        tap(app, app.buttons["network.ethereum"]); sleep(2)
        let contracts = app.segmentedControls.buttons.element(boundBy: 1)
        if contracts.waitForExistence(timeout: 5) { contracts.tap(); sleep(2); shot(app, "44c-contracts-ethereum") }
        goBack(app); sleep(1)
        app.swipeUp(); sleep(1); shot(app, "44d-contracts-section")
        if app.buttons["contracts.everyChain"].waitForExistence(timeout: 3) {
            tap(app, app.buttons["contracts.everyChain"]); sleep(2); shot(app, "44e-contracts-every-chain")
            goBack(app); sleep(1)
        }
        app.swipeDown(); sleep(1)
        goBack(app); sleep(1)
        tap(app, app.buttons["Compatibility"]); sleep(1); shot(app, "45-compatibility")
        app.swipeUp(); sleep(1); shot(app, "46-compatibility-bottom")
        goBack(app); sleep(1)
        if app.buttons["settings.openSource"].waitForExistence(timeout: 3) {
            tap(app, app.buttons["settings.openSource"]); sleep(2); shot(app, "46a-open-source")
            goBack(app); sleep(1)
        }
        tap(app, app.buttons["Terms of Use"]); sleep(1); shot(app, "46b-terms-of-use")
        scrollToContact(app); shot(app, "46b2-terms-of-use-bottom")
        goBack(app); sleep(1)
        tap(app, app.buttons["Privacy Policy"]); sleep(1); shot(app, "46c-privacy-policy")
        scrollToContact(app); shot(app, "46c2-privacy-policy-bottom")
        goBack(app); sleep(1)
        app.terminate()
        return run
    }

    // MARK: App Lock

    @MainActor private func lockScreens(dark: Bool, run: String) {
        let app = XCUIApplication()
        app.launchArguments = ["--bittool-signer-ui-tests", "--app-lock-enabled", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"] + extraArguments
        if dark { app.launchArguments.append("--dark-appearance") }
        app.launchEnvironment = ["BITTOOL_SIGNER_UI_TEST_RUN": run]
        app.launch()
        guard app.buttons["appLock.usePassword"].waitForExistence(timeout: 15) else { return }
        sleep(2); shot(app, "50-app-lock")
        app.buttons["appLock.usePassword"].tap(); sleep(1); shot(app, "51-app-lock-password")
        app.terminate()
    }

    // MARK: Helpers

    /// Optional extra launch arguments, e.g. a Dynamic Type size:
    /// TEST_RUNNER_BITTOOL_SIGNER_EXTRA_ARGS="-UIPreferredContentSizeCategoryName UICTContentSizeCategoryAccessibilityL"
    private var extraArguments: [String] {
        (ProcessInfo.processInfo.environment["BITTOOL_SIGNER_EXTRA_ARGS"] ?? "").split(separator: " ").map(String.init)
    }

    @MainActor private func launch(fixtures: Int, dark: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--bittool-signer-ui-tests", "--reset-ui-fixtures", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"] + extraArguments
        if dark { app.launchArguments.append("--dark-appearance") }
        app.launchEnvironment = ["BITTOOL_SIGNER_UI_TEST_RUN": UUID().uuidString, "BITTOOL_SIGNER_UI_FIXTURE_COUNT": String(fixtures)]
        app.launch()
        if fixtures > 0 {
            let cards = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "wallet.card."))
            let deadline = Date().addingTimeInterval(120)
            while cards.count < fixtures && Date() < deadline { usleep(250_000) }
            sleep(1)
        } else {
            XCTAssertTrue(app.buttons["welcome.create"].waitForExistence(timeout: 20))
        }
        return app
    }

    @MainActor private func tap(_ app: XCUIApplication, _ element: XCUIElement) {
        var found = element.waitForExistence(timeout: 3)
        for _ in 0..<6 where !found { app.swipeUp(); found = element.waitForExistence(timeout: 1) }
        for _ in 0..<10 where !found { app.swipeDown(); found = element.waitForExistence(timeout: 1) }
        guard found else { XCTFail("Missing \(element)"); return }
        for _ in 0..<4 where !element.isHittable { app.swipeUp() }
        for _ in 0..<6 where !element.isHittable { app.swipeDown() }
        element.tap()
    }

    /// iPhone shows a tab bar; iPadOS 18+ shows the tabs as a floating top bar.
    @MainActor private func openTab(_ app: XCUIApplication, _ name: String) {
        // Retries while a sheet is still dismissing and the tab bar is being rebuilt.
        for _ in 0..<4 {
            let tab = app.tabBars.buttons[name]
            if tab.waitForExistence(timeout: 1), tab.isHittable { tab.tap(); return }
            let floating = app.buttons.matching(NSPredicate(format: "label == %@", name)).firstMatch
            if floating.exists, floating.isHittable { floating.tap(); return }
            sleep(1)
        }
        XCTFail("Missing tab \(name)")
    }

    @MainActor private func goBack(_ app: XCUIApplication) {
        let bar = app.navigationBars.firstMatch
        let back = bar.buttons["BackButton"].exists ? bar.buttons["BackButton"] : bar.buttons.element(boundBy: 0)
        if back.exists { back.tap() }
    }

    /// Both legal documents end with the contact address; scrolling there also
    /// shows that the last block clears the tab bar.
    @MainActor private func scrollToContact(_ app: XCUIApplication) {
        let contact = app.staticTexts["https://bittool.com/signer"]
        for _ in 0 ..< 25 where !contact.isHittable { app.swipeUp() }
        XCTAssertTrue(contact.isHittable, "The contact address should be readable at the end of the page.")
        sleep(1)
    }

    /// `sensitive` shots contain throwaway test words: saved to the local shot
    /// directory for review only, never attached to test results.
    @MainActor private func shot(_ app: XCUIApplication, _ name: String, sensitive: Bool = false) {
        let image = XCUIScreen.main.screenshot()
        if !sensitive {
            let attachment = XCTAttachment(screenshot: image)
            attachment.name = prefix + "-" + name; attachment.lifetime = .keepAlways; add(attachment)
        }
        if let directory = ProcessInfo.processInfo.environment["BITTOOL_SIGNER_SHOT_DIR"] {
            let url = URL(fileURLWithPath: directory).appendingPathComponent(prefix + "-" + name + ".png")
            try? image.pngRepresentation.write(to: url)
        }
    }
}
