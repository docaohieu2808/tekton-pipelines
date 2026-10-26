'use strict';
const test = require('node:test');
const assert = require('node:assert');
const { greeting } = require('../src/index.js');

// Deliberately wrong: the pipeline must go red and must not build an image.
test('greeting says goodbye', () => {
  assert.strictEqual(greeting(), 'goodbye from tekton');
});
