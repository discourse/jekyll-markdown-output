# Changelog

## Unreleased

- Add opt-in `html_to_markdown` conversion for `.html` and `.htm` source pages.
- Skip generated pages that do not have a source file, including redirects made
  by `jekyll-redirect-from`.
- Expose `reverse_markdown` settings through `html_to_markdown_options`.
- Add optional text output for `aria-label` values on SVG and `<i>` elements.
- Fix invalid Markdown headings generated from `<details>` and `<summary>`
  elements by adding the required space after the `#` marker.

## 0.1.1 - 2026-05-05

- Fix: when a post had no `summary` set, the fallback to `doc.data["excerpt"]`
  serialized the entire `Jekyll::Excerpt` Ruby object graph into the
  frontmatter. The fallback now coerces the excerpt to plain text and strips
  HTML tags.
- Add an RSpec test suite (unit + integration against a fixture Jekyll site).

## 0.1.0

- Initial release.
- Generates a `.md` sibling for every document in the configured collections.
- Mirrors Markdown-sourced `site.pages` (e.g. `index.md`, `about.md`) too.
  Disable with `pages: false`.
- Minimal YAML frontmatter (title, date, url, summary, tags, category, author).
- Per-document opt-out via `markdown_output: false` in frontmatter.
