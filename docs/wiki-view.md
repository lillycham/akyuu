# The wiki view

Status: built, 2026-10-13. It is the first tab of the web view (`akyuu serve`,
`akyuu viz`).

The graph shows how memories relate. The wiki is for reading them: each ref is
a page, and the body of its current memory is rendered as Markdown.

## What a page shows

- The ref name, the kind, the agent, the time and the id of the memory.
- The body, as Markdown: headings, lists (two levels), fenced code, quotes,
  rules, paragraphs, `code`, **strong**, *em*, `[text](https://...)` and bare
  `http(s)` URLs.
- Links in the text: a ref name (`me/profile`) becomes a link to its page,
  and a whole id becomes a link to the memory panel. Only the names of refs
  that exist are links, and only as whole words.
- **Links to**: the `about`, `derived-from` and `refines` edges of the memory.
  A target that a ref holds shows the ref name.
- **Linked from**: the edges that point at the memory, and the pages whose text
  names this ref.
- **History**: the older values of the ref, each with a comparison to now (the
  Compare panel).
- **Episodes**, for a log (a ref with a `log` part in its name, or whose memory
  is an episode or a note): the episodes, newest first, 15 at a time.

The left side is a tree of the refs by their parts, with a filter. The address
is `#wiki/<ref>`, so a page has a link of its own and the back button works.

## Safety

A body is text from the store, so it is untrusted. The page reads it into plain
data (`mdBlocks`, `mdInline`) and builds DOM nodes with `textContent` only: no
HTML from the store reaches the page, and the check of the page fails if the
script uses `innerHTML` or a similar sink. A link becomes an `<a>` only for
`http(s)`, a ref name or an id; `javascript:` and other schemes stay text.

The view is read-only, like the rest of the server.

## Where it lives

- `GET /api/pages`: each ref with its current memory (kind, agent, time, body)
  and its older values. A ref that cannot be read has an `error` and no body.
- The export (`akyuu viz`) builds the same pages from the refs and the memories
  that it holds, so the wiki works offline too.
- `web/index.html`: the pure functions (`mdBlocks`, `mdInline`, `refMatcher`,
  `wikiTree`, `textBacklinks`, `isLogPage`) are checked in node by
  `test/check-page.js`, with the rest of the page in a small fake DOM.

## Not done

- Tables and images in Markdown.
- A full-text search box in the wiki: the Search tab does that.
