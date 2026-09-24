# Design

The visual authority is the user's installed, running MyClip application, not a separately compiled preview host. See REFERENCE.md for measured proportions. Recreate its light macOS window in HTML with system typography, restrained separators, blue selections, compact toolbar buttons and generous document spacing.

Keep a 1600 × 1000 macOS desktop with a 30 px menu bar and an 84 px translucent Dock. Place the 1240 × 820 MyClip window at (180, 66). Its 230 px sidebar remains consistent across pages. Memory adds a 300 px file pane. Backstage uses four vertical Agent rows; Settings pairs explanatory text with grouped controls.

Every page, sheet, task card, chart and Timeline preview is semantic HTML/CSS. Buttons, selects, disclosures, switches, text fields and draggable cards own their actions. There are no bitmap window layers or transparent hotspots. Original artwork and brand icons are assets; private reference captures never enter the asset tree.

The pointer clicks the Dock, shows two finite bounces, and opens the window. Permission switches, Next and Begin align to the HTML control coordinates. One paused GSAP timeline owns all automatic motion. Interacting with the app pauses review playback; manual navigation preserves edits. Selecting a storyboard scene starts from its reproducible fixture.

Codex and Claude remain HTML desktop illustrations with explicitly labeled fictional conversations. Tool results are frozen responses from MyClip MCP against app-data.js. Source buttons expose the original returned Markdown. The player and captions live outside the desktop.
