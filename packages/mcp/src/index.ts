#!/usr/bin/env node

import { serveStdio } from "@modelcontextprotocol/server/stdio";
import { homedir } from "node:os";
import { join, resolve } from "node:path";
import { pathToFileURL } from "node:url";
import { installClientConfig, type SupportedClient } from "./client-config.js";
import { collectDiagnostics, type DiagnosticsDependencies } from "./diagnostics.js";
import { createComputerUseMcpServer, SERVER_VERSION } from "./server.js";

const HELP = `computer-use-mcp ${SERVER_VERSION}

Usage:
  computer-use-mcp          Serve MCP over stdio
  computer-use-mcp setup    Wait boundedly for host readiness after local setup launches it
  computer-use-mcp doctor   Read-only host, bridge, runtime, and toolchain report
  computer-use-mcp configure <claude-desktop|claude-code|cursor|codex> [path]
                            Merge this server into a client configuration
  computer-use-mcp --help   Show this help
  computer-use-mcp --version
`;

type TextWriter = { write(value: string): unknown };

const SUPPORTED_CLIENTS = new Set<SupportedClient>([
  "claude-desktop",
  "claude-code",
  "cursor",
  "codex"
]);

function defaultClientConfigPath(client: SupportedClient): string {
  switch (client) {
    case "claude-desktop":
      return join(homedir(), "Library", "Application Support", "Claude", "claude_desktop_config.json");
    case "claude-code": return resolve(".mcp.json");
    case "cursor": return resolve(".cursor", "mcp.json");
    case "codex": return join(homedir(), ".codex", "config.toml");
  }
}

export type CliOptions = {
  stdout?: TextWriter;
  stderr?: TextWriter;
  diagnostics?: DiagnosticsDependencies;
};

async function doctor(mode: "doctor" | "setup", options: CliOptions): Promise<number> {
  const stdout = options.stdout ?? process.stdout;
  try {
    const result = await collectDiagnostics(mode, options.diagnostics);
    stdout.write(`${JSON.stringify(result.report)}\n`);
    return result.exitCode;
  } catch {
    stdout.write(
      `${JSON.stringify({
        schema_version: 1,
        ok: false,
        mode,
        error_code: "DIAGNOSTICS_FAILED",
        error: "The diagnostic report could not be completed safely.",
        remediation: ["Rebuild the MCP package and rerun doctor."]
      })}\n`
    );
    return 1;
  }
}

async function serve(stderr: TextWriter): Promise<void> {
  const handle = serveStdio(
    context =>
      createComputerUseMcpServer({
        era: context.era,
        onDiagnostic: (message, error) => {
          const detail = error instanceof Error ? `: ${error.message}` : "";
          stderr.write(`[computer-use-mcp] ${message}${detail}\n`);
        }
      }),
    {
      legacy: "serve",
      onerror: error => stderr.write(`[computer-use-mcp] MCP transport error: ${error.message}\n`)
    }
  );

  let closing = false;
  const close = async (): Promise<void> => {
    if (closing) return;
    closing = true;
    await handle.close();
  };
  process.once("SIGINT", () => void close());
  process.once("SIGTERM", () => void close());
}

export async function runCli(
  arguments_: readonly string[] = process.argv.slice(2),
  options: CliOptions = {}
): Promise<number> {
  const stdout = options.stdout ?? process.stdout;
  const stderr = options.stderr ?? process.stderr;
  const command = arguments_[0];
  if (command === "--help" || command === "-h" || command === "help") {
    stdout.write(HELP);
    return 0;
  }
  if (command === "--version" || command === "-V") {
    stdout.write(`${SERVER_VERSION}\n`);
    return 0;
  }
  if (command === "doctor" || command === "setup") return doctor(command, options);
  if (command === "configure") {
    const requested = arguments_[1];
    if (!SUPPORTED_CLIENTS.has(requested as SupportedClient)) {
      stderr.write(`Unsupported or missing client: ${requested ?? ""}\n${HELP}`);
      return 2;
    }
    const client = requested as SupportedClient;
    const entryPath = process.argv[1];
    if (entryPath === undefined) {
      stderr.write("Cannot resolve the computer-use-mcp executable path.\n");
      return 1;
    }
    const path = arguments_[2] ?? defaultClientConfigPath(client);
    try {
      installClientConfig({
        client,
        path,
        entry: { command: process.execPath, args: [resolve(entryPath)] }
      });
      stdout.write(`Configured computer-use-mcp for ${client} in ${resolve(path)}.\n`);
      return 0;
    } catch (error) {
      const message = error instanceof Error ? error.message : "Unknown configuration error";
      stderr.write(`Could not configure ${client}: ${message}\n`);
      return 1;
    }
  }
  if (command !== undefined) {
    stderr.write(`Unknown command: ${command}\n${HELP}`);
    return 2;
  }
  await serve(stderr);
  return 0;
}

const launchedAsProgram =
  process.argv[1] !== undefined && import.meta.url === pathToFileURL(process.argv[1]).href;
if (launchedAsProgram) {
  const exitCode = await runCli();
  if (exitCode !== 0) process.exitCode = exitCode;
}
