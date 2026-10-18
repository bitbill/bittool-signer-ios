import XCTest

/// End-to-end flows against isolated simulator fixtures (never production vaults).
///
/// Restore uses a public, unfunded BIP39 test vector. Creation uses fresh random
/// phrases that are read into local memory only: never log them, put them in
/// failure messages or attach screenshots while words or word choices are visible.
final class BitToolSignerUITests: XCTestCase {
    private let publicRecoveryPhrase = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"
    private let fixturePassword = "Public-Test-Password1!"
    private let publicSigningRequest = "UR:ETH-SIGN-REQUEST/OSADTPDAGDMYCNHYNLVAVSFZFYONCAGYWPFMSOFWPFAOHDECFWINJYGUINIOJTIHJPCXJOKPIDJZINIACXGOGACXIYINKSJYKPJPIHDMCXGLJLCXIYKPJTIEJKCXJLJPCXJOIHJPJNINJKJKINJLJTJKDMAXAXAAADAHTAADDYOEADLECSDWYKCSFNYKAEYKAEWKAEWKAOCYJKSKTNBKAMGHMKHDWSZCCNDNFZEOVEKIMHAEFSFPWPEEWPPLTNMWATJKGDKPIDJZINIACXJYIHJKJYCXIYINKSJYKPJPIHFWHGMKCH"
    /// Fixture 1 approving unlimited USDT to Permit2, whose address is in the
    /// bundled known-contract library at the same address on every EVM network.
    private let approveKnownSpenderRequest = "UR:ETH-SIGN-REQUEST/OLADTPDAGDNDCAWMGTFRKIGRPMNDUTDNBTKGFSSBJNAOHDJOAOYAJNADATLRFRNYSGAELPAAPDCHSPAELFWDHNMWTNSELBMDLGDMVWCNOECXIDAMNLFEMSSEFSLSCKSTLAROFYASHYOSQDAEAEAEAEAEAEAEAEAEAEAEAEAEAEAEAEAECPTYJKAXBSBYJNUEWLYNQZFTSTLUOTZMZMZMZMZMZMZMZMZMZMZMZMZMZMZMZMZMZMZMZMZMZMZMZMZMZMZMZMZMZMZMZMRTAXAAAAADAHTAADDYOEADLECSDWYKCSFNYKAEYKAEWKAEWKAOCYJKSKTNBKAMGHMKHDWSZCCNDNFZEOVEKIMHAEFSFPWPEEWPPLTNMWDIFDNSZE"
    /// The same approval to an address the library does not list.
    private let approveUnlistedSpenderRequest = "UR:ETH-SIGN-REQUEST/OLADTPDAGDNDCAWMGTFRKIGRPMNDUTDNBTKGFSSBJNAOHDJOAOYAJNADATLRFRNYSGAELPAAPDCHSPAELFWDHNMWTNSELBMDLGDMVWCNOECXIDAMNLFEMSSEFSLSCKSTLAROFYASHYOSQDAEAEAEAEAEAEAEAEAEAEAEAEBYBYBYBYBYBYBYBYBYBYBYBYBYBYBYBYBYBYBYBYAEAEAEAEAEAEAEAEAEAEAEAEAEAEAEAEAEAEAEAEAEAEAEAEAEAEAEAEAEBSFWFZRTAXAAAAADAHTAADDYOEADLECSDWYKCSFNYKAEYKAEWKAEWKAOCYJKSKTNBKAMGHMKHDWSZCCNDNFZEOVEKIMHAEFSFPWPEEWPPLTNMWMEWZMEJO"

    override func setUpWithError() throws { continueAfterFailure = false }

    // MARK: - Welcome and setup

    @MainActor
    func testOnboardingKeepsImportIntentAndIsShownOnce() throws {
        let app = launch()
        XCTAssertFalse(app.tabBars.firstMatch.exists, "No tabs before the first wallet exists.")
        // The welcome links open the bundled documents in a sheet, not a browser.
        tap(app.buttons["welcome.privacy"], in: app)
        XCTAssertTrue(app.navigationBars["Privacy Policy"].waitForExistence(timeout: 5))
        XCTAssertTrue(element(containing: "collects nothing", in: app).waitForExistence(timeout: 5))
        app.buttons["legal.done"].tap()
        XCTAssertTrue(app.buttons["welcome.import"].waitForExistence(timeout: 5))
        app.buttons["welcome.import"].tap()
        XCTAssertTrue(app.staticTexts["Offline by Design"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Skip"].exists, "Safety guidance has no Skip.")
        for page in 1...3 {
            XCTAssertTrue(element(labeled: "Page \(page) of 3", in: app).waitForExistence(timeout: 3))
            app.buttons["onboarding.next"].tap()
        }
        assertStep(1, of: 2, in: app)
        XCTAssertTrue(app.navigationBars["Import Wallet"].exists, "The Import choice must survive the introduction.")

        let input = app.textViews["recovery.input.visible"]
        input.tap(); input.typeText("abandon abandon abandon")
        XCTAssertTrue(app.descendants(matching: .any)["recovery.status"].label.contains("3 words"))
        tap(app.buttons["setup.import"], in: app)
        XCTAssertTrue(element(containing: "Invalid recovery phrase", in: app).waitForExistence(timeout: 10))

        app.navigationBars["Import Wallet"].buttons["Cancel"].tap()
        let discard = app.buttons["Discard"]
        XCTAssertTrue(discard.waitForExistence(timeout: 3), "Typed words must not be dropped without confirmation.")
        discard.tap()
        XCTAssertTrue(app.buttons["welcome.create"].waitForExistence(timeout: 5))
        app.buttons["welcome.create"].tap()
        assertStep(1, of: 4, in: app)
        XCTAssertFalse(app.staticTexts["Offline by Design"].exists, "The introduction is shown once.")
    }

    @MainActor
    func testImportSealsWalletAndOpensWallets() throws {
        let app = launch()
        openSetup(.restore, in: app)
        let input = app.textViews["recovery.input.visible"]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        input.tap(); input.typeText(publicRecoveryPhrase)
        XCTAssertTrue(app.descendants(matching: .any)["recovery.status"].label.contains("12 words"))
        tap(app.buttons["setup.import"], in: app)

        assertStep(2, of: 2, in: app)
        let finish = app.buttons["setup.finish"]
        XCTAssertFalse(finish.isEnabled)
        type(fixturePassword, into: app.secureTextFields["Wallet password"])
        type("Mismatch-Password1!", into: app.secureTextFields["Confirm password"])
        XCTAssertFalse(finish.isEnabled, "Mismatched passwords must not seal the wallet.")
        clear(app.secureTextFields["Confirm password"], count: 19)
        type(fixturePassword, into: app.secureTextFields["Confirm password"])
        tap(finish, in: app)

        XCTAssertTrue(app.staticTexts["Wallet Imported"].waitForExistence(timeout: 60))
        tap(app.buttons["setup.done"], in: app)
        let card = walletCards(in: app).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 30))
        XCTAssertTrue(card.label.contains("My Wallet"))
        XCTAssertTrue(app.tabBars.buttons["Scan"].exists)
        XCTAssertFalse(app.buttons["welcome.create"].exists)
    }

    @MainActor
    func testCreateRequiresRevealBackupCheckAndPassword() throws {
        let app = launch()
        openSetup(.create, in: app)
        assertStep(1, of: 4, in: app)
        app.buttons["12 words"].tap()
        tap(app.buttons["setup.create"], in: app)

        assertStep(2, of: 4, in: app)
        let reveal = app.buttons["recovery.reveal"]
        let firstWord = app.descendants(matching: .any)["recovery.word.0"].firstMatch
        let written = app.buttons["backup.continue"]
        XCTAssertTrue(reveal.waitForExistence(timeout: 10))
        XCTAssertFalse(firstWord.exists, "A new phrase starts concealed.")
        XCTAssertFalse(written.isEnabled, "The words must be revealed before they can be written down.")
        attach(app, "Concealed backup")

        let words = revealWords(in: app)
        XCTAssertFalse(app.alerts.firstMatch.exists, "Tap to Reveal shows the words directly, without a confirmation.")
        XCTAssertTrue(written.isEnabled)
        tap(app.buttons["recovery.hide"], in: app)
        XCTAssertTrue(reveal.waitForExistence(timeout: 3))
        XCTAssertFalse(firstWord.exists)

        backgroundAndReactivate(app)
        assertStep(2, of: 4, in: app)
        XCTAssertFalse(firstWord.exists, "Returning from background must require fresh consent.")
        XCTAssertTrue(revealWords(in: app) == words, "Suspending must conceal the draft, not replace it.")

        tap(written, in: app)
        assertStep(3, of: 4, in: app)
        XCTAssertFalse(firstWord.exists, "The check never shows the phrase.")
        let confirm = app.buttons["verification.continue"]
        XCTAssertFalse(confirm.isEnabled)

        let blanks = blankPositions(in: app)
        let chipOrder = chipLabels(in: app)
        XCTAssertEqual(blanks.count, 4, "A 12-word phrase blanks four positions.")
        XCTAssertEqual(chipOrder.sorted(), blanks.map { words[$0] }.sorted(), "The chips are exactly the missing words.")
        XCTAssertTrue(app.buttons["verification.slot.\(blanks[0])"].value as? String == "Empty, next to fill")

        // Words in the wrong order: a clear error, and the same blanks to fill again.
        fill(blanks, words: words, swapped: true, in: app)
        XCTAssertTrue(confirm.isEnabled)
        tap(confirm, in: app)
        XCTAssertTrue(element(containing: "Some words don", in: app).waitForExistence(timeout: 3))
        XCTAssertEqual(blankPositions(in: app), blanks, "A wrong answer keeps the same check.")
        XCTAssertEqual(chipLabels(in: app), chipOrder)
        assertBlanksEmpty(blanks, in: app)
        XCTAssertFalse(confirm.isEnabled)

        // Tapping a filled blank takes its word out again.
        fill([blanks[0]], words: words, in: app)
        tap(app.buttons["verification.slot.\(blanks[0])"], in: app)
        assertBlanksEmpty(blanks, in: app)

        fill(blanks, words: words, in: app)
        backgroundAndReactivate(app)
        assertStep(3, of: 4, in: app)
        XCTAssertEqual(blankPositions(in: app), blanks, "Backgrounding keeps the blanks and the chip order.")
        XCTAssertEqual(chipLabels(in: app), chipOrder)
        assertBlanksEmpty(blanks, in: app)
        fill(blanks, words: words, in: app)
        tap(confirm, in: app)

        assertStep(4, of: 4, in: app)
        let password = app.secureTextFields["Wallet password"]
        let confirmation = app.secureTextFields["Confirm password"]
        type("UiTest-Backup8!", into: password)
        type("UiTest-Backup8!", into: confirmation)
        XCTAssertTrue(app.buttons["setup.finish"].isEnabled)
        backgroundAndReactivate(app)
        assertStep(4, of: 4, in: app)
        assertEmptySecureField(password, placeholder: "Wallet password")
        assertEmptySecureField(confirmation, placeholder: "Confirm password")
        XCTAssertFalse(app.buttons["setup.finish"].isEnabled)
        type("UiTest-Backup8!", into: password)
        type("UiTest-Backup8!", into: confirmation)
        tap(app.buttons["setup.finish"], in: app)

        XCTAssertTrue(app.staticTexts["Wallet Created"].waitForExistence(timeout: 60))
        tap(app.buttons["setup.connect"], in: app)
        XCTAssertTrue(app.navigationBars["Pair Wallet"].waitForExistence(timeout: 10), "Pair opens on Wallet Level.")
        XCTAssertFalse(app.secureTextFields.firstMatch.exists, "Pairing uses public data only.")
        // The push after closing setup completes: the page is interactive and its QR loads.
        let copy = app.buttons["connect.copy"]
        XCTAssertTrue(waitUntilEnabled(copy), "The pairing QR loads once the Connect page has fully appeared.")
        XCTAssertEqual(app.segmentedControls["connect.level"].buttons.element(boundBy: 0).label, "Wallet Level")
        app.segmentedControls["connect.level"].buttons["Coin Level"].tap()
        XCTAssertTrue(app.navigationBars["Pair Bitcoin"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.segmentedControls["pairing.outputMode"].buttons.element(boundBy: 0).label, "Account XPUB")
        XCTAssertTrue(app.segmentedControls["pairing.outputMode"].buttons["Account XPUB"].isSelected,
                      "Account XPUB is the default Bitcoin export.")
        tap(app.buttons["chain.evm"], in: app)
        XCTAssertTrue(app.navigationBars["Pair EVM"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["chain.evm"].isSelected)
        XCTAssertFalse(app.buttons["chain.bitcoin"].isSelected)
    }

    @MainActor
    func testShowPhraseAgainReturnsToTheSameConcealedDraft() throws {
        let app = launch()
        openSetup(.create, in: app)
        app.buttons["12 words"].tap()
        tap(app.buttons["setup.create"], in: app)
        let words = revealWords(in: app)
        tap(app.buttons["backup.continue"], in: app)
        assertStep(3, of: 4, in: app)

        tap(app.buttons["verification.showPhrase"], in: app)
        assertStep(2, of: 4, in: app)
        XCTAssertFalse(app.descendants(matching: .any)["recovery.word.0"].firstMatch.exists)
        XCTAssertTrue(revealWords(in: app) == words, "Reviewing again must keep the same phrase.")
        tap(app.buttons["recovery.hide"], in: app)

        app.navigationBars.buttons["Cancel"].firstMatch.tap()
        let discard = app.buttons["Discard"]
        XCTAssertTrue(discard.waitForExistence(timeout: 3), "A generated phrase is only discarded after confirmation.")
        discard.tap()
        XCTAssertTrue(app.buttons["welcome.create"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testBackupOffersRecoveryCardsTipsAndAConcealedQR() throws {
        let app = launch()
        openSetup(.create, in: app)
        XCTAssertTrue(app.buttons["12 words"].waitForExistence(timeout: 10))
        app.buttons["12 words"].tap()
        tap(app.buttons["setup.create"], in: app)
        assertStep(2, of: 4, in: app)

        // Recovery cards (2 of 3) start concealed and show with one tap.
        tap(app.buttons["backup.cards"], in: app)
        XCTAssertTrue(app.navigationBars["Recovery Cards"].waitForExistence(timeout: 5))
        let cardsReveal = app.buttons["cards.reveal"]
        XCTAssertTrue(cardsReveal.waitForExistence(timeout: 3))
        let firstCard = app.descendants(matching: .any)["cards.card.0"].firstMatch
        XCTAssertFalse(firstCard.exists, "Cards start concealed.")
        XCTAssertTrue(element(containing: "12-word phrase", in: app).exists, "Short phrases warn that one card reveals too much.")
        cardsReveal.tap()
        XCTAssertFalse(app.alerts.firstMatch.waitForExistence(timeout: 1))
        XCTAssertTrue(firstCard.waitForExistence(timeout: 3))
        // Word 1 is left out of card 1 and present on cards 2 and 3.
        XCTAssertEqual(app.descendants(matching: .any)["cards.card.0.word.0"].firstMatch.label, "Word 1, not on this card")
        XCTAssertNotEqual(app.descendants(matching: .any)["cards.card.1.word.0"].firstMatch.label, "Word 1, not on this card")
        backgroundAndReactivate(app)
        XCTAssertFalse(firstCard.exists, "Backgrounding conceals the cards.")
        if app.navigationBars["Recovery Cards"].exists {
            app.navigationBars["Recovery Cards"].buttons["Done"].tap()
        }
        XCTAssertTrue(app.buttons["recovery.reveal"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["backup.continue"].isEnabled, "Showing the words on the cards counts as revealing them.")

        tap(app.buttons["backup.tips"], in: app)
        XCTAssertTrue(app.navigationBars["Security Tips"].waitForExistence(timeout: 3))
        app.navigationBars["Security Tips"].buttons["Done"].tap()

        // The QR code holds the plain phrase: concealed, shown with one tap, never shared.
        app.segmentedControls["backup.format"].buttons["QR Code"].tap()
        XCTAssertFalse(app.descendants(matching: .any)["recovery.word.0"].firstMatch.exists)
        let qrReveal = app.buttons["backup.qr.reveal"]
        XCTAssertTrue(qrReveal.waitForExistence(timeout: 3))
        XCTAssertFalse(app.descendants(matching: .any)["backup.qr"].firstMatch.exists)
        XCTAssertTrue(element(containing: "plain text", in: app).exists)
        qrReveal.tap()
        XCTAssertFalse(app.alerts.firstMatch.waitForExistence(timeout: 1))
        XCTAssertTrue(app.descendants(matching: .any)["backup.qr"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Save or Print"].exists, "The plain QR code is never offered for sharing.")
        // Content scrolls under the glass bottom bar, which XCUITest still reports as hittable.
        scrollClear(of: app.buttons["backup.continue"], app.buttons["backup.qr.hide"], in: app)
        app.buttons["backup.qr.hide"].tap()
        XCTAssertTrue(qrReveal.waitForExistence(timeout: 3))

        app.navigationBars.buttons["Cancel"].firstMatch.tap()
        let discard = app.buttons["Discard"]
        XCTAssertTrue(discard.waitForExistence(timeout: 3))
        discard.tap()
    }

    @MainActor
    func testImportAcceptsOtherLanguagesAndAsksWhenAmbiguous() throws {
        let app = launch()
        openSetup(.restore, in: app)
        let input = app.textViews["recovery.input.visible"]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        // A Spanish phrase typed without accents ("dragon" for "dragón").
        input.tap(); input.typeText("obra diadema gorila farmacia colgar gorra pausa talar cocina duda dragon optar")
        let status = app.descendants(matching: .any)["recovery.status"]
        XCTAssertTrue(status.label.contains("12 words"))
        XCTAssertTrue(status.label.contains("Español"), "The language is detected while typing.")
        tap(app.buttons["setup.import"], in: app)
        assertStep(2, of: 2, in: app)
        app.navigationBars.buttons["Cancel"].firstMatch.tap()
        let discard = app.buttons["Discard"]
        XCTAssertTrue(discard.waitForExistence(timeout: 3))
        discard.tap()

        // Valid Italian, and valid Spanish once accents are added: two wallets, so ask.
        openSetup(.restore, in: app)
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        input.tap(); input.typeText("nomina solido comodo nucleo pagina armonia nucleo liquido pagina logica nucleo nucleo")
        tap(app.buttons["setup.import"], in: app)
        let spanish = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Español")).firstMatch
        XCTAssertTrue(spanish.waitForExistence(timeout: 5), "The person chooses the language of their backup.")
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Italiano")).firstMatch.exists)
        spanish.tap()
        assertStep(2, of: 2, in: app)
        type(fixturePassword, into: app.secureTextFields["Wallet password"])
        type(fixturePassword, into: app.secureTextFields["Confirm password"])
        tap(app.buttons["setup.finish"], in: app)
        XCTAssertTrue(app.staticTexts["Wallet Imported"].waitForExistence(timeout: 60))
    }

    @MainActor
    func testImportDraftSurvivesBackground() throws {
        let app = launch()
        openSetup(.restore, in: app)
        let name = app.textFields["setup.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        clear(name, count: "My Wallet".count)
        type("Travel Signer", into: name)
        let input = app.textViews["recovery.input.visible"]
        input.tap(); input.typeText(publicRecoveryPhrase)

        backgroundAndReactivate(app)
        assertStep(1, of: 2, in: app)
        XCTAssertEqual(name.value as? String, "Travel Signer")
        XCTAssertEqual(input.value as? String, publicRecoveryPhrase)
        XCTAssertFalse(app.alerts.firstMatch.exists)

        tap(app.buttons["setup.import"], in: app)
        assertStep(2, of: 2, in: app)
        let password = app.secureTextFields["Wallet password"]
        type(fixturePassword, into: password)
        backgroundAndReactivate(app)
        assertEmptySecureField(password, placeholder: "Wallet password")

        goBack(in: app)
        assertStep(1, of: 2, in: app)
        XCTAssertEqual(input.value as? String, publicRecoveryPhrase)
        XCTAssertEqual(name.value as? String, "Travel Signer")
    }

    // MARK: - Signing

    @MainActor
    func testPastedRequestIsMatchedReviewedAndSignedWithPassword() throws {
        let app = launch(fixtures: 1)
        app.tabBars.buttons["Scan"].tap()
        XCTAssertTrue(app.buttons["signing.scan"].waitForExistence(timeout: 5))

        tap(app.buttons["signing.paste"], in: app)
        let payload = app.textViews["signing.payload"]
        XCTAssertTrue(payload.waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["signing.decode"].isEnabled)
        payload.tap(); payload.typeText("unsupported-qr-test-fixture")
        tap(app.buttons["signing.decode"], in: app)
        XCTAssertTrue(element(containing: "Unsupported", in: app).waitForExistence(timeout: 10))
        app.navigationBars["Paste Request"].buttons["Cancel"].tap()

        tap(app.buttons["signing.paste"], in: app)
        XCTAssertTrue(payload.waitForExistence(timeout: 3))
        typePayload(publicSigningRequest, into: payload, in: app)
        tap(app.buttons["signing.decode"], in: app)

        XCTAssertTrue(app.navigationBars["Review Request"].waitForExistence(timeout: 20))
        let sign = app.buttons["signing.authorize"]
        XCTAssertTrue(sign.waitForExistence(timeout: 20))
        XCTAssertTrue(sign.label.contains("Public fixture 1"), "The request must match the fixture wallet by its keys.")
        let risk = app.buttons["signing.risk"]
        XCTAssertTrue(risk.exists)
        XCTAssertFalse(sign.isEnabled, "Signing waits for the risk acknowledgement.")
        risk.tap()
        XCTAssertEqual(risk.value as? String, "Checked")
        XCTAssertTrue(sign.isEnabled)

        sign.tap()
        let password = app.secureTextFields["Wallet password"]
        XCTAssertTrue(password.waitForExistence(timeout: 5))
        type(fixturePassword, into: password)
        backgroundAndReactivate(app)
        XCTAssertTrue(app.navigationBars["Authorize Signature"].waitForNonExistence(timeout: 5),
                      "Backgrounding closes authorization and discards the typed password.")
        XCTAssertEqual(risk.value as? String, "Not checked", "Consent is per visit.")
        XCTAssertFalse(sign.isEnabled)

        risk.tap(); sign.tap()
        XCTAssertTrue(password.waitForExistence(timeout: 5))
        assertEmptySecureField(password, placeholder: "Wallet password")
        type("Wrong-Password1!", into: password)
        app.buttons["authorize.sign"].tap()
        XCTAssertTrue(element(containing: "password is incorrect", in: app).waitForExistence(timeout: 30))
        type(fixturePassword, into: password)
        app.buttons["authorize.sign"].tap()

        XCTAssertTrue(app.staticTexts["signature.title"].waitForExistence(timeout: 30))
        attach(app, "Signature for public fixture — no funds")
        // Done is the only primary action; the payload and file export sit in the result card.
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "label == %@", "Export as File")).count, 1)
        let signatureToggle = app.buttons["signature.payloadToggle"]
        scrollClear(of: app.buttons["signature.done"], signatureToggle, in: app)
        signatureToggle.tap()
        let signaturePayload = app.staticTexts["signature.payload"]
        XCTAssertTrue(signaturePayload.waitForExistence(timeout: 5))
        XCTAssertTrue(signaturePayload.label.contains("request-id") && signaturePayload.label.contains("signature"))
        XCTAssertTrue(app.buttons["signature.export"].exists)
        tap(app.buttons["signature.done"], in: app)
        XCTAssertTrue(app.buttons["signing.scan"].waitForExistence(timeout: 5))

        app.tabBars.buttons["Activity"].tap()
        let row = app.buttons["activity.row"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertTrue(row.label.contains("Public fixture 1"))
        row.tap()
        XCTAssertTrue(app.navigationBars["Signature"].waitForExistence(timeout: 3))
        XCTAssertTrue(element(containing: "Request fingerprint", in: app).exists)
        // The record keeps what went in and what came out. The request is
        // reviewed again on device, so the decoded fields are the real ones.
        let decoded = app.buttons["activity.decoded"]
        XCTAssertTrue(scrollToExistence(decoded, in: app), "The stored request decodes again.")
        decoded.tap()
        XCTAssertTrue(app.navigationBars["Signed Request"].waitForExistence(timeout: 10))
        XCTAssertTrue(element(containing: "Details", in: app).waitForExistence(timeout: 5))
        XCTAssertTrue(scrollToExistence(element(containing: "Derivation path", in: app), in: app))
        goBack(in: app)
        XCTAssertTrue(app.navigationBars["Signature"].waitForExistence(timeout: 5))
        // The signature can be shown again; doing so creates nothing new.
        let showQR = app.buttons["activity.showQR"]
        XCTAssertTrue(scrollToExistence(showQR, in: app))
        showQR.tap()
        XCTAssertTrue(element(containing: "Scanning it again signs nothing new", in: app).waitForExistence(timeout: 5))
        app.buttons["Done"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Signature"].waitForExistence(timeout: 5))
        XCTAssertTrue(scrollToExistence(app.buttons["activity.export"], in: app))
        let storedPayload = app.buttons["activity.signatureToggle"]
        XCTAssertTrue(scrollToExistence(storedPayload, in: app))
        storedPayload.tap()
        XCTAssertTrue(element(containing: "ur:eth-signature", in: app).waitForExistence(timeout: 5))
        goBack(in: app)
        tap(app.buttons["activity.clear"], in: app)
        let clear = app.buttons["Clear Activity"]
        XCTAssertTrue(clear.waitForExistence(timeout: 3))
        clear.tap()
        XCTAssertTrue(app.staticTexts["No Signatures Yet"].waitForExistence(timeout: 3))
    }

    @MainActor
    func testRejectClearsTheReviewedRequest() throws {
        let app = launch(fixtures: 1)
        app.tabBars.buttons["Scan"].tap()
        tap(app.buttons["signing.paste"], in: app)
        let payload = app.textViews["signing.payload"]
        XCTAssertTrue(payload.waitForExistence(timeout: 3))
        typePayload(publicSigningRequest, into: payload, in: app)
        tap(app.buttons["signing.decode"], in: app)
        XCTAssertTrue(app.buttons["signing.authorize"].waitForExistence(timeout: 20))
        app.buttons["signing.reject"].tap()
        XCTAssertTrue(app.buttons["signing.scan"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.navigationBars["Review Request"].exists)
    }

    /// A dApp approval names the spender when the bundled library knows it, and
    /// says so plainly when it does not. Nothing is fetched either way.
    @MainActor
    func testApprovalNamesAKnownSpenderAndFlagsAnUnlistedOne() throws {
        let app = launch(fixtures: 1)
        app.tabBars.buttons["Scan"].tap()
        tap(app.buttons["signing.paste"], in: app)
        let payload = app.textViews["signing.payload"]
        XCTAssertTrue(payload.waitForExistence(timeout: 3))
        typePayload(approveKnownSpenderRequest, into: payload, in: app)
        tap(app.buttons["signing.decode"], in: app)

        XCTAssertTrue(app.navigationBars["Review Request"].waitForExistence(timeout: 20))
        let notice = app.descendants(matching: .any).matching(identifier: "review.contractNotice").firstMatch
        XCTAssertTrue(notice.waitForExistence(timeout: 20), "The review carries the known-contract notice.")
        XCTAssertTrue(notice.label.contains("Permit2") && notice.label.contains("Uniswap"),
                      "The notice names the deployment: \(notice.label)")
        XCTAssertTrue(notice.label.contains("Known public contract"), notice.label)
        XCTAssertTrue(scrollToExistence(element(containing: "Spender (known contract)", in: app), in: app),
                      "Details repeat the identification as a field.")
        XCTAssertFalse(element(containing: "not in the bundled list", in: app).exists,
                       "A listed spender is never also called unlisted.")
        app.buttons["signing.reject"].tap()

        XCTAssertTrue(app.buttons["signing.scan"].waitForExistence(timeout: 5))
        tap(app.buttons["signing.paste"], in: app)
        XCTAssertTrue(payload.waitForExistence(timeout: 3))
        typePayload(approveUnlistedSpenderRequest, into: payload, in: app)
        tap(app.buttons["signing.decode"], in: app)

        XCTAssertTrue(app.navigationBars["Review Request"].waitForExistence(timeout: 20))
        let unlisted = app.descendants(matching: .any).matching(identifier: "review.contractNotice").firstMatch
        XCTAssertTrue(unlisted.waitForExistence(timeout: 20))
        XCTAssertTrue(unlisted.label.contains("Spender is not a known contract"), unlisted.label)
        XCTAssertFalse(unlisted.label.contains("Permit2"), unlisted.label)
        XCTAssertTrue(scrollToExistence(element(containing: "not in the bundled list of known public contracts", in: app), in: app),
                      "The warning says what to check before signing.")
    }

    /// The scan button on the wallet list opens the camera itself, rather than
    /// only moving to the Scan tab and leaving another tap to make.
    @MainActor
    func testWalletsScanButtonOpensTheCameraDirectly() throws {
        let app = launch(fixtures: 1)
        XCTAssertTrue(app.buttons["wallets.scan"].waitForExistence(timeout: 10))
        app.buttons["wallets.scan"].tap()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let close = app.buttons["Close"]
        for _ in 0..<20 where !close.exists {
            let permission = springboard.alerts.firstMatch
            if permission.exists {
                for label in ["Allow", "OK"] where permission.buttons[label].exists {
                    permission.buttons[label].tap(); break
                }
            }
            _ = close.waitForExistence(timeout: 1)
        }
        XCTAssertTrue(close.exists, "The camera opens straight from the wallet list.")
        XCTAssertTrue(app.staticTexts["Scan Request"].exists)
        close.tap()
        // Closing it leaves the person on Scan, where the request would be reviewed.
        XCTAssertTrue(app.buttons["signing.scan"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testScanCardOpensCameraWithoutPassword() throws {
        let app = launch(fixtures: 1)
        app.tabBars.buttons["Scan"].tap()
        let card = app.buttons["signing.scan"]
        tap(card, in: app)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let permission = springboard.alerts.firstMatch
        let close = app.buttons["Close"]
        for _ in 0..<20 where !close.exists {
            if permission.exists {
                for label in ["Allow", "OK"] where permission.buttons[label].exists {
                    permission.buttons[label].tap(); break
                }
            }
            _ = close.waitForExistence(timeout: 1)
        }
        XCTAssertTrue(close.exists, "The scanner sheet opens once the camera permission is answered.")
        XCTAssertTrue(app.staticTexts["Scan Request"].exists)
        XCTAssertFalse(app.secureTextFields.firstMatch.exists)
        close.tap()
        XCTAssertTrue(card.waitForExistence(timeout: 5))
    }

    // MARK: - Wallets

    @MainActor
    func testConnectAndAddressesUsePublicDataOnly() throws {
        let app = launch(fixtures: 3)
        XCTAssertEqual(walletCards(in: app).count, 3)
        // Wallets are labelled by their master fingerprint (public test phrase: 73C5DA0A).
        XCTAssertTrue(element(containing: "Fingerprint 73C5DA0A", in: app).waitForExistence(timeout: 10))
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "wallet.connect.")).firstMatch.tap()
        // Wallet level: where the page opens, one animated QR for every chain, in a single form (no Simple/Full choice).
        XCTAssertTrue(app.navigationBars["Pair Wallet"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.segmentedControls["connect.walletMode"].exists)
        XCTAssertTrue(element(containing: "bc1q, bc1p, 3, 1", in: app).waitForExistence(timeout: 10),
                      "The page says it carries every Bitcoin address type.")
        XCTAssertTrue(element(containing: "all three Solana addresses", in: app).exists)
        XCTAssertTrue(app.descendants(matching: .any)["connect.walletQR"].firstMatch.waitForExistence(timeout: 20))
        XCTAssertTrue(waitUntilEnabled(app.buttons["connect.copy"]))
        XCTAssertTrue(scrollToExistence(element(containing: "bittool-signer-wallet v1", in: app), in: app))
        XCTAssertTrue(scrollToExistence(element(containing: "BitTool Wallet", in: app), in: app), "BitTool Wallet is listed for wallet-level pairing.")
        app.swipeDown(); app.swipeDown(); app.swipeDown(); app.swipeDown()
        app.segmentedControls["connect.level"].buttons["Coin Level"].tap()
        XCTAssertTrue(app.navigationBars["Pair Bitcoin"].waitForExistence(timeout: 5))
        // Each coin-level QR shows what it carries, collapsed until tapped.
        let payloadToggle = app.buttons["connect.payloadToggle"]
        XCTAssertTrue(scrollToExistence(payloadToggle, in: app))
        tap(payloadToggle, in: app)
        let payloadText = app.staticTexts["connect.payload"]
        XCTAssertTrue(payloadText.waitForExistence(timeout: 5))
        XCTAssertTrue(payloadText.label.contains("master-fingerprint"))
        XCTAssertTrue(element(containing: "1942346250 is fingerprint 73C5DA0A", in: app).exists)
        app.swipeDown(); app.swipeDown(); app.swipeDown()
        for (chain, title) in [("evm", "Pair EVM"), ("tron", "Pair TRON"), ("solana", "Pair Solana"), ("bitcoin", "Pair Bitcoin")] {
            app.buttons["chain." + chain].tap()
            XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 5))
        }
        // TRON exports any address index, not just 0–99.
        app.buttons["chain.tron"].tap()
        let index = app.textFields["connect.tronIndex.field"]
        XCTAssertTrue(index.waitForExistence(timeout: 5))
        index.tap()
        index.press(forDuration: 1.0)
        if app.menuItems["Select All"].waitForExistence(timeout: 2) { app.menuItems["Select All"].tap() }
        index.typeText("123456")
        if app.toolbars.buttons["Done"].exists { app.toolbars.buttons["Done"].tap() }
        XCTAssertTrue(element(containing: "m/44'/195'/0'/0/123456", in: app).waitForExistence(timeout: 10))
        XCTAssertTrue(waitUntilEnabled(app.buttons["connect.copy"]), "The address for index 123456 is exported.")
        // TRON wallets can only watch an address; none is listed as a QR signer, and Ownbit is gone.
        XCTAssertTrue(scrollToExistence(element(containing: "Watch only", in: app), in: app))
        XCTAssertFalse(element(containing: "Watch and sign by QR", in: app).exists)
        XCTAssertTrue(scrollToExistence(element(containing: "TokenPocket", in: app), in: app))
        XCTAssertFalse(element(containing: "Ownbit", in: app).exists)
        app.buttons["chain.bitcoin"].tap()
        XCTAssertTrue(app.navigationBars["Pair Bitcoin"].waitForExistence(timeout: 5))
        XCTAssertTrue(scrollToExistence(element(containing: "Watch and sign by QR", in: app), in: app))
        XCTAssertTrue(scrollToExistence(element(containing: "Sparrow", in: app), in: app))
        XCTAssertTrue(scrollToExistence(element(containing: "BlueWallet", in: app), in: app))
        XCTAssertFalse(app.segmentedControls["pairing.outputMode"].buttons["Public Key"].exists, "The non-standard leaf-key export is gone.")
        // Switching levels keeps each side as it was.
        app.swipeDown(); app.swipeDown()
        app.segmentedControls["connect.level"].buttons["Wallet Level"].tap()
        XCTAssertTrue(app.navigationBars["Pair Wallet"].waitForExistence(timeout: 5))
        app.segmentedControls["connect.level"].buttons["Coin Level"].tap()
        XCTAssertTrue(app.navigationBars["Pair Bitcoin"].waitForExistence(timeout: 5), "Coin level is kept as it was.")
        XCTAssertFalse(app.secureTextFields.firstMatch.exists, "Pairing never asks for a password.")
        backgroundAndReactivate(app)
        XCTAssertTrue(app.navigationBars["Pair Bitcoin"].waitForExistence(timeout: 5))
        goBack(in: app)

        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "wallet.addresses.")).firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Addresses"].waitForExistence(timeout: 5))
        let first = app.buttons["address.row.0"]
        XCTAssertTrue(first.waitForExistence(timeout: 20))
        XCTAssertTrue(first.label.replacingOccurrences(of: " ", with: "").contains("bc1q"))
        app.buttons["chain.evm"].tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "0x")).firstMatch.waitForExistence(timeout: 20))
        // TRON lists plain addresses under a plain-language header, with no derivation path.
        app.buttons["chain.tron"].tap()
        XCTAssertTrue(element(containing: "TRX and TRC-20", in: app).waitForExistence(timeout: 20))
        XCTAssertTrue(app.buttons["address.row.0"].waitForExistence(timeout: 20))
        XCTAssertFalse(element(containing: "195'", in: app).exists)
        app.buttons["chain.solana"].tap()
        for profile in ["Standard", "Trust", "Legacy"] {
            XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", profile)).firstMatch.waitForExistence(timeout: 20),
                          "Solana lists every supported derivation path.")
        }
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Standard")).firstMatch.tap()
        XCTAssertTrue(element(containing: "Derivation path", in: app).waitForExistence(timeout: 5))
        app.buttons["Done"].tap()
        XCTAssertFalse(app.secureTextFields.firstMatch.exists)
    }

    @MainActor
    func testPasswordChangeProtectsRecoveryPhrase() throws {
        let app = launch(fixtures: 1)
        walletCards(in: app).firstMatch.tap()
        tap(app.buttons["detail.changePassword"], in: app)
        let current = app.secureTextFields["Current wallet password"]
        XCTAssertTrue(current.waitForExistence(timeout: 5))
        type("Wrong-Password1!", into: current)
        type("Updated-Test-Password2!", into: app.secureTextFields["New password"])
        type("Updated-Test-Password2!", into: app.secureTextFields["Confirm new password"])
        tap(app.buttons["vaultManagement.submit"], in: app)
        XCTAssertTrue(element(containing: "password is incorrect", in: app).waitForExistence(timeout: 30),
                      "A wrong current password must be reported, not silently ignored.")
        clear(current, count: "Wrong-Password1!".count)
        type(fixturePassword, into: current)
        tap(app.buttons["vaultManagement.submit"], in: app)
        XCTAssertTrue(app.navigationBars["Change Password"].waitForNonExistence(timeout: 60))
        XCTAssertTrue(app.buttons["detail.recoveryPhrase"].exists, "Changing the password keeps the wallet page open.")

        tap(app.buttons["detail.recoveryPhrase"], in: app)
        let password = app.secureTextFields["Wallet password"]
        XCTAssertTrue(password.waitForExistence(timeout: 5))
        type(fixturePassword, into: password)
        tap(app.buttons["vaultManagement.submit"], in: app)
        XCTAssertTrue(element(containing: "password is incorrect", in: app).waitForExistence(timeout: 30),
                      "The previous password no longer opens the wallet.")
        type("Updated-Test-Password2!", into: password)
        tap(app.buttons["vaultManagement.submit"], in: app)
        XCTAssertTrue(app.buttons["recovery.reveal"].waitForExistence(timeout: 30))
        XCTAssertFalse(app.descendants(matching: .any)["recovery.word.0"].firstMatch.exists)

        backgroundAndReactivate(app)
        XCTAssertTrue(password.waitForExistence(timeout: 5), "Backgrounding discards the decrypted phrase.")
        XCTAssertFalse(app.buttons["recovery.reveal"].exists)
        app.navigationBars["Recovery Phrase"].buttons["Cancel"].tap()
        XCTAssertTrue(app.buttons["detail.recoveryPhrase"].waitForExistence(timeout: 5))
    }

    /// Forgetting the password is recoverable with the recovery phrase: importing
    /// the same phrase again offers to reset that wallet's password rather than
    /// refusing a duplicate, and the wallet keeps its identity.
    @MainActor
    func testImportingAnExistingPhraseResetsItsPasswordInPlace() throws {
        let app = launch(fixtures: 1)
        let cards = walletCards(in: app)
        let name = cards.firstMatch.label

        app.buttons["wallets.add"].tap()
        tap(app.buttons["Import Recovery Phrase"], in: app)
        if app.buttons["onboarding.next"].waitForExistence(timeout: 3) {
            for _ in 0..<3 { tap(app.buttons["onboarding.next"], in: app) }
        }
        let input = app.textViews["recovery.input.visible"]
        XCTAssertTrue(input.waitForExistence(timeout: 10))
        // The fixture wallet's own phrase, with no BIP39 passphrase.
        input.tap(); input.typeText("abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about")
        tap(app.buttons["setup.import"], in: app)

        let finish = app.buttons["setup.finish"]
        XCTAssertTrue(finish.waitForExistence(timeout: 20))
        XCTAssertTrue(app.navigationBars["Reset Password"].waitForExistence(timeout: 30),
                      "An identical phrase offers to reset that wallet's password.")
        XCTAssertFalse(element(containing: "If you forget this password", in: app).exists,
                       "The hint describes what this screen is already doing.")

        let newPassword = "Recovered-Test-Password3!"
        type(newPassword, into: app.secureTextFields["Wallet password"])
        type(newPassword, into: app.secureTextFields["Confirm password"])
        tap(finish, in: app)
        XCTAssertTrue(app.staticTexts["Password Reset"].waitForExistence(timeout: 60))
        tap(app.buttons["setup.done"], in: app)

        // One wallet, the same one: a reset is not an import.
        XCTAssertTrue(cards.firstMatch.waitForExistence(timeout: 20))
        XCTAssertEqual(cards.count, 1, "The wallet is reset in place, never duplicated.")
        XCTAssertEqual(cards.firstMatch.label, name, "It keeps its name and identity.")

        // Only the new password opens it now.
        cards.firstMatch.tap()
        tap(app.buttons["detail.recoveryPhrase"], in: app)
        let password = app.secureTextFields["Wallet password"]
        XCTAssertTrue(password.waitForExistence(timeout: 5))
        type(fixturePassword, into: password)
        tap(app.buttons["vaultManagement.submit"], in: app)
        XCTAssertTrue(element(containing: "password is incorrect", in: app).waitForExistence(timeout: 30),
                      "The forgotten password no longer opens the wallet.")
        type(newPassword, into: password)
        tap(app.buttons["vaultManagement.submit"], in: app)
        XCTAssertTrue(app.buttons["recovery.reveal"].waitForExistence(timeout: 30),
                      "The new password opens the same recovery phrase.")
    }

    @MainActor
    func testRenameThenDeleteLastWalletReturnsToWelcome() throws {
        let app = launch(fixtures: 1)
        walletCards(in: app).firstMatch.tap()
        // The wallet page also opens Connect on its wallet-level QR.
        tap(app.buttons["detail.connect.wallet"], in: app)
        XCTAssertTrue(app.navigationBars["Pair Wallet"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.descendants(matching: .any)["connect.walletQR"].firstMatch.waitForExistence(timeout: 20))
        goBack(in: app)
        XCTAssertTrue(app.navigationBars["Public fixture 1"].waitForExistence(timeout: 10), "Back returns to the wallet page.")
        // Picking a chain is a coin-level choice, so that page opens on Coin
        // Level for that chain, not on the wallet-level QR.
        for (chain, title) in [("bitcoin", "Pair Bitcoin"), ("tron", "Pair TRON")] {
            tap(app.buttons["detail.connect." + chain], in: app)
            XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 10), "A chain row opens on Coin Level.")
            XCTAssertTrue(app.segmentedControls["connect.level"].buttons["Coin Level"].isSelected)
            goBack(in: app)
            XCTAssertTrue(app.navigationBars["Public fixture 1"].waitForExistence(timeout: 10))
        }
        tap(app.buttons["detail.rename"], in: app)
        let alert = app.alerts["Rename Wallet"]
        XCTAssertTrue(alert.waitForExistence(timeout: 3))
        let field = alert.textFields.firstMatch
        field.tap()
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: "Public fixture 1".count) + "Travel Signer")
        alert.buttons["Save"].tap()
        XCTAssertTrue(app.navigationBars["Travel Signer"].waitForExistence(timeout: 5))

        tap(app.buttons["detail.delete"], in: app)
        let submit = app.buttons["vaultManagement.submit"]
        XCTAssertTrue(submit.waitForExistence(timeout: 5))
        XCTAssertFalse(submit.isEnabled, "Deleting requires confirming the deletion itself.")
        setSwitch(app.switches["delete.backupConfirmed"], on: true, in: app)
        // The password is asked for in its own prompt, after biometrics where the
        // device has them, and nothing is deleted until it is right.
        tap(submit, in: app)
        let prompt = app.alerts["Wallet Password"]
        XCTAssertTrue(prompt.waitForExistence(timeout: 20), "Deleting asks for the wallet password.")
        prompt.secureTextFields.firstMatch.tap()
        prompt.secureTextFields.firstMatch.typeText("Wrong-Password1!")
        prompt.buttons["Delete"].tap()
        XCTAssertTrue(element(containing: "password is incorrect", in: app).waitForExistence(timeout: 30),
                      "A wrong password must be reported and must not delete anything.")
        XCTAssertTrue(app.navigationBars["Delete Wallet"].exists, "The wallet is still there.")
        tap(submit, in: app)
        XCTAssertTrue(prompt.waitForExistence(timeout: 20))
        prompt.secureTextFields.firstMatch.tap()
        prompt.secureTextFields.firstMatch.typeText(fixturePassword)
        prompt.buttons["Delete"].tap()
        XCTAssertTrue(app.buttons["welcome.create"].waitForExistence(timeout: 30))
    }

    // MARK: - App Lock and Settings

    @MainActor
    func testAppLockColdLaunchPasswordFallbackAndShortBackground() throws {
        var app = launch(fixtures: 1, dark: true)
        let run = app.launchEnvironment["BITTOOL_SIGNER_UI_TEST_RUN"]!
        app.terminate()
        app = XCUIApplication()
        app.launchArguments = ["--bittool-signer-ui-tests", "--app-lock-enabled", "--dark-appearance", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchEnvironment = ["BITTOOL_SIGNER_UI_TEST_RUN": run]
        app.launch()

        XCTAssertTrue(app.staticTexts["BitTool Signer Is Locked"].waitForExistence(timeout: 15))
        XCTAssertTrue(element(containing: "Face ID was cancelled", in: app).waitForExistence(timeout: 5))
        let hiddenTab = app.tabBars.buttons["Scan"]
        XCTAssertFalse(hiddenTab.exists && hiddenTab.isHittable, "Nothing behind the lock is reachable.")
        attach(app, "App Lock — dark")
        app.buttons["appLock.usePassword"].tap()
        let password = app.secureTextFields["Wallet password"]
        XCTAssertTrue(password.waitForExistence(timeout: 3))
        type("Wrong-Password1!", into: password)
        app.buttons["appLock.unlock"].tap()
        XCTAssertTrue(element(containing: "password is incorrect", in: app).waitForExistence(timeout: 30))
        type(fixturePassword, into: password)
        app.buttons["appLock.unlock"].tap()
        XCTAssertTrue(app.staticTexts["BitTool Signer Is Locked"].waitForNonExistence(timeout: 30))

        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "wallet.addresses.")).firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Addresses"].waitForExistence(timeout: 5))
        backgroundAndReactivate(app)
        XCTAssertTrue(app.navigationBars["Addresses"].waitForExistence(timeout: 5), "A short visit elsewhere keeps the page.")
        XCTAssertFalse(app.staticTexts["BitTool Signer Is Locked"].exists, "The grace period applies to short background visits.")
    }

    @MainActor
    func testSettingsReferencePagesAndGuide() throws {
        let app = launch(fixtures: 1)
        app.tabBars.buttons["Settings"].tap()
        let lock = app.switches["settings.appLock"]
        XCTAssertTrue(lock.waitForExistence(timeout: 5))
        XCTAssertEqual(lock.value as? String, "0")
        lock.coordinate(withNormalizedOffset: CGVector(dx: 0.94, dy: 0.5)).tap()
        XCTAssertTrue(element(containing: "Face ID was cancelled", in: app).waitForExistence(timeout: 5))
        XCTAssertEqual(lock.value as? String, "0", "App Lock only turns on after successful biometrics.")

        let directory = "Networks, Tokens & Contracts"
        tap(app.buttons[directory], in: app)
        XCTAssertTrue(app.navigationBars[directory].waitForExistence(timeout: 5))
        tap(app.buttons["network.solana"], in: app)
        XCTAssertTrue(app.navigationBars["Solana"].waitForExistence(timeout: 5))
        let tokens = app.cells.firstMatch
        XCTAssertTrue(tokens.waitForExistence(timeout: 5), "The bundled registry lists Solana tokens.")
        goBack(in: app)
        tap(app.buttons["network.ethereum"], in: app)
        XCTAssertTrue(app.navigationBars["Ethereum"].waitForExistence(timeout: 5))
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap(); search.typeText("tether")
        XCTAssertTrue(element(containing: "USDT", in: app).waitForExistence(timeout: 3))
        XCTAssertFalse(element(containing: "USD Coin", in: app).exists, "Search filters the list.")
        // The same page browses the known-contract library for this network.
        if search.buttons["Clear text"].exists { search.buttons["Clear text"].tap() }
        let contracts = app.segmentedControls.buttons.element(boundBy: 1)
        XCTAssertTrue(contracts.waitForExistence(timeout: 5), "Ethereum has both tokens and contracts.")
        contracts.tap()
        XCTAssertTrue(app.cells.firstMatch.waitForExistence(timeout: 5), "The bundled library lists Ethereum contracts.")
        search.tap(); search.typeText("permit2")
        XCTAssertTrue(element(containing: "Permit2", in: app).waitForExistence(timeout: 3))
        XCTAssertFalse(element(containing: "Seaport", in: app).exists, "Search filters the contract list.")
        goBack(in: app)
        if !app.navigationBars[directory].waitForExistence(timeout: 2) { goBack(in: app) }
        XCTAssertTrue(app.navigationBars[directory].waitForExistence(timeout: 5))
        // Deterministic deployments are reachable as their own row.
        tap(app.buttons["contracts.everyChain"], in: app)
        XCTAssertTrue(app.navigationBars["All EVM networks"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.cells.firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.segmentedControls.firstMatch.exists, "A contracts-only page carries no picker.")
        goBack(in: app)
        XCTAssertTrue(app.navigationBars[directory].waitForExistence(timeout: 5))
        goBack(in: app)

        tap(app.buttons["Compatibility"], in: app)
        XCTAssertTrue(app.navigationBars["Compatibility"].waitForExistence(timeout: 3))
        backgroundAndReactivate(app)
        XCTAssertTrue(app.navigationBars["Compatibility"].waitForExistence(timeout: 3))

        // The Wallets tab lists every wallet with a site to copy, behind a
        // notice that none of them is verified or endorsed.
        app.segmentedControls["compatibility.tab"].buttons["Wallets"].tap()
        XCTAssertTrue(element(containing: "says it supports", in: app).waitForExistence(timeout: 5),
                      "The directory says the claims are unverified.")
        XCTAssertTrue(element(containing: "Anyone can submit a wallet", in: app).exists)
        XCTAssertTrue(element(containing: "BitTool is not responsible", in: app).exists)
        let sparrow = app.descendants(matching: .any)["directory.wallet.Sparrow"].firstMatch
        XCTAssertTrue(scrollToExistence(sparrow, in: app), "Every listed wallet appears in the directory.")
        XCTAssertTrue(element(containing: "sparrowwallet.com", in: app).exists, "The site is shown as copyable text.")
        XCTAssertFalse(app.links.firstMatch.exists, "No tappable links: the app has no network.")

        // Submitting a wallet is explained, not mailed: no mail client opens.
        let submit = app.buttons["directory.submit"]
        XCTAssertTrue(scrollToExistence(submit, in: app))
        tap(submit, in: app)
        XCTAssertTrue(app.navigationBars["Submit a Wallet"].waitForExistence(timeout: 5))
        XCTAssertTrue(element(containing: "support@bittool.com", in: app).exists)
        XCTAssertTrue(element(containing: "Add supported wallet", in: app).exists)
        for required in ["Wallet name", "Official website", "App icon", "Source code", "QR formats supported"] {
            XCTAssertTrue(scrollToExistence(element(containing: required, in: app), in: app), required)
        }
        goBack(in: app)
        goBack(in: app)

        // Contact Us: the publisher and an address to copy, no mail client.
        tap(app.buttons["Contact Us"], in: app)
        XCTAssertTrue(app.navigationBars["Contact Us"].waitForExistence(timeout: 5))
        XCTAssertTrue(element(containing: "BITTOOL PTE. LTD.", in: app).exists)
        XCTAssertTrue(element(containing: "support@bittool.com", in: app).exists)
        XCTAssertFalse(app.links.firstMatch.exists, "The address is text, not a mailto link.")
        goBack(in: app)

        // Open Source: the address is text, and the build is described on device.
        tap(app.buttons["settings.openSource"], in: app)
        XCTAssertTrue(app.navigationBars["Open Source"].waitForExistence(timeout: 5))
        XCTAssertTrue(element(containing: "https://github.com/bitbill/bittool-signer-ios", in: app).waitForExistence(timeout: 5))
        XCTAssertTrue(scrollToExistence(element(containing: "Signing engine", in: app), in: app))
        // The digest is read from the bundled engine, so it is 64 hex characters, never a placeholder.
        let digest = app.staticTexts.matching(NSPredicate(format: "label MATCHES %@", "[0-9a-f]{64}")).firstMatch
        XCTAssertTrue(digest.waitForExistence(timeout: 10), "The engine digest is computed on device.")
        XCTAssertTrue(scrollToExistence(app.buttons["openSource.notices"], in: app))
        tap(app.buttons["openSource.notices"], in: app)
        XCTAssertTrue(app.navigationBars["Third-Party Notices"].waitForExistence(timeout: 5))
        goBack(in: app)
        goBack(in: app)

        // Legal documents are part of the app: no browser, no network.
        tap(app.buttons["Terms of Use"], in: app)
        XCTAssertTrue(app.navigationBars["Terms of Use"].waitForExistence(timeout: 5))
        XCTAssertTrue(element(containing: "Version 1.1", in: app).waitForExistence(timeout: 5))
        goBack(in: app)
        tap(app.buttons["Privacy Policy"], in: app)
        XCTAssertTrue(app.navigationBars["Privacy Policy"].waitForExistence(timeout: 5))
        XCTAssertTrue(element(containing: "collects nothing", in: app).waitForExistence(timeout: 5))
        goBack(in: app)
        XCTAssertFalse(element(containing: "open in your browser", in: app).exists)

        XCTAssertFalse(app.buttons["Offline Setup Guide"].exists, "The guide is part of onboarding, not of Settings.")
    }

    // MARK: - Helpers

    private enum Setup { case create, restore }

    @MainActor
    private func launch(fixtures: Int = 0, dark: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--bittool-signer-ui-tests", "--reset-ui-fixtures", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        if dark { app.launchArguments.append("--dark-appearance") }
        app.launchEnvironment = ["BITTOOL_SIGNER_UI_TEST_RUN": UUID().uuidString, "BITTOOL_SIGNER_UI_FIXTURE_COUNT": String(fixtures)]
        app.launch()
        if fixtures > 0 {
            let cards = walletCards(in: app)
            let deadline = Date().addingTimeInterval(150)
            while cards.count < fixtures && Date() < deadline { usleep(250_000) }
            XCTAssertEqual(cards.count, fixtures, "Fixture wallets must finish loading.")
            // Fixtures are created behind the Welcome screen; let the switch to the
            // wallet list finish so the first tap is not lost in the transition.
            sleep(1)
        } else {
            XCTAssertTrue(app.buttons["welcome.create"].waitForExistence(timeout: 20))
        }
        return app
    }

    @MainActor
    private func walletCards(in app: XCUIApplication) -> XCUIElementQuery {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "wallet.card."))
    }

    @MainActor
    private func openSetup(_ mode: Setup, in app: XCUIApplication) {
        let start = app.buttons[mode == .create ? "welcome.create" : "welcome.import"]
        // A just-dismissed setup sheet may still be animating away.
        let deadline = Date().addingTimeInterval(5)
        while !(start.exists && start.isHittable) && Date() < deadline { usleep(200_000) }
        start.tap()
        // Under load the sheet can take a moment; tap again only if nothing opened.
        let opened = app.buttons["onboarding.next"].waitForExistence(timeout: 5) || !(start.exists && start.isHittable)
        if !opened { start.tap() }
        if app.buttons["onboarding.next"].waitForExistence(timeout: 3) {
            for _ in 0..<3 { tap(app.buttons["onboarding.next"], in: app) }
        }
    }

    @MainActor
    private func element(labeled label: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", label)).firstMatch
    }

    @MainActor
    private func element(containing text: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS[c] %@", text)).firstMatch
    }

    @MainActor
    private func assertStep(_ step: Int, of total: Int, in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let header = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", "Step \(step) of \(total)")).firstMatch
        XCTAssertTrue(header.waitForExistence(timeout: 15), "Expected setup step \(step) of \(total).", file: file, line: line)
    }

    /// Lists create rows lazily, so an off-screen row only exists after scrolling to it.
    @MainActor
    private func scrollToExistence(_ element: XCUIElement, in app: XCUIApplication) -> Bool {
        if element.waitForExistence(timeout: 3) { return true }
        for _ in 0..<6 { app.swipeUp(); if element.waitForExistence(timeout: 1) { return true } }
        for _ in 0..<10 { app.swipeDown(); if element.waitForExistence(timeout: 1) { return true } }
        return false
    }

    /// Scrolls until `element` sits fully above `bar` (a control in a bottom action bar).
    @MainActor
    private func scrollClear(of bar: XCUIElement, _ element: XCUIElement, in app: XCUIApplication) {
        XCTAssertTrue(scrollToExistence(element, in: app))
        for _ in 0..<4 where bar.exists && element.frame.maxY > bar.frame.minY - 60 {
            app.swipeUp()
        }
    }

    @MainActor
    private func tap(_ element: XCUIElement, in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(scrollToExistence(element, in: app), "Missing element: \(element)", file: file, line: line)
        if !element.isHittable { dismissKeyboard(in: app) }
        for _ in 0..<4 where !element.isHittable { app.swipeUp() }
        for _ in 0..<6 where !element.isHittable { app.swipeDown() }
        XCTAssertTrue(element.isHittable, "Element is not hittable: \(element)", file: file, line: line)
        element.tap()
    }

    /// A sheet's action button can be covered by the keyboard. Tapping the
    /// navigation bar puts the keyboard away without changing anything.
    @MainActor
    private func dismissKeyboard(in app: XCUIApplication) {
        guard app.keyboards.element(boundBy: 0).exists else { return }
        let bar = app.navigationBars.firstMatch
        guard bar.exists else { return }
        bar.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        for _ in 0..<10 where app.keyboards.element(boundBy: 0).exists { usleep(200_000) }
    }

    /// Types a long QR payload into the paste sheet and checks it arrived whole.
    /// `typeText` drops characters when the simulator is loaded (several clones
    /// running the suite at once), which turns into a checksum failure and a
    /// decode that never produces a review. Verifying and retyping keeps the
    /// test about the app instead of about the keyboard.
    @MainActor
    private func typePayload(_ text: String, into field: XCUIElement, in app: XCUIApplication,
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(field.waitForExistence(timeout: 5), file: file, line: line)
        for attempt in 0..<3 {
            field.tap()
            if attempt > 0 {
                field.press(forDuration: 1.0)
                if app.menuItems["Select All"].waitForExistence(timeout: 2) { app.menuItems["Select All"].tap() }
                field.typeText(XCUIKeyboardKey.delete.rawValue)
            }
            field.typeText(text)
            if (field.value as? String) == text { return }
        }
        XCTFail("The payload could not be typed whole: \((field.value as? String)?.count ?? 0) of \(text.count) characters.",
                file: file, line: line)
    }

    @MainActor
    private func type(_ text: String, into field: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(field.waitForExistence(timeout: 5), file: file, line: line)
        field.tap()
        field.typeText(text)
    }

    @MainActor
    private func clear(_ field: XCUIElement, count: Int) {
        field.tap()
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: count))
    }

    @MainActor
    private func setSwitch(_ toggle: XCUIElement, on: Bool, in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let target = on ? "1" : "0"
        XCTAssertTrue(toggle.waitForExistence(timeout: 5), file: file, line: line)
        guard toggle.value as? String != target else { return }
        tap(toggle, in: app, file: file, line: line)
        // A SwiftUI toggle only flips on its switch, which sits at the trailing edge.
        if toggle.value as? String != target { toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.94, dy: 0.5)).tap() }
        XCTAssertEqual(toggle.value as? String, target, file: file, line: line)
    }

    @MainActor
    private func goBack(in app: XCUIApplication) {
        let bar = app.navigationBars.firstMatch
        let back = bar.buttons["BackButton"].exists ? bar.buttons["BackButton"] : bar.buttons.element(boundBy: 0)
        back.tap()
    }

    @MainActor
    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }

    @MainActor
    private func backgroundAndReactivate(_ app: XCUIApplication) {
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 5) || app.state == .runningBackgroundSuspended,
                      "The app must actually enter background before testing restoration.")
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 5))
    }

    @MainActor
    private func assertEmptySecureField(_ field: XCUIElement, placeholder: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(field.waitForExistence(timeout: 5), file: file, line: line)
        let value = field.value as? String
        XCTAssertTrue(value == nil || value == "" || value == placeholder, "A password typed before backgrounding must be cleared.", file: file, line: line)
    }

    @MainActor
    private func waitUntilEnabled(_ element: XCUIElement, timeout: TimeInterval = 20) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: element)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    /// Reveals the concealed phrase with one tap and reads it into memory only.
    @MainActor
    private func revealWords(in app: XCUIApplication, count: Int = 12) -> [String] {
        tap(app.buttons["recovery.reveal"], in: app)
        XCTAssertTrue(app.descendants(matching: .any)["recovery.word.0"].firstMatch.waitForExistence(timeout: 3))
        return (0..<count).map { index in
            let cell = app.descendants(matching: .any)["recovery.word.\(index)"].firstMatch
            XCTAssertTrue(cell.exists)
            // The combined label holds the position and one word. Never place
            // the label or word into diagnostics.
            let components = cell.label.split { !$0.isASCII || !$0.isLetter }
            XCTAssertTrue(components.count == 1, "Each recovery cell must contain one English word.")
            return components.first.map(String.init) ?? ""
        }
    }

    /// Blank positions of the fill-in check, ascending.
    @MainActor
    private func blankPositions(in app: XCUIApplication) -> [Int] {
        let prefix = "verification.slot."
        let slots = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", prefix))
        XCTAssertTrue(slots.firstMatch.waitForExistence(timeout: 5))
        return slots.allElementsBoundByIndex.compactMap { Int($0.identifier.dropFirst(prefix.count)) }.sorted()
    }

    @MainActor
    private func chipLabels(in app: XCUIApplication) -> [String] {
        (0..<8).compactMap { index in
            let chip = app.buttons["verification.chip.\(index)"]
            return chip.exists ? chip.label : nil
        }
    }

    /// Taps the missing words in order (or with the first two differing words swapped).
    @MainActor
    private func fill(_ positions: [Int], words: [String], swapped: Bool = false, in app: XCUIApplication) {
        var order = positions.map { words[$0] }
        if swapped, let other = order.indices.dropFirst().first(where: { order[$0] != order[0] }) {
            order.swapAt(0, other)
        }
        for word in order {
            let chip = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label == %@ AND value == %@",
                                                        "verification.chip.", word, "Available")).firstMatch
            tap(chip, in: app)
        }
    }

    @MainActor
    private func assertBlanksEmpty(_ positions: [Int], in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        for position in positions {
            let value = app.buttons["verification.slot.\(position)"].value as? String
            XCTAssertTrue(value?.hasPrefix("Empty") == true, "Blanks start empty.", file: file, line: line)
        }
    }
}
