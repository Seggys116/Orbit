# Extension corpus

`extension-corpus.json` pins the real Chrome extensions (by id, version and SHA-256) that the live suites load and drive. It is a test input, not a build input; `Scripts/extension-corpus` is its only reader and writer.
