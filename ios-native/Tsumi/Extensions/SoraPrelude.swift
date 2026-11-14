import Foundation

/// JavaScript installed in every module context before the module runs. It provides what Sora
/// modules expect from their host (JavaScriptCore has no web APIs): `fetchv2` (both call styles of
/// `buildFetchv2Polyfill` in common/modules/extension.js, plus the Sora app's `redirect`/`encoding`
/// arguments), a standard-ish `fetch`, `console`, timers, `atob`/`btoa`, TextEncoder/TextDecoder,
/// URL/URLSearchParams and AbortController. Native hooks: __tsumiLog, __tsumiSchedule,
/// __tsumiFetch, __tsumiBytes, __tsumiDone (see SoraBridge).
enum SoraPrelude {
  static let source = #"""
(function (g) {
  'use strict';
  var hasOwn = Object.prototype.hasOwnProperty;

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
  g.btoa = btoaImpl;
  g.atob = atobImpl;

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
    return plain;
  };

  var makeResponse = function (meta) {
    var text = typeof meta.text === 'string' ? meta.text : '';
    var status = Number(meta.status) || 0;
    var bodyId = meta.bodyId;
    var bytes = function () { return binaryToBytes(atobImpl(__tsumiBytes(bodyId))); };
    var response = {
      ok: status >= 200 && status < 300,
      status: status,
      statusText: String(meta.statusText || ''),
      url: String(meta.url || ''),
      redirected: false,
      type: 'basic',
      bodyUsed: false,
      headers: makeHeaders(meta.headers),
      text: function () { return Promise.resolve(text); },
      json: function () { return new Promise(function (resolve) { resolve(JSON.parse(text)); }); },
      arrayBuffer: function () {
        return new Promise(function (resolve) { var b = bytes(); resolve(b.buffer.slice(b.byteOffset, b.byteOffset + b.byteLength)); });
      },
      blob: function () {
        return new Promise(function (resolve) {
          var b = bytes();
          resolve({
            size: b.length,
            type: response.headers['content-type'] || '',
            arrayBuffer: function () { return Promise.resolve(b.buffer.slice(b.byteOffset, b.byteOffset + b.byteLength)); },
            text: function () { return Promise.resolve(utf8Decode(b)); }
          });
        });
      },
      clone: function () { return makeResponse(meta); }
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

  g.fetch = function (input, init) {
    var options = init || {};
    var url = (input && typeof input === 'object' && input.url) ? input.url : input;
    var follow = options.redirect !== 'manual' && options.redirect !== 'error';
    return request(url, normHeaders(options.headers), String(options.method || 'GET').toUpperCase(), options.body, follow, null, true);
  };
})(globalThis);
"""#
}
