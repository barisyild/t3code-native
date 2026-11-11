function startT3McpApp(app, initialContext, hostVersion) {
  let context = initialContext;
  let stopped = false;
  let frameLoaded = false;
  const frame = () => document.getElementById("visual-reply");
  const native = async (method, params = {}) => {
    if (stopped) throw new T3McpApp.McpAppHostRefusal({ message: "The app was closed." });
    try {
      return await window.webkit.messageHandlers.mcpApp.postMessage({ method, params });
    } catch (error) {
      throw new T3McpApp.McpAppHostRefusal({
        message: typeof error === "string" ? error : error?.message || "Request failed.",
      });
    }
  };
  const hostContext = () => ({
    ...context,
    styles: { variables: T3McpApp.mcpAppStyleVariables(context.styles.variables) },
  });
  const host = T3McpApp.makeMcpAppHost({
    app,
    hostVersion,
    post: (message) => frame()?.contentWindow?.postMessage(message, "*"),
    hostContext,
    callTool: (params) => native("callTool", params),
    readResource: (params) => native("readResource", params),
    openLink: (url) => native("openLink", { url }),
    sendMessage: (text) => native("sendMessage", { text }),
    updateModelContext: (params) => native("updateModelContext", params),
    requestDisplayMode: (mode) => native("displayMode", { mode }),
    downloadFile: (files) =>
      native("downloadFile", {
        files: files.map((file) => {
          if (file._tag === "link") return file;
          let text = "";
          for (let offset = 0; offset < file.bytes.length; offset += 8192) {
            text += String.fromCharCode(...file.bytes.subarray(offset, offset + 8192));
          }
          return { _tag: "embedded", name: file.name, base64: btoa(text) };
        }),
      }),
    onRequestTeardown: () => { void native("requestTeardown").catch(() => {}); },
    onSizeChanged: (size) => { void native("size", size).catch(() => {}); },
  });
  const receive = (event) => {
    if (!stopped && event.source !== null && event.source === frame()?.contentWindow) host.receive(event.data);
  };
  window.addEventListener("message", receive);
  document.addEventListener("load", (event) => {
    if (event.target !== frame()) return;
    if (frameLoaded) {
      void native("leftPage").catch(() => {});
      stopped = true;
      host.dispose();
    } else {
      frameLoaded = true;
    }
  }, true);
  globalThis.t3McpApp = {
    update(next) {
      context = next;
      document.documentElement.style.colorScheme = next.theme;
      document.documentElement.style.backgroundColor = next.styles.variables["--background"];
      host.updateHostContext();
    },
    toolCall(call) { host.setToolCall(call); },
    async teardown() {
      await host.teardown();
      stopped = true;
      window.removeEventListener("message", receive);
    },
  };
}
