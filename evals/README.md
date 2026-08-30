# Deterministic MCP evaluations

`fixture.xml` contains ten independent, read-only questions for the native
two-window fixture. The evaluation operator must start the fixture, approve the
two exact windows through the normal native picker, and expose only the returned
opaque grant IDs to the evaluation harness. There is no preapproval bypass in a
development or production host build.

The questions call only inspection tools after setup. They intentionally exercise window disambiguation, stable element IDs, secure-value redaction, cross-window synthesis, and logical coordinate metadata without mutating the fixture.
