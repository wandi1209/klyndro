# Protocol fixtures

These JSON files are the shared, executable contract for the parts of
[`../specification/klyndro-protocol-v1.md`](../specification/klyndro-protocol-v1.md) that
are implemented at M0: the envelope model and its validation rules.

They are consumed by **both** implementations:

- macOS: `apps/macos/KlyndroKit/Tests/KlyndroKitTests/FixtureConformanceTests.swift`
- Android: `apps/android/app/src/test/kotlin/id/my/wandidev/klyndro/FixtureConformanceTest.kt`

`manifest.json` declares every fixture and the decoder outcome each implementation must
produce. Adding a fixture without adding a manifest entry is a bug; a test asserts that
the manifest and the directory contents agree.

## Expectations

| `expect` | Decoder must |
| --- | --- |
| `valid` | Decode successfully, with the listed `type` |
| `unknown_type` | Decode successfully; the type is not in the v1 catalog, so it is ignored without an error |
| `malformed` | Reject with a protocol error (never crash, never dispatch) |

Fixtures describe *frames' JSON payloads*, not the length prefix, because framing is
covered by unit tests in each implementation.

## Conventions

- Envelope keys are lowercase snake_case.
- `id` values are fixed UUIDs so fixtures are stable across runs. They are not secrets.
- `text` values are obviously synthetic. Never place real clipboard content in a fixture.
