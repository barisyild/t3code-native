# T3 Code AppKit

An optional native macOS client for T3 Code. The app, assets, dependencies, and build script
live in this directory. Keep this directory as an additive change when merging upstream
updates. AppKit uses T3 Code's pairing API and orchestration v2 WebSocket protocol, so it
can use the same server as the Electron, web, and mobile clients.

## Build and connect

To add AppKit to a T3 Code source checkout, place this directory at `apps/macos` in
that checkout and build from there.

Use macOS 14 or later and Xcode with Swift 6.2 or later. From this directory, run
`sh build.sh --open` to build and open **T3 Code AppKit**. Run `sh build.sh` to build it
and print the path to the signed bundle. The build uses the Swift dependencies pinned
in `Package.resolved`.

For a local server, install the checkout’s JavaScript dependencies first. The build
bundles the Node.js version pinned by the checkout, verifying its archive before caching
it in `.build`. Use `sh build.sh --client-only` to skip bundling the checkout runtime.
You can also build this directory on its own and pair it with a running environment.
The build packages the pinned Markdown rendering assets for offline use. It verifies
the downloaded archives when the assets are unavailable in the checkout. It bundles
the checkout’s shared math parser when its dependencies are installed. Standalone
builds use the generated parser and license notices under Assets/TranscriptRenderer/MathParser.

On a running T3 environment, use `t3 pair` and paste the pairing link into
**Pair Environment**. **Start Local Server** launches `apps/server` with the
bundled Node.js runtime in a source build. A client-only build can use an installed
`t3` CLI. Launch with `--server-executable /path/to/t3` to choose a specific executable.
It keeps its data in
`~/Library/Application Support/T3 Code AppKit`. To try the client against a
checkout, run `vp run dev --home-dir /tmp/t3code-appkit-dev --no-seed` in the T3 repo and
pair with that environment.

The source launcher loads the AppKit compatibility module for browser zoom and
assistant-quote delivery. It applies the fixes in memory when the corresponding
upstream code matches. To use the same fixes on a separate source host, start
that host with `node --import ./apps/macos/server-compatibility.mjs apps/server/src/bin.ts`
from its checkout.

Use **File → Add Project** to open an existing folder, create a named Git project,
or clone a repository on the connected environment. **Browse on Host** lists that
environment’s folders. When the environment tracks clone progress, you can compose a
draft while cloning and send it once the checkout is ready. Cancel, retry, or remove
the clone from its conversation banner.

To configure T3 Connect, set `T3CODE_RELAY_URL`, `T3CODE_CLERK_PUBLISHABLE_KEY`, and
`T3CODE_CLERK_JWT_TEMPLATE` in the build environment or in this directory's `.env.local`.
The build also reads these public settings from the enclosing T3 checkout when present.
Embedding the settings in a client-only build requires Node.js 22 or later.

In **Settings → T3 Connect**, sign in and turn on the tunnel for the local environment
started by AppKit. The same panel shows the tunnel’s reachability and lets you choose
whether to publish agent activity or hold incoming webhooks while the host is offline.

In **Settings → Sharing & Access**, create scoped pairing links for the connected
environment and review or revoke its client sessions. Copy newly issued links from
the panel while it stays open.

Turn on **Guest links** there for an environment with a running T3 Connect tunnel.
Use **File → Share with Guest** in a conversation to copy a one-time link that opens
in the guest’s browser. Their proposed messages appear in the conversation with
**Send to Agent** and **Dismiss**. Click the guest status above the prompt to end
the share or replace its link.

In **Settings → Providers**, configure Codex or Claude to use an existing CLI on the
connected environment. Add a **Codex · T3 managed** provider to install its runtime
and sign in from AppKit. Managing providers requires Provider management access.

Open **File → Project Settings** or use a project’s sidebar menu to rename or pin it
and set its default model, workspace, and auto-pull. To bring back an archived project,
select it in **Settings → Projects** and choose **Restore Project**.
When the project and environment leave the workspace mode unset, a new thread uses
`defaultThreadEnvMode` from the project’s `t3.json`. A checkout chosen in the composer
takes priority for that draft.

Open **Project Actions** in a project's settings to add, edit, or import commands
from `t3.json`. Run a saved action from the conversation’s actions menu or Quick Open.
Its output appears in a separate terminal session for the thread’s current checkout.

Select output in the terminal and choose **Add to Chat** from its context menu.
Click the selection in the draft or sent message to read or copy the numbered
output. Remove it from the draft before sending if it is no longer relevant.

The Browser panel streams Chromium from the connected environment. Loopback addresses in
its address bar reach that environment. Use **⌘T** for a tab in your default profile or
the menu beside **+** for a named profile or **Incognito**. **Settings → Browser** manages
profiles, the search engine, and display defaults for new tabs. The display menu at
the bottom of the Browser panel changes the current tab. Clearing or removing a
profile clears its data on the connected environment and closes its tabs there.

Use the record button in the Browser panel to capture the current tab. Recording
continues on that tab while you work elsewhere in the app. To finish several
captures together, choose **View → Stop All Browser Recordings**. Stopping saves
an MP4 in the app's Browser Recordings folder. Open **View → Latest Browser Recording** to
play it, save a copy, or attach it to the conversation's draft. Set the frame rate
and optional shortcut and click overlays in **Settings → Browser**.

The menu next to the Browser record button captures the current viewport as PNG.
Use **Annotate Browser Region** to select an area of the captured frame and add a
note and cropped image to the conversation's draft.

**Scheduled** shows the environment's tasks.
The **Repository** menu opens source control for the current checkout. **Pull Requests**
uses the connected environment's source control account.

In a conversation, open **View → Toggle Device** or press **⌘⌥7** to see the devices
available on the connected environment. Select a simulator or emulator and open it,
then click its screen to send touch and keyboard input. Use **Device Actions** for
host tools and to disconnect or power off a simulator. Closing the panel stops the
preview and keeps the device session available for that conversation.
Use **Settings → Devices** to add SSH or EAS simulator hosts for the connected
environment, or enable **Simlock Hosts** and add a gateway. Test SSH from the
environment and check the Expo or Simlock account in the host editor. Device host
settings require Settings write access.

Open **Usage** from the rail or with **⌘⌥6**. Cost and token history require Diagnostics
access to the connected environment. **Limits** shows the provider balances it reports.
In **Settings → Usage**, add a CLIProxyAPI hub to include its account limits.
The environment stores the management key or resolves it from a configured secret provider.
When an account reports reset credits, **Use Reset** in **Limits** lets you redeem one.

Preview sent images and files directly from the conversation, then use **Save As…**
to download a copy to this Mac.

Open a file from **Files** to edit it. Changes save automatically with Filesystem
write access. Use **⌘S** to save immediately or **Save a Copy…** to keep the complete
file on this Mac. Supported media and documents open in Quick Look. If refreshing
finds a different server version while you have edits, choose which version to keep.
Click a file link or a changed file in a conversation to open it in **Files**. Links
with line and column numbers jump to that position. Host files outside the active
workspace open read-only.

Paste an image or drop files into the prompt, a queued message edit, or an agent
question that accepts attachments. Question attachments stay with their own answer
as you move through the form and upload when you send the answers.

In **Settings → Voice**, choose an installed speech model and enable dictation
for the connected environment. The microphone button or **⌘⇧D** starts a recording.
Click **Finish Dictation** to insert the transcript into the draft. Press **Return**
while recording to finish and send, or use **Cancel Dictation** to discard it.
Under **Transcribe with**, you can choose OpenAI, Grok Voice Transcribe, or
an OpenRouter model using a key saved on the connected environment.
**Clean up transcripts** separately allows the environment’s text generation
model to receive the transcript and nearby draft text. **Cleanup Settings**
sets its model, instructions, and spoken correction cue.

Queued follow-ups appear above the composer. Use **⌥↑** from the start of a draft to edit
the latest queued message, or **⌘⇧↩** to send the next queued message when available.
After stopping a turn, use **Resume Queue** to continue the held messages in order.

Click the model name to choose a provider, model family and version. Effort and
speed are in the same menu. **/model** also opens it.

Type **/** to find provider commands or **$** to find skills for the selected model
and workspace. Use the arrow keys to navigate and Return or Tab to accept.
**/clear** prepares the next message to start a fresh session on supported servers.

Send **/goal <objective>** with Codex or Claude to set a goal. The goal above the
prompt shows its progress and lets you clear it or pause and resume a Codex goal.

Open **Side Chats** in the conversation toolbar or send **/side** with an optional
prompt. **Bring Back** adds a finished side chat’s context to your next message in
the main conversation. Reopen a finished side chat from the same toolbar menu.

Open **Related Conversations** from the View menu to find the source of a fork and
open its forks, side chats, and subagents. **Merge Back** adds a finished fork’s
context to the source conversation’s next message. **Subagent Work** shows the
child transcript when the provider supplies one.

Open **Search** or press **⌘K** to find conversations and messages on the connected
environment. Choose a message result to jump to it. Message search covers active
conversations. **Find Files** and **Find in Files** search the selected checkout,
and a content result opens its file at the matching line.

In **Settings → Notifications**, choose how AppKit alerts you when a conversation
on the connected environment finishes or needs attention. The Dock badge counts
conversations with new alerts while AppKit is in the background.

Use **⌘F** in a thread to find messages and plans, including older history. Press
**Return** or **Shift+Return** to cycle through matches. Use **⌘⇧F** to filter the
thread list. **Fork from This Response** starts a new thread from a completed reply.
Use **Edit from here** beside a user message to rewind a stopped conversation and
return its prompt and attachments to your draft. The confirmation lets you restore
files too when the thread uses an isolated worktree.

Select text in an assistant response and choose **Cite in Composer** from the
context menu. Click the inline quote to add a comment, remove it, or go back to
the source. Sent quotes keep the excerpt and comment even if the source changes.

Markdown replies display Mermaid diagrams and LaTeX equations, including inline
formulas such as `$x^2$` and display formulas such as `\[x^2\]`. Double-click a diagram
to enlarge it. Use the context menu to copy the LaTeX or Mermaid source. The
LaTeX display setting is in **Settings → Appearance**.

Ask an agent for a chart or other visual reply to see the published page inside
the conversation. The page toolbar adjusts zoom or opens an expanded view.

MCP apps appear at their tool call in the conversation. Tool calls that can make
changes and messages from the app ask for your approval. If an app’s source
conversation has stopped, send a message there to use the app again.

Export a plan as Markdown to this Mac or save it to the thread’s active checkout on
the connected environment. Saving to the environment requires Filesystem write access.
