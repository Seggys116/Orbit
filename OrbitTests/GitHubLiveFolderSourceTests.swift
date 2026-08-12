import Foundation
import XCTest

@MainActor
final class GitHubLiveFolderSourceTests: XCTestCase {

    // MARK: - The request

    func test_theSearchURLIsTheFirstPartyEndpointOnGithubDotCom() throws {
        let url = try XCTUnwrap(GitHubSearchEndpoint.searchURL(query: "is:pr is:open author:zak sort:updated"))

        XCTAssertEqual(
            url.absoluteString,
            "https://github.com/search?q=is%3Apr%20is%3Aopen%20author%3Azak%20sort%3Aupdated&type=issues",
            """
            The query must be percent-encoded against the unreserved set. `api.github.com` is a \
            different host from the one the session cookie is scoped to and would answer 401 — \
            this endpoint is on `github.com` itself for exactly that reason.
            """
        )
        XCTAssertEqual(url.host, "github.com")
    }

    func test_theSearchURLEncodesQueryMetacharacters() throws {
        let url = try XCTUnwrap(GitHubSearchEndpoint.searchURL(query: "author:a&b=c+d"))
        XCTAssertEqual(url.absoluteString, "https://github.com/search?q=author%3Aa%26b%3Dc%2Bd&type=issues")
    }

    func test_theSearchURLEncodesNonASCIILetters() throws {
        let url = try XCTUnwrap(GitHubSearchEndpoint.searchURL(query: "repo:acme/café"))
        XCTAssertEqual(url.absoluteString, "https://github.com/search?q=repo%3Aacme%2Fcaf%C3%A9&type=issues")
    }

    func test_theCookieHeaderIsNameEqualsValueJoinedWithSemicolons() {
        let header = GitHubSearchEndpoint.cookieHeader(from: [
            "user_session": "abc",
            "dotcom_user": "zak",
        ])
        XCTAssertEqual(header, "dotcom_user=zak; user_session=abc", "sorted by name, so the header is deterministic")
    }

    func test_theRequestCarriesTheJSONAcceptHeaderTheCookiesAndTheBrowsersUserAgent() throws {
        let request = try XCTUnwrap(
            GitHubSearchEndpoint.request(
                query: "is:pr",
                cookies: ["dotcom_user": "zak", "user_session": "abc"],
                userAgent: "Mozilla/5.0 (Macintosh) Chrome/151.0.0.0"
            )
        )

        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Accept"), "application/json",
            "Without this the endpoint serves HTML, not the payload this feature reads."
        )
        XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "dotcom_user=zak; user_session=abc")
        XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "Mozilla/5.0 (Macintosh) Chrome/151.0.0.0")
    }

    func test_theRequestCarriesNoAmbientCookieStateInEitherDirection() throws {
        let request = try XCTUnwrap(
            GitHubSearchEndpoint.request(
                query: "is:pr",
                cookies: ["dotcom_user": "zak", "user_session": "abc"],
                userAgent: "Mozilla/5.0 (Macintosh) Chrome/151.0.0.0"
            )
        )
        XCTAssertFalse(
            request.httpShouldHandleCookies,
            "The explicit Cookie header must be the only cookie state this request carries, in and out."
        )
    }

    func test_anEmptyUserAgentSendsNoUserAgentHeaderAtAll() throws {
        let request = try XCTUnwrap(
            GitHubSearchEndpoint.request(query: "is:pr", cookies: ["dotcom_user": "zak"], userAgent: "")
        )
        XCTAssertNil(request.value(forHTTPHeaderField: "User-Agent"))
    }

    // MARK: - The status taxonomy

    func test_statusMapping() {
        XCTAssertNil(GitHubSearchEndpoint.failure(forStatus: 200, body: Data()), "200 means read the body")
        XCTAssertEqual(GitHubSearchEndpoint.failure(forStatus: 401, body: Data()), .signedOut)
        XCTAssertEqual(GitHubSearchEndpoint.failure(forStatus: 429, body: Data()), .rateLimited)
        XCTAssertEqual(GitHubSearchEndpoint.failure(forStatus: 500, body: Data()), .badResponse(500))
        XCTAssertEqual(GitHubSearchEndpoint.failure(forStatus: 404, body: Data()), .badResponse(404))
    }

    func test_a403WhoseBodyNamesARateLimitIsARateLimit() {
        let body = Data(#"{"message":"You have exceeded a secondary rate limit."}"#.utf8)
        XCTAssertEqual(GitHubSearchEndpoint.failure(forStatus: 403, body: body), .rateLimited)
    }

    func test_anOrdinary403IsNotARateLimit() {
        let body = Data(#"{"message":"Must have admin rights to Repository."}"#.utf8)
        XCTAssertEqual(GitHubSearchEndpoint.failure(forStatus: 403, body: body), .badResponse(403))
    }

    // MARK: - Title cleanup

    func test_stripsSearchHighlightMarkupAndDecodesEntities() {
        XCTAssertEqual(
            GitHubLiveFolderTitle.clean("Bump <em>react</em> @types&#x2F;react"),
            "Bump react @types/react"
        )
    }

    func test_decodesTheEntitiesGitHubsOwnEscapingProduces() {
        XCTAssertEqual(GitHubLiveFolderTitle.clean("Fix A&amp;B"), "Fix A&B")
        XCTAssertEqual(GitHubLiveFolderTitle.clean("Use &quot;strict&quot; mode"), "Use \"strict\" mode")
        XCTAssertEqual(GitHubLiveFolderTitle.clean("Handle &#47; in paths"), "Handle / in paths")
    }

    func test_aTitleThatLiterallyContainsAnEmTagKeepsIt() {
        XCTAssertEqual(GitHubLiveFolderTitle.clean("Render &lt;em&gt; correctly"), "Render <em> correctly")
    }

    func test_anUnknownEntityIsLeftAloneRatherThanGuessedAt() {
        XCTAssertEqual(GitHubLiveFolderTitle.clean("Three &frac34; done"), "Three &frac34; done")
    }

    // MARK: - The queries

    func test_theQueryStrings() {
        XCTAssertEqual(GitHubLiveFolderQuery.createdByMe(login: "zak"), "is:pr is:open author:zak sort:updated")
        XCTAssertEqual(
            GitHubLiveFolderQuery.reviewRequested(login: "zak"),
            "is:pr is:open review-requested:zak sort:updated"
        )
    }

    // MARK: - Decoding the verbatim payload

    private static let capturedPayload = """
    { "payload": {
        "logged_in": true,
        "result_count": 17604627,
        "results": [ {
          "id": "4205067172",
          "number": 6,
          "state": "open",
          "merged": false,
          "reviewable_state": "ready",
          "hl_title": "Bump <em>react</em>, <em>react</em>-dom",
          "author_name": "dependabot[bot]",
          "author_avatar_url": "https://avatars.githubusercontent.com/in/29110?s=48&v=4",
          "created": "2026-08-04T16:00:54.000Z",
          "labels": ["dependencies"],
          "num_comments": 0,
          "repo": { "repository": { "owner_login": "PebbleBird-co", "name": "FinalFinal-Chinese" } }
        } ],
        "errors": []
    } }
    """

    func test_decodesTheCapturedPayload() throws {
        let rows = try GitHubSearchPayload.pullRequests(from: Data(Self.capturedPayload.utf8)).get()

        XCTAssertEqual(rows.count, 1)
        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(row.id, "4205067172")
        XCTAssertEqual(row.number, 6)
        XCTAssertEqual(row.title, "Bump react, react-dom", "the highlight markup must not reach a sidebar row")
        XCTAssertEqual(row.ownerLogin, "PebbleBird-co")
        XCTAssertEqual(row.repositoryName, "FinalFinal-Chinese")
        XCTAssertEqual(row.repositorySlug, "PebbleBird-co/FinalFinal-Chinese")
        XCTAssertEqual(row.authorLogin, "dependabot[bot]")
        XCTAssertEqual(row.state, "open")
        XCTAssertFalse(row.isMerged)
        XCTAssertFalse(row.isDraft, "`reviewable_state: ready` is not a draft")
        XCTAssertEqual(
            row.url.absoluteString, "https://github.com/PebbleBird-co/FinalFinal-Chinese/pull/6",
            "clicking a row has to open the real pull request"
        )
        XCTAssertEqual(
            try XCTUnwrap(row.createdAt).timeIntervalSince1970,
            try XCTUnwrap(GitHubSearchPayload.parseTimestamp("2026-08-04T16:00:54Z")).timeIntervalSince1970,
            accuracy: 1
        )
    }

    func test_loggedInFalseIsSignedOutEvenWhenResultsArePresent() {
        let json = Self.capturedPayload.replacingOccurrences(of: "\"logged_in\": true", with: "\"logged_in\": false")
        let decoded = GitHubSearchPayload.pullRequests(from: Data(json.utf8))

        guard case .failure(let error) = decoded else {
            return XCTFail("A logged-out payload must not be read as the signed-in user's pull requests.")
        }
        XCTAssertEqual(error, .signedOut)
    }

    func test_aNonReadyReviewableStateIsADraft() throws {
        let json = Self.capturedPayload.replacingOccurrences(of: "\"ready\"", with: "\"draft\"")
        let rows = try GitHubSearchPayload.pullRequests(from: Data(json.utf8)).get()
        XCTAssertTrue(try XCTUnwrap(rows.first).isDraft)
    }

    func test_toleratesANumericID() throws {
        let json = Self.capturedPayload.replacingOccurrences(of: "\"id\": \"4205067172\"", with: "\"id\": 4205067172")
        let rows = try GitHubSearchPayload.pullRequests(from: Data(json.utf8)).get()
        XCTAssertEqual(try XCTUnwrap(rows.first).id, "4205067172")
    }

    func test_aResultWithNoRepositoryIsDroppedRatherThanGuessedAt() throws {
        let json = """
        { "payload": { "logged_in": true, "results": [
            { "id": "1", "number": 2, "hl_title": "Orphan" },
            { "id": "3", "number": 4, "hl_title": "Real",
              "repo": { "repository": { "owner_login": "o", "name": "r" } } }
        ] } }
        """
        let rows = try GitHubSearchPayload.pullRequests(from: Data(json.utf8)).get()
        XCTAssertEqual(rows.map(\.id), ["3"], "the orphan must be dropped, and the real row must survive it")
    }

    func test_unparseableJSONIsAMalformedFailureNotAnEmptyResult() {
        let decoded = GitHubSearchPayload.pullRequests(from: Data("not json".utf8))
        guard case .failure(let error) = decoded, case .malformed = error else {
            return XCTFail("Unparseable JSON must be distinguishable from `no pull requests`.")
        }
    }

    func test_aResponseWithNoPayloadObjectIsMalformed() {
        let decoded = GitHubSearchPayload.pullRequests(from: Data(#"{"nope": 1}"#.utf8))
        guard case .failure(let error) = decoded, case .malformed = error else {
            return XCTFail("A response with no `payload` is not an empty list of pull requests.")
        }
    }

    func test_parsesBothTimestampForms() {
        XCTAssertNotNil(GitHubSearchPayload.parseTimestamp("2026-08-04T16:00:54.000Z"))
        XCTAssertNotNil(GitHubSearchPayload.parseTimestamp("2026-08-04T16:00:54Z"))
        XCTAssertNil(GitHubSearchPayload.parseTimestamp("last Tuesday"))
    }

    // MARK: - The unconfigured source

    func test_theUnconfiguredSourceReportsSignedOut() async {
        let source = GitHubLiveFolderSource.unconfigured
        let login = await source.currentLogin()
        XCTAssertNil(login)

        let result = await source.search("is:pr")
        guard case .failure(let error) = result else { return XCTFail("An unconfigured source must not succeed.") }
        XCTAssertEqual(error, .signedOut)
    }
}
