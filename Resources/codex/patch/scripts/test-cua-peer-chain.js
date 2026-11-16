#!/usr/bin/env node
'use strict';

const { spawn } = require('node:child_process');
const fs = require('node:fs');
const net = require('node:net');
const os = require('node:os');
const path = require('node:path');

const mode = process.argv[2];

if (mode === 'coordinator') {
  const child = spawn(process.execPath, [__filename, 'server'], {
    stdio: 'inherit',
  });
  child.on('exit', (code, signal) => {
    process.exit(code ?? (signal ? 1 : 0));
  });
} else if (mode === 'server') {
  const addon = require(path.resolve(
    process.env.CUA_PEER_ADDON ||
      path.join(
        process.cwd(),
        'Contents/Resources/native/browser-use-peer-authorization.node',
      ),
  ));
  const socketPath = path.join(
    os.tmpdir(),
    `cua-peer-chain-${process.pid}-${Date.now()}.sock`,
  );
  const server = net.createServer((socket) => {
    const result = addon.authorizeSocketPeer(socket._handle.fd, false);
    console.log(JSON.stringify(result));
    socket.destroy();
    server.close();
    fs.rmSync(socketPath, { force: true });
    process.exit(result.authorized === true ? 0 : 1);
  });
  server.listen(socketPath, () => {
    const child = spawn(
      process.execPath,
      [__filename, 'client', socketPath],
      { stdio: 'ignore' },
    );
    child.on('error', (error) => {
      console.error(error);
      process.exit(1);
    });
  });
} else if (mode === 'client') {
  const socket = net.connect(process.argv[3]);
  socket.on('error', () => process.exit(1));
  socket.on('connect', () => {
    setTimeout(() => socket.end(), 50);
  });
} else {
  console.error('usage: test-cua-peer-chain.js coordinator');
  process.exit(2);
}
