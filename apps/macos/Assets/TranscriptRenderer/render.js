const artwork = document.querySelector("#artwork");
const unsafeAttributes = ["href", "xlink:href", "src", "srcset"];

function renderArtwork(kind, source, dark, inlineFontSize) {
  const inline = kind === "math" && inlineFontSize > 0;
  document.documentElement.dataset.appearance = dark ? "dark" : "light";
  document.documentElement.dataset.kind = kind;
  artwork.replaceChildren();
  artwork.classList.toggle("inline", inline);
  artwork.style.fontSize = inline ? inlineFontSize + "px" : "";
  artwork.style.transform = "";
  let baseline;
  if (kind === "math") {
    const markup = katex.renderToString(source, {
      displayMode: !inline,
      output: "mathml",
      throwOnError: true,
      trust: false,
      strict: "ignore",
      maxSize: 20,
      maxExpand: 1000,
    });
    const sanitized = DOMPurify.sanitize(markup, {
      USE_PROFILES: { mathMl: true },
      FORBID_TAGS: ["annotation", "annotation-xml", "mglyph"],
      FORBID_ATTR: unsafeAttributes,
      RETURN_DOM_FRAGMENT: true,
    });
    const math = sanitized.querySelector("math");
    if (!math) return null;
    artwork.append(math);
    if (inline) {
      baseline = document.createElement("span");
      baseline.style.cssText = "display:inline-block;width:0;height:0";
      artwork.append(baseline);
    }
  } else if (kind === "mermaid") {
    const { svg } = pele.render(source, {
      links: false,
      images: false,
      autoDirection: false,
      responsive: false,
      fontFamily: "system-ui, sans-serif",
    });
    const sanitized = DOMPurify.sanitize(svg, {
      USE_PROFILES: { svg: true, svgFilters: true },
      FORBID_TAGS: ["a", "image", "foreignObject", "style"],
      FORBID_ATTR: unsafeAttributes,
      RETURN_DOM_FRAGMENT: true,
    });
    const diagram = sanitized.querySelector("svg");
    if (!diagram) return null;
    artwork.append(diagram);
  } else {
    return null;
  }

  const bounds = artwork.getBoundingClientRect();
  const { width, height } = bounds;
  if (!Number.isFinite(width) || !Number.isFinite(height) || width <= 2 || height <= 0) return null;
  const scale = Math.min(1, 1080 / width, 1400 / height);
  const descent = baseline ? Math.max(0, bounds.bottom - baseline.getBoundingClientRect().bottom) * scale : 0;
  if (scale < 1) artwork.style.transform = "scale(" + scale + ")";
  return { width: Math.ceil(width * scale), height: Math.ceil(height * scale), descent };
}
