//
//  main.swift
//  lda-mcp
//
//  Executable entry point for the LDA MCP server. Constructs the server and
//  runs its stdio JSON-RPC loop.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import LDAMCP

let server = MCPServer()
server.runStdioLoop()
