import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
import path from "node:path";

// CEF (FiveM's embedded browser) loads files via nui://<resource>/nui/dist/...,
// so all asset URLs must be relative — `base: "./"` keeps the bundle portable
// across servers without baking in an absolute path.
export default defineConfig({
    plugins: [react()],
    base: "./",
    resolve: {
        alias: {
            "@": path.resolve(__dirname, "./src"),
        },
    },
    build: {
        outDir: "dist",
        emptyOutDir: true,
        // Predictable filenames so fxmanifest's `files` glob doesn't have to
        // care about cache-busting hashes.
        rollupOptions: {
            output: {
                entryFileNames: "assets/[name].js",
                chunkFileNames: "assets/[name].js",
                assetFileNames: "assets/[name][extname]",
            },
        },
    },
});
