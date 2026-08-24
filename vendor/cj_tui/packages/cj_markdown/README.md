# cj_markdown

`cj_markdown` is the Markdown parser package used by cj_tui.

It intentionally has no dependency on `cj_tui`. UI packages should consume the AST and map it into their own render model, such as `cj_tui.Document`.

## API

```cangjie
import cj_markdown.*

let doc = parseMarkdown("# Title\n\n- item")
for (block in doc.blocks) {
    // inspect block.kind, block.text, block.inlines
}

for (diagnostic in doc.diagnostics) {
    // inspect diagnostic.severity, diagnostic.message, diagnostic.range
}
```

Current parser coverage:

- source ranges on blocks and inline spans
- ATX headings, including optional closing `#`
- setext headings
- merged paragraphs
- soft-break inline ranges for merged paragraph source mapping
- grouped unordered and ordered list items with nested child items
- task list items
- block quotes with parsed child blocks, including indented quote markers
- fenced code blocks with language info
- indented code blocks
- list continuation lines
- pipe tables with header, alignment, and body rows
- horizontal rules
- HTML blocks and inline HTML
- reference definitions and reference-style links/images
- shortcut reference links
- inline links with optional title
- inline images
- inline code
- multi-backtick inline code spans
- inline strong and emphasis
- inline strikethrough
- autolinks
- common backslash escapes
- escaped pipe characters in table cells
- parser diagnostics, including unclosed fenced code blocks

## cj_tui Adapter

The `cj_tui` integration lives in an extension package, not in `cj_tui` core:

```text
cj_markdown MarkdownDocument
    -> cjtui_markdown adapter
    -> cj_tui Document
    -> DocumentView
```

This keeps Markdown parsing reusable by non-TUI consumers and keeps the TUI core focused on rendering.
