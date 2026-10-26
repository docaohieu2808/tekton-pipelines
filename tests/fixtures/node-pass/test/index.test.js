'use strict';
const test = require('node:test');
const assert = require('node:assert');
const { greeting } = require('../src/index.js');

test('greeting says hello', () => {
  assert.strictEqual(greeting(), 'hello from tekton');
});
