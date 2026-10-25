(function () {
  var a = document;

  function readVisitorIp() {
    return fetch('/cdn-cgi/trace', {
      cache: 'no-store',
      credentials: 'same-origin',
      headers: { Accept: 'text/plain' }
    }).then(function (response) {
      if (!response.ok) throw new Error('Cloudflare trace request failed');
      return response.text();
    }).then(function (trace) {
      var match = trace.match(/(?:^|\n)ip=([^\r\n]+)/);
      if (!match || !match[1]) throw new Error('Visitor IP was not provided');
      return match[1].trim();
    });
  }

  function initializeFooter() {
    var hostname = a.getElementById('cf-hostname');
    if (hostname && a.location && a.location.hostname) {
      hostname.textContent = a.location.hostname;
    }

    var footerIp = a.getElementById('cf-footer-item-ip');
    var reveal = a.getElementById('cf-footer-ip-reveal');
    var ip = a.getElementById('cf-footer-ip');

    if (footerIp && 'classList' in footerIp) {
      footerIp.classList.remove('hidden');
    }

    if (reveal && ip) {
      reveal.addEventListener('click', function () {
        reveal.classList.add('hidden');
        ip.classList.remove('hidden');
        ip.textContent = 'Loading...';

        readVisitorIp().then(function (visitorIp) {
          ip.textContent = visitorIp;
        }).catch(function () {
          ip.textContent = 'Unavailable';
        });
      });
    }

    var time = a.getElementById('cf-time');
    if (time) {
      time.textContent = new Date().toISOString().replace('T', ' ').substring(0, 19) + ' UTC';
    }

    var rayId = a.getElementById('cf-ray-id');
    if (rayId && window.crypto && window.crypto.getRandomValues) {
      var bytes = new Uint8Array(8);
      window.crypto.getRandomValues(bytes);
      rayId.textContent = Array.prototype.map.call(bytes, function (byte) {
        return byte.toString(16).padStart(2, '0');
      }).join('');
    }
  }

  document.addEventListener && a.addEventListener('DOMContentLoaded', initializeFooter);
})();
