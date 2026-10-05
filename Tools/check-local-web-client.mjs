import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { Script, createContext } from 'node:vm';

const source = readFileSync('Sources/Bloom/System/LocalWebClientScript.swift', 'utf8');
const javascript = source.split('static let javascript = #"""', 2)[1]?.split('"""#', 1)[0];
assert.ok(javascript, 'Browser client JavaScript could not be found');

const script = new Script(javascript, { filename: 'LocalWebClientScript.js' });
let clearedAddress = false;
let exchangedTicket = false;
const context = createContext({
  URLSearchParams,
  document: {
    documentElement: { dataset: { devBrowser: 'false' } },
    getElementById: () => ({ addEventListener() {} })
  },
  sessionStorage: { getItem: () => '', removeItem() {} },
  window: {
    location: { hash: '#connect=one-use-ticket', pathname: '/', search: '' },
    history: {
      replaceState(_state, _title, address) {
        assert.equal(address, '/');
        clearedAddress = true;
      }
    }
  },
  fetch(path, request) {
    assert.equal(path, '/api/connect');
    assert.equal(request.method, 'POST');
    assert.equal(JSON.parse(request.body).ticket, 'one-use-ticket');
    exchangedTicket = true;
    return Promise.reject(new Error('End of connection smoke check'));
  }
});

script.runInContext(context);
await new Promise(resolve => setImmediate(resolve));
assert.ok(clearedAddress, 'The one-use link remained in the address bar');
assert.ok(exchangedTicket, 'The one-use link was not exchanged');

let connectedDev = false;
const devContext = createContext({
  URLSearchParams,
  document: {
    documentElement: { dataset: { devBrowser: 'true' } },
    getElementById: () => ({ addEventListener() {} })
  },
  sessionStorage: { getItem: () => '', removeItem() {} },
  window: {
    location: { hash: '', hostname: '127.0.0.1', pathname: '/', search: '' },
    history: { replaceState() {} }
  },
  fetch(path, request) {
    assert.equal(path, '/api/dev-connect');
    assert.equal(request.method, 'POST');
    connectedDev = true;
    return Promise.reject(new Error('End of development connection smoke check'));
  }
});
script.runInContext(devContext);
await new Promise(resolve => setImmediate(resolve));
assert.ok(connectedDev, 'Bloom Dev did not start its local browser connection');

const productionLogin = { hidden: true, addEventListener() {} };
const productionContext = createContext({
  URLSearchParams,
  document: {
    documentElement: { dataset: { devBrowser: 'false' } },
    getElementById: id => id === 'login' ? productionLogin : { addEventListener() {} }
  },
  sessionStorage: { getItem: () => '', removeItem() {} },
  window: {
    location: { hash: '', hostname: '127.0.0.1', pathname: '/', search: '' },
    history: { replaceState() {} }
  },
  fetch() { throw new Error('The regular app must not auto-connect'); }
});
script.runInContext(productionContext);
assert.equal(productionLogin.hidden, false, 'The regular app skipped its access-code screen');
