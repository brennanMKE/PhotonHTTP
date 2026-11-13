import HTTPCore
import Testing
@testable import StaticFiles

/// #0139: ErrorPages also styles the responses protocol runners write themselves.
@Suite struct ErrorPagesProtocolResponseTests {
    @Test func runnerErrorsGetThePage() {
        let observers = ProtocolResponseObservers(chain: ErrorPages())
        #expect(observers.observers.count == 1)
        let built = TestRequest(.get, "/x")
        let thrown = observers.response(status: .internalServerError, cause: .handlerFailed, request: built.request,
                                        context: RequestContext())
        #expect(thrown.status == .internalServerError)
        #expect(thrown.header(.contentType) == "text/html; charset=utf-8")
        #expect(thrown.bodyText.contains("<h1>500 Internal Server Error</h1>"))
        // No request (an unparsable head): the page of a GET.
        let malformed = observers.response(status: .badRequest, cause: .malformedRequest, request: nil,
                                           context: RequestContext())
        #expect(malformed.bodyText.contains("<h1>400 Bad Request</h1>"))
    }

    @Test func headGetsNoPage() {
        let observers = ProtocolResponseObservers([ErrorPages()])
        let built = TestRequest(.head, "/x")
        let response = observers.response(status: .internalServerError, cause: .handlerFailed, request: built.request,
                                          context: RequestContext())
        guard case .empty = response.body else {
            Issue.record("HEAD got a body")
            return
        }
        #expect(response.header(.contentType) == nil)
    }
}
