'use strict';
const http = require('node:http');

function greeting() {
  return 'hello from tekton';
}

if (require.main === module) {
  http
    .createServer((_req, res) => res.end(greeting() + '\n'))
    .listen(3000);
}

module.exports = { greeting };
