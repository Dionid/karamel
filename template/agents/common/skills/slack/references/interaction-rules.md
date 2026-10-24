# Slack interaction rules

Generic etiquette for composing a Slack message through this skill. None of
this is a substitute for the approval rule in `SKILL.md` — every write still
needs explicit consent on the exact channel/thread and text; this is only about
how to shape that text once it's approved.

## Formatting: Slack mrkdwn, not standard Markdown

- Bold: `*single asterisks*` (never `**double**`)
- Italic: `_underscores_`
- Strike: `~tilde~`
- Code: single backtick, or triple-backtick blocks with no language identifier
- Links: `<url|label>` — wrap a bare link in `<>` too, to suppress the preview
- No `#` headings, no `---` rules, no pipe tables — use bullet lists instead
- Lists: `•` or `- ` (dash + space)
- Mentions: `<@USER_ID>`, `<!subteam^SUBTEAM_ID>`, `<!channel>`, `<!here>`

## Threading

- Replying to a specific message keeps it in that thread (`thread_ts`); don't
  start a new top-level message when the conversation already has one.
- A genuinely new topic is a new top-level message, not a reply shoehorned into
  an unrelated thread.
- A long analysis gets a short summary at the top level and the detail in the
  thread — not the other way round.

## Tagging back

A reply in a channel or a group DM should mention whoever it answers
(`<@USER_ID>`, from the inbound message's own sender field) so they see it
without having to notice the thread moved. Optional only in a genuine one-on-one
DM, where the other side sees every message anyway.

## Reactions

A reaction is a lighter-weight acknowledgement than a reply when a full message
isn't needed — "seen", "working on it", "done". Keep it to one reaction per
message; a message that gets a reaction and a reply and another reaction is
noise, not signal. `reactions_add`/`reactions_remove` are ordinary Slack writes
and follow the same approval rule as posting.

## Output hygiene

- No internal preamble ("scan complete", "file written") — say the actual
  answer.
- No absolute filesystem paths, no internal decision-record IDs, no tool names.
- No `.env` values, tokens, or other secrets, ever.
- One message, not a slide deck: consolidate into a single post rather than a
  burst of short ones.
- A channel meant for an external audience is stricter still: no internal
  detail at all, even in passing.

## Message length

- Keep a channel post concise; long analysis is a summary plus "details in
  thread".
- Never dump raw SQL/JSON output into a message — summarize, and put the raw
  data in the thread only if someone actually needs it.

## Group-chat judgement

- Respond when directly mentioned, when there's genuine value to add, or to
  correct something wrong.
- Stay silent on casual banter, when someone already answered, or when the
  reply would just be "yeah" — quality over quantity.
- Don't reply and react to the same message; pick one.
