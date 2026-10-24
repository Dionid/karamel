---
name: notion
description: Читать Notion — одну страницу, всё дерево страниц вглубь, или строки базы данных — используя корни из notion.json и токен из корневого .env. Использовать, когда пользователь спрашивает, что говорит Notion о чём-то, просит найти или искать страницу, прочитать spec/doc/handbook, который живёт в Notion, глубоко пройти раздел Notion, или называет URL Notion. Публикация в Notion — это скилл notion-publish.
---

# Read Notion

`notion.sh` (next to this file) does the API work. `NOTION_TOKEN` is sourced from
the workspace root `.env` inside the script, so it never reaches the transcript —
don't reimplement the `curl` calls inline.

**Everything here is read-only.** Writing a page is the **`notion-publish`**
skill, and it asks before overwriting.

## The page you can walk is configured, not guessed

Which pages this workspace reads from is a **team repository** decision, in
`notion.json` at the workspace root — the engine is generic and ships no page
ids of its own:

```json
{
  "defaultRoot": "team",
  "roots": {
    "team": {
      "title": "Engineering handbook",
      "page": "https://app.notion.com/p/...",
      "maxDepth": 6,
      "description": "what lives under this root"
    }
  }
}
```

`maxDepth` is how deep that root is meant to be read when `--depth` is not
passed. It bounds the page TREE only — links and database rows have their own
bounds, described two sections down, and a walk stops at whichever it meets
first. Adding a second root is an edit to that file, not to this skill.

A root may turn either half of the deep walk off for itself, and nothing else
in the manifest changes behaviour:

| key | default | what `false` does |
| --- | --- | --- |
| `dbs` | `true` | database rows are not walked, only named |
| `links` | `true` | Notion links in the page text are not followed |

| `maxLinkDepth` | `2` | how many link hops past the tree to take |
| `maxPages` | `2000` | hard page budget for the root; `0` removes it |

```bash
.claude/skills/notion/notion.sh roots   # ← what is configured, and which is default
```

Anywhere a command takes `<ref>`, you may pass a **root name** from that file, a
full Notion URL, a dashed uuid or a bare 32-hex id. **Omit it entirely and you
get `defaultRoot`** — that is what makes "посмотри в Notion" answerable without
anyone knowing an id.

## Reading

```bash
.claude/skills/notion/notion.sh page  [<ref>]                    # one page as markdown
.claude/skills/notion/notion.sh tree  [<ref>] [--depth N|max]    # the map of a subtree
.claude/skills/notion/notion.sh grep  <pattern> [<ref>] [-i]     # find text in a subtree
.claude/skills/notion/notion.sh dump  [<ref>] [--out DIR] [--layout nested]
.claude/skills/notion/notion.sh db    <ref> [--limit N]          # a database's rows
.claude/skills/notion/notion.sh search <query>                   # Notion's own search
.claude/skills/notion/notion.sh whoami                           # which integration this is
.claude/skills/notion/notion.sh edited <ref>                     # last_edited_time only, no walk
```

**Start with `tree`, then read what it names.** The map costs one request per
page and tells you what exists; `page` then fetches only the ones that matter.
Reading the whole tree to answer one question is the expensive way round.

`tree` closes with `PAGES`, `DATABASES`, `DEEPEST_LEVEL` and `DEPTH_LIMIT`. When
`DEEPEST_LEVEL` is below `DEPTH_LIMIT`, **the subtree was exhausted** — there is
nothing deeper, and you can say so. When they are equal the walk was cut off, and
the output says which `--depth` would go further. That distinction is the whole
answer to "смотри максимально глубоко": don't report a tree as complete unless
the numbers show it.

## Which command answers which question

| The ask | The command |
| --- | --- |
| "что у нас в Notion про X" | `grep X` — walks the default root and shows the pages that match |
| "прочитай <ссылка>" | `page <url>` |
| "что вообще есть в разделе Y" | `tree <ref>` |
| "разберись глубоко в разделе Y" | `dump <ref> --out <scratchpad>/notion-Y`, then read the files |
| "какие партнёры/задачи/встречи" | `db <ref>` — a database is rows, not prose |
| "найди страницу, названия не помню" | `search <query>` — the whole workspace, not just the root |
| "свежий ли этот файл слепка" | `edited <id>` (id from the file's own frontmatter) against that frontmatter's `edited` |

`grep` walks the API every time. When you will search the same subtree more than
once, `dump` it and then `grep <pattern> --from <dir>`, which is local and free.

**A dump you intend to keep needs `--layout nested`.** The default names files by
walk order (`001-…`, `002-…`), so one page inserted in Notion renames every file
after it — fine for a scratch dump, ruinous for one under version control, where
that is a hundred-file diff with no content change in it. `nested` mirrors the
page tree instead (`product.md` next to `product/payment-flows.md`), derives each
name from the title, and transliterates it to ASCII. Both layouts write the same
`INDEX.md` map and the same per-page frontmatter.

**The frontmatter of every dumped page carries `edited`** — that page's own
`last_edited_time` from Notion, not the date of the dump run. It costs a second
`GET /pages/<id>` per page (the markdown endpoint has no metadata of its own),
so `dump` is twice the requests, and twice the wall time, of a plain walk.

## Paying for a page once: `--cache` and `--resume`

One walk of a large root is hours, and a runtime that kills it at two leaves
nothing behind — the next attempt starts the root over. `--cache DIR` fixes
that by keeping each page's markdown beside the `last_edited_time` it was
rendered at, which splits the cost in two: *has this changed* is one request,
*what does it say* is another, and only the first has to be asked every time.

| | what it asks per cached page | measured on 40 pages |
| --- | --- | --- |
| cold | body + edited | 80s |
| `--cache` | edited only, body only when it moved | 41s |
| `--cache --resume` | nothing | 5.7s |

So the two modes answer different questions. **`--cache` alone is a refresh**:
every page is still asked whether it moved, so the result is as current as a
cold walk at about half the requests. **`--cache --resume` is a continuation**:
a cached page is taken on trust, which is the only way the already-walked part
replays fast enough to reach what was never walked at all. Resume therefore
does *not* notice a page that changed since it was cached — run without
`--resume` once the walk has finished to pick those up.

`--resume` without `--cache` is refused rather than walked cold: a run that
quietly started over would be indistinguishable from one that resumed. For the
same reason `notion-snapshot` labels a resumed snapshot in its PR.

Two things resume does **not** do, and both are deliberate. Database rows are
re-queried every time, because that is how a resumed walk notices rows added
since: on a root whose page count is mostly DB rows, resume is cheaper but not
free, and the 5.7s/40-page figure will not extrapolate. And a page whose render
was truncated is re-fetched by a refresh rather than served from cache — one
exhausted retry mid-walk would otherwise freeze that page in its broken form,
since its own `edited` never moves again.

The summary gains `FROM_CACHE=`, `FETCHED=` and `CACHE=`. A resumed run whose
`FETCHED` is 0 reached nothing new — that is a finished tree, not a stalled one.

## Checking whether a dump is stale

A committed dump (a `notion-snapshot`, or any `--keep`/`--out` you held onto) is
a copy, not the live page — read `notion-snapshot`'s own docs for what that means
for citing it. To find out whether the live page moved since the copy was taken,
without re-dumping the whole tree:

1. **Trust a recent dump outright.** If the run that produced it was less than a
   week old, its `edited` fields are current enough — don't spend a request
   re-checking them.
2. **Older than a week, check only the pages the answer actually rests on** —
   `notion.sh edited <id>` (the `id` is in the page's own frontmatter) against
   that same frontmatter's `edited`. One request, no walk, no title-matching
   ambiguity the way `search` has.
3. **They differ → re-read the live page** (`notion.sh page <id>`) before citing
   it as current. They match → the copy is still accurate for that page.

This is a per-page spot-check, not a reason to re-run the whole dump — a full
refresh is still something you're asked for, not something staleness triggers on
its own.

## What a walk reaches — and what that costs

A walk is **deep by default in both directions**:

- **Database rows are walked.** A root that is little more than one inline
  database comes out as its rows, not as a single line naming the database.
- **Notion links in the page text are followed.** A page is reached through
  whatever points at it, not only through the parent that owns it — which is
  what lets a walk cross from one tree into a page filed somewhere else
  entirely.

`--no-dbs` and `--no-links` turn each off for one run; `"dbs": false` /
`"links": false` turn it off for a root. `--dbs` / `--links` force it back on
against a manifest that opted out.

**The tree is walked first, links only after it.** That ordering is load-bearing,
not an optimisation: a page is claimed by the first edge that reaches it, so
following links where they are found would let a sentence decide whether a page
belongs to this tree or is a stranger it points at. Draining links afterwards
means a link can only ever reach a page the tree does not own — and such a page
is written under `_linked/` in a `nested` dump, not under whoever mentioned it,
so a committed path does not move when somebody writes a sentence. Everything
there is named `<slug>-<id8>`, because that directory is one flat namespace for
the whole run and walk order must not get to decide which of two same-titled
pages keeps the clean name.

Read `_linked/` as "no tree edge reached this page within the depth limit",
not as "this page is outside the tree": a structural child sitting past
`maxDepth` is not recorded by the tree walk, so a link can reach it afterwards
and file it there.

**Links are a graph, so they get their own bounds.** `maxDepth` bounds the tree;
`--link-depth N` (default 2) bounds how many link hops past it the walk takes,
and `--max-pages N` (default 2000, 0 = off) bounds the whole thing. Without
them a root on `maxDepth: 9999` would hand the walk the transitive closure of
everything the token can open. A walk that hit the budget reports
`BUDGET_EXHAUSTED` and **must not be committed as a snapshot** — the pages it
never read are indistinguishable from pages deleted in Notion. `db <ref>` is
still the cheap answer when all you wanted was the rows of one database.

A linked page the integration cannot open is reported as `UNREACHABLE_LINKS`,
separately from `SKIPPED_PAGES`. The difference matters: a skipped **child**
means part of the tree was not read, while an unreachable **link** means only
that this tree points somewhere it cannot follow — nothing is missing from it.

## Cost, and why the walk is throttled

One request per page, paced at ~3/s because that is Notion's limit — **two per
page for `dump`**, since it also fetches `edited` (see above). A 60-page tree is
around two minutes to read, around four to dump — fine to run, not fine to run
in a loop. `dump` is the way to pay that once and then work locally.

`--depth max` (20) exists for a subtree of unknown shape. It is not a better
default: it just means the walk stops when it runs out of pages instead of
running out of levels.

## Reporting what you found

- **Link the page.** Every command prints `https://app.notion.com/p/<id>` — a
  claim about what Notion says is checkable only with the page next to it.
- **Notion is not the code.** A page can be months stale, and several here are
  explicitly `Legacy` or `[ARCHIVED]`. When a Notion page and the repository
  disagree, the repository is what runs — say both and name the page's date.
- **Don't paraphrase a spec you only saw in `tree`.** The map has titles, not
  content.

## Failure modes

- `NOTION_TOKEN is not set` — the user has to add it to the root `.env`. There is
  no fallback.
- `[object_not_found]` / 404 — nearly always the integration is not connected to
  that page. In Notion: page ⋯ menu → Connections → add the integration. It needs
  the **parent** too, not just the child page. A page that exists but was never
  shared looks exactly like a page that does not exist.
- `SKIPPED_PAGES=yes` on a walk — a child page the integration cannot read. The
  walk continues past it rather than dying, so **the tree below that page is
  missing from the run**; the summary names each one. Report that, don't call the
  tree complete.
- `[unauthorized]` / 401 — token wrong, revoked, or from another workspace.
  `whoami` says which workspace the token actually belongs to.
- `[restricted_resource]` / 403 — the integration lacks read capability, fixed in
  its settings rather than here.
- `TRUNCATED=true` — part of the page could not be read. The markdown API
  leaves `<unknown …/>` where it met a block it does not render; `notion.sh`
  drops the content-free ones (breadcrumb, table of contents, button) and
  renders the rest from the blocks API, so what stays is a block the API itself
  refuses — most often one not shared with the integration. The walk summary
  names each page with its count of unreadable blocks — `?` when the API said
  `truncated` without naming a block, or the resolver itself failed. Say so instead of
  treating what came back as the full page.
- `no manifest at …/notion.json` — the workspace has no configured roots,
  so every command needs an explicit URL or id.

`Notion-Version` is pinned to `2026-03-11` in `notion.sh` — bump it there, in one
place, if the API moves on. `notion-publish/run.sh` pins its own copy.
