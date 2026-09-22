# Release notes

One file per published release, named for the version it belongs to:
`v1.3.0.md`. Introduced by
[#398](https://github.com/yvanvds/AccountManager/issues/398).

These are **not** a changelog. The file is what the **Wat is er nieuw** dialog
shows an operator on their first launch after the update that carried it
([#395](https://github.com/yvanvds/AccountManager/issues/395)), and it is the
only channel this project has to the people running it. Write for that reader:
what changed for them, and what they have to do about it.

- Write the file on the same PR as the `pubspec.yaml` version bump, so it is
  reviewed with the change it describes.
- A tag whose version has no file here **fails the release run** before
  anything is built. An empty body shows no dialog at all, so publishing
  without notes reaches every desk having told them nothing.
- Don't repeat the install, SmartScreen and bijwerken paragraphs — the workflow
  appends those below your file on every release.
- Markdown, lightly: headings, `-`/`1.` lists, `**bold**`, `*italic*`,
  `` `code` ``, fenced blocks, `---` and `[label](url)` links. No tables — the
  in-app reader renders them as literal pipes.

The full rules, and how the dialog decides when to appear, are in
[`../release-process.md`](../release-process.md).
