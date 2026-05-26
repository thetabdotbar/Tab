#!/usr/bin/env node
// Entrypoint for the stdio MCP server. Used by Claude Desktop / Cursor / etc.
// Register in claude_desktop_config.json like:
//
//   {
//     "mcpServers": {
//       "tab": {
//         "command": "npx",
//         "args": ["-y", "@tabdotbar/agent-sdk"],
//         "env": { "TAB_API_KEY": "sk_live_..." }
//       }
//     }
//   }

import { runStdioServer } from "./mcp.js";

await runStdioServer();
