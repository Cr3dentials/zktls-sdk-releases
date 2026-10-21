// The tree runtime's in-page bridge, injected at document start by the native hosts
// (a WKUserScript on iOS, addDocumentStartJavaScript on Android). Version 2: version 1, and the pack's
// script.
//
// It observes; nothing it reports is evidence. Three guardrails hold, each tested in bridge.test.js:
//   1. Only declared URL patterns are recorded: a request is captured only while a capture pattern is
//      set and its URL contains it; a reply is read only while a watch pattern is set and matches.
//   2. Request bodies are never recorded, and nothing on a never_record URL (sign-in, account
//      security) is recorded at all.
//   3. Session values (header values, stored values, script-readable cookies) never appear in what
//      drain() reports. They stay in this closure, are applied inside the page by pageFetch, and leave
//      only through sessionMaterial, to the SDK's native code, for the attested read.
//
// The pack's script is our signed code for a platform. The native host loads it once per document
// with the run's token, and runScript calls its functions with that token, so a page that registers
// functions of its own can only make the run fail. A function reaches the platform through api.fetch,
// held to the pack's domains and never_record, and returns plain JSON. A result that holds a session
// value the bridge applied for the function or handed to it is refused, as is a key its node does not
// store. The host hands a call the cookies its node declares, HttpOnly ones too. The bridge holds them for
// that call and sends one only as the Authorization header of an api.fetch that names it (bearerFromCookie).
// But the bridge runs in the page's own JavaScript world: a platform script that patches the built-ins it
// uses (Array.prototype.forEach, say) can read them, and the session values above too.
//
// Native code calls the methods of window.__zktlsBridge; answers that take time come back as messages
// on the SDK's own channel (webkit.messageHandlers.zktls on iOS, the zktls WebMessageListener object on
// Android). The page can see this object; that is acceptable because nothing it reports is evidence.
//
// Each document gets a fresh bridge, so the native host puts its configuration (the pack's domains,
// never_record and the patterns in force) in window.__zktlsConfig just before this script, and every
// event is posted to the host as it happens: a page that navigates away loses nothing. Captured
// requests, values included, are kept in the origin's sessionStorage, which holds nothing the page did
// not send itself.
(function () {
  'use strict';
  var VERSION = 2;
  if (window.__zktlsBridge && window.__zktlsBridge.version === VERSION) return;

  var config = window.__zktlsConfig || {};
  try {
    delete window.__zktlsConfig;
  } catch (e) {}
  var neverRecord = config.never_record || [];
  // The pack's domains: "host", or ".domain" for the domain and its subdomains. The bridge runs, and
  // a fetch it makes lands, nowhere else.
  var domains = config.domains || [];

  function onDomains(host) {
    var h = String(host).toLowerCase();
    for (var i = 0; i < domains.length; i++) {
      var d = String(domains[i]).toLowerCase();
      if (d.charAt(0) === '.' ? h === d.slice(1) || h.slice(-d.length) === d : h === d) return true;
    }
    return false;
  }

  // Only on the pack's own pages, in the main frame, over https: anywhere else, sign-in hosts included,
  // nothing is hooked or defined (on iOS this script is injected into every page and frame).
  var here = window.location;
  if (here.protocol !== 'https:' || window.top !== window || !onDomains(here.hostname)) return;

  var capturePattern = config.capture || null;
  var watchPattern = config.watch || null;
  var events = [];
  var MAX_EVENTS = 500;
  var MAX_WATCHED_BODY = 8 * 1024 * 1024;
  // Captured requests, values included, newest last. Never reported; read by pageFetch and
  // sessionMaterial only. Kept across the origin's navigations in sessionStorage.
  var STORE = '__zktls_captured';
  // Enough for every request a run's pages make while a capture is on: a script reads the operation
  // ids of all of them, and the oldest is dropped first.
  var MAX_CAPTURED = 200;
  var captured = (function () {
    try {
      var saved = JSON.parse(window.sessionStorage.getItem(STORE) || '[]');
      return Array.isArray(saved) ? saved : [];
    } catch (e) {
      return [];
    }
  })();

  function saveCaptured() {
    try {
      window.sessionStorage.setItem(STORE, JSON.stringify(captured));
    } catch (e) {}
  }

  function post(msg) {
    try {
      if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.zktls) {
        window.webkit.messageHandlers.zktls.postMessage(msg);
      } else if (window.zktls && typeof window.zktls.postMessage === 'function') {
        window.zktls.postMessage(JSON.stringify(msg));
      }
    } catch (e) {
      // A page that broke the channel only loses observed data.
    }
  }

  function absolute(url) {
    try {
      return new URL(String(url), window.location.href).href;
    } catch (e) {
      return String(url);
    }
  }

  function withoutQuery(url) {
    var i = url.search(/[?#]/);
    return i < 0 ? url : url.slice(0, i);
  }

  function forbidden(url) {
    for (var i = 0; i < neverRecord.length; i++) {
      if (url.indexOf(neverRecord[i]) >= 0) return true;
    }
    return false;
  }

  function capturing(url) {
    return capturePattern !== null && url.indexOf(capturePattern) >= 0 && !forbidden(url);
  }

  function watching(url) {
    return watchPattern !== null && url.indexOf(watchPattern) >= 0 && !forbidden(url);
  }

  function push(event) {
    if (events.length < MAX_EVENTS) events.push(event);
    post({ kind: 'event', event: event });
  }

  // Headers as a lower-cased name -> value object, from a Headers, an array of pairs or a plain object.
  function headerObject(h) {
    var out = {};
    if (!h) return out;
    if (typeof h.forEach === 'function' && typeof h.get === 'function') {
      h.forEach(function (v, k) {
        out[String(k).toLowerCase()] = String(v);
      });
    } else if (Array.isArray(h)) {
      h.forEach(function (pair) {
        out[String(pair[0]).toLowerCase()] = String(pair[1]);
      });
    } else {
      Object.keys(h).forEach(function (k) {
        out[k.toLowerCase()] = String(h[k]);
      });
    }
    return out;
  }

  // credentials is how the page sent it ('include', 'same-origin' or 'omit'), so a script can send its own
  // request alike: an API that answers CORS with "*" refuses a credentialed one.
  function record(method, url, headers, credentials) {
    if (!capturing(url) || method === 'OPTIONS') return;
    captured.push({ method: method, url: url, headers: headers, credentials: credentials || 'same-origin' });
    if (captured.length > MAX_CAPTURED) captured.shift();
    saveCaptured();
    // The report carries the URL without its query (a token can ride in it) and the header names.
    push({ kind: 'request', method: method, url: withoutQuery(url), headers: Object.keys(headers).sort() });
  }

  // The last replies a watch saw in this document, for a script's api.responses.
  var recent = [];
  var MAX_RECENT = 20;

  function watched(url, status, body) {
    if (!watching(url) || typeof body !== 'string' || body.length > MAX_WATCHED_BODY) return;
    push({ kind: 'response', url: url, status: status, body: body });
    recent.push({ url: url, status: status, body: body });
    if (recent.length > MAX_RECENT) recent.shift();
  }

  // fetch: the page's own calls.
  var pageFetchImpl = window.fetch;
  if (typeof pageFetchImpl === 'function') {
    window.fetch = function (input, init) {
      var url = absolute(input && typeof input === 'object' && 'url' in input ? input.url : input);
      var method = String((init && init.method) || (input && input.method) || 'GET').toUpperCase();
      try {
        var headers = headerObject(input && typeof input === 'object' && input.headers);
        var own = headerObject(init && init.headers);
        Object.keys(own).forEach(function (k) {
          headers[k] = own[k];
        });
        var credentials = (init && init.credentials) || (input && typeof input === 'object' && input.credentials);
        record(method, url, headers, String(credentials || 'same-origin'));
      } catch (e) {}
      var p = pageFetchImpl.apply(this, arguments);
      if (watching(url)) {
        p.then(function (res) {
          res
            .clone()
            .text()
            .then(function (body) {
              watched(url, res.status, body);
            })
            .catch(function () {});
        }).catch(function () {});
      }
      return p;
    };
  }

  // XMLHttpRequest: the page's own calls.
  var XHR = window.XMLHttpRequest;
  if (XHR && XHR.prototype) {
    var open = XHR.prototype.open;
    var setRequestHeader = XHR.prototype.setRequestHeader;
    var send = XHR.prototype.send;
    XHR.prototype.open = function (method, url) {
      this.__zktls = { method: String(method || 'GET').toUpperCase(), url: absolute(url), headers: {} };
      return open.apply(this, arguments);
    };
    XHR.prototype.setRequestHeader = function (name, value) {
      if (this.__zktls) this.__zktls.headers[String(name).toLowerCase()] = String(value);
      return setRequestHeader.apply(this, arguments);
    };
    XHR.prototype.send = function () {
      var info = this.__zktls;
      if (info) {
        try {
          record(info.method, info.url, info.headers, this.withCredentials ? 'include' : 'same-origin');
        } catch (e) {}
        if (watching(info.url)) {
          var xhr = this;
          xhr.addEventListener('load', function () {
            var body = null;
            if (xhr.responseType === '' || xhr.responseType === 'text') body = xhr.responseText;
            else if (xhr.responseType === 'json') body = JSON.stringify(xhr.response);
            watched(info.url, xhr.status, body);
          });
        }
      }
      return send.apply(this, arguments);
    };
  }

  function readCookie(name) {
    var escaped = String(name).replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
    var m = String(document.cookie || '').match(new RegExp('(?:^|;\\s*)' + escaped + '=([^;]+)'));
    return m ? m[1] : null;
  }

  function readStorage(key) {
    try {
      return window.localStorage.getItem(key);
    } catch (e) {
      return null;
    }
  }

  function matchesCapture(entry, pattern) {
    return entry && entry.headers && entry.method !== 'OPTIONS' && entry.url.indexOf(pattern) >= 0;
  }

  // The newest captured request on the pattern: an earlier one may predate the login.
  function latestCaptured(pattern) {
    for (var i = captured.length - 1; i >= 0; i--) {
      if (matchesCapture(captured[i], pattern)) return captured[i];
    }
    return null;
  }

  function copyHeaders(from, names) {
    var out = {};
    var keys = names && names.length ? names.map(function (n) { return String(n).toLowerCase(); }) : Object.keys(from.headers);
    keys.forEach(function (k) {
      if (from.headers[k] !== undefined) out[k] = from.headers[k];
    });
    return out;
  }

  // ---- The pack's script ----------------------------------------------------------------------

  var MAX_SCRIPT_RESULT = 32 * 1024 * 1024;
  var MAX_SCRIPT_REPLIES = 64 * 1024 * 1024;
  // A header whose name says it carries a credential: its value must not come back in a result.
  var SECRET_NAME = /authorization|cookie|token|csrf|xsrf|secret|session|password|api-?key/i;
  // The functions loaded in this document, and the token they were loaded with.
  var scripts = { token: null, fns: null };

  function reason(e) {
    return String(e && e.message ? e.message : e).slice(0, 500);
  }

  function copyJSON(v) {
    return v === undefined ? undefined : JSON.parse(JSON.stringify(v));
  }

  function loadScript(token, body, functions) {
    if (scripts.token !== null) return scripts.token === token ? '' : 'another script is loaded in this page';
    var fns = {};
    var open = true;
    var registry = Object.freeze({
      define: function (name, fn) {
        if (!open) throw new Error('the script is already loaded');
        if (typeof name !== 'string' || typeof fn !== 'function') throw new Error('define takes a name and a function');
        if (Object.prototype.hasOwnProperty.call(fns, name)) throw new Error(name + ' is defined twice');
        fns[name] = fn;
      },
    });
    try {
      body(registry);
    } catch (e) {
      return 'the script did not load: ' + reason(e);
    } finally {
      open = false;
    }
    var defined = Object.keys(fns).sort().join(', ');
    var wanted = (functions || []).slice().sort().join(', ');
    if (defined !== wanted) return 'the script defines ' + (defined || 'nothing') + ', not ' + wanted;
    scripts.fns = fns;
    scripts.token = token;
    return '';
  }

  // A session value as a result could carry it: literally, URL-encoded or base64-encoded.
  function encodings(v) {
    var out = [v, encodeURIComponent(v)];
    try { out.push(btoa(v)); out.push(btoa(v).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '')); } catch (_) {}
    return out;
  }

  // Where a fetch landed after its redirects must be on the pack's domains, over https, and not a
  // never_record address; otherwise its reply is not read.
  function landedOff(res, target) {
    var landed = res.url ? new URL(res.url) : target;
    if (landed.protocol !== 'https:' || !onDomains(landed.hostname) || forbidden(landed.href)) return 'redirect_refused: ' + landed.hostname;
    return '';
  }

  // One call's api: the bridge's page fetch and session material, held to the pack's domains, and
  // the values it hands out, which the result may not hold.
  function scriptApi(run, arg) {
    var secret = function (v) {
      if (typeof v !== 'string') return v;
      [v, v.replace(/^Bearer\s+/i, '')].forEach(function (plain) {
        encodings(plain).forEach(function (s) {
          if (s.length >= 8 && run.secrets.indexOf(s) < 0) run.secrets.push(s);
        });
      });
      return v;
    };
    var secretHeaders = function (headers) {
      Object.keys(headers).forEach(function (k) {
        if (SECRET_NAME.test(k)) secret(headers[k]);
      });
      return headers;
    };
    // The cookies the host read for this call, HttpOnly ones too: held here, applied by scriptFetch.
    run.cookies.forEach(function (c) { secret(c.value); });
    var config = copyJSON(arg.config || {});
    // The partner's run inputs, a copy per call: a script that writes to them changes only its own.
    var params = copyJSON(arg.params || {});
    return Object.freeze({
      fetch: function (url, opts) {
        return scriptFetch(run, secret, secretHeaders, url, opts || {});
      },
      captured: function (pattern) {
        return captured
          .filter(function (c) { return matchesCapture(c, String(pattern)); })
          .map(function (c) {
            return { method: c.method, url: c.url, headers: secretHeaders(copyJSON(c.headers)), credentials: c.credentials || 'same-origin' };
          });
      },
      responses: function (pattern) {
        return recent.filter(function (r) { return r.url.indexOf(String(pattern)) >= 0; }).map(copyJSON);
      },
      cookie: function (name) {
        return secret(readCookie(name));
      },
      storage: function (key) {
        return secret(readStorage(key));
      },
      sleep: function (ms) {
        return new Promise(function (resolve, reject) {
          if (!run.open) return reject(new Error('cancelled'));
          var w = { reject: reject };
          w.timer = setTimeout(function () {
            run.waits.splice(run.waits.indexOf(w), 1);
            resolve();
          }, Math.max(0, Number(ms) || 0));
          run.waits.push(w);
        });
      },
      cancelled: function () {
        return !run.open;
      },
      progress: function (percent, message) {
        var p = Math.max(0, Math.min(100, Math.round(Number(percent) || 0)));
        push({ kind: 'progress', url: String(window.location.href), percent: p, message: String(message || '') });
      },
      config: config,
      params: params,
      now: function () {
        return (arg.now_ms || 0) + (Date.now() - run.started);
      },
    });
  }

  function scriptFetch(run, secret, secretHeaders, url, opts) {
    if (!run.open) return Promise.reject(new Error('cancelled'));
    var target;
    try {
      target = new URL(absolute(url));
    } catch (e) {
      return Promise.reject(new Error('not a URL: ' + String(url)));
    }
    if (target.protocol !== 'https:' || !onDomains(target.hostname)) {
      return Promise.reject(new Error(target.hostname + ' is outside the pack\'s domains'));
    }
    if (forbidden(target.href)) return Promise.reject(new Error('a sign-in or account-security address'));
    var headers = secretHeaders(headerObject(opts.headers));
    if (opts.fromCaptured) {
      var from = latestCaptured(opts.fromCaptured.url_pattern);
      if (!from) return Promise.reject(new Error('no captured request on ' + opts.fromCaptured.url_pattern));
      var copied = secretHeaders(copyHeaders(from, opts.fromCaptured.headers));
      Object.keys(copied).forEach(function (k) {
        headers[k] = copied[k];
      });
    }
    if (opts.bearerFromCookie) {
      var want = opts.bearerFromCookie;
      var declared = run.cookies.filter(function (c) {
        return c.url === want.url && c.value_prefix === want.valuePrefix;
      })[0];
      if (!declared) return Promise.reject(new Error('the node declares no cookie on ' + want.url + ' starting ' + want.valuePrefix));
      if (!declared.value) return Promise.reject(new Error('no cookie on ' + want.url + ' starts with ' + want.valuePrefix));
      if (!headers.authorization) headers.authorization = 'Bearer ' + declared.value;
    }
    if (opts.bearerCookie && !headers.authorization) {
      var bearer = readCookie(opts.bearerCookie);
      if (bearer) headers.authorization = 'Bearer ' + secret(bearer);
    }
    if (opts.storageHeader) {
      var stored = readStorage(opts.storageHeader.key);
      if (!stored) return Promise.reject(new Error('no "' + opts.storageHeader.key + '" in localStorage'));
      headers[String(opts.storageHeader.header).toLowerCase()] = secret(stored);
    }
    run.fetches += 1;
    var controller = typeof AbortController === 'function' ? new AbortController() : null;
    var timer = controller ? setTimeout(function () { controller.abort(); }, opts.timeoutMs || 30000) : null;
    return pageFetchImpl
      .call(window, target.href, {
        method: opts.method || 'GET',
        credentials: opts.credentials || 'include',
        redirect: 'follow',
        headers: headers,
        body: opts.body === null || opts.body === undefined ? undefined : opts.body,
        signal: controller ? controller.signal : undefined,
      })
      .then(
        function (res) {
          var refused = landedOff(res, target);
          if (refused) {
            if (timer) clearTimeout(timer);
            throw new Error(refused);
          }
          return res.text().then(function (text) {
            if (timer) clearTimeout(timer);
            var body = String(text || '');
            run.bytes += body.length;
            if (run.bytes > MAX_SCRIPT_REPLIES) throw new Error('the replies are over ' + MAX_SCRIPT_REPLIES + ' bytes');
            return { status: res.status, url: res.url, headers: headerObject(res.headers), body: body };
          });
        },
        function (e) {
          if (timer) clearTimeout(timer);
          throw new Error('fetch failed: ' + reason(e));
        }
      );
  }

  function runScript(id, arg) {
    var done = function (r) {
      r.kind = 'script';
      r.id = id;
      post(r);
    };
    var fn = arg && scripts.token !== null && arg.token === scripts.token ? scripts.fns[arg.call] : undefined;
    if (typeof fn !== 'function') {
      done({ ok: false, error: 'no script function ' + (arg && arg.call) + ' is loaded in this page' });
      return;
    }
    var stores = arg.stores || [];
    var run = { open: true, fetches: 0, bytes: 0, secrets: [], waits: [], started: Date.now(), cookies: arg.cookies || [] };
    var timer;
    var finish = function (r) {
      if (!run.open) return;
      run.open = false;
      clearTimeout(timer);
      run.waits.forEach(function (w) {
        clearTimeout(w.timer);
        w.reject(new Error('cancelled'));
      });
      r.fetches = run.fetches;
      r.bytes = run.bytes;
      done(r);
    };
    var limit = arg.timeout_ms || 600000;
    timer = setTimeout(function () {
      finish({ ok: false, error: 'the script ran past ' + Math.round(limit / 1000) + ' s' });
    }, limit);
    var pending;
    try {
      pending = fn(scriptApi(run, arg), copyJSON(arg.args || {}));
    } catch (e) {
      finish({ ok: false, error: 'the script threw: ' + reason(e) });
      return;
    }
    Promise.resolve(pending).then(
      function (value) {
        if (!run.open) return;
        if (value === null || typeof value !== 'object' || Array.isArray(value)) {
          finish({ ok: false, error: 'the script returned no object of its keys' });
          return;
        }
        var json;
        try {
          json = JSON.stringify(value);
        } catch (e) {
          finish({ ok: false, error: 'the script\'s result is not JSON: ' + reason(e) });
          return;
        }
        if (json.length > MAX_SCRIPT_RESULT) {
          finish({ ok: false, error: 'the script\'s result is over ' + MAX_SCRIPT_RESULT + ' bytes' });
          return;
        }
        var extra = Object.keys(JSON.parse(json)).filter(function (k) { return stores.indexOf(k) < 0; });
        if (extra.length) {
          finish({ ok: false, error: 'the script returned ' + extra.join(', ') + ', which its node does not store' });
          return;
        }
        for (var i = 0; i < run.secrets.length; i++) {
          if (json.indexOf(run.secrets[i]) >= 0) {
            finish({ ok: false, error: 'the script returned a session value' });
            return;
          }
        }
        finish({ ok: true, result: json });
      },
      function (e) {
        finish({ ok: false, error: 'the script threw: ' + reason(e) });
      }
    );
  }

  var api = {
    version: VERSION,

    startCapture: function (pattern) {
      capturePattern = String(pattern);
    },
    stopCapture: function () {
      capturePattern = null;
    },
    startWatch: function (pattern) {
      watchPattern = String(pattern);
    },
    stopWatch: function () {
      watchPattern = null;
    },

    // Everything recorded since the last drain, as JSON, in one crossing.
    drain: function () {
      var out = events;
      events = [];
      return JSON.stringify(out);
    },

    storagePresent: function (key, value) {
      var stored = readStorage(key);
      if (!stored) return false;
      return value === null || value === undefined || stored === value;
    },

    elementPresent: function (selector) {
      try {
        return !!document.querySelector(selector);
      } catch (e) {
        return false;
      }
    },

    // A request the page makes on its own origin with its own cookies: page-fetch.js's inPageFetch,
    // plus copying a captured request's headers. Posts { kind: "fetch", id, ... } when done.
    pageFetch: function (id, request) {
      var done = function (result) {
        result.kind = 'fetch';
        result.id = id;
        post(result);
      };
      try {
        var url = absolute(request.url);
        if (new URL(url).origin !== window.location.origin) {
          done({ status: 0, fatal: 'the request is not on the page\'s origin' });
          return;
        }
        if (forbidden(url)) {
          done({ status: 0, fatal: 'the request is on a sign-in or account-security address' });
          return;
        }
        var headers = {};
        (request.headers || []).forEach(function (pair) {
          headers[String(pair[0]).toLowerCase()] = String(pair[1]);
        });
        if (request.from_captured) {
          var from = latestCaptured(request.from_captured.url_pattern);
          if (!from) {
            done({ status: 0, fatal: 'no captured request on ' + request.from_captured.url_pattern });
            return;
          }
          var copied = copyHeaders(from, request.from_captured.headers);
          Object.keys(copied).forEach(function (k) {
            headers[k] = copied[k];
          });
        }
        if (request.bearer_cookie && !headers.authorization) {
          var bearer = readCookie(request.bearer_cookie);
          if (bearer) headers.authorization = 'Bearer ' + bearer;
        }
        if (request.storage_header) {
          var stored = readStorage(request.storage_header.key);
          if (!stored) {
            done({ status: 0, fatal: 'no "' + request.storage_header.key + '" in localStorage' });
            return;
          }
          headers[String(request.storage_header.header).toLowerCase()] = stored;
        }
        var controller = typeof AbortController === 'function' ? new AbortController() : null;
        var timer = controller ? setTimeout(function () { controller.abort(); }, request.timeout_ms || 15000) : null;
        pageFetchImpl
          .call(window, url, {
            method: request.method || 'GET',
            credentials: 'include',
            redirect: 'follow',
            headers: headers,
            body: request.body === null ? undefined : request.body,
            signal: controller ? controller.signal : undefined,
          })
          .then(function (res) {
            var refused = landedOff(res, new URL(url));
            if (refused) {
              if (timer) clearTimeout(timer);
              done({ status: 0, fatal: refused });
              return;
            }
            return res.text().then(function (text) {
              if (timer) clearTimeout(timer);
              var body = String(text || '');
              if (request.max_body_bytes && body.length > request.max_body_bytes) {
                done({ status: 0, fatal: 'the reply is over ' + request.max_body_bytes + ' bytes' });
                return;
              }
              done({
                status: res.status,
                final_url: res.url,
                body: body,
                retry_after: res.headers && res.headers.get ? res.headers.get('retry-after') : null,
              });
            });
          })
          .catch(function (e) {
            if (timer) clearTimeout(timer);
            done({ status: 0, error: String(e && e.message ? e.message : e) });
          });
      } catch (e) {
        done({ status: 0, error: String(e && e.message ? e.message : e) });
      }
    },

    // The session material a collect declares, for the attested read: the one path on which a value
    // leaves the page, and only to the SDK's native code, which seals it. Posts
    // { kind: "session_material", id, headers: [[name, value]...], missing: [what...] }.
    sessionMaterial: function (id, session) {
      var headers = [];
      var missing = [];
      if (session.from_captured) {
        var from = latestCaptured(session.from_captured.url_pattern);
        if (from) {
          var copied = copyHeaders(from, session.from_captured.headers);
          Object.keys(copied).forEach(function (k) {
            headers.push([k, copied[k]]);
          });
        } else {
          missing.push('captured:' + session.from_captured.url_pattern);
        }
      }
      if (session.bearer_cookie) {
        var bearer = readCookie(session.bearer_cookie);
        if (bearer) headers.push(['authorization', 'Bearer ' + bearer]);
        else missing.push('cookie:' + session.bearer_cookie);
      }
      if (session.storage_header) {
        var stored = readStorage(session.storage_header.key);
        if (stored) headers.push([String(session.storage_header.header).toLowerCase(), stored]);
        else missing.push('storage:' + session.storage_header.key);
      }
      post({ kind: 'session_material', id: id, headers: headers, missing: missing });
    },

    // Loads the pack's script into this document once, with the run's token: '' when its functions
    // are the ones the pack lists, or why not. The native host calls it with the signed source as
    // body: function (zktls) { <source> }.
    loadScript: loadScript,

    // Calls one of the loaded functions: arg is { token, call, args, stores, config, params, now_ms,
    // timeout_ms }. Posts { kind: "script", id, ok, result (its JSON) | error, fetches, bytes }.
    runScript: runScript,
  };

  try {
    Object.defineProperty(window, '__zktlsBridge', { value: Object.freeze(api), enumerable: false, configurable: false, writable: false });
  } catch (e) {
    window.__zktlsBridge = api;
  }
})();
