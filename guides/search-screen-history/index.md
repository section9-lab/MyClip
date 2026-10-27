# How to search your screen history on Mac

Open **Timeline** in MyClip and type a word you remember from the screen into the search field. You can search the application name, window title, or text recognized inside a screenshot. If you remember when or where you saw it, narrow the results by date or app, then open a capture to check the original image.

This guide covers searching screenshots already saved by MyClip. The separate **Memory** view contains Markdown notes organized from those captures.

## 1. Start saving screens you want to find later

If you are new to MyClip, [download the Mac app](https://github.com/section9-lab/MyClip/releases/latest), move it to Applications, and finish onboarding. You need macOS 13+, Node.js 22+, and an account for your chosen organizing Agent. Grant Screen Recording and Accessibility permissions when prompted. See the [installation notes](https://section9-lab.github.io/MyClip/#download) if macOS blocks the first launch.

In **Settings → Screenshot** (Chinese interface: **设置 → 截图**), check the capture scope and mouse and keyboard triggers. MyClip captures the focused window by default; you can instead choose the display containing that window. Captures follow the enabled activity triggers rather than recording a continuous video.

Keep MyClip open while you work in other apps, then check **Timeline** for saved screenshots. It cannot recover a screen from before capture started, an excluded app, or a moment when no capture was triggered.

## 2. Search for a word from the screen

Select **Timeline** and click the search field at the top of the app. You can also press **Command-F** to focus it.

Start with something specific you remember seeing:

- A project name or an unusual word from a document.
- Part of a page or window title.
- An application name, such as Safari.
- A label from a design or an error message.

For example, if a page you read contained the words “release checklist,” try searching for **checklist**. This is an illustrative query; results depend on your own captured screens.

MyClip uses on-device optical character recognition (OCR) to extract text from screenshots for local search. Timeline searches the recognized text as well as app names and window titles. You can search saved captures while they are waiting for Agent organization.

Use words likely to appear on the screen. For a question such as “What did I decide about the release?”, try the organized notes in **Memory**, or the Agent workflow below.

## 3. Narrow the results by app and date

Use the filters above the screenshot grid:

- **App** (**应用**): choose the app where you saw the content.
- **All Dates** (**全部日期**): choose a start and end date, then click **OK** (**确定**).
- **Trigger Event** (**触发事件**): show mouse or keyboard captures if you remember how the screen was saved.

The filters work together with your search text. For example, search for **checklist**, select Safari, and set the dates to the day you read it. If nothing matches, remove the date or app restriction before trying a different word.

Timeline shows recent matches first. When there are many results, narrowing the date range makes older captures easier to find. Use the reset control to clear the filters; clear the search field separately to browse all available captures.

## 4. Open a result and check the screenshot

Click a screenshot card to open its detail view. Check the app name, window title, and capture time before relying on what you find.

Related captures may be grouped into one card. If the detail view contains several frames, use the frame strip or previous and next controls to inspect the other captures.

Select **OCR** beside the screenshot tab to read the extracted text. You can select the text or use **Copy raw text** (**复制原文**). OCR can miss small, blurred, or stylized text, so check the image when the wording matters.

If the capture has linked memories, the detail view also lets you open those notes in **Memory**.

## If a search comes back empty

- **No screenshots in Timeline:** check capture permissions, the enabled triggers, and excluded apps in Settings. MyClip skips its own windows, the lock screen, and excluded apps.
- **Screenshots exist, but a word does not match:** try a shorter distinctive word, the window title, or the app name. Open a likely capture and inspect its OCR text to see what was recognized.
- **A date or app filter is active:** reset the filters and retry. A search term remains active until you clear it.
- **The screen is old:** check **Settings → Storage → Keep Original Screenshots** (**存储 → 原始截图保留**). Original images and OCR text are cleaned up together when they expire; screenshots waiting for organization are retained. Organized memories are stored separately and may still contain the context you need.
- **You want an unsaved screen or an older video:** MyClip searches its capture library. It cannot reconstruct missing captures or replay the intervals between them.

## Ask Codex or Claude about saved work

Once your chosen Agent has organized captures into **Memory**, you can search those notes through MyClip's local MCP server. Follow the [Codex setup guide](https://section9-lab.github.io/MyClip/guides/codex/) or [Claude Code setup guide](https://section9-lab.github.io/MyClip/guides/claude-code/).

For example:

> Use MyClip to find the release checklist I reviewed yesterday. Cite the source capture times and tell me if the notes leave anything unclear.

MCP searches saved memories rather than performing a Timeline OCR search. Its two tools, `memory_search` and `memory_get`, are read-only. A query does not capture a new screen or start organization of queued screenshots.

## Where the screenshots and text are stored

Screenshots, OCR text, and Markdown notes are saved in your local MyClip library. OCR runs on your Mac. AI organization may send captures to your selected Agent's cloud service; connected MCP clients receive retrieved notes and may receive short profile and current-focus summaries when they connect.

Review capture scope, excluded apps, and retention in Settings before leaving MyClip running. Quit the app to stop capture. See [storage and privacy](https://section9-lab.github.io/MyClip/#privacy) for the product overview, or [watch the demo](https://section9-lab.github.io/MyClip/demo/) to see the app's main views.
