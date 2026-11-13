#if canImport(os)
import os
#endif

/// A response field or reason phrase that cannot be written as is: writing it would let a
/// value inject header lines or end the head early (response splitting, #0136).
public enum HTTPFieldValidationError: Error, Sendable, Hashable {
    /// The field at `position` has a name that is not an RFC 9110 token.
    case invalidFieldName(position: Int)
    /// The field at `position` has a value with CR, LF, NUL or another control byte.
    case invalidFieldValue(position: Int)
    /// The custom reason phrase contains a control byte.
    case invalidReasonPhrase
}

/// Release-mode checks of response fields, shared by every protocol (#0136).
///
/// RFC 9110 §5.5 (HTTP/1.1), RFC 9113 §8.2.1 (HTTP/2) and RFC 9114 §4.2 (HTTP/3) forbid CR, LF
/// and NUL in field values; HTTP/1.1 also needs field names to be tokens, or a name could carry
/// the line break. The protocol runners call ``validationError(_:)`` on every handler response
/// before encoding it and answer an invalid one with a bare `500` instead (the handler's fields
/// are never written). The checks run in release builds and allocate nothing.
///
/// Bytes are scanned eight at a time for any byte below `0x20` or equal to `0x7F`; only when
/// there is one (usually a horizontal tab, which is allowed) are the values checked byte by byte.
public enum HTTPFieldValidation {
    /// The first field whose name is not a token or whose value has a forbidden byte, or `nil`.
    /// Well-known names are valid by construction and are not rescanned.
    ///
    /// Fast path: one word-at-a-time scan of the whole arena (all names and values, which an
    /// owned ``HTTPFields`` stores back to back) for control bytes and DEL, plus a token check
    /// of the names that are not well known. Only an arena with such a byte (a tab in a value,
    /// stale bytes of a removed field, or a real violation) is checked field by field.
    @inlinable
    public static func validationError(_ index: HTTPFieldIndex, _ arena: ByteBuffer) -> HTTPFieldValidationError? {
        let count = index.count
        if count == 0 { return nil }
        let clean = arena.readerIndex == 0 && arena.withUnsafeReadableBytes { !mayContainControlOrDelete($0) }
        let names = index.names
        if clean {
            for i in 0..<count where !names[i].isWellKnown {
                let nameValid = arena.withSpan(of: index.nameViews[i]) { isValidName($0) }
                if !nameValid { return .invalidFieldName(position: i) }
            }
            return nil
        }
        for i in 0..<count {
            let field = index[i]
            if !field.name.isWellKnown {
                let nameValid = arena.withSpan(of: field.nameView) { isValidName($0) }
                if !nameValid { return .invalidFieldName(position: i) }
            }
            let valueValid = arena.withSpan(of: field.valueView) { isValidValue($0) }
            if !valueValid { return .invalidFieldValue(position: i) }
        }
        return nil
    }

    /// The first invalid field of `fields`, or `nil`.
    @inlinable
    public static func validationError(_ fields: HTTPFields) -> HTTPFieldValidationError? {
        fields.withFieldStorage { index, arena in validationError(index, arena) }
    }

    /// The first invalid field or reason phrase of `response`, or `nil`. Only custom reason
    /// phrases are scanned: registered ones are literals known to be valid.
    @inlinable
    public static func validationError(_ response: HTTPResponse) -> HTTPFieldValidationError? {
        if response.status.customReason != nil {
            let reasonValid = response.status.withReasonPhrase { isValidValue($0) }
            if !reasonValid { return .invalidReasonPhrase }
        }
        return validationError(response.headers)
    }

    /// True when `name` is a non-empty RFC 9110 token.
    @inlinable
    public static func isValidName(_ name: Span<UInt8>) -> Bool {
        guard !name.isEmpty else { return false }
        for i in name.indices where !ASCII.isTokenCharacter(name[i]) { return false }
        return true
    }

    /// True when every byte of `value` may appear in a field value (RFC 9110 §5.5): no CR,
    /// LF, NUL, other control bytes or DEL; SP, HTAB and obs-text are allowed.
    @inlinable
    public static func isValidValue(_ value: Span<UInt8>) -> Bool {
        let suspect = value.withUnsafeBytes { mayContainControlOrDelete($0) }
        guard suspect else { return true }
        for i in value.indices where !ASCII.isFieldValueCharacter(value[i]) { return false }
        return true
    }

    /// True when `bytes` has a byte below `0x20` (HTAB included) or `0x7F`; false means every
    /// byte is valid in a field value. Eight bytes per step; a short input is checked bytewise.
    @inlinable
    static func mayContainControlOrDelete(_ bytes: UnsafeRawBufferPointer) -> Bool {
        let count = bytes.count
        if count < 8 {
            for i in 0..<count {
                let byte = bytes[i]
                if byte < 0x20 || byte == 0x7F { return true }
            }
            return false
        }
        var flagged: UInt64 = 0
        var i = 0
        while i &+ 8 <= count {
            flagged |= controlOrDelete(bytes.loadUnaligned(fromByteOffset: i, as: UInt64.self))
            i &+= 8
        }
        if i < count {
            // The last eight bytes, overlapping the words already scanned.
            flagged |= controlOrDelete(bytes.loadUnaligned(fromByteOffset: count &- 8, as: UInt64.self))
        }
        return flagged != 0
    }

    /// High bits set for bytes of `word` below `0x20` or equal to `0x7F` (nonzero exactly when
    /// there is one; bits above a true match may be spurious, which only matters for locating it).
    @inlinable
    static func controlOrDelete(_ word: UInt64) -> UInt64 {
        let ones: UInt64 = 0x0101_0101_0101_0101
        let highs: UInt64 = 0x8080_8080_8080_8080
        let below20 = (word &- 0x20 &* ones) & ~word & highs
        let delete = word ^ (0x7F &* ones)
        let isDelete = (delete &- ones) & ~delete & highs
        return below20 | isDelete
    }
}

extension HTTPFieldValidation {
    /// Reports a handler response that was replaced with `500` because of `error`: an `os`
    /// log entry at the error level (subsystem `SwiftWebServer`, category `HTTP`). Cold path.
    @inline(never)
    public static func reportRejectedResponse(_ error: HTTPFieldValidationError, status: HTTPStatus,
                                              protocolName: StaticString) {
        #if canImport(os)
        let detail: String
        switch error {
        case .invalidFieldName(let position): detail = "field \(position) has a name that is not a token"
        case .invalidFieldValue(let position): detail = "field \(position) has a value with CR, LF, NUL or a control byte"
        case .invalidReasonPhrase: detail = "the reason phrase has a control byte"
        }
        let name = protocolName.description
        rejectionLog.error("\(name, privacy: .public): replaced a \(status.code, privacy: .public) response with 500: \(detail, privacy: .public)")
        #endif
    }

    #if canImport(os)
    static let rejectionLog = Logger(subsystem: "SwiftWebServer", category: "HTTP")
    #endif
}
