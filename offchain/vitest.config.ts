import { defineConfig } from "vitest/config";

// Source uses NodeNext-style ".js" specifiers on ".ts" files. Alias them back to
// extensionless so Vite resolves to the TypeScript source under test.
export default defineConfig({
  resolve: {
    alias: [{ find: /^(\.{1,2}\/.*)\.js$/, replacement: "$1" }],
  },
  test: {
    include: ["test/**/*.test.ts"],
  },
});
