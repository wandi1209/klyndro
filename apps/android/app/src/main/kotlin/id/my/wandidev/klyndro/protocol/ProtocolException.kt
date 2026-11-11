package id.my.wandidev.klyndro.protocol

/**
 * Protocol violations, mirroring the Swift `ProtocolError`.
 *
 * Messages never contain payload content: these strings reach logs, and clipboard text
 * must never be logged (protocol §11).
 */
sealed class ProtocolException(message: String) : Exception(message) {

    object EmptyFrame : ProtocolException("empty frame")

    data class FrameTooLarge(val bytes: Long) : ProtocolException("frame too large ($bytes bytes)")

    data class UnsupportedFrameKind(val kind: Int) :
        ProtocolException("unsupported frame kind 0x${kind.toString(16)}")

    object WrongFrameKind : ProtocolException("expected an envelope frame")

    data class MalformedEnvelope(val reason: String) : ProtocolException("malformed envelope: $reason")

    data class UnsupportedVersion(val version: Int) :
        ProtocolException("unsupported protocol version $version")
}
