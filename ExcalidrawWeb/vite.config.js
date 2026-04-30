import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
import { fileURLToPath, URL } from "node:url";

export default defineConfig({
  base: "./",
  define: {
    "process.env.NODE_ENV": JSON.stringify("production"),
  },
  plugins: [react()],
  build: {
    outDir: fileURLToPath(new URL("../Resources/ExcalidrawWeb", import.meta.url)),
    emptyOutDir: true,
    cssCodeSplit: false,
    lib: {
      entry: fileURLToPath(new URL("src/main.jsx", import.meta.url)),
      name: "OpenClientExcalidraw",
      formats: ["iife"],
      fileName: () => "assets/excalidraw.js",
      cssFileName: "assets/excalidraw",
    },
    rollupOptions: {
      output: {
        inlineDynamicImports: true,
      },
    },
  },
});
