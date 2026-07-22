# Project Rules

## Dart implementation

- Write idiomatic, modern Dart that takes advantage of the current SDK's language features.
- Prefer concise, strongly typed code and appropriate Dart constructs such as sealed and final classes, pattern matching, records, collection elements, and exhaustive switches when they make the code clearer and more correct.
- Model nullability explicitly, keep public APIs small and typed, and follow the effective Dart conventions enforced by the repository analyzer.
- Prefer enums over strings for closed, known sets of values; use string conversion only at serialization, parsing, or interoperability boundaries.
- Preserve original behavior and algorithms while expressing them naturally in Dart; do not transliterate JavaScript conventions that have a clearer Dart equivalent.
- Avoid unexplained numeric literals in implementation code. Extract repeated, algorithmic, domain-specific, and geometry values into clearly named constants near the renderer or utility that owns them.
- Document non-obvious constants with their meaning, units, and behavioral source (including the corresponding original concept or default when ported). Trivial structural values such as zero-based indices may remain inline when their meaning is self-evident.

## Development workflow

- Use test-driven development: add or update a failing behavioral test first, implement the smallest correct change, then refactor with the suite green.
- Port relevant upstream original parser cases and add focused Dart tests for edge cases, diagnostics, and regressions.
- Before considering a change complete, run formatting, static analysis, and the relevant tests.

## Dependencies

- Prefer established, actively maintained third-party Dart packages for solved infrastructure problems instead of reimplementing them.
- Evaluate packages for API fit, maintenance, platform support, license, and compatibility with the repository's Dart SDK constraint.
- Add a dependency only when it materially improves correctness, maintainability, or implementation effort, and use the narrowest suitable API.
