import React, { useEffect, useState } from "react";
import { createRoot } from "react-dom/client";
import { CaptureUpdateAction, Excalidraw, exportToBlob } from "@excalidraw/excalidraw";
import "@excalidraw/excalidraw/index.css";
import "./styles.css";

function postToSwift(message) {
  const handler = window.webkit?.messageHandlers?.excalidraw;
  if (handler) {
    handler.postMessage(message);
    return;
  }

  console.log("excalidraw bridge", message);
}

function blobToBase64(blob) {
  return new Promise((resolve, reject) => {
    const reader = new FileReader();
    reader.onloadend = () => {
      const result = typeof reader.result === "string" ? reader.result : "";
      const commaIndex = result.indexOf(",");
      resolve(commaIndex >= 0 ? result.slice(commaIndex + 1) : result);
    };
    reader.onerror = () => reject(reader.error || new Error("Unable to read exported drawing"));
    reader.readAsDataURL(blob);
  });
}

let excalidrawAPI = null;
let latestScene = {
  elements: [],
  appState: { theme: normalizeTheme(window.__openClientExcalidrawTheme), viewBackgroundColor: "#ffffff" },
  files: {},
};
let currentTheme = latestScene.appState.theme;
let setRenderedTheme = null;

function normalizeTheme(theme) {
  return theme === "dark" ? "dark" : "light";
}

function applyDocumentTheme(theme) {
  document.documentElement.dataset.openClientTheme = theme;
  document.documentElement.style.colorScheme = theme;
}

function applyExcalidrawTheme(theme) {
  currentTheme = normalizeTheme(theme);
  window.__openClientExcalidrawTheme = currentTheme;
  applyDocumentTheme(currentTheme);
  setRenderedTheme?.(currentTheme);
  excalidrawAPI?.updateScene?.({
    appState: { theme: currentTheme },
    captureUpdate: CaptureUpdateAction.NEVER,
  });
  return currentTheme;
}

applyDocumentTheme(currentTheme);
window.setExcalidrawTheme = applyExcalidrawTheme;

window.__openClientExcalidrawReady = false;
window.exportExcalidrawAsPng = async () => {
  try {
    const elements = excalidrawAPI?.getSceneElements?.() || latestScene.elements;
    const hasDrawableElements = elements.some((element) => !element.isDeleted);
    if (!hasDrawableElements) {
      postToSwift({ type: "error", code: "empty-scene", message: "Draw something before attaching." });
      return false;
    }

    const appState = excalidrawAPI?.getAppState?.() || latestScene.appState;
    const files = excalidrawAPI?.getFiles?.() || latestScene.files;
    const blob = await exportToBlob({
      elements,
      appState: {
        ...appState,
        exportBackground: true,
        exportWithDarkMode: false,
        viewBackgroundColor: appState.viewBackgroundColor || "#ffffff",
      },
      files,
      mimeType: "image/png",
      exportPadding: 24,
      maxWidthOrHeight: 2048,
    });

    if (!blob || blob.size === 0) {
      postToSwift({ type: "error", code: "export-empty", message: "The exported drawing was empty." });
      return false;
    }

    const base64 = await blobToBase64(blob);
    postToSwift({ type: "exported", mime: "image/png", base64, byteLength: blob.size });
    return true;
  } catch (error) {
    postToSwift({
      type: "error",
      code: "export-failed",
      message: error?.message || "Unable to export drawing.",
    });
    return false;
  }
};

function App() {
  const [theme, setTheme] = useState(currentTheme);

  useEffect(() => {
    setRenderedTheme = setTheme;
    applyExcalidrawTheme(currentTheme);
    return () => {
      if (setRenderedTheme === setTheme) {
        setRenderedTheme = null;
      }
    };
  }, []);

  return (
    <main className="drawing-root" data-theme={theme}>
      <Excalidraw
        theme={theme}
        excalidrawAPI={(api) => {
          excalidrawAPI = api;
          applyExcalidrawTheme(currentTheme);
          window.__openClientExcalidrawReady = true;
          postToSwift({ type: "ready" });
        }}
        onChange={(elements, appState, files) => {
          latestScene = {
            elements: Array.from(elements),
            appState,
            files,
          };
        }}
        initialData={{
          appState: {
            theme,
            viewBackgroundColor: "#ffffff",
          },
        }}
      />
    </main>
  );
}

createRoot(document.getElementById("root")).render(<App />);
