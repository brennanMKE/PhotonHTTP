import Testing
@testable import HTTPCore

private func validValue(_ bytes: [UInt8]) -> Bool {
    bytes.withUnsafeBufferPointer { HTTPFieldValidation.isValidValue($0.span) }
}

private func validName(_ bytes: [UInt8]) -> Bool {
    bytes.withUnsafeBufferPointer { HTTPFieldValidation.isValidName($0.span) }
}

/// #0136: release-mode field validation shared by every protocol.
@Suite struct HTTPFieldValidationTests {
    /// The word-at-a-time scan agrees with the byte table for every byte value at every
    /// position of values from 1 to 19 bytes (both the 8-byte words and the padded tail).
    @Test func wordScanAgreesWithTheByteTable() {
        var mismatches = 0
        for length in 1..<20 {
            for position in 0..<length {
                for byte in 0...255 {
                    var bytes = [UInt8](repeating: UInt8(ascii: "a"), count: length)
                    bytes[position] = UInt8(byte)
                    if validValue(bytes) != ASCII.isFieldValueCharacter(UInt8(byte)) {
                        mismatches += 1
                        Issue.record("length \(length) position \(position) byte \(byte)")
                        if mismatches > 10 { return }
                    }
                }
            }
        }
    }

    @Test func emptyValueIsValidAndEmptyNameIsNot() {
        #expect(validValue([]))
        #expect(!validName([]))
    }

    @Test func tabAndObsTextAreAllowed() {
        let value: [UInt8] = Array("a\tb c".utf8) + [0x80, 0xFF] + Array("0123456789".utf8)
        #expect(validValue(value))
    }

    @Test func injectedLineBreakInAValueIsReported() {
        var headers = HTTPFields()
        headers.append(.contentType, "text/plain")
        headers.append(.location, string: "/next\r\nSet-Cookie: session=stolen")
        #expect(HTTPFieldValidation.validationError(headers) == .invalidFieldValue(position: 1))
        #expect(HTTPFieldValidation.validationError(HTTPResponse(headers: headers)) == .invalidFieldValue(position: 1))
    }

    @Test func nameThatIsNotATokenIsReported() {
        var headers = HTTPFields()
        headers.append(name: "X-Evil\r\nSet-Cookie", value: "a")
        #expect(HTTPFieldValidation.validationError(headers) == .invalidFieldName(position: 0))
    }

    @Test func customReasonPhraseIsChecked() {
        #expect(HTTPFieldValidation.validationError(HTTPResponse(status: HTTPStatus(code: 299, reasonPhrase: "Fine"))) == nil)
        #expect(HTTPFieldValidation.validationError(HTTPResponse(status: HTTPStatus(code: 299, reasonPhrase: "Bad\r\nX: y")))
                == .invalidReasonPhrase)
    }

    @Test func typicalResponseIsValid() {
        var headers = HTTPFields()
        headers.append(.contentType, "text/html; charset=utf-8")
        headers.append(.etag, "\"5f3e-1a2b\"")
        headers.append(name: "X-Request-Id", value: "7f3a9c2e")
        #expect(HTTPFieldValidation.validationError(HTTPResponse(headers: headers)) == nil)
    }
}
