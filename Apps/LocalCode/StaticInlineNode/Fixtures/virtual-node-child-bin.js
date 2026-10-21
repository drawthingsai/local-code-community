#!/usr/bin/env node
"use strict";

console.log(
  JSON.stringify({
    argument: process.argv[2],
    environment: process.env.VIRTUAL_NODE_SHELL_VALUE,
  })
);
