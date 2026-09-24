# Running application reference

Captured 2026-09-24 from `/Applications/MyClip.app` (`cc.vibevibe.myclip`). About shows **0.6.13**. The application was brought forward with its existing “MyClip 资料库” command. Five full-size 2484 × 1898 captures were inspected; Stage Manager thumbnails were not used.

| Page | Observed structure | HTML reconstruction |
| --- | --- | --- |
| Memory | Sidebar, file tree, Markdown document; expandable related memories and sources | 230 px sidebar, 300 px file pane, 32 px document padding, 30/23 px headings |
| Timeline | Application/date/event filters, day groups, three-column thumbnails, time and event metadata | Three-column DOM thumbnails, native select controls, date sheet, detail and OCR tabs |
| Kanban | Kanban/Reports tabs, candidate review area, three independent status columns | Three candidate rows; neutral, orange and blue column treatments; task detail/editor |
| Reports | User-provided current application screenshot: period/date toolbar, white paper, status-marked task summaries, trailing Share panel | 58 px toolbar; 15 px report text; 360 × 520 panel, 224 × 200 faded preview and five-column destination grid; fictional shared task data |
| Backstage | Four vertically stacked Agent rows, record list, usage lower on the page | Single outlined Agent group, 58 px job rows, scrollable usage chart and table |
| Settings | Left explanations and right grouped cards; capture, exclusions, MCP, storage, about | 250 px description column, 28 px gap; six client buttons; full scrollable page |

All main pages share a light gray sidebar, 52 px toolbar, 46 px navigation rows, blue selection and bottom Agent/Settings controls. Layout is reconstructed from these references with original project icons. Differences: fictional content, a compact edit/info entry on Memory, browser-native date controls, and local simulated system/Agent operations.

Onboarding reflects the latest production source: required permissions and optional language first, optional Agent second. It keeps the project's original illustration. Actual UI references remain local and git-ignored under `snapshots/real-app/`; they contain personal content and must not become release assets.
