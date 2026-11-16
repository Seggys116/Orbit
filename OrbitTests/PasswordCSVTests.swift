import XCTest

final class PasswordCSVTests: XCTestCase {

    private func parse(_ text: String) throws -> PasswordCSV.ParseResult {
        try PasswordCSV.parse(text)
    }

    /// `origin username password` per imported login, in file order.
    private func triples(_ result: PasswordCSV.ParseResult) -> [String] {
        result.logins.map { "\($0.origin.absoluteString) \($0.username) \($0.password)" }
    }

    private func reasons(_ result: PasswordCSV.ParseResult) -> [PasswordCSV.SkipReason] {
        result.skipped.map(\.reason)
    }

    // MARK: - RFC 4180 records

    func testRecordsSplitOnCommasAndLineBreaks() {
        let records = PasswordCSV.records(in: "a,b,c\r\n1,2,3\n4,5,6\r7,8,9")
        XCTAssertEqual(records.map(\.fields), [["a", "b", "c"], ["1", "2", "3"], ["4", "5", "6"], ["7", "8", "9"]])
        XCTAssertEqual(records.map(\.line), [1, 2, 3, 4])
        XCTAssertTrue(records.allSatisfy { !$0.isMalformed })
    }

    func testQuotedFieldsHoldCommasQuotesAndLineBreaks() {
        let text = "\"a,b\",\"say \"\"hi\"\"\",\"line1\nline2\",\"crlf1\r\ncrlf2\"\r\nnext,row,x,y\r\n"
        let records = PasswordCSV.records(in: text)
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records[0].fields, ["a,b", "say \"hi\"", "line1\nline2", "crlf1\r\ncrlf2"])
        XCTAssertEqual(records[1].fields, ["next", "row", "x", "y"])
        XCTAssertEqual(records[1].line, 4)
    }

    func testEmptyFieldsAreKept() {
        XCTAssertEqual(PasswordCSV.records(in: "a,,c,").map(\.fields), [["a", "", "c", ""]])
        XCTAssertEqual(PasswordCSV.records(in: ",,").map(\.fields), [["", "", ""]])
        XCTAssertEqual(PasswordCSV.records(in: "\"\",x").map(\.fields), [["", "x"]])
    }

    func testAnEmptyQuotedFieldAloneIsARecordButABlankLineIsNot() {
        XCTAssertEqual(PasswordCSV.records(in: "a\n\n\"\"\n\nb\n").map(\.fields), [["a"], [""], ["b"]])
    }

    func testTrailingNewlineDoesNotAddARecord() {
        XCTAssertEqual(PasswordCSV.records(in: "a,b\r\n").count, 1)
        XCTAssertEqual(PasswordCSV.records(in: "a,b\r\n\r\n").count, 1)
        XCTAssertEqual(PasswordCSV.records(in: "").count, 0)
    }

    func testALeadingByteOrderMarkIsDropped() {
        let records = PasswordCSV.records(in: "\u{FEFF}url,password\r\nx,y")
        XCTAssertEqual(records.first?.fields, ["url", "password"])
    }

    func testAQuoteInTheMiddleOfAnUnquotedFieldIsLiteral() {
        XCTAssertEqual(PasswordCSV.records(in: "ab\"cd,e").map(\.fields), [["ab\"cd", "e"]])
    }

    func testAnUnterminatedQuoteMakesTheRecordMalformed() {
        let records = PasswordCSV.records(in: "a,b\n\"never closed,x\nmore")
        XCTAssertEqual(records.count, 2)
        XCTAssertFalse(records[0].isMalformed)
        XCTAssertTrue(records[1].isMalformed)
        XCTAssertEqual(records[1].line, 2)
    }

    func testCRLFCountsAsOneLineBreakInsideAndOutsideQuotes() {
        let records = PasswordCSV.records(in: "h\r\n\"a\r\nb\"\r\nlast")
        XCTAssertEqual(records.map(\.line), [1, 2, 4])
    }

    func testNonASCIIAndEmojiSurvive() {
        XCTAssertEqual(PasswordCSV.records(in: "\"caf\u{00E9}\",\u{1F512}\r\n").map(\.fields), [["caf\u{00E9}", "\u{1F512}"]])
    }

    // MARK: - Formats

    func testApplePasswordsAndSafariExport() throws {
        let result = try parse("""
        Title,URL,Username,Password,Notes,OTPAuth\r
        example.com,https://example.com/login,alice,s3cret,,\r
        "Bank, Inc",https://bank.example.org,bob,"p""w",note,otpauth://totp/x\r

        """)
        XCTAssertEqual(result.format, .applePasswords)
        XCTAssertEqual(triples(result), ["https://example.com alice s3cret", "https://bank.example.org bob p\"w"])
        XCTAssertTrue(result.skipped.isEmpty)
    }

    func testChromeEdgeBraveAndArcExport() throws {
        let result = try parse("""
        name,url,username,password,note
        example.com,https://example.com/signin,alice,s3cret,
        shop,https://shop.example.com:8443/,bob,hunter2,"a note, with comma"
        """)
        XCTAssertEqual(result.format, .chrome)
        XCTAssertEqual(triples(result), ["https://example.com alice s3cret", "https://shop.example.com:8443 bob hunter2"])
    }

    func testAnOlderChromeExportWithoutANoteColumn() throws {
        let result = try parse("name,url,username,password\nexample.com,https://example.com,alice,pw\n")
        XCTAssertEqual(result.format, .chrome)
        XCTAssertEqual(triples(result), ["https://example.com alice pw"])
    }

    func testFirefoxExport() throws {
        let result = try parse("""
        "url","username","password","httpRealm","formActionOrigin","guid","timeCreated","timeLastUsed","timePasswordChanged"
        "https://example.com","alice","s3cret","","https://example.com","{abc}","1","2","3"
        "https://intranet.example.org","bob","hunter2","Restricted","","{def}","1","2","3"
        """)
        XCTAssertEqual(result.format, .firefox)
        XCTAssertEqual(triples(result), ["https://example.com alice s3cret", "https://intranet.example.org bob hunter2"])
    }

    func testBitwardenExportTakesTheFirstURI() throws {
        let result = try parse("""
        folder,favorite,type,name,notes,fields,reprompt,login_uri,login_username,login_password,login_totp
        ,0,login,Example,,,0,"https://example.com/login
        https://www.example.com/other",alice,s3cret,
        """)
        XCTAssertEqual(result.format, .generic)
        XCTAssertEqual(triples(result), ["https://example.com alice s3cret"])
    }

    func testOnePasswordStyleHeaders() throws {
        let result = try parse("Title,Url,Username,Password,Notes,Type\nExample,https://example.com,alice,s3cret,,Login\n")
        XCTAssertEqual(result.format, .generic)
        XCTAssertEqual(triples(result), ["https://example.com alice s3cret"])
    }

    func testHeadersAreMatchedIgnoringCaseAndSurroundingSpace() throws {
        let result = try parse(" URL , USERNAME ,Password\nhttps://example.com,alice,pw\n")
        XCTAssertEqual(triples(result), ["https://example.com alice pw"])
    }

    func testColumnOrderDoesNotMatter() throws {
        let result = try parse("password,note,username,name,url\npw,n,alice,x,https://example.com\n")
        XCTAssertEqual(result.format, .chrome)
        XCTAssertEqual(triples(result), ["https://example.com alice pw"])
    }

    func testAByteOrderMarkBeforeTheHeaderIsIgnored() throws {
        let result = try parse("\u{FEFF}name,url,username,password,note\r\nx,https://example.com,alice,pw,\r\n")
        XCTAssertEqual(result.format, .chrome)
        XCTAssertEqual(result.logins.count, 1)
    }

    func testFilesWithoutAUsableHeaderThrow() {
        XCTAssertThrowsError(try PasswordCSV.parse("")) { XCTAssertEqual($0 as? PasswordCSV.ImportError, .empty) }
        XCTAssertThrowsError(try PasswordCSV.parse("foo,bar\n1,2\n")) { XCTAssertEqual($0 as? PasswordCSV.ImportError, .unrecognizedFormat) }
        XCTAssertThrowsError(try PasswordCSV.parse("url,username\nhttps://example.com,alice\n")) {
            XCTAssertEqual($0 as? PasswordCSV.ImportError, .unrecognizedFormat)
        }
        XCTAssertThrowsError(try PasswordCSV.parse("username,password\nalice,pw\n")) {
            XCTAssertEqual($0 as? PasswordCSV.ImportError, .unrecognizedFormat)
        }
    }

    func testAHeaderOnlyFileImportsNothing() throws {
        let result = try parse("name,url,username,password,note\r\n")
        XCTAssertTrue(result.logins.isEmpty)
        XCTAssertTrue(result.skipped.isEmpty)
    }

    func testDataIsDecodedAsUTF8WithOrWithoutABOMAndAsUTF16() throws {
        let text = "name,url,username,password,note\nx,https://example.com,alice,caf\u{00E9},\n"
        XCTAssertEqual(try PasswordCSV.parse(data: Data(text.utf8)).logins.first?.password, "caf\u{00E9}")
        XCTAssertEqual(try PasswordCSV.parse(data: Data([0xEF, 0xBB, 0xBF] + Array(text.utf8))).logins.first?.password, "caf\u{00E9}")
        let utf16 = try XCTUnwrap(text.data(using: .utf16))
        XCTAssertEqual(try PasswordCSV.parse(data: utf16).logins.first?.password, "caf\u{00E9}")
        XCTAssertThrowsError(try PasswordCSV.parse(data: Data([0x80, 0x81, 0xC0, 0x0A]))) {
            XCTAssertEqual($0 as? PasswordCSV.ImportError, .notText)
        }
    }

    // MARK: - Values

    func testPasswordsAreKeptExactlyAndUsernamesAreTrimmed() throws {
        let result = try parse("name,url,username,password,note\nx,https://example.com,  alice  ,\"  sp ace, \"\"q\"\"\nline2 \",\n")
        XCTAssertEqual(result.logins.first?.username, "alice")
        XCTAssertEqual(result.logins.first?.password, "  sp ace, \"q\"\nline2 ")
    }

    func testURLsAreReducedToAnOrigin() throws {
        let result = try parse("""
        url,username,password
        https://user:pass@WWW.Example.com:443/a/b?c=d#e,u1,p
        http://example.org:8080/path,u2,p
        example.net/login,u3,p
        localhost:3000/app,u4,p
        HTTPS://Upper.Example.com,u5,p
        """)
        XCTAssertEqual(result.logins.map(\.origin.absoluteString), [
            "https://www.example.com", "http://example.org:8080", "https://example.net",
            "https://localhost:3000", "https://upper.example.com",
        ])
        XCTAssertTrue(result.skipped.isEmpty)
    }

    // MARK: - Skipped rows

    func testSkippedRowsCarryTheirReason() throws {
        let result = try parse("""
        name,url,username,password,note
        a,,alice,pw,
        b,https://example.com,alice,,
        c,android://abcdef@com.example.app/,alice,pw,
        d,chrome://settings,alice,pw,
        e,ftp://example.com,alice,pw,
        f,https://example.com,,pw,
        g,https://,alice,pw,
        h,https://ok.example.com,alice,pw,
        i,https://only.example.com
        """)
        XCTAssertEqual(reasons(result), [
            .noUsableURL, .emptyPassword, .nonHTTPOrigin(scheme: "android"), .nonHTTPOrigin(scheme: "chrome"),
            .nonHTTPOrigin(scheme: "ftp"), .emptyUsername, .noUsableURL, .malformedRow,
        ])
        XCTAssertEqual(triples(result), ["https://ok.example.com alice pw"])
    }

    func testSkippedRowsRecordTheirLineAndNeverThePassword() throws {
        let result = try parse("name,url,username,password,note\nok,https://example.com,alice,pw,\"two\nlines\"\nbad,android://x@y/,alice,topsecret,\n")
        XCTAssertEqual(result.skipped.count, 1)
        XCTAssertEqual(result.skipped.first?.line, 4)
        XCTAssertEqual(result.skipped.first?.label, "android://x@y/")
        XCTAssertFalse(String(describing: result.skipped).contains("topsecret"))
        XCTAssertEqual(
            result.logins.first.map { String(describing: $0) },
            "ImportedLogin(https://example.com, <password withheld>)"
        )
    }

    func testAnUnterminatedQuoteSkipsTheRowAsMalformed() throws {
        let result = try parse("name,url,username,password,note\nok,https://example.com,alice,pw,\nbad,https://bad.example.com,bob,\"never closed\n")
        XCTAssertEqual(triples(result), ["https://example.com alice pw"])
        XCTAssertEqual(reasons(result), [.malformedRow])
        XCTAssertEqual(result.skipped.first?.line, 3)
    }

    func testARowMissingAColumnItNeedsIsMalformed() throws {
        let result = try parse("url,username,password\nhttps://example.com,alice\nhttps://example.org,bob,pw\n")
        XCTAssertEqual(reasons(result), [.malformedRow])
        XCTAssertEqual(triples(result), ["https://example.org bob pw"])
    }

    func testBlankLinesBetweenRowsAreIgnoredNotSkipped() throws {
        let result = try parse("url,username,password\n\nhttps://example.com,alice,pw\n\n\nhttps://example.org,bob,pw\n")
        XCTAssertEqual(result.logins.count, 2)
        XCTAssertTrue(result.skipped.isEmpty)
    }

    // MARK: - Export

    func testExportUsesTheChromeHeaderAndCRLF() {
        let login = SavedLogin(origin: "https://www.example.com", siteKey: "example.com", username: "alice", password: "s3cret")
        let text = PasswordCSV.export([login])
        XCTAssertEqual(text, "name,url,username,password,note\r\nwww.example.com,https://www.example.com,alice,s3cret,\r\n")
    }

    func testExportOfNothingIsJustTheHeader() {
        XCTAssertEqual(PasswordCSV.export([]), "name,url,username,password,note\r\n")
    }

    func testExportQuotesOnlyWhatNeedsIt() {
        XCTAssertEqual(PasswordCSV.escape("plain"), "plain")
        XCTAssertEqual(PasswordCSV.escape(" spaced "), " spaced ")
        XCTAssertEqual(PasswordCSV.escape(""), "")
        XCTAssertEqual(PasswordCSV.escape("a,b"), "\"a,b\"")
        XCTAssertEqual(PasswordCSV.escape("say \"hi\""), "\"say \"\"hi\"\"\"")
        XCTAssertEqual(PasswordCSV.escape("two\nlines"), "\"two\nlines\"")
        XCTAssertEqual(PasswordCSV.escape("two\r\nlines"), "\"two\r\nlines\"")
        XCTAssertEqual(PasswordCSV.escape("cr\rhere"), "\"cr\rhere\"")
    }

    func testExportIsOrderedBySiteAndUsernameWhateverTheInputOrder() {
        let logins = [
            SavedLogin(origin: "https://zeta.com", siteKey: "zeta.com", username: "a", password: "1"),
            SavedLogin(origin: "https://alpha.com", siteKey: "alpha.com", username: "b", password: "2"),
            SavedLogin(origin: "https://alpha.com", siteKey: "alpha.com", username: "a", password: "3"),
        ]
        let lines = PasswordCSV.export(logins).components(separatedBy: "\r\n")
        XCTAssertEqual(lines[1...3].map { $0.split(separator: ",").dropFirst().prefix(2).joined(separator: " ") }, [
            "https://alpha.com a", "https://alpha.com b", "https://zeta.com a",
        ])
    }

    func testExportThenImportRoundTripsAwkwardValues() throws {
        let awkward = [
            "plain", "with,comma", "with \"quotes\"", "line1\nline2", "crlf1\r\ncrlf2", " leading and trailing ",
            "caf\u{00E9} \u{1F512}", "=1+1", "@SUM(A1)", "\"", ",", "a\"\"b", "back\\slash", "tab\there",
        ]
        let logins = awkward.enumerated().map { index, password in
            SavedLogin(origin: "https://site\(index).example.com:\(8000 + index)", siteKey: "example.com", username: "user, \(index)", password: password)
        }
        let result = try PasswordCSV.parse(PasswordCSV.export(logins))
        XCTAssertEqual(result.format, .chrome)
        XCTAssertTrue(result.skipped.isEmpty)
        XCTAssertEqual(result.logins.count, logins.count)
        let imported = Dictionary(uniqueKeysWithValues: result.logins.map { ($0.origin.absoluteString, $0) })
        for login in logins {
            let match = try XCTUnwrap(imported[login.origin], login.origin)
            XCTAssertEqual(match.username, login.username)
            XCTAssertEqual(match.password, login.password)
        }
    }

    func testExportedPasswordsAreNotTrimmedOnTheWayBackIn() throws {
        let login = SavedLogin(origin: "https://example.com", siteKey: "example.com", username: "alice", password: "  pad  ")
        let result = try PasswordCSV.parse(PasswordCSV.export([login]))
        XCTAssertEqual(result.logins.first?.password, "  pad  ")
    }

    // MARK: - Formula injection

    func testExportPrefixesAQuoteToAnyFieldASpreadsheetWouldRunAsAFormula() {
        for trigger in ["=", "+", "-", "@", "\t", "\r"] {
            let field = trigger + "cmd|' /C calc'!A0"
            let escaped = PasswordCSV.escape(field)
            XCTAssertTrue(escaped.hasPrefix("'" + trigger) || escaped.hasPrefix("\"'" + trigger), "not neutralised: \(escaped.debugDescription)")
        }
        XCTAssertEqual(PasswordCSV.escape("=1+1"), "'=1+1")
        XCTAssertEqual(PasswordCSV.escape("+15551234"), "'+15551234")
        XCTAssertEqual(PasswordCSV.escape("-2+3"), "'-2+3")
        XCTAssertEqual(PasswordCSV.escape("@SUM(A1)"), "'@SUM(A1)")
        XCTAssertEqual(PasswordCSV.escape("\tcell"), "'\tcell")
        XCTAssertEqual(PasswordCSV.escape("\rcell"), "\"'\rcell\"")
    }

    func testExportLeavesOrdinaryFieldsAlone() {
        for field in ["plain", "a=b", "x+y", "e-mail", "name@example.com", "'quoted", "'abc", " =spaced"] {
            XCTAssertEqual(PasswordCSV.escape(field), field)
        }
    }

    func testTheExportedFileHoldsTheNeutralisedFieldsInEveryColumn() {
        let login = SavedLogin(origin: "https://example.com", siteKey: "example.com", username: "=cmd", password: "-p,w")
        XCTAssertEqual(
            PasswordCSV.export([login]),
            "name,url,username,password,note\r\nexample.com,https://example.com,'=cmd,\"'-p,w\",\r\n"
        )
    }

    func testImportStripsExactlyOneQuoteOnlyWhenAFormulaTriggerFollows() throws {
        for (stored, expected) in [("'=1+1", "=1+1"), ("'+1", "+1"), ("'-1", "-1"), ("'@x", "@x"), ("'\tx", "\tx"), ("'\rx", "\rx")] {
            XCTAssertEqual(PasswordCSV.restored(stored), expected)
        }
        for untouched in ["'abc", "'1", "'", "''", "''abc", "abc", "=1", "a'=b", "'' ", "' =x"] {
            XCTAssertEqual(PasswordCSV.restored(untouched), untouched)
        }
        let result = try parse("name,url,username,password,note\nx,https://example.com,'-bob,'=secret,\ny,https://example.org,carol,'letters,\n")
        XCTAssertEqual(result.logins.map(\.username), ["-bob", "carol"])
        XCTAssertEqual(result.logins.map(\.password), ["=secret", "'letters"])
    }

    func testAPasswordThatReallyStartsWithAQuoteAndALetterSurvivesTheRoundTrip() throws {
        let login = SavedLogin(origin: "https://example.com", siteKey: "example.com", username: "alice", password: "'abc")
        let result = try PasswordCSV.parse(PasswordCSV.export([login]))
        XCTAssertEqual(result.logins.first?.password, "'abc")
    }

    func testFormulaLikeValuesRoundTripExactly() throws {
        let passwords = [
            "=1+1", "+1", "-1", "@SUM(A1)", "\tx", "\rx", "\r\nx", "'=1+1", "''=1+1", "'+x", "'abc", "''abc", "'", "-", "=", "=cmd|' /C calc'!A0",
            "=HYPERLINK(\"http://evil.test\",\"x\")", "-,=", "@\"quoted\"",
        ]
        let logins = passwords.enumerated().map { index, password in
            SavedLogin(origin: "https://site\(index).example.com", siteKey: "example.com", username: "user\(index)", password: password)
        }
        let text = PasswordCSV.export(logins)
        let result = try PasswordCSV.parse(text)
        XCTAssertTrue(result.skipped.isEmpty)
        let imported = Dictionary(uniqueKeysWithValues: result.logins.map { ($0.origin.absoluteString, $0.password) })
        for login in logins {
            XCTAssertEqual(imported[login.origin], login.password, login.password.debugDescription)
        }
    }

    func testFormulaLikeUsernamesRoundTripToo() throws {
        let logins = ["=bob", "+1555", "-dash", "@handle"].enumerated().map { index, name in
            SavedLogin(origin: "https://site\(index).example.com", siteKey: "example.com", username: name, password: "pw")
        }
        let result = try PasswordCSV.parse(PasswordCSV.export(logins))
        XCTAssertEqual(result.logins.map(\.username), ["=bob", "+1555", "-dash", "@handle"])
    }

    // MARK: - Writing the export file

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("orbit-export-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func permissions(of url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    func testTheExportFileIsCreatedPrivateAndHoldsTheData() throws {
        let directory = try temporaryDirectory()
        let file = directory.appendingPathComponent("Orbit Passwords.csv")
        try PasswordExportFile.write(Data("name,url\r\n".utf8), to: file)
        XCTAssertEqual(try permissions(of: file), 0o600)
        XCTAssertEqual(try Data(contentsOf: file), Data("name,url\r\n".utf8))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["Orbit Passwords.csv"], "no temporary file is left behind")
    }

    func testReplacingAnExistingPublicFileLeavesAPrivateOne() throws {
        let directory = try temporaryDirectory()
        let file = directory.appendingPathComponent("passwords.csv")
        try Data("old".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)

        try PasswordExportFile.write(Data("new".utf8), to: file)
        XCTAssertEqual(try permissions(of: file), 0o600)
        XCTAssertEqual(String(data: try Data(contentsOf: file), encoding: .utf8), "new")
    }

    func testAnEmptyExportStillWritesAFile() throws {
        let file = try temporaryDirectory().appendingPathComponent("empty.csv")
        try PasswordExportFile.write(Data(), to: file)
        XCTAssertEqual(try permissions(of: file), 0o600)
        XCTAssertEqual(try Data(contentsOf: file).count, 0)
    }

    func testAFailureReportsTheRealErrorAndLeavesNothingBehind() throws {
        let directory = try temporaryDirectory()

        let missing = directory.appendingPathComponent("no-such-folder").appendingPathComponent("passwords.csv")
        XCTAssertThrowsError(try PasswordExportFile.write(Data("secret".utf8), to: missing)) { error in
            XCTAssertEqual((error as NSError).domain, NSPOSIXErrorDomain)
            XCTAssertEqual((error as NSError).code, Int(ENOENT))
        }

        // The destination is a directory, so the final rename fails after the data was written: the partial file must be removed.
        let blocked = directory.appendingPathComponent("blocked.csv", isDirectory: true)
        try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: false)
        try Data().write(to: blocked.appendingPathComponent("occupied"))
        XCTAssertThrowsError(try PasswordExportFile.write(Data("secret".utf8), to: blocked)) { error in
            XCTAssertEqual((error as NSError).domain, NSPOSIXErrorDomain)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted(), ["blocked.csv"])
    }

    // MARK: - Merge

    private func merge(_ text: String, into vault: InMemoryPasswordVault) throws -> PasswordCSV.MergeSummary {
        PasswordCSV.merge(try PasswordCSV.parse(text), into: vault)
    }

    func testMergeReportsAddedUpdatedUnchangedAndSkipped() throws {
        let vault = InMemoryPasswordVault()
        let first = "name,url,username,password,note\na,https://example.com,alice,one,\nb,https://example.org,bob,two,\nc,android://x@y/,carol,three,\n"
        XCTAssertEqual(try merge(first, into: vault), PasswordCSV.MergeSummary(added: 2, updated: 0, unchanged: 0, skipped: 1))
        XCTAssertEqual(vault.allLogins().count, 2)

        let second = "name,url,username,password,note\na,https://example.com,alice,one,\nb,https://example.org,bob,changed,\nd,https://example.net,dave,four,\n,,,,\n"
        XCTAssertEqual(try merge(second, into: vault), PasswordCSV.MergeSummary(added: 1, updated: 1, unchanged: 1, skipped: 1))
        XCTAssertEqual(vault.allLogins().count, 3)
        let bob = vault.logins(matching: URL(string: "https://example.org")!).first
        XCTAssertEqual(bob?.password, "changed")
    }

    func testMergeSavesThroughTheVaultSoUsernamesAreTrimmedAndOriginsNormalised() throws {
        let vault = InMemoryPasswordVault()
        _ = try merge("url,username,password\nhttps://Example.com/a,  alice ,pw\n", into: vault)
        let login = try XCTUnwrap(vault.allLogins().first)
        XCTAssertEqual(login.origin, "https://example.com")
        XCTAssertEqual(login.username, "alice")
        XCTAssertEqual(login.siteKey, "example.com")
    }

    func testRepeatedRowsInOneFileAreAddedOnceAndThenUpdatedOrUnchanged() throws {
        let vault = InMemoryPasswordVault()
        let summary = try merge("url,username,password\nhttps://example.com,alice,one\nhttps://example.com,alice,one\nhttps://example.com,alice,two\n", into: vault)
        XCTAssertEqual(summary, PasswordCSV.MergeSummary(added: 1, updated: 1, unchanged: 1, skipped: 0))
        XCTAssertEqual(vault.allLogins().map(\.password), ["two"])
    }

    func testMergeCountsALoginTheVaultRefusesAsSkipped() {
        let vault = InMemoryPasswordVault()
        let result = PasswordCSV.ParseResult(
            format: .generic,
            logins: [PasswordCSV.ImportedLogin(origin: URL(string: "ftp://example.com")!, username: "alice", password: "pw")],
            skipped: [PasswordCSV.SkippedRow(line: 2, reason: .noUsableURL, label: "")]
        )
        XCTAssertEqual(PasswordCSV.merge(result, into: vault), PasswordCSV.MergeSummary(added: 0, updated: 0, unchanged: 0, skipped: 2))
        XCTAssertTrue(vault.allLogins().isEmpty)
    }

    func testExportingAVaultAndImportingItIntoAnotherCopiesEveryLogin() throws {
        let source = InMemoryPasswordVault()
        source.save(origin: URL(string: "https://example.com")!, username: "alice", password: "p,\"1\"")
        source.save(origin: URL(string: "http://localhost:3000")!, username: "dev", password: "line\nbreak")
        let target = InMemoryPasswordVault()
        let summary = PasswordCSV.merge(try PasswordCSV.parse(PasswordCSV.export(source.allLogins())), into: target)
        XCTAssertEqual(summary, PasswordCSV.MergeSummary(added: 2, updated: 0, unchanged: 0, skipped: 0))
        XCTAssertEqual(
            target.allLogins().map { "\($0.origin) \($0.username) \($0.password)" },
            source.allLogins().map { "\($0.origin) \($0.username) \($0.password)" }
        )
    }
}
