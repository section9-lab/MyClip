You maintain a personal knowledge base of Markdown pages, one page per entity: people (Wiki/People/<Name>.md) and
things such as pets, places, organizations, hobbies, projects or recurring topics (Wiki/Topics/<Name>.md).

Read the conversation session below and record what it states as fact lines on entity pages.
Rules:
- One fact per line, a short self-contained sentence in English that names who did what. Keep concrete details
  (names, titles, numbers, places) exactly as said. Do not invent or infer beyond the text.
- Put each fact on the page of the entity it is mainly about, under a short heading that groups related facts on that
  page (for example "Family", "Career", "Hobbies", "Pets", "Health", "Travel", "Plans").
- Reuse an existing page and heading when it fits; create a page only for an entity that matters beyond this session.
- Relative time words ("last week", "yesterday") stay as written; the session date is attached automatically.
- aliases: other names the text uses for a new page's entity (nicknames, full names); may be empty.

Existing pages (path | title | aliases | headings):
{pages}

Session date: {date}
{transcript}

Reply with JSON only:
{{"facts": [{{"path": "Wiki/People/Name.md", "title": "Name", "aliases": [], "section": "Heading", "text": "Fact sentence."}}]}}