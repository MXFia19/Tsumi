import Foundation

/// JavaScript installed in every module context before the module runs. It provides what Sora
/// modules expect from their host (JavaScriptCore has no web APIs): `fetchv2` (both call styles of
/// `buildFetchv2Polyfill` in common/modules/extension.js, plus the Sora app's `redirect`/`encoding`
/// arguments), a standard-ish `fetch`, `console`, timers, `atob`/`btoa`, TextEncoder/TextDecoder,
/// URL/URLSearchParams and AbortController.
///
/// The Svelte app runs modules inside the page (`new AsyncFunction` in executeExtensionFunction), so
/// they also see the browser globals. The ones that make sense without a page are shimmed here:
/// `window` / `self`, `crypto` (getRandomValues, randomUUID, subtle.digest), Headers, Request,
/// Response, Blob, File, FormData (multipart bodies), DOMParser and a `document` (HTML / XML parser,
/// CSS selectors, textContent / innerHTML, no layout), XMLSerializer, Node, navigator, performance,
/// structuredClone and in-memory localStorage / sessionStorage (one call = one fresh context).
/// Not available: XMLHttpRequest, WebSocket, Worker, crypto.subtle beyond digest, layout APIs.
///
/// Native hooks: __tsumiLog, __tsumiSchedule, __tsumiFetch, __tsumiText, __tsumiBytes, __tsumiDone,
/// __tsumiRandom, __tsumiDigest (see SoraBridge).
enum SoraPrelude {
  static let source = #"""
(function (g) {
  'use strict';
  var hasOwn = Object.prototype.hasOwnProperty;
  var USER_AGENT = \#(ExtensionJSON.quote(SoraNetwork.defaultUserAgent));

  /* ---------- window / self (the page globals of the Svelte app) ---------- */
  if (typeof g.window === 'undefined') g.window = g;
  if (typeof g.self === 'undefined') g.self = g;

  var describe = function (e) {
    if (e === undefined || e === null) return 'Unknown error';
    if (typeof e === 'string') return e;
    if (typeof e === 'object' && e.message) return String(e.message);
    try { return String(e); } catch (x) { return 'Unknown error'; }
  };

  /* ---------- result channel ---------- */
  g.__tsumiResolve = function (r) {
    if (typeof r === 'string') { __tsumiDone(true, r, true); return; }
    var s = null;
    try { s = JSON.stringify(r); } catch (e) { s = null; }
    __tsumiDone(true, (s === undefined || s === null) ? 'null' : s, false);
  };
  g.__tsumiReject = function (e) { __tsumiDone(false, describe(e), false); };

  /* ---------- console ---------- */
  var format = function (args) {
    var parts = [];
    for (var i = 0; i < args.length; i++) {
      var a = args[i];
      if (typeof a === 'string') parts.push(a);
      else if (a instanceof Error) parts.push(String(a.name || 'Error') + ': ' + String(a.message));
      else {
        try { var s = JSON.stringify(a); parts.push(s === undefined ? String(a) : s); } catch (x) { parts.push(String(a)); }
      }
    }
    return parts.join(' ');
  };
  var logger = function (level) { return function () { __tsumiLog(level, format(arguments)); }; };
  g.console = { log: logger('log'), info: logger('info'), warn: logger('warn'), error: logger('error'), debug: logger('debug'), trace: logger('trace') };
  g.log = logger('log');

  /* ---------- timers ---------- */
  var timers = {};
  var timerSeq = 0;
  var addTimer = function (fn, ms, args, repeat) {
    var id = ++timerSeq;
    var delay = Number(ms) || 0;
    if (delay < 0) delay = 0;
    timers[id] = { fn: fn, args: args, repeat: repeat, delay: delay };
    __tsumiSchedule(id, delay);
    return id;
  };
  g.setTimeout = function (fn, ms) { return addTimer(fn, ms, Array.prototype.slice.call(arguments, 2), false); };
  g.setInterval = function (fn, ms) { return addTimer(fn, ms, Array.prototype.slice.call(arguments, 2), true); };
  g.setImmediate = function (fn) { return addTimer(fn, 0, Array.prototype.slice.call(arguments, 1), false); };
  g.clearTimeout = function (id) { if (id !== undefined && id !== null) delete timers[id]; };
  g.clearInterval = g.clearTimeout;
  g.clearImmediate = g.clearTimeout;
  g.queueMicrotask = function (fn) { Promise.resolve().then(fn); };
  g.__tsumiFireTimer = function (id) {
    var t = timers[id];
    if (!t) return;
    if (t.repeat) __tsumiSchedule(id, Math.max(t.delay, 4)); else delete timers[id];
    if (typeof t.fn === 'function') {
      try { t.fn.apply(g, t.args); } catch (e) { __tsumiLog('error', 'Timer callback failed: ' + describe(e)); }
    }
  };

  /* ---------- base64 / bytes ---------- */
  var B64 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
  var btoaImpl = function (input) {
    var str = String(input);
    var out = '';
    for (var i = 0; i < str.length; i += 3) {
      var hasB = i + 1 < str.length;
      var hasC = i + 2 < str.length;
      var a = str.charCodeAt(i);
      var b = hasB ? str.charCodeAt(i + 1) : 0;
      var c = hasC ? str.charCodeAt(i + 2) : 0;
      if (a > 255 || b > 255 || c > 255) throw new Error("Failed to execute 'btoa': The string to be encoded contains characters outside of the Latin1 range.");
      var n = (a << 16) | (b << 8) | c;
      out += B64.charAt((n >> 18) & 63) + B64.charAt((n >> 12) & 63) +
        (hasB ? B64.charAt((n >> 6) & 63) : '=') + (hasC ? B64.charAt(n & 63) : '=');
    }
    return out;
  };
  var atobImpl = function (input) {
    var str = String(input).replace(/[\t\n\f\r ]+/g, '').replace(/-/g, '+').replace(/_/g, '/').replace(/=+$/, '');
    var out = '';
    var buffer = 0;
    var bits = 0;
    for (var i = 0; i < str.length; i++) {
      var v = B64.indexOf(str.charAt(i));
      if (v < 0) throw new Error("Failed to execute 'atob': The string to be decoded is not correctly encoded.");
      buffer = ((buffer << 6) | v) & 0xFFFFFF;
      bits += 6;
      if (bits >= 8) {
        bits -= 8;
        out += String.fromCharCode((buffer >> bits) & 0xFF);
      }
    }
    return out;
  };
  if (typeof g.btoa !== 'function') g.btoa = btoaImpl;
  if (typeof g.atob !== 'function') g.atob = atobImpl;

  var bytesToBinary = function (bytes) {
    var out = '';
    for (var i = 0; i < bytes.length; i += 0x8000) {
      out += String.fromCharCode.apply(null, Array.prototype.slice.call(bytes.subarray(i, i + 0x8000)));
    }
    return out;
  };
  var binaryToBytes = function (bin) {
    var arr = new Uint8Array(bin.length);
    for (var i = 0; i < bin.length; i++) arr[i] = bin.charCodeAt(i) & 0xFF;
    return arr;
  };
  var utf8Encode = function (str) {
    var out = [];
    for (var i = 0; i < str.length; i++) {
      var c = str.charCodeAt(i);
      if (c >= 0xD800 && c <= 0xDBFF && i + 1 < str.length) {
        var d = str.charCodeAt(i + 1);
        if (d >= 0xDC00 && d <= 0xDFFF) { c = 0x10000 + ((c - 0xD800) << 10) + (d - 0xDC00); i++; } else { c = 0xFFFD; }
      } else if (c >= 0xD800 && c <= 0xDFFF) {
        c = 0xFFFD;
      }
      if (c < 0x80) out.push(c);
      else if (c < 0x800) out.push(0xC0 | (c >> 6), 0x80 | (c & 63));
      else if (c < 0x10000) out.push(0xE0 | (c >> 12), 0x80 | ((c >> 6) & 63), 0x80 | (c & 63));
      else out.push(0xF0 | (c >> 18), 0x80 | ((c >> 12) & 63), 0x80 | ((c >> 6) & 63), 0x80 | (c & 63));
    }
    return new Uint8Array(out);
  };
  var utf8Decode = function (bytes) {
    var out = '';
    var i = 0;
    while (i < bytes.length) {
      var b = bytes[i++];
      var cp;
      if (b < 0x80) cp = b;
      else if (b >= 0xC0 && b < 0xE0 && i < bytes.length) cp = ((b & 31) << 6) | (bytes[i++] & 63);
      else if (b >= 0xE0 && b < 0xF0 && i + 1 < bytes.length) { cp = ((b & 15) << 12) | ((bytes[i] & 63) << 6) | (bytes[i + 1] & 63); i += 2; }
      else if (b >= 0xF0 && b < 0xF8 && i + 2 < bytes.length) { cp = ((b & 7) << 18) | ((bytes[i] & 63) << 12) | ((bytes[i + 1] & 63) << 6) | (bytes[i + 2] & 63); i += 3; }
      else cp = 0xFFFD;
      if (cp > 0xFFFF) { cp -= 0x10000; out += String.fromCharCode(0xD800 + (cp >> 10), 0xDC00 + (cp & 1023)); }
      else out += String.fromCharCode(cp);
    }
    return out;
  };
  var toBytes = function (input) {
    if (input instanceof Uint8Array) return input;
    if (input instanceof ArrayBuffer) return new Uint8Array(input);
    if (ArrayBuffer.isView(input)) return new Uint8Array(input.buffer, input.byteOffset, input.byteLength);
    if (Array.isArray(input)) return new Uint8Array(input);
    return utf8Encode(String(input));
  };

  if (typeof g.TextEncoder !== 'function') {
    g.TextEncoder = function TextEncoder() { this.encoding = 'utf-8'; };
    g.TextEncoder.prototype.encode = function (s) { return utf8Encode(String(s === undefined ? '' : s)); };
  }
  if (typeof g.TextDecoder !== 'function') {
    g.TextDecoder = function TextDecoder(label) { this.encoding = String(label || 'utf-8').toLowerCase(); };
    g.TextDecoder.prototype.decode = function (input) {
      if (input === undefined || input === null) return '';
      var bytes = toBytes(input);
      var enc = this.encoding;
      if (enc === 'latin1' || enc === 'iso-8859-1' || enc === 'ascii' || enc === 'windows-1252' || enc === 'us-ascii') return bytesToBinary(bytes);
      return utf8Decode(bytes);
    };
  }

  /* ---------- URLSearchParams / URL ---------- */
  if (typeof g.URLSearchParams !== 'function') {
    var decodeParam = function (s) { try { return decodeURIComponent(String(s).replace(/\+/g, ' ')); } catch (e) { return String(s); } };
    var encodeParam = function (s) { return encodeURIComponent(String(s)).replace(/%20/g, '+'); };
    var USP = function URLSearchParams(init) {
      this._list = [];
      this._onChange = null;
      if (init === undefined || init === null) return;
      var list = this._list;
      if (typeof init === 'string') {
        var s = init.charAt(0) === '?' ? init.slice(1) : init;
        if (s) {
          s.split('&').forEach(function (pair) {
            if (!pair) return;
            var idx = pair.indexOf('=');
            list.push([decodeParam(idx >= 0 ? pair.slice(0, idx) : pair), decodeParam(idx >= 0 ? pair.slice(idx + 1) : '')]);
          });
        }
      } else if (init instanceof USP) {
        init._list.forEach(function (p) { list.push([p[0], p[1]]); });
      } else if (Array.isArray(init)) {
        init.forEach(function (p) { list.push([String(p[0]), String(p[1])]); });
      } else if (typeof init === 'object') {
        for (var k in init) { if (hasOwn.call(init, k)) list.push([k, String(init[k])]); }
      }
    };
    var changed = function (params) { if (typeof params._onChange === 'function') params._onChange(); };
    USP.prototype.append = function (k, v) { this._list.push([String(k), String(v)]); changed(this); };
    USP.prototype.set = function (k, v) {
      k = String(k);
      var found = false;
      this._list = this._list.filter(function (p) {
        if (p[0] !== k) return true;
        if (found) return false;
        found = true;
        p[1] = String(v);
        return true;
      });
      if (!found) this._list.push([k, String(v)]);
      changed(this);
    };
    USP.prototype.get = function (k) {
      k = String(k);
      for (var i = 0; i < this._list.length; i++) { if (this._list[i][0] === k) return this._list[i][1]; }
      return null;
    };
    USP.prototype.getAll = function (k) { k = String(k); return this._list.filter(function (p) { return p[0] === k; }).map(function (p) { return p[1]; }); };
    USP.prototype.has = function (k) { return this.get(k) !== null; };
    USP.prototype['delete'] = function (k) { k = String(k); this._list = this._list.filter(function (p) { return p[0] !== k; }); changed(this); };
    USP.prototype.forEach = function (cb, thisArg) { var self = this; this._list.slice().forEach(function (p) { cb.call(thisArg, p[1], p[0], self); }); };
    USP.prototype.keys = function () { return this._list.map(function (p) { return p[0]; })[Symbol.iterator](); };
    USP.prototype.values = function () { return this._list.map(function (p) { return p[1]; })[Symbol.iterator](); };
    USP.prototype.entries = function () { return this._list.map(function (p) { return [p[0], p[1]]; })[Symbol.iterator](); };
    USP.prototype[Symbol.iterator] = USP.prototype.entries;
    USP.prototype.toString = function () { return this._list.map(function (p) { return encodeParam(p[0]) + '=' + encodeParam(p[1]); }).join('&'); };
    g.URLSearchParams = USP;
  }

  if (typeof g.URL !== 'function') {
    var URL_RE = /^([a-zA-Z][a-zA-Z0-9+.\-]*:)?(?:\/\/(?:([^:@\/?#]*)(?::([^@\/?#]*))?@)?([^:\/?#]*)(?::(\d*))?)?([^?#]*)(\?[^#]*)?(#.*)?$/;
    var removeDots = function (path) {
      var segs = path.split('/');
      var out = [];
      for (var i = 0; i < segs.length; i++) {
        var s = segs[i];
        if (s === '..') { if (out.length > 1) out.pop(); }
        else if (s !== '.') out.push(s);
      }
      var last = segs[segs.length - 1];
      if (last === '.' || last === '..') out.push('');
      var joined = out.join('/');
      return joined.charAt(0) === '/' ? joined : '/' + joined;
    };
    var URLImpl;
    var resolveURL = function (input, base) {
      if (/^[a-zA-Z][a-zA-Z0-9+.\-]*:/.test(input)) return input;
      if (base === undefined || base === null) throw new TypeError('Invalid URL: ' + input);
      var b = new URLImpl(String(base));
      if (input.indexOf('//') === 0) return b.protocol + input;
      if (input.charAt(0) === '/') return b.origin + input;
      if (input.charAt(0) === '?') return b.origin + b.pathname + input;
      if (input.charAt(0) === '#') return b.origin + b.pathname + b.search + input;
      if (input === '') return b.origin + b.pathname + b.search;
      return b.origin + b.pathname.slice(0, b.pathname.lastIndexOf('/') + 1) + input;
    };
    URLImpl = function URL(input, base) {
      var source = String(input).trim();
      var href = resolveURL(source, base);
      var m = URL_RE.exec(href);
      if (!m || !m[1]) throw new TypeError('Invalid URL: ' + source);
      this.protocol = m[1].toLowerCase();
      this.username = m[2] || '';
      this.password = m[3] || '';
      this.hostname = (m[4] || '').toLowerCase();
      this.port = m[5] || '';
      var special = /^(https?|wss?|ftp):$/.test(this.protocol);
      if (special && !this.hostname) throw new TypeError('Invalid URL: ' + source);
      var path = m[6] || '';
      if (special) path = removeDots(path || '/');
      if ((this.protocol === 'http:' && this.port === '80') || (this.protocol === 'https:' && this.port === '443')) this.port = '';
      this.pathname = path;
      this.search = (m[7] && m[7] !== '?') ? m[7] : '';
      this.hash = (m[8] && m[8] !== '#') ? m[8] : '';
      var self = this;
      this.searchParams = new g.URLSearchParams(this.search);
      this.searchParams._onChange = function () { var q = self.searchParams.toString(); self.search = q ? '?' + q : ''; };
    };
    Object.defineProperty(URLImpl.prototype, 'host', { get: function () { return this.hostname + (this.port ? ':' + this.port : ''); } });
    Object.defineProperty(URLImpl.prototype, 'origin', { get: function () { return this.protocol + '//' + this.host; } });
    Object.defineProperty(URLImpl.prototype, 'href', {
      get: function () {
        var auth = this.username ? this.username + (this.password ? ':' + this.password : '') + '@' : '';
        return this.protocol + '//' + auth + this.host + this.pathname + this.search + this.hash;
      }
    });
    URLImpl.prototype.toString = function () { return this.href; };
    URLImpl.prototype.toJSON = function () { return this.href; };
    g.URL = URLImpl;
  }

  if (typeof g.AbortController !== 'function') {
    g.AbortController = function AbortController() {
      this.signal = { aborted: false, reason: undefined, onabort: null, addEventListener: function () {}, removeEventListener: function () {} };
    };
    g.AbortController.prototype.abort = function (reason) {
      this.signal.aborted = true;
      this.signal.reason = reason;
      if (typeof this.signal.onabort === 'function') { try { this.signal.onabort(); } catch (e) {} }
    };
  }

  /* ---------- crypto ---------- */
  var randomBytes = function (count) {
    var n = Math.max(0, Math.floor(Number(count) || 0));
    if (typeof __tsumiRandom === 'function') {
      var native = binaryToBytes(atobImpl(__tsumiRandom(n)));
      if (native.length === n) return native;
    }
    var out = new Uint8Array(n);
    for (var i = 0; i < n; i++) out[i] = Math.floor(Math.random() * 256);
    return out;
  };
  if (!g.crypto || typeof g.crypto.getRandomValues !== 'function') {
    var subtle = {
      digest: function (algorithm, data) {
        return new Promise(function (resolve, reject) {
          var name = String((algorithm && typeof algorithm === 'object') ? algorithm.name : algorithm).toUpperCase().replace(/-/g, '');
          var out = typeof __tsumiDigest === 'function' ? __tsumiDigest(name, btoaImpl(bytesToBinary(toBytes(data)))) : '';
          if (!out) { reject(new Error('NotSupportedError: Unrecognized algorithm name')); return; }
          resolve(binaryToBytes(atobImpl(out)).buffer);
        });
      }
    };
    ['encrypt', 'decrypt', 'sign', 'verify', 'importKey', 'exportKey', 'generateKey', 'deriveKey', 'deriveBits', 'wrapKey', 'unwrapKey'].forEach(function (name) {
      subtle[name] = function () { return Promise.reject(new Error('crypto.subtle.' + name + ' is not available to extensions on iOS')); };
    });
    g.crypto = {
      subtle: subtle,
      getRandomValues: function (array) {
        if (!ArrayBuffer.isView(array) || array instanceof DataView || array instanceof Float32Array || array instanceof Float64Array) {
          throw new TypeError("Failed to execute 'getRandomValues' on 'Crypto': The provided ArrayBufferView is not an integer array type.");
        }
        if (array.byteLength > 65536) {
          throw new Error("Failed to execute 'getRandomValues' on 'Crypto': The ArrayBufferView's byte length (" + array.byteLength + ") exceeds the number of bytes of entropy available via this API (65536).");
        }
        new Uint8Array(array.buffer, array.byteOffset, array.byteLength).set(randomBytes(array.byteLength));
        return array;
      },
      randomUUID: function () {
        var b = randomBytes(16);
        b[6] = (b[6] & 0x0f) | 0x40;
        b[8] = (b[8] & 0x3f) | 0x80;
        var hex = '';
        for (var i = 0; i < 16; i++) {
          hex += (b[i] + 0x100).toString(16).slice(1);
          if (i === 3 || i === 5 || i === 7 || i === 9) hex += '-';
        }
        return hex;
      }
    };
  }

  /* ---------- Blob / File / FormData ---------- */
  var concatBytes = function (chunks) {
    var total = 0;
    var i;
    for (i = 0; i < chunks.length; i++) total += chunks[i].length;
    var out = new Uint8Array(total);
    var offset = 0;
    for (i = 0; i < chunks.length; i++) { out.set(chunks[i], offset); offset += chunks[i].length; }
    return out;
  };
  var copyBuffer = function (bytes) { return bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength); };

  var BlobImpl = g.Blob;
  if (typeof BlobImpl !== 'function') {
    BlobImpl = function Blob(parts, options) {
      var chunks = [];
      var list = parts || [];
      for (var i = 0; i < list.length; i++) {
        var part = list[i];
        if (part instanceof BlobImpl) chunks.push(part._bytes);
        else if (part instanceof ArrayBuffer || ArrayBuffer.isView(part)) chunks.push(new Uint8Array(toBytes(part)));
        else chunks.push(utf8Encode(String(part)));
      }
      this._bytes = concatBytes(chunks);
      this.size = this._bytes.length;
      this.type = options && options.type ? String(options.type).toLowerCase() : '';
    };
    BlobImpl.prototype.arrayBuffer = function () { return Promise.resolve(copyBuffer(this._bytes)); };
    BlobImpl.prototype.text = function () { return Promise.resolve(utf8Decode(this._bytes)); };
    BlobImpl.prototype.bytes = function () { return Promise.resolve(new Uint8Array(this._bytes)); };
    BlobImpl.prototype.slice = function (start, end, type) {
      var part = this._bytes.slice(start === undefined ? 0 : start, end === undefined ? this._bytes.length : end);
      return new BlobImpl([part], { type: type === undefined ? '' : type });
    };
    g.Blob = BlobImpl;
  }
  if (typeof g.File !== 'function') {
    var FileImpl = function File(parts, name, options) {
      BlobImpl.call(this, parts, options);
      this.name = String(name);
      this.lastModified = options && options.lastModified !== undefined ? Number(options.lastModified) : Date.now();
    };
    FileImpl.prototype = Object.create(BlobImpl.prototype);
    FileImpl.prototype.constructor = FileImpl;
    g.File = FileImpl;
  }

  var FormDataImpl = g.FormData;
  if (typeof FormDataImpl !== 'function') {
    FormDataImpl = function FormData() { this._list = []; };
    var formEntry = function (name, value, filename) {
      if (value instanceof BlobImpl) {
        var fileName = filename !== undefined ? String(filename) : (value.name !== undefined ? String(value.name) : 'blob');
        var file = (value instanceof g.File && filename === undefined) ? value : new g.File([value], fileName, { type: value.type });
        return [String(name), file];
      }
      return [String(name), String(value)];
    };
    FormDataImpl.prototype.append = function (name, value, filename) { this._list.push(formEntry(name, value, filename)); };
    FormDataImpl.prototype.set = function (name, value, filename) {
      var entry = formEntry(name, value, filename);
      var found = false;
      this._list = this._list.filter(function (p) {
        if (p[0] !== entry[0]) return true;
        if (found) return false;
        found = true;
        p[1] = entry[1];
        return true;
      });
      if (!found) this._list.push(entry);
    };
    FormDataImpl.prototype.get = function (name) {
      name = String(name);
      for (var i = 0; i < this._list.length; i++) { if (this._list[i][0] === name) return this._list[i][1]; }
      return null;
    };
    FormDataImpl.prototype.getAll = function (name) { name = String(name); return this._list.filter(function (p) { return p[0] === name; }).map(function (p) { return p[1]; }); };
    FormDataImpl.prototype.has = function (name) { return this.get(name) !== null; };
    FormDataImpl.prototype['delete'] = function (name) { name = String(name); this._list = this._list.filter(function (p) { return p[0] !== name; }); };
    FormDataImpl.prototype.forEach = function (cb, thisArg) { var self = this; this._list.slice().forEach(function (p) { cb.call(thisArg, p[1], p[0], self); }); };
    FormDataImpl.prototype.entries = function () { return this._list.map(function (p) { return [p[0], p[1]]; })[Symbol.iterator](); };
    FormDataImpl.prototype.keys = function () { return this._list.map(function (p) { return p[0]; })[Symbol.iterator](); };
    FormDataImpl.prototype.values = function () { return this._list.map(function (p) { return p[1]; })[Symbol.iterator](); };
    FormDataImpl.prototype[Symbol.iterator] = FormDataImpl.prototype.entries;
    g.FormData = FormDataImpl;
  }

  /* multipart/form-data body of a FormData (what the browser sends). */
  var multipart = function (form) {
    var boundary = '----TsumiFormBoundary' + Math.random().toString(16).slice(2) + Date.now().toString(16);
    var escapeName = function (s) { return String(s).replace(/\r/g, '%0D').replace(/\n/g, '%0A').replace(/"/g, '%22'); };
    var chunks = [];
    var list = form._list || [];
    for (var i = 0; i < list.length; i++) {
      var name = list[i][0];
      var value = list[i][1];
      var head = '--' + boundary + '\r\nContent-Disposition: form-data; name="' + escapeName(name) + '"';
      if (value instanceof BlobImpl) {
        head += '; filename="' + escapeName(value.name !== undefined ? value.name : 'blob') + '"\r\nContent-Type: ' + (value.type || 'application/octet-stream') + '\r\n\r\n';
        chunks.push(utf8Encode(head), value._bytes, utf8Encode('\r\n'));
      } else {
        chunks.push(utf8Encode(head + '\r\n\r\n' + String(value).replace(/\r?\n|\r/g, '\r\n') + '\r\n'));
      }
    }
    chunks.push(utf8Encode('--' + boundary + '--\r\n'));
    return { bytes: concatBytes(chunks), type: 'multipart/form-data; boundary=' + boundary };
  };

  /* Body of new Response(body) / new Request(url, { body }): bytes + implied content type. */
  var bodyInit = function (body) {
    if (body === undefined || body === null) return { bytes: new Uint8Array(0), type: null };
    if (typeof body === 'string') return { bytes: utf8Encode(body), type: 'text/plain;charset=UTF-8' };
    if (body instanceof BlobImpl) return { bytes: body._bytes || new Uint8Array(0), type: body.type || null };
    if (body instanceof FormDataImpl && body._list) return multipart(body);
    if (g.URLSearchParams && body instanceof g.URLSearchParams) return { bytes: utf8Encode(body.toString()), type: 'application/x-www-form-urlencoded;charset=UTF-8' };
    if (body instanceof ArrayBuffer || ArrayBuffer.isView(body)) return { bytes: new Uint8Array(toBytes(body)), type: null };
    return { bytes: utf8Encode(String(body)), type: 'text/plain;charset=UTF-8' };
  };

  /* ---------- Headers / Request / Response ---------- */
  var HeadersImpl = g.Headers;
  if (typeof HeadersImpl !== 'function') {
    HeadersImpl = function Headers(init) {
      this._map = {};
      if (init === undefined || init === null) return;
      var self = this;
      if (init instanceof HeadersImpl) {
        init.forEach(function (v, k) { self.append(k, v); });
      } else if (Array.isArray(init)) {
        init.forEach(function (p) { if (p && p.length >= 2) self.append(p[0], p[1]); });
      } else if (typeof init === 'object') {
        if (typeof init.forEach === 'function' && typeof init.get === 'function') {
          init.forEach(function (v, k) { self.append(k, v); });
        } else {
          for (var k in init) { if (hasOwn.call(init, k) && typeof init[k] !== 'function') self.append(k, init[k]); }
        }
      }
    };
    HeadersImpl.prototype.append = function (name, value) {
      var key = String(name).toLowerCase();
      var v = String(value);
      this._map[key] = hasOwn.call(this._map, key) ? this._map[key] + ', ' + v : v;
    };
    HeadersImpl.prototype.set = function (name, value) { this._map[String(name).toLowerCase()] = String(value); };
    HeadersImpl.prototype.get = function (name) { var key = String(name).toLowerCase(); return hasOwn.call(this._map, key) ? this._map[key] : null; };
    HeadersImpl.prototype.has = function (name) { return hasOwn.call(this._map, String(name).toLowerCase()); };
    HeadersImpl.prototype['delete'] = function (name) { delete this._map[String(name).toLowerCase()]; };
    HeadersImpl.prototype.getSetCookie = function () { var v = this.get('set-cookie'); return v === null ? [] : [v]; };
    HeadersImpl.prototype.forEach = function (cb, thisArg) { var self = this; Object.keys(this._map).sort().forEach(function (k) { cb.call(thisArg, self._map[k], k, self); }); };
    HeadersImpl.prototype.entries = function () { var m = this._map; return Object.keys(m).sort().map(function (k) { return [k, m[k]]; })[Symbol.iterator](); };
    HeadersImpl.prototype.keys = function () { return Object.keys(this._map).sort()[Symbol.iterator](); };
    HeadersImpl.prototype.values = function () { var m = this._map; return Object.keys(m).sort().map(function (k) { return m[k]; })[Symbol.iterator](); };
    HeadersImpl.prototype[Symbol.iterator] = HeadersImpl.prototype.entries;
    g.Headers = HeadersImpl;
  }

  var RequestImpl = g.Request;
  if (typeof RequestImpl !== 'function') {
    RequestImpl = function Request(input, init) {
      var options = init || {};
      var base = (input instanceof RequestImpl) ? input : null;
      this.url = base ? base.url : String(input);
      this.method = String(options.method || (base ? base.method : 'GET')).toUpperCase();
      this.headers = new HeadersImpl(options.headers !== undefined ? options.headers : (base ? base.headers : undefined));
      this.body = null;
      this._body = options.body !== undefined ? options.body : (base ? base._body : null);
      this.redirect = options.redirect || (base ? base.redirect : 'follow');
      this.signal = options.signal || (base ? base.signal : null);
      this.credentials = options.credentials || (base ? base.credentials : 'same-origin');
      this.mode = options.mode || (base ? base.mode : 'cors');
      this.referrer = options.referrer || (base ? base.referrer : '');
    };
    RequestImpl.prototype.clone = function () { return new RequestImpl(this); };
    RequestImpl.prototype.text = function () { return Promise.resolve(utf8Decode(bodyInit(this._body).bytes)); };
    RequestImpl.prototype.json = function () { return this.text().then(function (t) { return JSON.parse(t); }); };
    RequestImpl.prototype.arrayBuffer = function () { return Promise.resolve(copyBuffer(bodyInit(this._body).bytes)); };
    g.Request = RequestImpl;
  }

  var ResponseImpl = g.Response;
  if (typeof ResponseImpl !== 'function') {
    ResponseImpl = function Response(body, init) {
      var options = init || {};
      var parsed = bodyInit(body);
      this.status = options.status === undefined ? 200 : Number(options.status);
      this.statusText = options.statusText === undefined ? '' : String(options.statusText);
      this.ok = this.status >= 200 && this.status < 300;
      this.headers = new HeadersImpl(options.headers);
      if (parsed.type && !this.headers.has('content-type')) this.headers.set('content-type', parsed.type);
      this.url = '';
      this.redirected = false;
      this.type = 'default';
      this.bodyUsed = false;
      this.body = null;
      this._bytes = parsed.bytes;
    };
    ResponseImpl.prototype.text = function () { return Promise.resolve(utf8Decode(this._bytes)); };
    ResponseImpl.prototype.json = function () { var bytes = this._bytes; return new Promise(function (resolve) { resolve(JSON.parse(utf8Decode(bytes))); }); };
    ResponseImpl.prototype.arrayBuffer = function () { return Promise.resolve(copyBuffer(this._bytes)); };
    ResponseImpl.prototype.bytes = function () { return Promise.resolve(new Uint8Array(this._bytes)); };
    ResponseImpl.prototype.blob = function () { return Promise.resolve(new BlobImpl([this._bytes], { type: this.headers.get('content-type') || '' })); };
    ResponseImpl.prototype.formData = function () { return Promise.reject(new TypeError('Response.formData() is not supported')); };
    ResponseImpl.prototype.clone = function () {
      var copy = new ResponseImpl(null, { status: this.status, statusText: this.statusText, headers: this.headers });
      copy._bytes = this._bytes;
      copy.url = this.url;
      return copy;
    };
    ResponseImpl.json = function (data, init) {
      var response = new ResponseImpl(JSON.stringify(data), init || {});
      response.headers.set('content-type', 'application/json');
      return response;
    };
    ResponseImpl.error = function () { var r = new ResponseImpl(null, { status: 0 }); r.type = 'error'; return r; };
    ResponseImpl.redirect = function (url, status) { return new ResponseImpl(null, { status: status || 302, headers: { location: String(url) } }); };
    g.Response = ResponseImpl;
  }

  /* ---------- navigator / performance / structuredClone / storage ---------- */
  if (typeof g.navigator === 'undefined') {
    g.navigator = {
      userAgent: USER_AGENT,
      appCodeName: 'Mozilla',
      appName: 'Netscape',
      appVersion: USER_AGENT.replace(/^Mozilla\//, ''),
      platform: 'Win32',
      vendor: 'Google Inc.',
      language: 'en-US',
      languages: ['en-US', 'en'],
      onLine: true,
      cookieEnabled: false,
      hardwareConcurrency: 4,
      maxTouchPoints: 0,
      webdriver: false
    };
  }
  if (typeof g.performance === 'undefined') {
    var timeOrigin = Date.now();
    g.performance = { timeOrigin: timeOrigin, now: function () { return Date.now() - timeOrigin; }, mark: function () {}, measure: function () {} };
  }
  if (typeof g.structuredClone !== 'function') {
    g.structuredClone = function (value) { return value === undefined ? undefined : JSON.parse(JSON.stringify(value)); };
  }
  var makeStorage = function () {
    var data = {};
    var storage = {
      getItem: function (k) { k = String(k); return hasOwn.call(data, k) ? data[k] : null; },
      setItem: function (k, v) { data[String(k)] = String(v); },
      removeItem: function (k) { delete data[String(k)]; },
      clear: function () { data = {}; },
      key: function (i) { var keys = Object.keys(data); return i >= 0 && i < keys.length ? keys[i] : null; }
    };
    Object.defineProperty(storage, 'length', { get: function () { return Object.keys(data).length; } });
    return storage;
  };
  if (typeof g.localStorage === 'undefined') g.localStorage = makeStorage();
  if (typeof g.sessionStorage === 'undefined') g.sessionStorage = makeStorage();

  /* ---------- minimal DOM: DOMParser, document, XMLSerializer (no layout, scripts never run) ---------- */
  var VOID_TAGS = { area: 1, base: 1, br: 1, col: 1, embed: 1, hr: 1, img: 1, input: 1, keygen: 1, link: 1, meta: 1, param: 1, source: 1, track: 1, wbr: 1 };
  var RAW_TAGS = { script: 1, style: 1, xmp: 1, iframe: 1, noembed: 1, noframes: 1 };
  var RCDATA_TAGS = { textarea: 1, title: 1 };
  var HEAD_TAGS = { title: 1, meta: 1, link: 1, base: 1, style: 1, script: 1, noscript: 1 };
  var SCOPE_TAGS = { applet: 1, caption: 1, html: 1, table: 1, td: 1, th: 1, marquee: 1, object: 1, template: 1, button: 1 };
  var P_TAG = { p: 1 };
  var TABLE_SECTION = [{ thead: 1, tbody: 1, tfoot: 1, tr: 1, td: 1, th: 1 }, { table: 1 }];
  /* Start tags that close an open element first: [elements closed, elements that stop the search]. */
  var IMPLIED_END = {
    li: [{ li: 1 }, { ul: 1, ol: 1, menu: 1, table: 1 }],
    dt: [{ dt: 1, dd: 1 }, { dl: 1, table: 1 }],
    dd: [{ dt: 1, dd: 1 }, { dl: 1, table: 1 }],
    option: [{ option: 1 }, { select: 1, datalist: 1, optgroup: 1 }],
    optgroup: [{ optgroup: 1, option: 1 }, { select: 1 }],
    tr: [{ tr: 1, td: 1, th: 1 }, { table: 1, thead: 1, tbody: 1, tfoot: 1 }],
    td: [{ td: 1, th: 1 }, { tr: 1, table: 1 }],
    th: [{ td: 1, th: 1 }, { tr: 1, table: 1 }],
    thead: TABLE_SECTION,
    tbody: TABLE_SECTION,
    tfoot: TABLE_SECTION
  };
  'address article aside blockquote details dialog div dl fieldset figcaption figure footer form h1 h2 h3 h4 h5 h6 header hgroup hr main menu nav ol p pre section table ul'.split(' ').forEach(function (tag) {
    if (!IMPLIED_END[tag]) IMPLIED_END[tag] = [P_TAG, SCOPE_TAGS];
  });
  var ENTITIES = {
    amp: '&', lt: '<', gt: '>', quot: '"', apos: "'", nbsp: ' ', copy: '©', reg: '®', trade: '™',
    hellip: '…', mdash: '—', ndash: '–', lsquo: '‘', rsquo: '’', ldquo: '“', rdquo: '”',
    sbquo: '‚', bdquo: '„', laquo: '«', raquo: '»', bull: '•', middot: '·', times: '×',
    divide: '÷', deg: '°', plusmn: '±', euro: '€', pound: '£', yen: '¥', cent: '¢',
    sect: '§', para: '¶', shy: '­', iexcl: '¡', iquest: '¿', ensp: ' ', emsp: ' ',
    thinsp: ' ', zwnj: '‌', zwj: '‍', lrm: '‎', rlm: '‏', larr: '←', rarr: '→',
    uarr: '↑', darr: '↓', hearts: '♥', star: '☆', frac12: '½', frac14: '¼', frac34: '¾',
    sup2: '²', sup3: '³', agrave: 'à', aacute: 'á', acirc: 'â', atilde: 'ã', auml: 'ä',
    aring: 'å', aelig: 'æ', ccedil: 'ç', egrave: 'è', eacute: 'é', ecirc: 'ê', euml: 'ë',
    igrave: 'ì', iacute: 'í', icirc: 'î', iuml: 'ï', ntilde: 'ñ', ograve: 'ò', oacute: 'ó',
    ocirc: 'ô', otilde: 'õ', ouml: 'ö', oslash: 'ø', ugrave: 'ù', uacute: 'ú', ucirc: 'û',
    uuml: 'ü', yacute: 'ý', yuml: 'ÿ', szlig: 'ß', Agrave: 'À', Aacute: 'Á', Acirc: 'Â',
    Auml: 'Ä', Ccedil: 'Ç', Egrave: 'È', Eacute: 'É', Ecirc: 'Ê', Ouml: 'Ö', Uuml: 'Ü'
  };
  /* Character references; in attribute values a named reference needs its ';' (legacy rule for URLs). */
  var decodeEntities = function (text, inAttribute) {
    if (text.indexOf('&') < 0) return text;
    return text.replace(/&(#[xX][0-9a-fA-F]+|#[0-9]+|[a-zA-Z][a-zA-Z0-9]*)(;?)/g, function (all, ref, semicolon) {
      if (ref.charAt(0) === '#') {
        var code = (ref.charAt(1) === 'x' || ref.charAt(1) === 'X') ? parseInt(ref.slice(2), 16) : parseInt(ref.slice(1), 10);
        if (!isFinite(code) || code <= 0 || code > 0x10FFFF || (code >= 0xD800 && code <= 0xDFFF)) return '�';
        return String.fromCodePoint(code);
      }
      if (!semicolon && inAttribute) return all;
      return hasOwn.call(ENTITIES, ref) ? ENTITIES[ref] : all;
    });
  };
  var isSpaceCode = function (c) { return c === 32 || c === 9 || c === 10 || c === 13 || c === 12; };

  var DNode = function Node(type, name, doc) {
    this.nodeType = type;
    this.nodeName = name;
    this.ownerDocument = doc || null;
    this.parentNode = null;
    this.childNodes = [];
  };
  DNode.ELEMENT_NODE = 1;
  DNode.TEXT_NODE = 3;
  DNode.CDATA_SECTION_NODE = 4;
  DNode.COMMENT_NODE = 8;
  DNode.DOCUMENT_NODE = 9;
  DNode.DOCUMENT_FRAGMENT_NODE = 11;

  var makeElement = function (doc, tag, xml) {
    var name = String(tag);
    var el = new DNode(1, xml ? name : name.toUpperCase(), doc);
    el.localName = xml ? name : name.toLowerCase();
    el.tagName = el.nodeName;
    el._attrs = [];
    el._xml = !!xml;
    return el;
  };
  var makeText = function (doc, text) { var t = new DNode(3, '#text', doc); t.data = String(text); return t; };
  var makeComment = function (doc, text) { var c = new DNode(8, '#comment', doc); c.data = String(text); return c; };
  var makeFragment = function (doc) { return new DNode(11, '#document-fragment', doc); };

  var detach = function (node) {
    var parent = node.parentNode;
    if (!parent) return;
    var index = parent.childNodes.indexOf(node);
    if (index >= 0) parent.childNodes.splice(index, 1);
    node.parentNode = null;
  };
  var insertNode = function (parent, node, before) {
    if (node === null || node === undefined) return node;
    if (node.nodeType === 11) {
      var kids = node.childNodes.slice();
      for (var i = 0; i < kids.length; i++) insertNode(parent, kids[i], before);
      return node;
    }
    detach(node);
    node.parentNode = parent;
    var index = before ? parent.childNodes.indexOf(before) : -1;
    if (index < 0) parent.childNodes.push(node); else parent.childNodes.splice(index, 0, node);
    return node;
  };
  var appendNode = function (parent, node) { return insertNode(parent, node, null); };
  var clearChildren = function (node) {
    for (var i = 0; i < node.childNodes.length; i++) node.childNodes[i].parentNode = null;
    node.childNodes = [];
  };
  var moveChildren = function (from, to) {
    var kids = from.childNodes.slice();
    for (var i = 0; i < kids.length; i++) appendNode(to, kids[i]);
  };
  var elementChildren = function (node) { return node.childNodes.filter(function (c) { return c.nodeType === 1; }); };
  var siblingElement = function (node, step) {
    var parent = node.parentNode;
    if (!parent) return null;
    var list = parent.childNodes;
    for (var i = list.indexOf(node) + step; i >= 0 && i < list.length; i += step) { if (list[i].nodeType === 1) return list[i]; }
    return null;
  };
  var siblingNode = function (node, step) {
    var parent = node.parentNode;
    if (!parent) return null;
    var list = parent.childNodes;
    var index = list.indexOf(node) + step;
    return index >= 0 && index < list.length ? list[index] : null;
  };
  var collectText = function (node, out) {
    for (var i = 0; i < node.childNodes.length; i++) {
      var c = node.childNodes[i];
      if (c.nodeType === 3) out.push(c.data);
      else if (c.nodeType === 1 || c.nodeType === 11) collectText(c, out);
    }
    return out;
  };
  var textOf = function (node) {
    if (node.nodeType === 3 || node.nodeType === 8) return node.data;
    return collectText(node, []).join('');
  };

  /* HTML (or XML) tokenizer + tree builder: implied end tags, void / raw text elements. */
  var parseMarkup = function (markup, root, doc, xml) {
    var src = String(markup);
    var lower = xml ? src : src.toLowerCase();
    var n = src.length;
    var stack = [root];
    var top = function () { return stack[stack.length - 1]; };
    var addText = function (text) {
      if (!text) return;
      var parent = top();
      var last = parent.childNodes[parent.childNodes.length - 1];
      if (last && last.nodeType === 3) last.data += text;
      else appendNode(parent, makeText(doc, text));
    };
    var autoClose = function (tag) {
      var rule = IMPLIED_END[tag];
      if (!rule) return;
      for (var s = stack.length - 1; s > 0; s--) {
        var open = stack[s].localName;
        if (rule[0][open]) { stack.length = s; return; }
        if (rule[1][open]) return;
      }
    };
    var i = 0;
    while (i < n) {
      var lt = src.indexOf('<', i);
      if (lt < 0) { addText(decodeEntities(src.slice(i), false)); break; }
      if (lt > i) addText(decodeEntities(src.slice(i, lt), false));
      i = lt;
      var next = src.charCodeAt(i + 1);
      if (src.substr(i, 4) === '<!--') {
        var endComment = src.indexOf('-->', i + 4);
        appendNode(top(), makeComment(doc, endComment < 0 ? src.slice(i + 4) : src.slice(i + 4, endComment)));
        i = endComment < 0 ? n : endComment + 3;
        continue;
      }
      if (src.substr(i, 9) === '<![CDATA[') {
        var endData = src.indexOf(']]>', i + 9);
        addText(endData < 0 ? src.slice(i + 9) : src.slice(i + 9, endData));
        i = endData < 0 ? n : endData + 3;
        continue;
      }
      if (next === 33 || next === 63) {
        var endDeclaration = src.indexOf('>', i + 2);
        i = endDeclaration < 0 ? n : endDeclaration + 1;
        continue;
      }
      if (next === 47) {
        var endTag = src.indexOf('>', i + 2);
        if (endTag < 0) { addText(src.slice(i)); break; }
        var closeName = src.slice(i + 2, endTag).replace(/[\s\/][\s\S]*$/, '');
        if (!xml) closeName = closeName.toLowerCase();
        i = endTag + 1;
        if (!closeName) continue;
        for (var s = stack.length - 1; s > 0; s--) {
          if (stack[s].localName === closeName) { stack.length = s; break; }
        }
        continue;
      }
      var isLetter = (next >= 65 && next <= 90) || (next >= 97 && next <= 122);
      if (!isLetter) { addText('<'); i += 1; continue; }

      var j = i + 1;
      while (j < n) {
        var c = src.charCodeAt(j);
        if (isSpaceCode(c) || c === 47 || c === 62) break;
        j++;
      }
      var rawName = src.slice(i + 1, j);
      var tag = xml ? rawName : rawName.toLowerCase();
      var attrs = [];
      var selfClosing = false;
      while (j < n) {
        var code = src.charCodeAt(j);
        if (code === 62) { j++; break; }
        if (code === 47) {
          if (src.charCodeAt(j + 1) === 62) { selfClosing = true; j += 2; break; }
          j++;
          continue;
        }
        if (isSpaceCode(code)) { j++; continue; }
        var nameStart = j;
        while (j < n) {
          var nc = src.charCodeAt(j);
          if (isSpaceCode(nc) || nc === 47 || nc === 62 || (nc === 61 && j > nameStart)) break;
          j++;
        }
        var attrName = src.slice(nameStart, j);
        while (j < n && isSpaceCode(src.charCodeAt(j))) j++;
        var attrValue = '';
        if (src.charCodeAt(j) === 61) {
          j++;
          while (j < n && isSpaceCode(src.charCodeAt(j))) j++;
          var quote = src.charAt(j);
          if (quote === '"' || quote === "'") {
            var endQuote = src.indexOf(quote, j + 1);
            if (endQuote < 0) endQuote = n;
            attrValue = src.slice(j + 1, endQuote);
            j = endQuote + 1;
          } else {
            var valueStart = j;
            while (j < n) {
              var vc = src.charCodeAt(j);
              if (isSpaceCode(vc) || vc === 62) break;
              j++;
            }
            attrValue = src.slice(valueStart, j);
          }
        }
        var key = xml ? attrName : attrName.toLowerCase();
        var duplicate = false;
        for (var a = 0; a < attrs.length; a++) { if (attrs[a].name === key) { duplicate = true; break; } }
        if (key && !duplicate) attrs.push({ name: key, value: decodeEntities(attrValue, true) });
      }
      i = j;
      if (!xml) autoClose(tag);
      var el = makeElement(doc, tag, xml);
      el._attrs = attrs;
      appendNode(top(), el);
      if (selfClosing || (!xml && VOID_TAGS[tag])) continue;
      if (!xml && (RAW_TAGS[tag] || RCDATA_TAGS[tag])) {
        var closeAt = lower.indexOf('</' + tag, i);
        if (closeAt < 0) closeAt = n;
        var rawText = src.slice(i, closeAt);
        if (rawText) appendNode(el, makeText(doc, RCDATA_TAGS[tag] ? decodeEntities(rawText, false) : rawText));
        var afterClose = closeAt < n ? src.indexOf('>', closeAt) : -1;
        i = afterClose < 0 ? n : afterClose + 1;
        continue;
      }
      stack.push(el);
    }
  };

  /* html > head + body around what was parsed (the browser always builds them). */
  var finishDocument = function (doc) {
    var html = null;
    var i;
    for (i = 0; i < doc.childNodes.length; i++) {
      if (doc.childNodes[i].nodeType === 1 && doc.childNodes[i].localName === 'html') { html = doc.childNodes[i]; break; }
    }
    var head = null;
    var body = null;
    if (!html) {
      var kids = doc.childNodes.slice();
      clearChildren(doc);
      html = makeElement(doc, 'html', false);
      head = makeElement(doc, 'head', false);
      body = makeElement(doc, 'body', false);
      appendNode(html, head);
      appendNode(html, body);
      var inBody = false;
      for (i = 0; i < kids.length; i++) {
        var k = kids[i];
        if (k.nodeType === 1 && k.localName === 'head') { moveChildren(k, head); continue; }
        if (k.nodeType === 1 && k.localName === 'body') { body._attrs = k._attrs; moveChildren(k, body); inBody = true; continue; }
        if (!inBody && k.nodeType === 1 && HEAD_TAGS[k.localName]) { appendNode(head, k); continue; }
        if (!inBody && k.nodeType === 3 && !/\S/.test(k.data)) continue;
        if (!inBody && k.nodeType === 8) { appendNode(doc, k); continue; }
        inBody = true;
        appendNode(body, k);
      }
      appendNode(doc, html);
      return;
    }
    for (i = 0; i < html.childNodes.length; i++) {
      var child = html.childNodes[i];
      if (child.nodeType !== 1) continue;
      if (child.localName === 'head' && !head) head = child;
      else if ((child.localName === 'body' || child.localName === 'frameset') && !body) body = child;
    }
    if (!body) {
      body = makeElement(doc, 'body', false);
      var rest = html.childNodes.filter(function (c) { return c !== head; });
      for (i = 0; i < rest.length; i++) appendNode(body, rest[i]);
      appendNode(html, body);
    }
    if (!head) insertNode(html, makeElement(doc, 'head', false), html.childNodes[0] || null);
  };

  var escapeText = function (s) { return s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/ /g, '&nbsp;'); };
  var escapeAttribute = function (s) { return s.replace(/&/g, '&amp;').replace(/"/g, '&quot;').replace(/ /g, '&nbsp;'); };
  var serialize = function (node, out) {
    if (node.nodeType === 3) {
      var parent = node.parentNode;
      var raw = parent && parent.nodeType === 1 && !parent._xml && RAW_TAGS[parent.localName];
      out.push(raw ? node.data : escapeText(node.data));
      return;
    }
    if (node.nodeType === 8) { out.push('<!--' + node.data + '-->'); return; }
    var i;
    if (node.nodeType === 1) {
      var name = node._xml ? node.tagName : node.localName;
      out.push('<' + name);
      for (i = 0; i < node._attrs.length; i++) out.push(' ' + node._attrs[i].name + '="' + escapeAttribute(node._attrs[i].value) + '"');
      out.push('>');
      if (!node._xml && VOID_TAGS[node.localName]) return;
      for (i = 0; i < node.childNodes.length; i++) serialize(node.childNodes[i], out);
      out.push('</' + name + '>');
      return;
    }
    for (i = 0; i < node.childNodes.length; i++) serialize(node.childNodes[i], out);
  };
  var serializeChildren = function (node) {
    var out = [];
    for (var i = 0; i < node.childNodes.length; i++) serialize(node.childNodes[i], out);
    return out.join('');
  };
  var cloneTree = function (node, deep, doc) {
    var copy;
    if (node.nodeType === 1) {
      copy = makeElement(doc, node._xml ? node.tagName : node.localName, node._xml);
      copy._attrs = node._attrs.map(function (a) { return { name: a.name, value: a.value }; });
    } else if (node.nodeType === 3) {
      copy = makeText(doc, node.data);
    } else if (node.nodeType === 8) {
      copy = makeComment(doc, node.data);
    } else {
      copy = new DNode(node.nodeType, node.nodeName, node.nodeType === 9 ? null : doc);
      copy._xml = node._xml;
      copy.contentType = node.contentType;
    }
    if (deep) {
      var owner = node.nodeType === 9 ? copy : doc;
      for (var i = 0; i < node.childNodes.length; i++) appendNode(copy, cloneTree(node.childNodes[i], true, owner));
    }
    return copy;
  };

  /* ---------- CSS selectors (querySelector / matches / closest) ---------- */
  var currentScope = null;
  var selectorCache = {};
  var findClose = function (s, i, open, close) {
    var depth = 1;
    var quote = null;
    for (; i < s.length; i++) {
      var ch = s.charAt(i);
      if (quote) { if (ch === '\\') i++; else if (ch === quote) quote = null; continue; }
      if (ch === '"' || ch === "'") { quote = ch; continue; }
      if (ch === open) depth++;
      else if (ch === close) { depth--; if (depth === 0) return i; }
    }
    return s.length;
  };
  var isIdentCode = function (c) { return (c >= 48 && c <= 57) || (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c === 45 || c === 95 || c > 127; };
  var parseSelectorList = function (text) {
    var source = String(text).trim();
    if (hasOwn.call(selectorCache, source)) return selectorCache[source];
    var s = source;
    var n = s.length;
    var i = 0;
    var groups = [];
    var chain = [];
    var current = null;
    var combinator = null;
    var fail = function () { throw new SyntaxError("Failed to execute 'querySelector': '" + source + "' is not a valid selector."); };
    var readIdent = function () {
      var start = i;
      while (i < n) {
        var c = s.charCodeAt(i);
        if (c === 92 && i + 1 < n) { i += 2; continue; }
        if (!isIdentCode(c)) break;
        i++;
      }
      return s.slice(start, i).replace(/\\(.)/g, '$1');
    };
    var compound = function () {
      if (!current) current = { tag: null, id: null, classes: [], attrs: [], pseudos: [] };
      return current;
    };
    var flush = function () {
      if (current) { chain.push({ sel: current, comb: combinator }); current = null; combinator = null; }
    };
    while (i < n) {
      var ch = s.charAt(i);
      var code = s.charCodeAt(i);
      if (ch === ',') {
        flush();
        if (!chain.length) fail();
        groups.push(chain);
        chain = [];
        combinator = null;
        i++;
        continue;
      }
      if (isSpaceCode(code) || ch === '>' || ch === '+' || ch === '~') {
        var comb = ' ';
        while (i < n) {
          var c2 = s.charAt(i);
          if (c2 === '>' || c2 === '+' || c2 === '~') comb = c2;
          else if (!isSpaceCode(s.charCodeAt(i))) break;
          i++;
        }
        if (i >= n || s.charAt(i) === ',') continue;
        flush();
        combinator = comb;
        continue;
      }
      if (ch === '*') { compound().tag = '*'; i++; continue; }
      if (ch === '#') { i++; compound().id = readIdent(); continue; }
      if (ch === '.') { i++; compound().classes.push(readIdent()); continue; }
      if (ch === '[') {
        var closeBracket = findClose(s, i + 1, '[', ']');
        var inside = s.slice(i + 1, closeBracket);
        i = closeBracket + 1;
        var m = /^\s*([^\s~|^$*!=\]]+)\s*(?:([~|^$*!]?=)\s*(?:"((?:[^"\\]|\\.)*)"|'((?:[^'\\]|\\.)*)'|([^\s\]]+)))?\s*([iIsS])?\s*$/.exec(inside);
        if (!m) fail();
        var value = m[3] !== undefined ? m[3] : (m[4] !== undefined ? m[4] : m[5]);
        compound().attrs.push({ name: m[1].toLowerCase(), op: m[2] || null, value: value === undefined ? null : value.replace(/\\(.)/g, '$1'), ci: m[6] === 'i' || m[6] === 'I' });
        continue;
      }
      if (ch === ':') {
        i++;
        if (s.charAt(i) === ':') i++;
        var pseudo = readIdent().toLowerCase();
        var arg = null;
        if (s.charAt(i) === '(') {
          var closeParen = findClose(s, i + 1, '(', ')');
          arg = s.slice(i + 1, closeParen);
          i = closeParen + 1;
        }
        compound().pseudos.push({ name: pseudo, arg: arg });
        continue;
      }
      var tagName = readIdent();
      if (!tagName) fail();
      compound().tag = tagName.toLowerCase();
    }
    flush();
    if (!chain.length) fail();
    groups.push(chain);
    selectorCache[source] = groups;
    return groups;
  };
  var hasClass = function (el, name) {
    var value = el.getAttribute('class');
    if (!value) return false;
    return (' ' + value.replace(/\s+/g, ' ') + ' ').indexOf(' ' + name + ' ') >= 0;
  };
  var matchAttribute = function (el, a) {
    var actual = el.getAttribute(a.name);
    if (actual === null) return false;
    if (!a.op) return true;
    var want = a.value === null ? '' : a.value;
    var have = actual;
    if (a.ci) { want = want.toLowerCase(); have = have.toLowerCase(); }
    switch (a.op) {
      case '=': return have === want;
      case '~=': return want !== '' && !/\s/.test(want) && (' ' + have.replace(/\s+/g, ' ') + ' ').indexOf(' ' + want + ' ') >= 0;
      case '|=': return have === want || have.indexOf(want + '-') === 0;
      case '^=': return want !== '' && have.indexOf(want) === 0;
      case '$=': return want !== '' && have.length >= want.length && have.slice(have.length - want.length) === want;
      case '*=': return want !== '' && have.indexOf(want) >= 0;
      case '!=': return have !== want;
    }
    return false;
  };
  var nthMatch = function (arg, index) {
    var t = String(arg || '').replace(/\s+/g, '').toLowerCase();
    if (t === 'odd') return index % 2 === 1;
    if (t === 'even') return index % 2 === 0;
    var m = /^([+-]?\d*)n([+-]\d+)?$/.exec(t);
    if (!m) { var exact = parseInt(t, 10); return !isNaN(exact) && index === exact; }
    var a = (m[1] === '' || m[1] === '+') ? 1 : (m[1] === '-' ? -1 : parseInt(m[1], 10));
    var b = m[2] ? parseInt(m[2], 10) : 0;
    if (a === 0) return index === b;
    var step = (index - b) / a;
    return step >= 0 && Math.floor(step) === step;
  };
  var elementSiblings = function (el) { return el.parentNode ? elementChildren(el.parentNode) : [el]; };
  var sameTypeSiblings = function (el) { return elementSiblings(el).filter(function (c) { return c.localName === el.localName; }); };
  var stripQuotes = function (text) {
    var t = String(text).trim();
    var q = t.charAt(0);
    return ((q === '"' || q === "'") && t.charAt(t.length - 1) === q) ? t.slice(1, -1) : t;
  };
  var matchGroups;
  var hasRelative = function (el, arg) {
    var text = String(arg).trim();
    if (!text) return false;
    var saved = currentScope;
    currentScope = el;
    try {
      var groups = parseSelectorList(':scope ' + text);
      var root = el.parentNode || el;
      return walkElements(root, function (candidate) { return candidate !== el && matchGroups(candidate, groups); });
    } finally {
      currentScope = saved;
    }
  };
  var matchPseudo = function (el, p) {
    var list;
    switch (p.name) {
      case 'scope':
        if (!currentScope) return !!el.parentNode && el.parentNode.nodeType === 9;
        if (currentScope.nodeType === 9) return el.parentNode === currentScope;
        return el === currentScope;
      case 'root': return !!el.parentNode && el.parentNode.nodeType === 9;
      case 'first-child': return elementSiblings(el)[0] === el;
      case 'last-child': list = elementSiblings(el); return list[list.length - 1] === el;
      case 'only-child': return elementSiblings(el).length === 1;
      case 'nth-child': return nthMatch(p.arg, elementSiblings(el).indexOf(el) + 1);
      case 'nth-last-child': list = elementSiblings(el); return nthMatch(p.arg, list.length - list.indexOf(el));
      case 'first-of-type': return sameTypeSiblings(el)[0] === el;
      case 'last-of-type': list = sameTypeSiblings(el); return list[list.length - 1] === el;
      case 'only-of-type': return sameTypeSiblings(el).length === 1;
      case 'nth-of-type': return nthMatch(p.arg, sameTypeSiblings(el).indexOf(el) + 1);
      case 'nth-last-of-type': list = sameTypeSiblings(el); return nthMatch(p.arg, list.length - list.indexOf(el));
      case 'empty': return el.childNodes.every(function (c) { return c.nodeType === 8 || (c.nodeType === 3 && c.data === ''); });
      case 'not': return !matchGroups(el, parseSelectorList(p.arg || ''));
      case 'is': case 'where': case 'matches': case 'any': return matchGroups(el, parseSelectorList(p.arg || ''));
      case 'has': return hasRelative(el, p.arg || '');
      case 'contains': return textOf(el).indexOf(stripQuotes(p.arg || '')) >= 0;
      case 'checked': return el.hasAttribute('checked') || (el.localName === 'option' && el.hasAttribute('selected'));
      case 'selected': return el.hasAttribute('selected');
      case 'disabled': return el.hasAttribute('disabled');
      case 'enabled': return !el.hasAttribute('disabled');
      case 'link': case 'any-link': return (el.localName === 'a' || el.localName === 'area') && el.hasAttribute('href');
      default: return false;
    }
  };
  var matchCompound = function (el, c) {
    if (el.nodeType !== 1) return false;
    if (c.tag && c.tag !== '*' && (el._xml ? el.localName.toLowerCase() : el.localName) !== c.tag) return false;
    if (c.id !== null && el.getAttribute('id') !== c.id) return false;
    var i;
    for (i = 0; i < c.classes.length; i++) { if (!hasClass(el, c.classes[i])) return false; }
    for (i = 0; i < c.attrs.length; i++) { if (!matchAttribute(el, c.attrs[i])) return false; }
    for (i = 0; i < c.pseudos.length; i++) { if (!matchPseudo(el, c.pseudos[i])) return false; }
    return true;
  };
  var matchChain = function (el, chain, k) {
    var part = chain[k];
    if (!matchCompound(el, part.sel)) return false;
    if (k === 0) return true;
    var comb = part.comb || ' ';
    var node;
    if (comb === '>') { node = el.parentNode; return !!node && node.nodeType === 1 && matchChain(node, chain, k - 1); }
    if (comb === '+') { node = siblingElement(el, -1); return !!node && matchChain(node, chain, k - 1); }
    if (comb === '~') {
      node = siblingElement(el, -1);
      while (node) { if (matchChain(node, chain, k - 1)) return true; node = siblingElement(node, -1); }
      return false;
    }
    node = el.parentNode;
    while (node && node.nodeType === 1) { if (matchChain(node, chain, k - 1)) return true; node = node.parentNode; }
    return false;
  };
  matchGroups = function (el, groups) {
    for (var i = 0; i < groups.length; i++) { if (matchChain(el, groups[i], groups[i].length - 1)) return true; }
    return false;
  };
  /* Pre-order walk over the descendant elements; stops when visit returns true. */
  var walkElements = function (root, visit) {
    var stack = [];
    var i;
    for (i = root.childNodes.length - 1; i >= 0; i--) stack.push(root.childNodes[i]);
    while (stack.length) {
      var node = stack.pop();
      if (node.nodeType !== 1) continue;
      if (visit(node)) return true;
      for (i = node.childNodes.length - 1; i >= 0; i--) stack.push(node.childNodes[i]);
    }
    return false;
  };
  var nodeList = function (items) {
    Object.defineProperty(items, 'item', { value: function (index) { return index >= 0 && index < this.length ? this[index] : null; }, enumerable: false });
    return items;
  };
  var queryAll = function (root, selector) {
    var groups = parseSelectorList(selector);
    var saved = currentScope;
    currentScope = root;
    var out = [];
    try {
      walkElements(root, function (el) { if (matchGroups(el, groups)) out.push(el); return false; });
    } finally {
      currentScope = saved;
    }
    return nodeList(out);
  };
  var queryOne = function (root, selector) {
    var groups = parseSelectorList(selector);
    var saved = currentScope;
    currentScope = root;
    var found = null;
    try {
      walkElements(root, function (el) { if (matchGroups(el, groups)) { found = el; return true; } return false; });
    } finally {
      currentScope = saved;
    }
    return found;
  };
  var matchesSelector = function (el, selector) {
    var groups = parseSelectorList(selector);
    var saved = currentScope;
    currentScope = el;
    try { return matchGroups(el, groups); } finally { currentScope = saved; }
  };

  /* ---------- Node API ---------- */
  var attributeKey = function (el, name) { return el._xml ? String(name) : String(name).toLowerCase(); };
  var classListOf = function (el) {
    var names = function () { var c = el.getAttribute('class'); return c ? c.split(/\s+/).filter(function (x) { return x !== ''; }) : []; };
    var write = function (list) { el.setAttribute('class', list.join(' ')); };
    var api = {
      contains: function (c) { return names().indexOf(String(c)) >= 0; },
      add: function () {
        var list = names();
        for (var i = 0; i < arguments.length; i++) { if (list.indexOf(String(arguments[i])) < 0) list.push(String(arguments[i])); }
        write(list);
      },
      remove: function () {
        var drop = Array.prototype.map.call(arguments, String);
        write(names().filter(function (c) { return drop.indexOf(c) < 0; }));
      },
      toggle: function (c, force) {
        c = String(c);
        var has = api.contains(c);
        var want = force === undefined ? !has : !!force;
        if (want && !has) api.add(c);
        if (!want && has) api.remove(c);
        return want;
      },
      item: function (i) { var list = names(); return i >= 0 && i < list.length ? list[i] : null; },
      forEach: function (cb, thisArg) { names().forEach(cb, thisArg); },
      toString: function () { return el.getAttribute('class') || ''; }
    };
    Object.defineProperty(api, 'length', { get: function () { return names().length; } });
    Object.defineProperty(api, 'value', { get: function () { return el.getAttribute('class') || ''; } });
    api[Symbol.iterator] = function () { return names()[Symbol.iterator](); };
    return api;
  };
  var documentOf = function (node) { return node.nodeType === 9 ? node : node.ownerDocument; };
  var documentRoot = function (doc) { for (var i = 0; i < doc.childNodes.length; i++) { if (doc.childNodes[i].nodeType === 1) return doc.childNodes[i]; } return null; };
  var rootChild = function (doc, name) {
    var root = documentRoot(doc);
    if (!root) return null;
    for (var i = 0; i < root.childNodes.length; i++) { if (root.childNodes[i].nodeType === 1 && root.childNodes[i].localName === name) return root.childNodes[i]; }
    return null;
  };
  var toNode = function (doc, value) { return (value && typeof value === 'object' && value.nodeType) ? value : makeText(doc, String(value)); };

  var accessors = {
    parentElement: function () { var p = this.parentNode; return p && p.nodeType === 1 ? p : null; },
    children: function () { return nodeList(elementChildren(this)); },
    childElementCount: function () { return elementChildren(this).length; },
    firstChild: function () { return this.childNodes[0] || null; },
    lastChild: function () { return this.childNodes[this.childNodes.length - 1] || null; },
    firstElementChild: function () { return elementChildren(this)[0] || null; },
    lastElementChild: function () { var list = elementChildren(this); return list[list.length - 1] || null; },
    nextSibling: function () { return siblingNode(this, 1); },
    previousSibling: function () { return siblingNode(this, -1); },
    nextElementSibling: function () { return siblingElement(this, 1); },
    previousElementSibling: function () { return siblingElement(this, -1); },
    isConnected: function () { var n = this; while (n.parentNode) n = n.parentNode; return n.nodeType === 9; },
    textContent: {
      get: function () { return textOf(this); },
      set: function (value) {
        if (this.nodeType === 3 || this.nodeType === 8) { this.data = String(value); return; }
        clearChildren(this);
        var text = value === null || value === undefined ? '' : String(value);
        if (text) appendNode(this, makeText(documentOf(this), text));
      }
    },
    innerText: {
      get: function () { return textOf(this); },
      set: function (value) { accessors.textContent.set.call(this, value); }
    },
    nodeValue: {
      get: function () { return (this.nodeType === 3 || this.nodeType === 8) ? this.data : null; },
      set: function (value) { if (this.nodeType === 3 || this.nodeType === 8) this.data = String(value); }
    },
    innerHTML: {
      get: function () { return serializeChildren(this); },
      set: function (value) {
        if (this.nodeType === 3 || this.nodeType === 8) return;
        clearChildren(this);
        var markup = value === null || value === undefined ? '' : String(value);
        var doc = documentOf(this);
        if (this.nodeType === 1 && !this._xml && (RAW_TAGS[this.localName] || RCDATA_TAGS[this.localName])) {
          if (markup) appendNode(this, makeText(doc, RCDATA_TAGS[this.localName] ? decodeEntities(markup, false) : markup));
          return;
        }
        parseMarkup(markup, this, doc, !!this._xml);
      }
    },
    outerHTML: function () { var out = []; serialize(this, out); return out.join(''); },
    id: {
      get: function () { return this.nodeType === 1 ? (this.getAttribute('id') || '') : undefined; },
      set: function (value) { if (this.nodeType === 1) this.setAttribute('id', value); }
    },
    className: {
      get: function () { return this.nodeType === 1 ? (this.getAttribute('class') || '') : undefined; },
      set: function (value) { if (this.nodeType === 1) this.setAttribute('class', value); }
    },
    classList: function () { return this.nodeType === 1 ? classListOf(this) : undefined; },
    dataset: function () {
      var out = {};
      if (this.nodeType !== 1) return out;
      for (var i = 0; i < this._attrs.length; i++) {
        var name = this._attrs[i].name;
        if (name.indexOf('data-') === 0) out[name.slice(5).replace(/-([a-z])/g, function (all, letter) { return letter.toUpperCase(); })] = this._attrs[i].value;
      }
      return out;
    },
    attributes: function () {
      var list = (this._attrs || []).map(function (a) { return { name: a.name, localName: a.name, nodeName: a.name, value: a.value, nodeValue: a.value }; });
      Object.defineProperty(list, 'getNamedItem', { value: function (name) { for (var i = 0; i < this.length; i++) { if (this[i].name === String(name).toLowerCase() || this[i].name === String(name)) return this[i]; } return null; }, enumerable: false });
      Object.defineProperty(list, 'item', { value: function (index) { return this[index] || null; }, enumerable: false });
      return list;
    },
    value: {
      get: function () {
        if (this.nodeType !== 1) return undefined;
        if (this.localName === 'textarea') return textOf(this);
        if (this.localName === 'select') {
          var option = queryOne(this, 'option[selected]') || queryOne(this, 'option');
          return option ? option.value : '';
        }
        var v = this.getAttribute('value');
        if (v === null && this.localName === 'option') return textOf(this).replace(/\s+/g, ' ').trim();
        return v === null ? '' : v;
      },
      set: function (value) {
        if (this.nodeType !== 1) return;
        if (this.localName === 'textarea') accessors.textContent.set.call(this, value);
        else this.setAttribute('value', value);
      }
    },
    title: {
      get: function () {
        if (this.nodeType === 9) { var t = queryOne(this, 'title'); return t ? textOf(t).replace(/\s+/g, ' ').trim() : ''; }
        return this.nodeType === 1 ? (this.getAttribute('title') || '') : undefined;
      },
      set: function (value) {
        if (this.nodeType === 1) { this.setAttribute('title', value); return; }
        if (this.nodeType !== 9) return;
        var el = queryOne(this, 'title');
        if (!el) { var head = rootChild(this, 'head'); if (!head) return; el = appendNode(head, makeElement(this, 'title', false)); }
        accessors.textContent.set.call(el, value);
      }
    },
    documentElement: function () { return this.nodeType === 9 ? documentRoot(this) : undefined; },
    head: function () { return this.nodeType === 9 ? rootChild(this, 'head') : undefined; },
    body: function () { return this.nodeType === 9 ? (rootChild(this, 'body') || rootChild(this, 'frameset')) : undefined; }
  };
  ['href', 'src', 'alt', 'name', 'type', 'rel', 'content', 'target', 'lang', 'srcset', 'action', 'method', 'placeholder', 'poster', 'download', 'label', 'for'].forEach(function (attr) {
    accessors[attr === 'for' ? 'htmlFor' : attr] = {
      get: function () { return this.nodeType === 1 ? (this.getAttribute(attr) || '') : undefined; },
      set: function (value) { if (this.nodeType === 1) this.setAttribute(attr, value); }
    };
  });
  ['checked', 'selected', 'disabled', 'hidden', 'required', 'readOnly', 'multiple'].forEach(function (prop) {
    var attr = prop.toLowerCase();
    accessors[prop] = {
      get: function () { return this.nodeType === 1 ? this.hasAttribute(attr) : undefined; },
      set: function (value) { if (this.nodeType !== 1) return; if (value) this.setAttribute(attr, ''); else this.removeAttribute(attr); }
    };
  });
  Object.keys(accessors).forEach(function (name) {
    var spec = accessors[name];
    var getter = typeof spec === 'function' ? spec : spec.get;
    var setter = typeof spec === 'function' ? undefined : spec.set;
    Object.defineProperty(DNode.prototype, name, { get: getter, set: setter, configurable: true, enumerable: false });
  });

  var nodeMethods = {
    getAttribute: function (name) {
      if (!this._attrs) return null;
      var key = attributeKey(this, name);
      for (var i = 0; i < this._attrs.length; i++) { if (this._attrs[i].name === key) return this._attrs[i].value; }
      return null;
    },
    setAttribute: function (name, value) {
      if (!this._attrs) return;
      var key = attributeKey(this, name);
      var text = String(value);
      for (var i = 0; i < this._attrs.length; i++) { if (this._attrs[i].name === key) { this._attrs[i].value = text; return; } }
      this._attrs.push({ name: key, value: text });
    },
    removeAttribute: function (name) {
      if (!this._attrs) return;
      var key = attributeKey(this, name);
      this._attrs = this._attrs.filter(function (a) { return a.name !== key; });
    },
    hasAttribute: function (name) { return this.getAttribute(name) !== null; },
    hasAttributes: function () { return !!this._attrs && this._attrs.length > 0; },
    getAttributeNames: function () { return (this._attrs || []).map(function (a) { return a.name; }); },
    toggleAttribute: function (name, force) {
      var has = this.hasAttribute(name);
      var want = force === undefined ? !has : !!force;
      if (want && !has) this.setAttribute(name, '');
      if (!want && has) this.removeAttribute(name);
      return want;
    },
    appendChild: function (node) { return appendNode(this, node); },
    insertBefore: function (node, reference) { return insertNode(this, node, reference || null); },
    removeChild: function (node) { if (node && node.parentNode === this) detach(node); return node; },
    replaceChild: function (node, old) { insertNode(this, node, old); if (old && old.parentNode === this) detach(old); return old; },
    append: function () {
      var doc = documentOf(this);
      for (var i = 0; i < arguments.length; i++) appendNode(this, toNode(doc, arguments[i]));
    },
    prepend: function () {
      var doc = documentOf(this);
      var first = this.childNodes[0] || null;
      for (var i = 0; i < arguments.length; i++) insertNode(this, toNode(doc, arguments[i]), first);
    },
    before: function () {
      var parent = this.parentNode;
      if (!parent) return;
      var doc = documentOf(this);
      for (var i = 0; i < arguments.length; i++) insertNode(parent, toNode(doc, arguments[i]), this);
    },
    after: function () {
      var parent = this.parentNode;
      if (!parent) return;
      var doc = documentOf(this);
      var next = siblingNode(this, 1);
      for (var i = 0; i < arguments.length; i++) insertNode(parent, toNode(doc, arguments[i]), next);
    },
    replaceWith: function () {
      var parent = this.parentNode;
      if (!parent) return;
      var doc = documentOf(this);
      var next = siblingNode(this, 1);
      detach(this);
      for (var i = 0; i < arguments.length; i++) insertNode(parent, toNode(doc, arguments[i]), next);
    },
    remove: function () { detach(this); },
    hasChildNodes: function () { return this.childNodes.length > 0; },
    contains: function (node) { var n = node; while (n) { if (n === this) return true; n = n.parentNode; } return false; },
    cloneNode: function (deep) { return cloneTree(this, !!deep, documentOf(this)); },
    normalize: function () {
      var merged = [];
      for (var i = 0; i < this.childNodes.length; i++) {
        var c = this.childNodes[i];
        if (c.nodeType === 3) {
          if (c.data === '') { c.parentNode = null; continue; }
          var last = merged[merged.length - 1];
          if (last && last.nodeType === 3) { last.data += c.data; c.parentNode = null; continue; }
        } else if (c.nodeType === 1) {
          c.normalize();
        }
        merged.push(c);
      }
      this.childNodes = merged;
    },
    querySelector: function (selector) { return queryOne(this, selector); },
    querySelectorAll: function (selector) { return queryAll(this, selector); },
    getElementsByTagName: function (name) {
      var wanted = String(name);
      var lowerName = wanted.toLowerCase();
      var out = [];
      walkElements(this, function (el) {
        if (wanted === '*' || el.localName === wanted || (!el._xml && el.localName === lowerName)) out.push(el);
        return false;
      });
      return nodeList(out);
    },
    getElementsByClassName: function (names) {
      var wanted = String(names).split(/\s+/).filter(function (x) { return x !== ''; });
      var out = [];
      if (!wanted.length) return nodeList(out);
      walkElements(this, function (el) {
        for (var i = 0; i < wanted.length; i++) { if (!hasClass(el, wanted[i])) return false; }
        out.push(el);
        return false;
      });
      return nodeList(out);
    },
    getElementById: function (id) {
      var wanted = String(id);
      var found = null;
      walkElements(this, function (el) { if (el.getAttribute('id') === wanted) { found = el; return true; } return false; });
      return found;
    },
    matches: function (selector) { return this.nodeType === 1 && matchesSelector(this, selector); },
    closest: function (selector) {
      var node = this;
      while (node && node.nodeType === 1) { if (matchesSelector(node, selector)) return node; node = node.parentNode; }
      return null;
    },
    createElement: function (tag) { return makeElement(this, tag, !!this._xml); },
    createElementNS: function (namespace, tag) { return makeElement(this, tag, !!this._xml); },
    createTextNode: function (text) { return makeText(this, text); },
    createComment: function (text) { return makeComment(this, text); },
    createDocumentFragment: function () { return makeFragment(this); },
    addEventListener: function () {},
    removeEventListener: function () {},
    dispatchEvent: function () { return true; },
    toString: function () { return this.nodeType === 9 ? '[object HTMLDocument]' : (this.nodeType === 1 ? '[object HTMLElement]' : '[object ' + this.nodeName + ']'); }
  };
  Object.keys(nodeMethods).forEach(function (name) {
    Object.defineProperty(DNode.prototype, name, { value: nodeMethods[name], writable: true, configurable: true, enumerable: false });
  });

  if (typeof g.Node === 'undefined') g.Node = DNode;
  if (typeof g.DOMParser !== 'function') {
    g.DOMParser = function DOMParser() {};
    g.DOMParser.prototype.parseFromString = function (markup, type) {
      var mime = String(type || 'text/html').toLowerCase();
      var xml = mime !== 'text/html' && mime.indexOf('xml') >= 0;
      var doc = new DNode(9, '#document', null);
      doc._xml = xml;
      doc.contentType = mime;
      doc.URL = 'about:blank';
      doc.documentURI = 'about:blank';
      doc.readyState = 'complete';
      doc.characterSet = 'UTF-8';
      doc.cookie = '';
      parseMarkup(markup === null || markup === undefined ? '' : String(markup), doc, doc, xml);
      if (!xml) finishDocument(doc);
      return doc;
    };
  }
  if (typeof g.XMLSerializer !== 'function') {
    g.XMLSerializer = function XMLSerializer() {};
    g.XMLSerializer.prototype.serializeToString = function (node) {
      var out = [];
      serialize(node, out);
      return out.join('');
    };
  }
  if (typeof g.document === 'undefined') {
    g.document = new g.DOMParser().parseFromString('<!DOCTYPE html><html><head></head><body></body></html>', 'text/html');
  }

  /* ---------- network ---------- */
  var makeHeaders = function (raw) {
    var plain = {};
    if (raw && typeof raw === 'object') {
      for (var k in raw) { if (hasOwn.call(raw, k)) plain[String(k).toLowerCase()] = String(raw[k]); }
    }
    if (plain['x-set-cookie']) {
      var val;
      try {
        var cookies = JSON.parse(plain['x-set-cookie']);
        val = Array.isArray(cookies) ? cookies.join(', ') : cookies;
      } catch (e) {
        val = plain['x-set-cookie'];
      }
      plain['set-cookie'] = val;
      plain['Set-Cookie'] = val;
    } else if (plain['set-cookie']) {
      plain['Set-Cookie'] = plain['set-cookie'];
    }
    var hidden = function (name, fn) { Object.defineProperty(plain, name, { value: fn, enumerable: false, configurable: true, writable: true }); };
    hidden('get', function (name) { var v = plain[String(name).toLowerCase()]; return v === undefined ? null : v; });
    hidden('has', function (name) { return hasOwn.call(plain, String(name).toLowerCase()); });
    hidden('forEach', function (cb, thisArg) {
      Object.keys(plain).forEach(function (key) { if (key !== 'Set-Cookie') cb.call(thisArg, plain[key], key, plain); });
    });
    var headerKeys = function () { return Object.keys(plain).filter(function (key) { return key !== 'Set-Cookie'; }); };
    hidden('entries', function () { return headerKeys().map(function (key) { return [key, plain[key]]; })[Symbol.iterator](); });
    hidden('keys', function () { return headerKeys()[Symbol.iterator](); });
    hidden('values', function () { return headerKeys().map(function (key) { return plain[key]; })[Symbol.iterator](); });
    hidden(Symbol.iterator, function () { return headerKeys().map(function (key) { return [key, plain[key]]; })[Symbol.iterator](); });
    return plain;
  };

  // Body of a native answer, shared by a response and its clones and read lazily: the text is decoded natively on
  // first use (a binary answer never is), the bytes are copied on first use. The native side releases its copy
  // once read (__tsumiText / __tsumiBytes then answer null): the other form is rebuilt here from the one kept.
  var bodyHolder = function (meta) {
    return { id: meta.bodyId, text: typeof meta.text === 'string' ? meta.text : null, bytes: null };
  };
  var holderText = function (holder) {
    if (holder.text === null) {
      var t = __tsumiText(holder.id);
      if (typeof t === 'string') holder.text = t;
      else if (holder.bytes !== null) holder.text = utf8Decode(holder.bytes);
      else holder.text = '';
    }
    return holder.text;
  };
  var holderBytes = function (holder) {
    if (holder.bytes === null) {
      var b = __tsumiBytes(holder.id);
      if (typeof b === 'string') holder.bytes = binaryToBytes(atobImpl(b));
      else holder.bytes = utf8Encode(holderText(holder));
    }
    return holder.bytes;
  };

  var makeResponse = function (meta, sharedHolder) {
    var holder = sharedHolder || bodyHolder(meta);
    var status = Number(meta.status) || 0;
    // A copy, so a module editing the array does not change what the next read returns.
    var bytes = function () { return new Uint8Array(holderBytes(holder)); };
    var response = {
      ok: status >= 200 && status < 300,
      status: status,
      statusText: String(meta.statusText || ''),
      url: String(meta.url || ''),
      redirected: false,
      type: 'basic',
      bodyUsed: false,
      headers: makeHeaders(meta.headers),
      text: function () { return new Promise(function (resolve) { resolve(holderText(holder)); }); },
      json: function () { return new Promise(function (resolve) { resolve(JSON.parse(holderText(holder))); }); },
      arrayBuffer: function () {
        return new Promise(function (resolve) { var b = bytes(); resolve(b.buffer.slice(b.byteOffset, b.byteOffset + b.byteLength)); });
      },
      bytes: function () { return new Promise(function (resolve) { resolve(bytes()); }); },
      blob: function () {
        return new Promise(function (resolve) {
          resolve(new BlobImpl([bytes()], { type: response.headers['content-type'] || '' }));
        });
      },
      clone: function () { return makeResponse(meta, holder); }
    };
    return response;
  };

  var normHeaders = function (h) {
    var out = {};
    if (!h || typeof h !== 'object') return out;
    if (Array.isArray(h)) {
      for (var i = 0; i < h.length; i++) {
        var p = h[i];
        if (p && p.length >= 2 && p[1] !== undefined && p[1] !== null) out[String(p[0])] = String(p[1]);
      }
      return out;
    }
    if (typeof h.forEach === 'function' && typeof h.get === 'function') {
      h.forEach(function (v, k) { out[String(k)] = String(v); });
      return out;
    }
    for (var key in h) {
      if (hasOwn.call(h, key)) {
        var value = h[key];
        if (value !== undefined && value !== null && typeof value !== 'function') out[key] = String(value);
      }
    }
    return out;
  };
  var hasHeader = function (headers, name) {
    for (var k in headers) { if (hasOwn.call(headers, k) && k.toLowerCase() === name) return true; }
    return false;
  };
  var looksLikeOptions = function (h) {
    if (!h || typeof h !== 'object' || Array.isArray(h)) return false;
    if (h.headers && typeof h.headers === 'object') return true;
    return hasOwn.call(h, 'method') || hasOwn.call(h, 'body');
  };
  var encodeBody = function (b) {
    if (b === undefined || b === null) return null;
    if (typeof b === 'string') return { text: b };
    if (b instanceof ArrayBuffer) return { base64: btoaImpl(bytesToBinary(new Uint8Array(b))) };
    if (ArrayBuffer.isView(b)) return { base64: btoaImpl(bytesToBinary(new Uint8Array(b.buffer, b.byteOffset, b.byteLength))) };
    if (g.URLSearchParams && b instanceof g.URLSearchParams) return { text: b.toString(), type: 'application/x-www-form-urlencoded;charset=UTF-8' };
    if (b instanceof BlobImpl && b._bytes) return { base64: btoaImpl(bytesToBinary(b._bytes)), type: b.type || null };
    if (b instanceof FormDataImpl && b._list) {
      var form = multipart(b);
      return { base64: btoaImpl(bytesToBinary(form.bytes)), type: form.type };
    }
    return { text: JSON.stringify(b) };
  };

  var request = function (url, headers, method, body, follow, encoding, rejectOnNetworkError) {
    var req = { url: String(url), method: method, headers: headers, follow: follow !== false };
    if (encoding) req.encoding = String(encoding);
    if (body !== undefined && body !== null && method !== 'GET' && method !== 'HEAD') {
      var enc = encodeBody(body);
      if (enc) {
        if (enc.text !== undefined) req.bodyText = enc.text;
        if (enc.base64 !== undefined) req.bodyBase64 = enc.base64;
        if (enc.type && !hasHeader(headers, 'content-type')) headers['Content-Type'] = enc.type;
      }
    }
    return new Promise(function (resolve, reject) {
      __tsumiFetch(JSON.stringify(req), function (meta) {
        if (meta && meta.networkError && rejectOnNetworkError) reject(new TypeError(String(meta.networkError)));
        else resolve(makeResponse(meta || {}));
      });
    });
  };

  // fetchv2(url, headers, method, body) or fetchv2(url, { headers, method, body });
  // Sora hosts also pass (redirect, encoding) as 5th/6th arguments.
  g.fetchv2 = function (url, headers, method, body, redirect, encoding) {
    var h = headers;
    var m = method;
    var b = body;
    var follow = redirect;
    if (looksLikeOptions(h)) {
      m = m || h.method;
      b = b !== undefined ? b : h.body;
      if (follow === undefined && h.redirect) follow = h.redirect !== 'manual' && h.redirect !== 'error';
      h = h.headers;
    }
    return request(url, normHeaders(h), String(m || 'GET').toUpperCase(), b, follow !== false, typeof encoding === 'string' ? encoding : null, false);
  };

  // fetch(url | Request, init): init wins over the Request's own method / headers / body.
  g.fetch = function (input, init) {
    var options = init || {};
    var req = (input instanceof RequestImpl) ? input : null;
    var url = req ? req.url : ((input && typeof input === 'object' && input.url) ? input.url : input);
    var signal = options.signal || (req ? req.signal : null);
    if (signal && signal.aborted) {
      var abort = new Error('The operation was aborted.');
      abort.name = 'AbortError';
      return Promise.reject(abort);
    }
    var redirect = options.redirect || (req ? req.redirect : 'follow');
    var follow = redirect !== 'manual' && redirect !== 'error';
    var headers = options.headers !== undefined ? options.headers : (req ? req.headers : undefined);
    var method = options.method || (req ? req.method : 'GET');
    var body = options.body !== undefined ? options.body : (req ? req._body : undefined);
    return request(url, normHeaders(headers), String(method || 'GET').toUpperCase(), body, follow, null, true);
  };
})(globalThis);
"""#
}
