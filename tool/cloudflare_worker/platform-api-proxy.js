// Same-origin reverse proxy: /platform-api/* -> https://platform.deepseek.com/*
// The platform sends no CORS headers, so a browser page can only read its
// responses through a proxy on its own origin.
export default {
  async fetch(request) {
    const url = new URL(request.url);
    const suffix = url.pathname.replace(/^\/platform-api/, '') + url.search;
    const target = 'https://platform.deepseek.com' + suffix;

    if (request.method === 'OPTIONS') {
      return new Response(null, {
        status: 204,
        headers: {
          'Access-Control-Allow-Origin': '*',
          'Access-Control-Allow-Methods': 'GET,POST,PUT,DELETE,OPTIONS',
          'Access-Control-Allow-Headers': '*',
          'Access-Control-Max-Age': '86400',
        },
      });
    }

    const headers = new Headers(request.headers);
    headers.delete('host');
    // The platform answers 429 to requests without a browser User-Agent;
    // the browser's own UA arrives with the request and is forwarded as-is.

    const upstream = await fetch(target, {
      method: request.method,
      headers,
      body: request.body,
      redirect: 'manual',
    });

    const resp = new Response(upstream.body, upstream);
    resp.headers.set('Access-Control-Allow-Origin', url.origin);
    return resp;
  },
};
