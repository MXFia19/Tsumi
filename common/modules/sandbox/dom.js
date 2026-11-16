/* eslint-disable */
// Minimal DOM for Sora modules run in the extension sandbox (sandbox.js): a Web Worker has no DOMParser, document,
// XMLSerializer or Node. Same code as the "minimal DOM", "CSS selectors" and "Node API" parts of the iOS prelude
// (ios-native/Tsumi/Extensions/SoraPrelude.swift): keep both in sync (PC / iPhone parity).
// HTML / XML parser, CSS selectors, textContent / innerHTML, no layout, scripts never run.
//
// Self-contained on purpose: sandbox.js sends its source to the worker (installDom.toString()), so the function must
// not use anything declared outside its own body.
export function installDom (g) {
  'use strict';
  var hasOwn = Object.prototype.hasOwnProperty;

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
}
