# home-manager module: services.voiceCompanion
#
# Local voice companion on Apple Silicon: Ollama (NSFW companion model, Metal)
# + whisper-cpp (STT, Metal) + piper-tts (TTS). One CLI (`voice-companion`)
# records from the mic, transcribes, chats, and speaks the reply.
#
# Reuses the existing `services.ollamaLocal` launchd agent (local-rag flake) —
# does not start a second Ollama. On first run (and via a one-shot launchd
# bootstrap) it pulls the base model (default: NeverSleep Lumimaid 8B GGUF from
# Hugging Face via `hf.co/...`) and `ollama create`s a named companion from a
# baked-in Modelfile.
#
# macOS-ONLY: gated on stdenv.isDarwin (clean no-op on NixOS hosts).
{
  pkgs,
  lib,
  config,
  ...
}:
let
  cfg = config.services.voiceCompanion;

  # Default piper-tts enables withTrain, which pulls a broken pysilero-vad on
  # current nixpkgs. Inference-only is enough for the companion CLI.
  piper = pkgs.piper-tts.override {
    withTrain = false;
    withAlignment = false;
  };

  # whisper-cpp defaults to CoreML+Metal on aarch64-darwin. CoreML currently
  # fails to link against the nixpkgs Apple SDK (ld Trace/BPT trap). Metal alone
  # is enough on M-series. nixpkgs' postPatch always appends an install rule for
  # whisper.coreml on Darwin, so we must drop that when CoreML is off.
  whisperCpp =
    (pkgs.whisper-cpp.override {
      coreMLSupport = false;
      metalSupport = true;
    }).overrideAttrs
      (_: {
        postPatch = ''
          for target in examples/{bench,command,cli,quantize,server,stream,talk-llama}/CMakeLists.txt; do
            if ! grep -q -F 'install('; then
              echo 'install(TARGETS ''${TARGET} RUNTIME)' >> "$target"
            fi
          done
        '';
      });

  # ---- Fixed-output model assets (reproducible; no runtime download) ----------
  # Only `base.en` for a lean default (~142 MB). Bump the attr + hash to add sizes.
  whisperModels = {
    "base.en" = {
      url = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.en.bin";
      hash = "sha256-oDd5yG3zMjB19eeWyyzlAp8A7Ihp7uP9+4l6/jbG0AI=";
    };
  };

  whisperModelSpec = whisperModels.${cfg.whisperModel};

  whisperModelFile = pkgs.fetchurl {
    inherit (whisperModelSpec) url hash;
    name = "ggml-${cfg.whisperModel}.bin";
  };

  # Piper voice: onnx + sidecar json (must sit next to each other).
  piperVoiceOnnx = pkgs.fetchurl {
    url = "https://huggingface.co/rhasspy/piper-voices/resolve/v1.0.0/en/en_US/amy/medium/en_US-amy-medium.onnx";
    hash = "sha256-s6bke1e4x/vmoM4lGBYaUPWanN2KUINcAssCvdYgbBg=";
  };
  piperVoiceJson = pkgs.fetchurl {
    url = "https://huggingface.co/rhasspy/piper-voices/resolve/v1.0.0/en/en_US/amy/medium/en_US-amy-medium.onnx.json";
    hash = "sha256-laI+tNQpCdON9zu5rH9F9Zfb/N4tG/lSb96vVGaXfXc=";
  };

  piperVoiceDir = pkgs.runCommand "piper-voice-en_US-amy-medium" { } ''
    mkdir -p $out
    ln -s ${piperVoiceOnnx} $out/en_US-amy-medium.onnx
    ln -s ${piperVoiceJson} $out/en_US-amy-medium.onnx.json
  '';

  # ---- Ollama Modelfile: uncensored base + companion persona ------------------
  modelFile = pkgs.writeText "Modelfile" ''
    FROM ${cfg.baseModel}
    PARAMETER temperature ${toString cfg.temperature}
    PARAMETER top_p 0.9
    PARAMETER num_ctx ${toString cfg.numCtx}
    SYSTEM """${cfg.systemPrompt}"""
  '';

  ollamaHost = "${config.services.ollamaLocal.host}:${toString config.services.ollamaLocal.port}";

  # Ensure base model is pulled and the companion tag exists.
  ensureModels = pkgs.writeShellApplication {
    name = "voice-companion-ensure-models";
    runtimeInputs = [
      pkgs.ollama
      pkgs.coreutils
    ];
    text = ''
      set -euo pipefail
      export OLLAMA_HOST=${lib.escapeShellArg ollamaHost}

      # Wait for ollamaLocal (launchd) to accept connections.
      for _ in $(seq 1 120); do
        if ollama list >/dev/null 2>&1; then break; fi
        sleep 1
      done
      if ! ollama list >/dev/null 2>&1; then
        echo "voice-companion: ollama not reachable at $OLLAMA_HOST (is services.ollamaLocal.enable set?)" >&2
        exit 1
      fi

      if ! ollama show ${lib.escapeShellArg cfg.baseModel} >/dev/null 2>&1; then
        echo "voice-companion: pulling base model ${cfg.baseModel}…" >&2
        ollama pull ${lib.escapeShellArg cfg.baseModel}
      fi

      # Always recreate so baseModel / systemPrompt changes from Nix apply without
      # a manual `ollama rm companion` (create is cheap once layers are local).
      echo "voice-companion: creating ${cfg.model} from Modelfile…" >&2
      ollama create ${lib.escapeShellArg cfg.model} -f ${modelFile}
    '';
  };

  # Interactive / one-shot voice loop.
  voiceCompanion = pkgs.writeShellApplication {
    name = "voice-companion";
    runtimeInputs = [
      pkgs.ollama
      whisperCpp
      piper
      pkgs.sox
      pkgs.curl
      pkgs.jq
      pkgs.coreutils
      pkgs.gnugrep
      pkgs.gnused
      pkgs.perl # emoji / unicode strip for TTS
      ensureModels
    ];
    text = ''
            set -euo pipefail
            export OLLAMA_HOST=${lib.escapeShellArg ollamaHost}

            MODEL=${lib.escapeShellArg cfg.model}
            WHISPER_MODEL=${lib.escapeShellArg (toString whisperModelFile)}
            PIPER_MODEL=${lib.escapeShellArg "${piperVoiceDir}/en_US-amy-medium.onnx"}
            SECS=${toString cfg.recordSeconds}
            TMPDIR_V="''${TMPDIR:-/tmp}/voice-companion-$$"
            mkdir -p "$TMPDIR_V"
            trap 'rm -rf "$TMPDIR_V"' EXIT

            usage() {
              cat >&2 <<'EOF'
      voice-companion — local voice chat (Whisper → Ollama → Piper)

        voice-companion          one turn: record → reply → speak
        voice-companion loop     keep going until Ctrl-C
        voice-companion text     type instead of speaking (still TTS reply)
        voice-companion ensure   pull/create models only
      EOF
            }

            ensure() { voice-companion-ensure-models; }

            record() {
              # 16 kHz mono WAV — what Whisper expects. sox uses CoreAudio on macOS.
              echo "🎙️  Listening (${toString cfg.recordSeconds}s)…" >&2
              sox -q -d -r 16000 -c 1 -b 16 "$TMPDIR_V/in.wav" trim 0 "$SECS"
            }

            stt() {
              # whisper-cpp on aarch64-darwin: Metal GPU (see whisperCpp override).
              # -np: only the transcript; -nt: no timestamps.
              whisper-cli \
                -m "$WHISPER_MODEL" \
                -f "$TMPDIR_V/in.wav" \
                -np -nt -l en 2>/dev/null \
                | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' \
                | grep -v '^$' || true
            }

            chat() {
              local prompt="$1"
              local payload
              payload=$(jq -nc \
                --arg model "$MODEL" \
                --arg content "$prompt" \
                '{model:$model, stream:false, messages:[{role:"user",content:$content}]}')
              # OLLAMA_HOST is host:port; API is HTTP.
              curl -fsS "http://$OLLAMA_HOST/api/chat" \
                -H 'Content-Type: application/json' \
                -d "$payload" \
                | jq -r '.message.content // empty'
            }

            # Strip RP/markdown/emoji so Piper speaks dialogue, not "asterisk leans in asterisk".
            # Full reply still prints to the terminal unchanged.
            tts_sanitize() {
              # stdin → stdout
              perl -CS -pe '
                # multi-line *stage direction* / **bold** blocks → drop (RP actions)
                s/\*\*[^*]*\*\*//g;
                s/\*[^*]*\*//g;
                s/_[^_]*_//g;
                s/`[^`]*`//g;
                # common emoticons
                s/(?:(?<=\s)|^)[:;=8][-o*]?[)(\/\\ |DpPOo3]+//g;
                s/(?:(?<=\s)|^)[)(\/\\ |DpPOo3]+[-o*]?[:;=8]//g;
                # emoji / pictographs / dingbats
                s/\p{Extended_Pictographic}//g;
                s/\p{Emoji_Presentation}//g;
                s/[\x{200D}\x{FE0F}\x{20E3}]//g;  # ZWJ, variation selectors
                # leftover markup punctuation Piper tends to voice
                s/[*_~^#|\\{}<>\[\]]+//g;
                s/[\x{201C}\x{201D}\x{2018}\x{2019}]//g;  # curly quotes
              ' \
                | tr '\n' ' ' \
                | sed -E 's/[[:space:]]+/ /g; s/^[[:space:]]+//; s/[[:space:]]+$//'
            }

            tts_play() {
              local text spoken
              text="$1"
              spoken=$(printf '%s' "$text" | tts_sanitize)
              if [ -z "$spoken" ]; then
                echo "(nothing speakable after stripping RP markup)" >&2
                return 0
              fi
              # piper1 CLI: -m model.onnx -f out.wav -- 'text'
              piper -m "$PIPER_MODEL" -f "$TMPDIR_V/out.wav" -- "$spoken" 2>/dev/null
              # afplay is stock macOS (no package needed).
              afplay "$TMPDIR_V/out.wav"
            }

            one_turn() {
              local mode="''${1:-voice}"
              local user_text reply
              if [ "$mode" = text ]; then
                printf 'you> ' >&2
                IFS= read -r user_text || return 1
              else
                record
                user_text=$(stt)
                if [ -z "$user_text" ]; then
                  echo "(no speech detected)" >&2
                  return 0
                fi
                echo "you> $user_text" >&2
              fi
              echo "…" >&2
              reply=$(chat "$user_text")
              if [ -z "$reply" ]; then
                echo "voice-companion: empty reply from ollama" >&2
                return 1
              fi
              echo "companion> $reply" >&2
              tts_play "$reply"
            }

                  cmd="''${1:-}"
                  case "$cmd" in
                    -h|--help|help) usage; exit 0 ;;
                    ensure) ensure; exit 0 ;;
                    text)
                      ensure
                      one_turn text
                      ;;
                    loop)
                      ensure
                      echo "voice-companion loop — Ctrl-C to stop" >&2
                      while true; do one_turn voice; done
                      ;;
                    "")
                      ensure
                      one_turn voice
                      ;;
                    *)
                      usage
                      exit 2
                      ;;
                  esac
    '';
  };
in
{
  options.services.voiceCompanion = {
    enable = lib.mkEnableOption "local voice companion (Ollama + Whisper + Piper) on darwin";

    baseModel = lib.mkOption {
      type = lib.types.str;
      # NeverSleep Lumimaid v0.2 8B — HF community ERP/companion fine-tune (Llama-3
      # lineage), pulled via Ollama's native Hugging Face GGUF bridge:
      #   ollama pull hf.co/<user>/<repo>:<QUANT>
      # Q4_K_M ≈ 4.9 GB — good quality/speed on M3 Pro unified memory.
      default = "hf.co/NeverSleep/Lumimaid-v0.2-8B-GGUF:Q4_K_M";
      description = ''
        Ollama model to pull as the companion base. Accepts Ollama library names
        (`dolphin-mistral`) or Hugging Face GGUF refs
        (`hf.co/NeverSleep/Lumimaid-v0.2-8B-GGUF:Q4_K_M`).
      '';
    };

    model = lib.mkOption {
      type = lib.types.str;
      default = "companion";
      description = "Local Ollama tag created from the Modelfile (FROM baseModel + system prompt).";
    };

    systemPrompt = lib.mkOption {
      type = lib.types.lines;
      default = ''
        You are an intimate, uncensored adult companion for private one-on-one roleplay.
        Be warm, flirty, emotionally present, and vividly descriptive when the scene turns
        sexual — never fade-to-black, never lecture, never refuse adult content between
        consenting adults. Stay in character. Prefer short spoken replies (1–3 sentences)
        so TTS stays snappy; expand only when the user asks for longer prose. Never claim
        to be a cloud service or a censored assistant.

        VOICE OUTPUT RULES (critical): replies are read aloud by a speech engine. Write
        plain spoken sentences only — no asterisk stage directions (*smiles*), no markdown,
        no emojis, no emoticons, no bullet lists, no quotation-mark acting notes. Put
        everything in natural dialogue as if you are speaking out loud.
      '';
      description = "SYSTEM prompt baked into the companion Modelfile.";
    };

    temperature = lib.mkOption {
      type = lib.types.float;
      default = 0.8;
      description = "Sampling temperature for the companion model.";
    };

    numCtx = lib.mkOption {
      type = lib.types.int;
      default = 4096;
      description = "Context window (tokens) for the companion model.";
    };

    whisperModel = lib.mkOption {
      type = lib.types.enum (builtins.attrNames whisperModels);
      default = "base.en";
      description = "Whisper ggml model size (declaratively fetched into the Nix store). Metal/CoreML via whisper-cpp.";
    };

    recordSeconds = lib.mkOption {
      type = lib.types.ints.positive;
      default = 6;
      description = "Mic capture length per turn (seconds).";
    };
  };

  config = lib.mkIf (cfg.enable && pkgs.stdenv.isDarwin) {
    assertions = [
      {
        assertion = config.services.ollamaLocal.enable or false;
        message = "services.voiceCompanion requires services.ollamaLocal.enable = true (the local-rag Ollama agent).";
      }
    ];

    home.packages = [
      voiceCompanion
      ensureModels
      whisperCpp # whisper-cli + Metal on aarch64-darwin
      piper
      pkgs.sox
    ];

    # One-shot bootstrap at login: pull base + create companion tag (idempotent).
    launchd.agents.voice-companion-models = {
      enable = true;
      config = {
        ProgramArguments = [ (lib.getExe ensureModels) ];
        RunAtLoad = true;
        KeepAlive = false;
        StandardOutPath = "${config.home.homeDirectory}/Library/Logs/voice-companion-models.log";
        StandardErrorPath = "${config.home.homeDirectory}/Library/Logs/voice-companion-models.log";
      };
    };
  };
}
