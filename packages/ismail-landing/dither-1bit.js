// 1-bit dither fields — pure #000/#fff, no greys. Tone is carried entirely by an
// 8x8 Bayer threshold (the Duochrome hatch device), never by alpha or grey fills.
//
// Two custom elements share ONE guarded WebGL harness (Field1Bit):
//   <hatch-field>  — the hero's ordered-dither flow field (+ optional portrait src).
//   <dither-field> — an ambient domain-warped "plate-mark" field for the contact band.
//
// The dither math (hash/value-noise/fbm/Bayer) lives once in LIB and is prepended to
// every fragment shader — the reusable *math* is what we keep. The Bayer recursion is
// after basement.studio's shader-lab dither-textures (Apache-2.0) — function only, no
// framework: no three.js, no WebGPU, ~5 KB of raw WebGL 1 with a graceful null-context
// fallback. Each field: compute a scalar in [0,1], dither the threshold, step() to
// pure black or white. Guards (WCAG/perf): 30 fps cap, off-screen + hidden-tab pause,
// live prefers-reduced-motion freeze, and a Pause control outside the aria-hidden root.
(function () {
  if (customElements.get('hatch-field')) return;

  // Shared GLSL prelude — the 1-bit dither kernel, defined once (DRY).
  const LIB = `precision highp float;
float hash(vec2 p){return fract(sin(dot(p,vec2(127.1,311.7)))*43758.5453);}
float vnoise(vec2 p){vec2 i=floor(p),f=fract(p);vec2 u=f*f*(3.-2.*f);
  return mix(mix(hash(i),hash(i+vec2(1,0)),u.x),mix(hash(i+vec2(0,1)),hash(i+vec2(1,1)),u.x),u.y);}
float fbm(vec2 p){float s=0.,a=.5;for(int i=0;i<5;i++){s+=a*vnoise(p);p*=2.03;a*=.5;}return s;}
float bayer2(vec2 a){a=floor(a);return fract(a.x/2.+a.y*a.y*.75);}
float dither8(vec2 b){return ((bayer2(b*.25)*.25+bayer2(b*.5))*.25+bayer2(b))*1.523;}`;

  const VERT = `attribute vec2 a;void main(){gl_Position=vec4(a,0.,1.);}`;

  // ── Base harness ───────────────────────────────────────────────────────────
  // Owns the whole lifecycle; a subclass supplies FRAG (its scalar field) + the
  // uniform names it needs, and may override the knobs / hooks below.
  class Field1Bit extends HTMLElement {
    // knobs — subclasses override
    get maxDPR() { return 2; }
    get fps() { return 30; }
    get animated() { return true; }               // false → draw one static frame, no RAF
    get preserveBuffer() { return !this.animated; } // static canvases must persist across repaints
    get usesPointer() { return false; }
    get pointerHome() { return [0.5, 0.5]; }
    get toggleAttr() { return 'data-motion-toggle'; }

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

      const gl = c.getContext('webgl', { antialias: false, alpha: false, powerPreference: 'low-power', preserveDrawingBuffer: this.preserveBuffer });
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
      gl.attachShader(prog, sh(gl.FRAGMENT_SHADER, LIB + '\n' + this.constructor.FRAG));
      gl.linkProgram(prog); gl.useProgram(prog);
      this.prog = prog;

      const buf = gl.createBuffer();
      gl.bindBuffer(gl.ARRAY_BUFFER, buf);
      gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([-1, -1, 3, -1, -1, 3]), gl.STATIC_DRAW);
      const loc = gl.getAttribLocation(prog, 'a');
      gl.enableVertexAttribArray(loc);
      gl.vertexAttribPointer(loc, 2, gl.FLOAT, false, 0, 0);

      this.u = {};
      for (const name of this.constructor.UNIFORMS) this.u[name] = gl.getUniformLocation(prog, name);

      if (this.onInit) this.onInit(gl); // subclass extras (e.g. textures)

      if (this.usesPointer) {
        this.pointer = this.pointerHome.slice();
        this._target = this.pointerHome.slice();
        this._onMove = (e) => {
          const r = this.getBoundingClientRect();
          this._target = [(e.clientX - r.left) / r.width, 1 - (e.clientY - r.top) / r.height];
        };
        this._onLeave = () => { this._target = this.pointerHome.slice(); };
        this.addEventListener('pointermove', this._onMove);
        this.addEventListener('pointerleave', this._onLeave);
      } else {
        this.pointer = this.pointerHome.slice();
      }

      this._ro = new ResizeObserver(() => this.resize());
      this._ro.observe(this);
      this.resize();

      this._io = new IntersectionObserver((es) => {
        this._visible = es[0].isIntersecting;
        // A static plate redraws its one frame on re-entry — cheap insurance against
        // any compositor dropping the preserved buffer after it scrolled away.
        if (this._visible && !this.animated) this.draw(this._staticTime());
      }, { threshold: 0 });
      this._io.observe(this);
      this._visible = true;

      // Reduced-motion re-evaluated live (not sampled once) so a mid-session OS
      // toggle takes effect immediately (WCAG 2.3.3 / 2.2.2).
      this._paused = false;
      this._mq = matchMedia('(prefers-reduced-motion: reduce)');
      this._reduced = this._mq.matches;
      this._onMQ = (e) => {
        this._reduced = e.matches;
        if (this._toggle) this._toggle.hidden = e.matches; // nothing to pause when motion is off
        if (e.matches) this.draw(this._staticTime()); // freeze on a static frame
      };
      this._mq.addEventListener('change', this._onMQ);

      // WCAG 2.2.2 Pause, Stop, Hide — a control for ALL users, not only those
      // with the OS flag. It lives OUTSIDE this aria-hidden element, so it is
      // exposed to assistive tech.
      const toggle = this.parentElement && this.parentElement.querySelector('[' + this.toggleAttr + ']');
      if (toggle) {
        this._toggle = toggle;
        toggle.hidden = this._reduced;
        toggle.addEventListener('click', () => {
          this._paused = !this._paused;
          toggle.setAttribute('aria-pressed', String(this._paused));
          toggle.textContent = this._paused ? 'Play motion' : 'Pause motion';
        });
      }

      this._interval = 1000 / this.fps;
      this._last = 0;
      this._t0 = performance.now();
      if (this.animated) this.frame();
      else this.draw(this._staticTime());
    }

    _staticTime() {
      // A static field draws one fixed frame; an animated one, frozen by
      // reduced-motion, holds its current wall-clock position.
      if (!this.animated) return this.constructor.STATIC_T || 0;
      return (performance.now() - this._t0) / 1000;
    }

    resize() {
      const dpr = Math.min(devicePixelRatio || 1, this.maxDPR);
      const w = Math.max(1, Math.round(this.clientWidth * dpr));
      const h = Math.max(1, Math.round(this.clientHeight * dpr));
      if (w === this._w && h === this._h) return;
      this._w = w; this._h = h;
      this.canvas.width = w; this.canvas.height = h;
      this.gl.viewport(0, 0, w, h);
      this._dpr = dpr;
      if (this._reduced || !this.animated) this.draw(this._staticTime());
    }

    draw(time) {
      const gl = this.gl, u = this.u;
      if (u.u_res) gl.uniform2f(u.u_res, this._w, this._h);
      if (u.u_t) gl.uniform1f(u.u_t, time);
      if (u.u_p) gl.uniform2f(u.u_p, this.pointer[0], this.pointer[1]);
      if (u.u_inv) gl.uniform1f(u.u_inv, this.hasAttribute('invert') ? 1 : 0);
      if (u.u_px) gl.uniform1f(u.u_px, (parseFloat(this.getAttribute('dot')) || 2) * (this._dpr || 1));
      if (this.extraUniforms) this.extraUniforms(gl, u);
      gl.drawArrays(gl.TRIANGLES, 0, 3);
    }

    frame = () => {
      this._raf = requestAnimationFrame(this.frame);
      if (!this.gl) return;
      if (this.beforeFrame) this.beforeFrame();
      if (this._reduced || this._paused || !this._visible) return;
      const now = performance.now();
      if (now - this._last < this._interval) return; // frame-rate cap (perf + seizure safety)
      this._last = now;
      if (this.usesPointer) {
        this.pointer[0] += (this._target[0] - this.pointer[0]) * 0.07;
        this.pointer[1] += (this._target[1] - this.pointer[1]) * 0.07;
      }
      this.draw((now - this._t0) / 1000);
    };

    disconnectedCallback() {
      cancelAnimationFrame(this._raf);
      this._ro && this._ro.disconnect();
      this._io && this._io.disconnect();
      this._mq && this._onMQ && this._mq.removeEventListener('change', this._onMQ);
      if (this._onMove) this.removeEventListener('pointermove', this._onMove);
      if (this._onLeave) this.removeEventListener('pointerleave', this._onLeave);
    }
  }

  // ── <hatch-field> — the hero flow field (unchanged behaviour) ───────────────
  class HatchField extends Field1Bit {
    static UNIFORMS = ['u_res', 'u_t', 'u_p', 'u_inv', 'u_px', 'u_img', 'u_has', 'u_ia'];
    static FRAG = `
uniform vec2 u_res;uniform float u_t;uniform vec2 u_p;uniform float u_inv;uniform float u_px;
uniform sampler2D u_img;uniform float u_has;uniform float u_ia;
void main(){
  vec2 frag=gl_FragCoord.xy;
  vec2 uv=frag/u_res;
  vec2 p=vec2(uv.x*(u_res.x/u_res.y),uv.y);
  float t=u_t*.05;
  vec2 q=vec2(fbm(p*1.7+vec2(t,0.)),fbm(p*1.7+vec2(4.3,-t)));
  float g=1.12-(uv.x*.62+uv.y*.72);
  float v=g+(fbm(p*2.2+q*.9+vec2(0.,t*.6))-.5)*.55;
  if(u_has>.5){
    float ca=u_res.x/u_res.y;
    vec2 iuv=uv;
    if(ca>u_ia){iuv.y=(uv.y-.5)*(u_ia/ca)+.5;} else {iuv.x=(uv.x-.5)*(ca/u_ia)+.5;}
    iuv=(iuv-.5)*1.12+.5+vec2(.035,.0);
    vec3 c=texture2D(u_img,vec2(iuv.x,1.-iuv.y)).rgb;
    float lum=dot(c,vec3(.299,.587,.114));
    lum=clamp((lum-.36)*1.85+.5,0.,1.);
    v=lum+(fbm(p*2.4+q*.7+vec2(0.,t*.5))-.5)*.09*smoothstep(.02,.3,lum);
  }
  vec2 m=u_p; m.x*=u_res.x/u_res.y;
  float d=distance(p,m);
  v-=.5*exp(-d*d*11.0)*(u_has>.5?.34:1.0);
  v=clamp(v,0.,1.);
  float th=dither8(frag/u_px);
  float ink=step(th,v)*step(.012,v);
  ink=mix(ink,1.-ink,u_inv);
  gl_FragColor=vec4(vec3(1.-ink),1.);
}`;

    get maxDPR() { return 2; }
    get usesPointer() { return true; }
    get pointerHome() { return [0.5, 1.35]; }
    get toggleAttr() { return 'data-hatch-toggle'; }

    onInit() { this._has = 0; this._ia = 1; this._loadSrc(); }
    beforeFrame() { if (this.getAttribute('src') !== this._srcTried) this._loadSrc(); }
    extraUniforms(gl, u) {
      gl.uniform1i(u.u_img, 0);
      gl.uniform1f(u.u_has, this._has || 0);
      gl.uniform1f(u.u_ia, this._ia || 1);
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
  }

  // ── <dither-field> — ambient domain-warped plate-mark for the contact band ──
  // A slow marbled fbm, edge-weighted so coverage hugs the band's frame and stays
  // sparse through the centre. Content sits on solid-ink knockouts (styles.css),
  // so text never rides the dither — mandatory since opacity/scrim is banned.
  class DitherField extends Field1Bit {
    static STATIC_T = 5.0; // the fixed frame this plate holds
    static UNIFORMS = ['u_res', 'u_t', 'u_inv', 'u_px'];
    static FRAG = `
uniform vec2 u_res;uniform float u_t;uniform float u_inv;uniform float u_px;
void main(){
  vec2 frag=gl_FragCoord.xy;
  vec2 uv=frag/u_res;
  vec2 p=vec2(uv.x*(u_res.x/u_res.y),uv.y);
  float t=u_t*.03;                                  // slow, seconds-scale drift
  vec2 q=vec2(fbm(p*1.3+vec2(t,1.3)),fbm(p*1.3+vec2(-t,5.2)));
  float f=fbm(p*1.7+q*1.0+vec2(0.,t*.5));            // marbled scalar field
  // Plate-mark framing: dither hugs the top/bottom frame (and far L/R corners),
  // fading to open black through the centre band where the copy sits — echoing
  // the hero's wash. Solid knockouts (styles.css) keep copy legible regardless.
  float edge=smoothstep(0.30,1.0,abs(uv.y-.5)*2.0);
  edge=max(edge,smoothstep(0.86,1.0,abs(uv.x-.5)*2.0));
  float v=clamp((f-0.42)*1.55*edge,0.,1.);          // subtract -> sparse speckle
  float th=dither8(frag/u_px);
  float m=step(th,v)*step(.02,v);                   // m=1 -> white mark
  m=mix(m,1.-m,u_inv);
  gl_FragColor=vec4(vec3(m),1.);
}`;

    get maxDPR() { return 2; }
    get animated() { return false; } // a static printed plate; the hero owns the page's motion
  }

  customElements.define('hatch-field', HatchField);
  customElements.define('dither-field', DitherField);
})();
