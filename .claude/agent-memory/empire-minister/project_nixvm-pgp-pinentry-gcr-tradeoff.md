---
name: nixvm-pgp-pinentry-gcr-tradeoff
description: SHIPPED 2026-10-06 (5fa443e) as gpa + gpg-agent + XFCE's default pinentry-gnome3; gcr-3 is back ON PURPOSE. pinentry-gtk2 is a throwing alias stub, and gpa/seahorse both carry avahi+openldap.
metadata:
  type: project
---

**Status: SHIPPED** in `5fa443e` as `gpa` + `programs.gnupg.agent.enable = true` and **no
`pinentryPackage` assignment** — `xfce.nix:169`'s `mkDefault pkgs.pinentry-gnome3` already
resolves here (verified: `pinentryPackage.pname`, and the rendered `pinentry-program` points
into `pinentry-gnome3-1.3.2`). The original brief specified `pinentry-gtk2`, which does not
exist; that instruction was dropped.

**`gcr-3` IS BACK, DELIBERATELY. Do not remove it.** It left with gnome-keyring because the
keyring DAEMON produced a dialog the passwordless account could not answer. A GPG passphrase
prompt has a **valid answer** — the credential the operator sets at key generation — so it fails
the credential-prompt-class test in [[nixvm-autologin-locker-lockout-trap]] and stays. `gcr-4`
was already present and is unrelated. Closure delta measured: **1535 -> 1544 paths**
(`gpa-0.11.0`, `gnupg-2.4.9` + 3 doc outputs, `pinentry-gnome3-1.3.2`, `gcr-3.41.2`,
`libsecret-0.21.7`).

## `pinentry-gtk2` does not exist at this pin

The attribute **is** in `attrNames` (so a grep for it "finds" it) but **throws** on eval:

```
error: 'pinentry-gtk2' has been removed as it depended on the deprecated GTK2 engine,
       use pinentry-gnome3 instead.
```

Same shape as `tor-browser-bundle-bin` — an alias removal stub. `pkgs.pinentry` itself also
throws ("Pick an appropriate variant"). **A probe that lists attribute names is not evidence a
package exists**; force the value.

## Every GUI flavour costs something. Measured closures, aarch64-linux:

| attr | paths | gcr-3 | qtbase | GUI prompt? |
|---|---|---|---|---|
| `pinentry-gnome3` | 129 | **1** | 0 | yes |
| `pinentry-qt` | 181 | 0 | **2** | yes |
| `pinentry-egui` | **22** | 0 | 0 | yes (Rust/egui) |
| `pinentry-curses` | 15 | 0 | 0 | **no** — needs a tty |
| `pinentry-tty` | 14 | 0 | 0 | **no** |

`pinentry-gnome3` is what `xfce.nix:169` sets (`mkDefault pkgs.pinentry-gnome3`), and it pulls
**`gcr-3.41.2` + `libsecret`** — i.e. it undoes part of the gnome-keyring removal
([[nixvm-autologin-locker-lockout-trap]]). Note `gcr-4` is **already** in the closure (count 1)
and is unrelated; the regression test is specifically **gcr-3**.

`pinentry-egui` is the only measured option that is GUI-capable, gcr-free and Qt-free, at 22
paths. **Untested here** — nobody has confirmed it renders under XFCE.

## The brief's rationale for `gpa` is partly WRONG — measured

`gpa`'s own closure is **126 paths** and contains **`avahi-0.8` and `openldap-2.6.13`**, which
the brief attributed to `seahorse` as the reason to reject it. gpa does carry the stated
`gtk+3`, `gpgme-2.1.2`, `libassuan-3.0.2`, `libgpg-error-1.61` — but it is not avahi/LDAP-free.
Do not repeat the "gpa avoids the keyserver deps" claim; it does not.

## Facts that DID hold

- `programs.gnupg.agent.pinentryPackage` is the right option (`programs/gnupg.nix:71`), default
  `pkgs.pinentry-curses`, and the module's whole `config` is `mkIf cfg.agent.enable` (`:106`) —
  so pinentry's absence from the closure today was never a broken dependency. `agent.enable`
  evaluates **false**.
- `gnupg.nix:211` explains the gnome3 cost: `services.dbus.packages` is added
  `mkIf (lib.elem "gnome3" (cfg.agent.pinentryPackage.flavors or []))`.
- SSH→PGP conversion remains impossible at this pin; a fresh keypair is generated in the guest
  and the operator's SSH key is not involved.

## Decision taken: gnome3, and gpa kept

`seahorse` measured the same way for the comparison the brief got wrong:

| | paths | carries |
|---|---|---|
| `gpa` | **126** | avahi 1, openldap 1, gtk+3 1 |
| `seahorse` | **145** | avahi 1, openldap 1, gtk+3 1, **libsecret 1** |

Both carry avahi + openldap, so "seahorse is the heavy one because of keyserver deps" is false.
`gpa` kept on two measured grounds: 19 fewer paths, and it is **not a libsecret front-end** —
browsing the Secret Service is half of seahorse's reason to exist and is dead here with
gnome-keyring off. `kleopatra` stays rejected and that one is genuinely heavy (KF6/Qt6 +
akonadi, which defaults to MariaDB).

**Instrument trap, mine:** `grep -c -- "-gcr-3-"` returned **0** while `gcr-3.41.2` was in the
closure — the store path has no trailing dash after the version-leading `3`. The pattern must be
`-gcr-3` (no trailing delimiter). A zero from a name-grep is worth cross-checking against the
printed list.

`~/.gnupg` would live on the durable **unencrypted** qcow2 and dies with a wipe — any key must
be exported by the operator.

## Boot-verified 2026-10-06, and ONE MORE INSTRUMENT TRAP

`gpg (GnuPG) 2.4.9`; `gpa`, `gpg`, `gpgconf` all on PATH; and the authoritative proof that the
override took — **`/etc/gnupg/gpg-agent.conf`**:

```
pinentry-program /nix/store/xsb5y8z8f5ky6qy8r2s189q8bpybiqdf-pinentry-gnome3-1.3.2/bin/pinentry
```

**`gpgconf --list-components` IS THE WRONG INSTRUMENT.** Its pinentry line reads
`pinentry:Passphrase Entry:/nix/store/…-gnupg-2.4.9/bin/pinentry` — gnupg's **compiled-in
default**, not the configured program. That path **does not even exist on disk** (`ls` → No such
file). Reading it as the answer would have reported the wrong pinentry. Read
`/etc/gnupg/gpg-agent.conf` instead (there is no `~/.gnupg/gpg-agent.conf`).

Deliberately NOT run, and do not run them in a verification pass: `gpg --clearsign`,
`--full-generate-key`, or anything else that opens a **blocking modal passphrase dialog** on the
operator's screen. Checking the binaries and the conf file is sufficient.
