import React, { useEffect, useRef } from "react";
import { createRoot } from "react-dom/client";
import { Excalidraw, exportToBlob } from "@excalidraw/excalidraw";
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

function App() {
  const excalidrawAPIRef = useRef(null);
  const latestSceneRef = useRef({
    elements: [],
    appState: { viewBackgroundColor: "#ffffff" },
    files: {},
  });

  useEffect(() => {
    window.exportExcalidrawAsPng = async () => {
      try {
        const api = excalidrawAPIRef.current;
        const scene = latestSceneRef.current;
        const elements = api?.getSceneElements?.() || scene.elements;
        const hasDrawableElements = elements.some((element) => !element.isDeleted);
        if (!hasDrawableElements) {
          postToSwift({ type: "error", code: "empty-scene", message: "Draw something before attaching." });
          return false;
        }

        const appState = api?.getAppState?.() || scene.appState;
        const files = api?.getFiles?.() || scene.files;
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

    return () => {
      if (window.exportExcalidrawAsPng) {
        delete window.exportExcalidrawAsPng;
      }
    };
  }, []);

  useEffect(() => {
    requestAnimationFrame(() => postToSwift({ type: "ready" }));
  }, []);

  return (
    <main className="drawing-root">
      <Excalidraw
        excalidrawAPI={(api) => {
          excalidrawAPIRef.current = api;
          postToSwift({ type: "ready" });
        }}
        onChange={(elements, appState, files) => {
          latestSceneRef.current = {
            elements: Array.from(elements),
            appState,
            files,
          };
        }}
        initialData={{
          appState: {
            viewBackgroundColor: "#ffffff",
          },
        }}
      />
    </main>
  );
}

createRoot(document.getElementById("root")).render(<App />);
