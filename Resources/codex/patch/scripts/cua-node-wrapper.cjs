#!/usr/bin/env node
'use strict';

const { spawn } = require('node:child_process');

const [target, ...args] = process.argv.slice(2);
if (!target) {
  console.error('cua-node-wrapper: missing node_repl executable');
  process.exit(2);
}

const child = spawn(target, args, {
  stdio: 'inherit',
  env: process.env,
});

let forwardingSignal = false;
for (const signal of ['SIGINT', 'SIGTERM', 'SIGHUP']) {
  process.on(signal, () => {
    forwardingSignal = true;
    if (child.exitCode == null && child.signalCode == null) {
      child.kill(signal);
    }
  });
}

child.on('error', (error) => {
  console.error(`cua-node-wrapper: failed to start node_repl: ${error.message}`);
  process.exitCode = 1;
});

child.on('exit', (code, signal) => {
  if (code != null) {
    process.exit(code);
  }
  if (forwardingSignal) {
    process.exit(0);
  }
  process.kill(process.pid, signal || 'SIGTERM');
});
