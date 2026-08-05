// <hatch-field> — 1-bit ordered-dither flow field. Pure #000/#fff, no greys:
// tone is carried entirely by an 8x8 Bayer threshold, matching the Duochrome hatch device.
(function () {
  if (customElements.get('hatch-field')) return;

  const VERT = `attribute vec2 a;void main(){gl_Position=vec4(a,0.,1.);}`;

  const FRAG = `precision highp float;
uniform vec2 u_res;uniform float u_t;uniform vec2 u_p;uniform float u_inv;uniform float u_px;
uniform sampler2D u_img;uniform float u_has;uniform float u_ia;

float hash(vec2 p){return fract(sin(dot(p,vec2(127.1,311.7)))*43758.5453);}
float vnoise(vec2 p){
  vec2 i=floor(p),f=fract(p);vec2 u=f*f*(3.-2.*f);
  return mix(mix(hash(i),hash(i+vec2(1,0)),u.x),mix(hash(i+vec2(0,1)),hash(i+vec2(1,1)),u.x),u.y);
}
float fbm(vec2 p){float s=0.,a=.5;for(int i=0;i<5;i++){s+=a*vnoise(p);p*=2.03;a*=.5;}return s;}

float bayer2(vec2 a){a=floor(a);return fract(a.x/2.+a.y*a.y*.75);}

void main(){
  vec2 frag=gl_FragCoord.xy;
  vec2 uv=frag/u_res;
  vec2 p=vec2(uv.x*(u_res.x/u_res.y),uv.y);

  float t=u_t*.05;
  vec2 q=vec2(fbm(p*1.7+vec2(t,0.)),fbm(p*1.7+vec2(4.3,-t)));

  // smooth diagonal wash: dense low-left, open top-right
  float g=1.12-(uv.x*.62+uv.y*.72);
  float v=g+(fbm(p*2.2+q*.9+vec2(0.,t*.6))-.5)*.55;

  if(u_has>.5){
    // cover-fit the portrait, dither its luminance, let the field breathe through it
    float ca=u_res.x/u_res.y;
    vec2 iuv=uv;
    if(ca>u_ia){iuv.y=(uv.y-.5)*(u_ia/ca)+.5;} else {iuv.x=(uv.x-.5)*(ca/u_ia)+.5;}
    iuv=(iuv-.5)*1.12+.5+vec2(.035,.0);
    vec3 c=texture2D(u_img,vec2(iuv.x,1.-iuv.y)).rgb;
    float lum=dot(c,vec3(.299,.587,.114));
    lum=clamp((lum-.36)*1.85+.5,0.,1.);
    v=lum+(fbm(p*2.4+q*.7+vec2(0.,t*.5))-.5)*.09*smoothstep(.02,.3,lum);
  }

  // pointer opens a clearing in the field
  vec2 m=u_p; m.x*=u_res.x/u_res.y;
  float d=distance(p,m);
  v-=.5*exp(-d*d*11.0)*(u_has>.5?.34:1.0);

  v=clamp(v,0.,1.);

  vec2 b=frag/u_px;
  float th=((bayer2(b*.25)*.25+bayer2(b*.5))*.25+bayer2(b))*1.523;

  float ink=step(th,v)*step(.012,v);
  ink=mix(ink,1.-ink,u_inv);
  gl_FragColor=vec4(vec3(1.-ink),1.);
}`;

  class HatchField extends HTMLElement {
    connectedCallback() {
      if (this._init) return;
      this._init = true;
      this.style.display = 'block';
      this.style.position = this.style.position || 'absolute';
      this.style.inset = this.style.inset || '0';

      const c = document.createElement('canvas');
      c.style.cssText = 'display:block;width:100%;height:100%';
      this.appendChild(c);
      this.canvas = c;

      const gl = c.getContext('webgl', { antialias: false, alpha: false, powerPreference: 'low-power' });
      if (!gl) { this.style.background = '#fff'; return; }
      this.gl = gl;

      const sh = (type, src) => {
        const s = gl.createShader(type);
        gl.shaderSource(s, src); gl.compileShader(s);
        if (!gl.getShaderParameter(s, gl.COMPILE_STATUS)) console.warn(gl.getShaderInfoLog(s));
        return s;
      };
      const prog = gl.createProgram();
      gl.attachShader(prog, sh(gl.VERTEX_SHADER, VERT));
      gl.attachShader(prog, sh(gl.FRAGMENT_SHADER, FRAG));
      gl.linkProgram(prog); gl.useProgram(prog);
      this.prog = prog;

      const buf = gl.createBuffer();
      gl.bindBuffer(gl.ARRAY_BUFFER, buf);
      gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([-1, -1, 3, -1, -1, 3]), gl.STATIC_DRAW);
      const loc = gl.getAttribLocation(prog, 'a');
      gl.enableVertexAttribArray(loc);
      gl.vertexAttribPointer(loc, 2, gl.FLOAT, false, 0, 0);

      this.u = {
        res: gl.getUniformLocation(prog, 'u_res'),
        t: gl.getUniformLocation(prog, 'u_t'),
        p: gl.getUniformLocation(prog, 'u_p'),
        inv: gl.getUniformLocation(prog, 'u_inv'),
        px: gl.getUniformLocation(prog, 'u_px'),
        img: gl.getUniformLocation(prog, 'u_img'),
        has: gl.getUniformLocation(prog, 'u_has'),
        ia: gl.getUniformLocation(prog, 'u_ia'),
      };

      this._has = 0; this._ia = 1;
      this._loadSrc();

      this.pointer = [0.5, 1.35];
      this._target = [0.5, 1.35];
      this._onMove = (e) => {
        const r = this.getBoundingClientRect();
        this._target = [(e.clientX - r.left) / r.width, 1 - (e.clientY - r.top) / r.height];
      };
      this._onLeave = () => { this._target = [0.5, 1.35]; };
      this.addEventListener('pointermove', this._onMove);
      this.addEventListener('pointerleave', this._onLeave);

      this._ro = new ResizeObserver(() => this.resize());
      this._ro.observe(this);
      this.resize();

      this._io = new IntersectionObserver((es) => { this._visible = es[0].isIntersecting; }, { threshold: 0 });
      this._io.observe(this);
      this._visible = true;

      // Reduced-motion is re-evaluated live (not sampled once) so a mid-session
      // OS toggle takes effect immediately (WCAG 2.3.3 / 2.2.2).
      this._paused = false;
      this._mq = matchMedia('(prefers-reduced-motion: reduce)');
      this._reduced = this._mq.matches;
      this._onMQ = (e) => {
        this._reduced = e.matches;
        if (this._toggle) this._toggle.hidden = e.matches; // nothing to pause when motion is off
        if (e.matches) this.draw((performance.now() - this._t0) / 1000); // freeze on a static frame
      };
      this._mq.addEventListener('change', this._onMQ);

      // WCAG 2.2.2 Pause, Stop, Hide — a control for ALL users, not only those
      // with the OS flag. It lives in .hero-media, OUTSIDE this aria-hidden
      // element, so it is exposed to assistive tech.
      const toggle = this.parentElement && this.parentElement.querySelector('[data-hatch-toggle]');
      if (toggle) {
        this._toggle = toggle;
        toggle.hidden = this._reduced;
        toggle.addEventListener('click', () => {
          this._paused = !this._paused;
          toggle.setAttribute('aria-pressed', String(this._paused));
          toggle.textContent = this._paused ? 'Play motion' : 'Pause motion';
        });
      }

      this._t0 = performance.now();
      this.frame();
    }

    _loadSrc() {
      const gl = this.gl;
      const src = this.getAttribute('src');
      if (!gl || !src || src === this._srcTried) return;
      this._srcTried = src;
      const tex = gl.createTexture();
      const im = new Image();
      im.onload = () => {
        gl.activeTexture(gl.TEXTURE0);
        gl.bindTexture(gl.TEXTURE_2D, tex);
        gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
        gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
        gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR);
        gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR);
        gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGB, gl.RGB, gl.UNSIGNED_BYTE, im);
        this._ia = im.naturalWidth / im.naturalHeight;
        this._has = 1;
        this.draw(0);
      };
      im.src = src;
    }

    resize() {
      const dpr = Math.min(devicePixelRatio || 1, 2);
      const w = Math.max(1, Math.round(this.clientWidth * dpr));
      const h = Math.max(1, Math.round(this.clientHeight * dpr));
      if (w === this._w && h === this._h) return;
      this._w = w; this._h = h;
      this.canvas.width = w; this.canvas.height = h;
      this.gl.viewport(0, 0, w, h);
      this._dpr = dpr;
      if (this._reduced) this.draw(0);
    }

    draw(time) {
      const gl = this.gl;
      gl.uniform2f(this.u.res, this._w, this._h);
      gl.uniform1f(this.u.t, time);
      gl.uniform2f(this.u.p, this.pointer[0], this.pointer[1]);
      gl.uniform1f(this.u.inv, this.hasAttribute('invert') ? 1 : 0);
      gl.uniform1f(this.u.px, (parseFloat(this.getAttribute('dot')) || 2) * (this._dpr || 1));
      gl.uniform1i(this.u.img, 0);
      gl.uniform1f(this.u.has, this._has || 0);
      gl.uniform1f(this.u.ia, this._ia || 1);
      gl.drawArrays(gl.TRIANGLES, 0, 3);
    }

    frame = () => {
      this._raf = requestAnimationFrame(this.frame);
      if (!this.gl) return;
      if (this.getAttribute('src') !== this._srcTried) this._loadSrc();
      if (this._reduced || this._paused || !this._visible) return;
      this.pointer[0] += (this._target[0] - this.pointer[0]) * 0.07;
      this.pointer[1] += (this._target[1] - this.pointer[1]) * 0.07;
      this.draw((performance.now() - this._t0) / 1000);
    };

    disconnectedCallback() {
      cancelAnimationFrame(this._raf);
      this._ro && this._ro.disconnect();
      this._io && this._io.disconnect();
      this._mq && this._onMQ && this._mq.removeEventListener('change', this._onMQ);
    }
  }

  customElements.define('hatch-field', HatchField);
})();
